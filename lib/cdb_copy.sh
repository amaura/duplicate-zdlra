#!/usr/bin/env bash
# CDB-only workflow. Sourced by dup_db.sh; no work on source/import.
# shellcheck disable=SC2015,SC2016,SC2153
CDB_FILE_TOOL=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cdb_files.py

cdb_warn() {
    log 'CDB COPY: all existing target physical standbys require recreation by the separate script. No standby connections or management are performed. Final original settings may reactivate Broker/transport.'
}
cdb_state() {
    CUTOVER=$1
    printf '%s\n' "$CUTOVER" > "$RUN/cutover"
    log "CDB transition: $CUTOVER."
}
cdb_finish() {
    local rc=$1
    log "CDB copy exit=$rc; last verified phase=$PHASE; transition=$CUTOVER; evidence=$RUN; private recovery material=${CDB_WORK:-not-created}."
    cdb_warn
    if ((rc)); then
        if [[ ${CDB_RELEASE_ATTEMPTED:-0} == 1 ]]; then
            local svc enabled running pdb
            while IFS='|' read -r svc enabled running pdb; do
                (srv "$RUN/service.$svc.failure-disable" disable service -db "$DB_UNIQUE_NAME" -service "$svc") || log "Could not disable $svc after release failure; manual intervention required."
                (srv "$RUN/service.$svc.failure-stop" stop service -db "$DB_UNIQUE_NAME" -service "$svc" -stopoption IMMEDIATE -force) || log "Could not stop $svc after release failure; manual intervention required."
            done < "$RUN/services.tsv"
        fi
        log 'Services are never released by failure cleanup. Inspect per-file deletion.results and wallet/controlfile transitions before manual recovery; retain all newly restored files.'
        if [[ -e $RUN/deletion.started ]]; then
            log 'Old-file deletion was attempted: the former target may be unusable. No automatic rollback. Recovery needs an independent usable database backup; retained configuration/controlfiles/wallets do not preserve deleted data.'
        else
            log 'No old database-file deletion was attempted. Inspect captured resource/wallet states before any manual restart.'
        fi
    fi
    [[ -z ${LOCK:-} ]] || { rm -f "$LOCK/owner"; rmdir "$LOCK"; }
    exit "$rc"
}

cdb_file() {
    local action=$1 out=$2; shift 2
    if ! python3 "$CDB_FILE_TOOL" "$action" home "$ORACLE_HOME" "$@" > "$out" 2> "$out.error"; then
        redact < "$out.error" | tee -a "$LOG" >&2
        die "CDB private file operation failed ($action); secret contents suppressed."
    fi
    rm -f "$out.error"
}
cdb_registered() {
    local field=$1 file=$2
    RESULT=$(sed -n "s/^$field: *//p" "$file")
    [[ -n $RESULT && $RESULT != *$'\n'* ]] || die "Cannot establish registered $field."
}
cdb_dbconfig() { srv "$1" config database -db "$DB_UNIQUE_NAME" -verbose; }
cdb_resource() {
    local stage=$1 expected=$2
    cdb_file resource "$RUN/database-resource.$stage.json" name "ora.${DB_UNIQUE_NAME,,}.db"
    python3 - "$RUN/database-resource.$stage.json" "$expected" "$RUN/database-resource.before.json" <<'PYRESOURCE' || die 'Database resource enablement/configuration mismatch.'
import json,sys
from pathlib import Path
current=json.loads(Path(sys.argv[1]).read_text())
before=json.loads(Path(sys.argv[3]).read_text())
sys.exit(0 if current['enabled']==int(sys.argv[2]) and current['configuration_sha256']==before['configuration_sha256'] else 1)
PYRESOURCE
}
cdb_config_paths() {
    cdb_registered 'Oracle home' "$RUN/database.before"
    [[ $RESULT == "$ORACLE_HOME" ]] || die 'Registered Oracle home differs from environment.'
    local registered_instances
    registered_instances=$(sed -n 's/^Database instances: *//p' "$RUN/database.before")
    [[ -n $registered_instances ]] || die 'Configured RAC instance inventory is missing.'
    printf '%s\n' "$registered_instances" | tr ',' '\n' | sort > "$RUN/registered-instances"
    cut -d'|' -f1 "$TARGET_RAC_FILE" | sort > "$RUN/runtime-instances"
    cmp -s "$RUN/registered-instances" "$RUN/runtime-instances" || die 'Configured and online RAC instance sets differ.'
    grep -Fxq 'Type: RAC' "$RUN/database.before" && grep -Fxq 'Database is administrator managed' "$RUN/database.before" || die 'CDB mode requires administrator-managed RAC.'
    cdb_resource before 1
    [[ $(grep -c '^Spfile:' "$RUN/database.before") == 1 ]] || die 'Unresolved parameter registration.'
    CDB_PARAM=$(sed -n 's/^Spfile: *//p' "$RUN/database.before")
    CDB_PARAM_KIND=SPFILE CDB_PARAM_VALUE=$CDB_PARAM
    if [[ -z $CDB_PARAM ]]; then
        CDB_PARAM_KIND=PFILE CDB_PARAM_VALUE='<NULL>'
        CDB_PARAM="$ORACLE_HOME/dbs/init$TARGET_SID.ora"
    fi
    cdb_registered 'Password file' "$RUN/database.before"; CDB_PASSWORD=$RESULT
    # Unregistered PFILE configurations require default-path and startup-alert
    # evidence independently on each node; never guess a custom startup path.
    [[ $CDB_PARAM == +* ]] || safe_path "$CDB_PARAM" || die 'Unsafe registered parameter path.'
    [[ $CDB_PASSWORD == +* ]] || safe_path "$CDB_PASSWORD" || die 'Unsafe password-file path.'
    sql "$TARGET_SID" "$RUN/config-paths.out" <<'SQL'
select nvl(value,'<NULL>') from v$parameter where name='spfile';
select file_name from v$passwordfile_info;
select name from v$controlfile order by name;
SQL
    mapfile -t CDB_PATHS < "$RUN/config-paths.out"
    ((${#CDB_PATHS[@]} >= 3)) && [[ ${CDB_PATHS[0]} == "$CDB_PARAM_VALUE" && ${CDB_PATHS[1]} == "$CDB_PASSWORD" ]] || die 'Runtime/registered parameter/password paths differ or are unresolved.'
    printf '%s\n' "${CDB_PATHS[@]:2}" > "$RUN/controls.paths"
    printf '%s\n' "$CDB_PARAM" "$CDB_PASSWORD" "${CDB_PATHS[@]:2}" > "$RUN/protected.paths"

}
cdb_inventory() {
    sql "$TARGET_SID" "$1" <<'SQL'
select kind||'|'||path||'|'||bytes from (
select 'DATA' kind,name path,bytes from v$datafile union all
select 'TEMP',name,bytes from v$tempfile union all
select 'REDO',f.member,l.bytes from v$logfile f join v$log l on l.group#=f.group# union all
select 'REDO',f.member,l.bytes from v$logfile f join v$standby_log l on l.group#=f.group#)
order by kind,path;
SQL
}
cdb_normalize_inventory() {
    cdb_file manifest "$2" rows_file "$1" protected_file "$RUN/protected.paths" excluded_file "$RUN/excluded.paths" unique "$DB_UNIQUE_NAME"
}
cdb_retained() {
    local stage=$1 inst host _state _version item kind source dest
    while IFS='|' read -r inst host _state _version; do
        for kind in PARAM PASSWORD; do
            source=$CDB_PARAM
            [[ $kind != PARAM || $CDB_PARAM_KIND != PFILE ]] || source="$ORACLE_HOME/dbs/init$inst.ora"
            [[ $kind != PASSWORD ]] || source=$CDB_PASSWORD
            dest="$CDB_WORK/retained_${inst}_${kind}_${stage}"
            cdb_file snapshot "$RUN/retained.$inst.$kind.$stage.json" host "$host" kind "$kind" source "$source" dest "$dest"
            if [[ $stage != before ]]; then
                cmp -s "$RUN/retained.$inst.$kind.before.json" "$RUN/retained.$inst.$kind.$stage.json" || die "Original $kind changed on $inst."
            fi
        done
        cdb_file startup-files "$RUN/startup-files.$inst.$stage.json" host "$host" sid "$inst" work "$CDB_WORK" stage "$stage"
        if [[ $stage == before && $inst == "$TARGET_SID" ]]; then
            python3 - "$RUN/startup-files.$inst.$stage.json" >> "$RUN/protected.paths" <<'PYSTARTUP'
import json,sys
for item in json.load(open(sys.argv[1])).values():
    if 'source' in item:
        print(item['source'])
PYSTARTUP
        fi
        if [[ $stage != before ]]; then
            cmp -s "$RUN/startup-files.$inst.before.json" "$RUN/startup-files.$inst.$stage.json" || die "Default startup files changed on $inst."
        fi
    done < "$TARGET_RAC_FILE"
}
cdb_node_prepare() {
    local inst host _state _version
    while IFS='|' read -r inst host _state _version; do
        sql "$inst" "$RUN/node.$inst.config" "$host" <<'SQL'
select 'IDENTITY|'||d.name||'|'||d.db_unique_name||'|'||d.dbid||'|'||d.database_role||'|'||i.instance_name from v$database d cross join v$instance i;
select 'SETTING|'||name||'|'||nvl(value,'<NULL>') from v$parameter where name in
('db_block_size','db_files','compatible','spfile','wallet_root','tde_configuration','instance_number','thread','undo_tablespace','cluster_database','job_queue_processes','aq_tm_processes','dg_broker_start','service_names','local_listener','remote_listener') or regexp_like(name,'^log_archive_dest(_state)?_([1-9]|[12][0-9]|3[01])$') order by name;
select 'PASSWORD|'||file_name from v$passwordfile_info;
select 'VERSION|'||version_full from v$instance;
select 'PATCH|'||patch_id||'|'||action||'|'||status from dba_registry_sqlpatch order by action_time,patch_id;
SQL
        grep -Fxiq "IDENTITY|$TARGET_CDB|$DB_UNIQUE_NAME|$TARGET_DBID|PRIMARY|$inst" "$RUN/node.$inst.config" &&
        grep -Fxq "SETTING|spfile|$CDB_PARAM_VALUE" "$RUN/node.$inst.config" &&
        grep -Fxq "PASSWORD|$CDB_PASSWORD" "$RUN/node.$inst.config" &&
        grep -Fxq "SETTING|wallet_root|$TARGET_WALLET" "$RUN/node.$inst.config" &&
        grep -Fxq 'SETTING|cluster_database|TRUE' "$RUN/node.$inst.config" || die "Node configuration mismatch on $inst."
        cdb_file probe "$RUN/node.$inst.paths.json" host "$host" parent "$CDB_WORK_PARENT" root "$TARGET_WALLET"
        cdb_file prepare "$RUN/node.$inst.work.json" host "$host" parent "$CDB_WORK_PARENT" name "${CDB_WORK##*/}"
        if [[ $CDB_PARAM_KIND == PFILE ]]; then
            cdb_file pfile-probe "$RUN/node.$inst.pfile.json" host "$host" sid "$inst"
            sql "$inst" "$RUN/node.$inst.pfile-source" "$host" <<'SQL'
select regexp_substr(message_text,'/[^[:space:]]+') from v$diag_alert_ext
where originating_timestamp >= (select startup_time from v$instance)
and message_text like 'Using parameter settings in server-side pfile %';
SQL
            one_line "$RUN/node.$inst.pfile-source"
            [[ $RESULT == "$ORACLE_HOME/dbs/init$inst.ora" ]] || die 'Original PFILE startup path cannot be verified against Clusterware default startup.'
        fi
    done < "$TARGET_RAC_FILE"
}
cdb_snapshot_services() {
    local svc cfg pdb enabled running item seen='|'
    srv "$RUN/services.all" config service -db "$DB_UNIQUE_NAME"
    : > "$RUN/services.tsv"
    while IFS= read -r svc; do
        [[ $svc =~ ^[A-Za-z][A-Za-z0-9_.-]*$ && $seen != *"|${svc^^}|"* ]] || die 'Unsupported/duplicate Clusterware service name.'
        seen+="${svc^^}|"
        cfg="$RUN/service.$svc.before"
        srv "$cfg" config service -db "$DB_UNIQUE_NAME" -service "$svc" -verbose
        grep -q '^Preferred instances:' "$cfg" && ! grep -Eqi '^Global: true|^Service is .* on ' "$cfg" || die "Unsupported service configuration $svc."
        pdb=$(sed -n 's/^Pluggable database name: *//p' "$cfg")
        [[ -z $pdb ]] || identifier "$pdb" 30 || die 'Unsafe service PDB association.'
        enabled=$(sed -nE 's/^Service is (enabled|disabled)\.?$/\1/p' "$cfg")
        [[ $enabled == enabled || $enabled == disabled ]] || die "Unknown service enablement $svc."
        srv "$RUN/service.$svc.status.before" status service -db "$DB_UNIQUE_NAME" -service "$svc" -force
        one_line "$RUN/service.$svc.status.before"
        if [[ $RESULT == "Service $svc is not running." || $RESULT == "Service $svc is not running" ]]; then
            running=-
        elif [[ $RESULT == "Service $svc is running on instance(s) "* ]]; then
            running=${RESULT#"Service $svc is running on instance(s) "}; running=${running%.}; running=${running// /}
            [[ $running =~ ^[A-Za-z][A-Za-z0-9_]*(,[A-Za-z][A-Za-z0-9_]*)*$ && $enabled == enabled ]] || die 'Unsupported running service state.'
            local -a members
            IFS=',' read -r -a members <<< "$running"
            for item in "${members[@]}"; do
                awk -F'|' -v i="$item" '$1==i {ok=1} END {exit !ok}' "$TARGET_RAC_FILE" || die 'Service runs outside verified RAC inventory.'
            done
        else die "Unknown service placement $svc."; fi
        printf '%s|%s|%s|%s\n' "$svc" "$enabled" "$running" "${pdb:--}" >> "$RUN/services.tsv"
    done < <(sed -n 's/^Service name: *//p' "$RUN/services.all")
    # Check that the unfiltered inventory parser did not silently skip output.
    [[ ! -s $RUN/services.all || -s $RUN/services.tsv ]] || die 'Unrecognized complete service inventory.'
}
cdb_services_frozen() {
    local svc enabled running pdb
    srv "$RUN/services.freeze" config service -db "$DB_UNIQUE_NAME"
    cmp -s "$RUN/services.all" "$RUN/services.freeze" || die 'Service resource inventory changed.'
    while IFS='|' read -r svc enabled running pdb; do
        srv "$RUN/service.$svc.freeze" config service -db "$DB_UNIQUE_NAME" -service "$svc" -verbose
        cmp -s "$RUN/service.$svc.before" "$RUN/service.$svc.freeze" || die 'Service resource changed.'
        srv "$RUN/service.$svc.status.freeze" status service -db "$DB_UNIQUE_NAME" -service "$svc" -force
        cmp -s "$RUN/service.$svc.status.before" "$RUN/service.$svc.status.freeze" || die 'Service running state changed.'
    done < "$RUN/services.tsv"
}
cdb_services_held() {
    local svc enabled running pdb
    while IFS='|' read -r svc enabled running pdb; do
        srv "$RUN/service.$svc.held" config service -db "$DB_UNIQUE_NAME" -service "$svc" -verbose
        grep -Eq '^Service is disabled\.?$' "$RUN/service.$svc.held" || die "Service $svc is not disabled."
        # Only the enablement line may differ while held.
        sed -E 's/^Service is (enabled|disabled)\.?$/Service is HELD/' "$RUN/service.$svc.before" > "$RUN/service.$svc.expected-held"
        sed -E 's/^Service is (enabled|disabled)\.?$/Service is HELD/' "$RUN/service.$svc.held" > "$RUN/service.$svc.actual-held"
        cmp -s "$RUN/service.$svc.expected-held" "$RUN/service.$svc.actual-held" || die "Service $svc attributes changed while held."
        srv "$RUN/service.$svc.status.held" status service -db "$DB_UNIQUE_NAME" -service "$svc" -force
        one_line "$RUN/service.$svc.status.held"
        [[ $RESULT == "Service $svc is not running." || $RESULT == "Service $svc is not running" ]] || die "Service $svc is running before readiness."
    done < "$RUN/services.tsv"
}
cdb_stop() {
    local svc enabled running pdb
    cdb_state stopping-resources
    while IFS='|' read -r svc enabled running pdb; do
        srv "$RUN/service.$svc.disable" disable service -db "$DB_UNIQUE_NAME" -service "$svc"
        [[ $running == - ]] || srv "$RUN/service.$svc.stop" stop service -db "$DB_UNIQUE_NAME" -service "$svc" -stopoption IMMEDIATE -force
    done < "$RUN/services.tsv"
    srv "$RUN/database.disable" disable database -db "$DB_UNIQUE_NAME"
    srv "$RUN/database.stop" stop database -db "$DB_UNIQUE_NAME" -stopoption IMMEDIATE
    cdb_stopped
    cdb_services_held
    cdb_state rac-stopped-disabled
}
cdb_stopped() {
    local inst host _state _version
    cdb_dbconfig "$RUN/database.held"
    cdb_resource held 0
    cmp -s "$RUN/database.before" "$RUN/database.held" || die 'Database resource drifted while held.'
    srv "$RUN/database.stopped" status database -db "$DB_UNIQUE_NAME"
    [[ $(wc -l < "$RUN/database.stopped") -eq 2 ]] || die 'Incomplete RAC stop evidence.'
    while IFS='|' read -r inst host _state _version; do
        grep -Fxq "Instance $inst is not running on node ${host%%.*}" "$RUN/database.stopped" ||
        grep -Fxq "Instance $inst is not running on node $host" "$RUN/database.stopped" || die "Instance $inst shutdown unconfirmed."
        # Independently rule out unmanaged processes on each node. The read-only
        # worker checks the OS process inventory even when Clusterware is down.
        cdb_file stopped "$RUN/node.$inst.stopped.json" host "$host" sid "$inst"
    done < "$TARGET_RAC_FILE"
}

cdb_catalog() {
    # The catalog is the only source connection. Capture active files at the
    # requested point, using creation SCN to disambiguate file-number reuse.
    local point predicate
    point="to_date('${RECOVERY_TIME:-9999-12-31 23:59:59}','YYYY-MM-DD HH24:MI:SS')"
    discover_credentials
    sql CATALOG "$RUN/source.out" <<SQL
select distinct d.db_key||'|'||d.dbid from rc_database d join rc_site s on s.db_key=d.db_key
where upper(d.name)='$SOURCE_CDB' and upper(s.db_unique_name)='$SOURCE_UNIQUE';
SQL
    one_line "$RUN/source.out"; IFS='|' read -r SOURCE_DBKEY SOURCE_DBID <<< "$RESULT"
    positive "$SOURCE_DBKEY" && [[ $SOURCE_DBID =~ ^[0-9]+$ && $SOURCE_DBID != "$TARGET_DBID" ]] || die 'Unsafe/ambiguous source identity.'
    predicate="status='CURRENT'"; [[ -z $RECOVERY_TIME ]] || predicate="resetlogs_time <= $point"
    sql CATALOG "$RUN/incarnation.out" <<SQL
select dbinc_key||'|'||resetlogs_change#||'|'||to_char(resetlogs_time,'YYYY-MM-DD HH24:MI:SS')
from rc_database_incarnation where db_key=$SOURCE_DBKEY and status in ('CURRENT','PARENT') and $predicate
and resetlogs_time=(select max(resetlogs_time) from rc_database_incarnation where db_key=$SOURCE_DBKEY and status in ('CURRENT','PARENT') and $predicate);
SQL
    one_line "$RUN/incarnation.out"; IFS='|' read -r SOURCE_INC SOURCE_RESET SOURCE_RESET_TIME <<< "$RESULT"
    log "Source DBID=$SOURCE_DBID incarnation=$SOURCE_INC resetlogs=$SOURCE_RESET_TIME."
    positive "$SOURCE_INC" && [[ $SOURCE_RESET =~ ^[0-9]+$ ]] || die 'Unknown source incarnation.'
    sql CATALOG "$RUN/source-files.out" <<SQL
select distinct f.file#||'|'||f.creation_change#||'|'||f.con_id||'|'||greatest(f.bytes,nvl(
(select max(b.datafile_blocks*b.block_size) from rc_backup_datafile b where b.db_key=f.db_key and b.dbinc_key=f.dbinc_key and b.file#=f.file# and b.creation_change#=f.creation_change# and b.status='A' and b.checkpoint_time < $point),0))||'|'||f.block_size||'|'||nvl(f.read_only,0)||'|'||nvl(f.stop_change#,0)||'|'||
(select count(*) from rc_backup_datafile b where b.db_key=f.db_key and b.dbinc_key=f.dbinc_key and b.file#=f.file# and b.creation_change#=f.creation_change#
and b.status='A' and b.datafile_blocks>0 and b.block_size=f.block_size and b.checkpoint_time < $point and (b.incremental_level is null or b.incremental_level=0)
and exists (select 1 from rc_backup_piece p where p.bs_key=b.bs_key and p.status='A' and p.device_type='SBT_TAPE'))
from rc_datafile f where f.db_key=$SOURCE_DBKEY and f.dbinc_key=$SOURCE_INC
and upper(f.db_unique_name)='$SOURCE_UNIQUE' and f.creation_time <= $point and (f.drop_time is null or f.drop_time > $point) order by 1;
SQL
    cdb_source_manifest
    sql CATALOG "$RUN/source-online-redo.out" <<SQL
select case when count(*)>0 and count(bytes)=count(*) and min(bytes)>0 then ceil(sum(bytes)/1048576) else -1 end||'|'||count(distinct thread#)||'|'||count(distinct group#) from (
select distinct l.thread#,l.group#,l.name,l.bytes from rc_redo_log l join rc_site s on s.site_key=l.site_key and s.db_key=l.db_key
where l.db_key=$SOURCE_DBKEY and l.dbinc_key=$SOURCE_INC and upper(s.db_unique_name)='$SOURCE_UNIQUE' and l.type='ONLINE');
SQL
    one_line "$RUN/source-online-redo.out"
    local redo_threads redo_groups
    IFS='|' read -r CDB_REDO_MB redo_threads redo_groups <<< "$RESULT"
    positive "$CDB_REDO_MB" && [[ $redo_threads == 2 ]] && positive "$redo_groups" && ((redo_groups >= 4)) || die 'Unknown source online redo recreation budget.'
    sql CATALOG "$RUN/redo-inventory.out" <<SQL
select thread#||'|'||min(sequence#)||'|'||max(sequence#)||'|'||to_char(max(next_time),'YYYY-MM-DD HH24:MI:SS')
from rc_backup_redolog r where db_key=$SOURCE_DBKEY and dbinc_key=$SOURCE_INC and status='A'
and exists (select 1 from rc_backup_piece p where p.bs_key=r.bs_key and p.status='A' and p.device_type='SBT_TAPE') group by thread# order by thread#;
SQL
    awk -F'|' 'NF!=4 || $1!~/^[1-9][0-9]*$/ || $2!~/^[0-9]+$/ || $3!~/^[0-9]+$/ {bad=1} {n++} END {exit (bad || n!=2)}' "$RUN/redo-inventory.out" || die 'Expected both source RAC redo threads.'
    dry_run_range
    sql CATALOG "$RUN/tempfiles.raw.out" <<SQL
select distinct file# from rc_tempfile where db_key=$SOURCE_DBKEY and dbinc_key=$SOURCE_INC
and creation_time <= $point and (drop_time is null or drop_time > $point) order by file#;
SQL
    normalize_tempfile_ids "$RUN/tempfiles.raw.out" "$RUN/tempfiles.normalized.out"
    sql CATALOG "$RUN/temp-size.out" <<SQL
select case when count(*)>0 and count(bytes)=count(*) and min(bytes)>0 then ceil(sum(bytes)/1048576) else -1 end from (select file#,max(bytes) bytes from rc_tempfile where db_key=$SOURCE_DBKEY and dbinc_key=$SOURCE_INC
and creation_time <= $point and (drop_time is null or drop_time > $point) group by file#);
SQL
    one_line "$RUN/temp-size.out"; positive "$RESULT" || die 'Unknown source tempfile size.'
    CDB_TEMP_MB=$RESULT
}
cdb_source_manifest() {
    python3 - "$RUN/source-files.out" "$RUN/source-files.expected" "$RUN/source-size" <<'PY' || die 'Unusable source file manifest; see catalog evidence.'
import sys
from pathlib import Path
rows = [line.strip().split('|') for line in Path(sys.argv[1]).read_text().splitlines() if line.strip()]
if not rows or any(len(r)!=8 or any(not x.isdecimal() for x in r) for r in rows):
    sys.exit('Incomplete source catalog file manifest')
rows = [list(map(int, r)) for r in rows]
if len({r[0] for r in rows})!=len(rows) or not {1,2}.issubset({r[2] for r in rows}):
    sys.exit('Ambiguous source files or missing root/seed')
if any(r[0]<1 or r[1]<1 or r[3]<1 or r[4] not in (2048,4096,8192,16384,32768) or r[5] not in (0,1) or r[7]<1 or (r[5]==0 and r[6]>0) for r in rows):
    sys.exit('Unsupported offline-clean source file or missing SBT full/level-0 backup')
with Path(sys.argv[2]).open('w') as out:
    for r in sorted(rows):
        out.write('%s|%s|%s\n' % tuple(r[:3]))
root = [r for r in rows if r[0]==1 and r[2]==1]
if len(root)!=1:
    sys.exit('Unknown source root block size')
Path(sys.argv[3]).write_text('%s|%s|%s\n' % ((sum(r[3] for r in rows)+1048575)//1048576, root[0][4], max(r[0] for r in rows)))
PY
    IFS='|' read -r SOURCE_MB BLOCK_SIZE CDB_MAX_FILE < "$RUN/source-size"
}
cdb_compatibility() {
    local inst host _state _version block files number thread undo seen='|' threads='|'
    while IFS='|' read -r inst host _state _version; do
        block=$(sed -n 's/^SETTING|db_block_size|//p' "$RUN/node.$inst.config")
        files=$(sed -n 's/^SETTING|db_files|//p' "$RUN/node.$inst.config")
        number=$(sed -n 's/^SETTING|instance_number|//p' "$RUN/node.$inst.config")
        thread=$(sed -n 's/^SETTING|thread|//p' "$RUN/node.$inst.config")
        undo=$(sed -n 's/^SETTING|undo_tablespace|//p' "$RUN/node.$inst.config")
        [[ $block == "$BLOCK_SIZE" ]] && positive "$files" && ((files >= CDB_MAX_FILE)) || die 'Retained DB_BLOCK_SIZE/DB_FILES cannot support source copy.'
        positive "$number" && positive "$thread" && identifier "$undo" 30 && [[ $seen != *"|$number|"* && $threads != *"|$thread|"* ]] || die 'Unsupported retained RAC instance/thread/undo mapping.'
        seen+="$number|"; threads+="$thread|"
        grep -q "^$thread|" "$RUN/redo-inventory.out" || die 'Source/retained RAC redo threads differ.'
        [[ $inst != "$TARGET_SID" ]] || { CDB_NUMBER=$number CDB_THREAD=$thread CDB_UNDO=$undo; }
        grep -E '^(PATCH|VERSION)\|' "$RUN/node.$inst.config" > "$RUN/version.$inst"
        grep -E '^(PATCH|VERSION)\|' "$RUN/node.$TARGET_SID.config" > "$RUN/version.expected"
        cmp -s "$RUN/version.expected" "$RUN/version.$inst" || die 'Target nodes differ in Oracle RU/SQL patch history.'
    done < "$TARGET_RAC_FILE"
}
cdb_capacity() {
    local stage=$1 group need result
    for group in "$AUX_DATA_DEST" "$AUX_RECO_DEST"; do
        cdb_file capacity "$RUN/capacity.${group#+}.$stage.json" group "$group"
        need=$DUP_REDO_RESERVE_MB
        if [[ $group == "$AUX_DATA_DEST" ]]; then need=$((SOURCE_MB + CDB_TEMP_MB + CDB_REDO_MB + (SOURCE_MB + CDB_TEMP_MB) / 4 + DUP_REDO_RESERVE_MB)); fi
        if [[ $AUX_RECO_DEST == "$AUX_DATA_DEST" ]]; then need=$((need + DUP_REDO_RESERVE_MB)); fi
        result=$(python3 - "$RUN/capacity.${group#+}.$stage.json" "$RUN/old-files.json" "$group" "$stage" "$need" <<'PY'
import json,sys
from pathlib import Path
cap=json.loads(Path(sys.argv[1]).read_text())['usable_mb']
files=json.loads(Path(sys.argv[2]).read_text())
# Logical ASM file bytes conservatively undercount allocation-unit rounding.
# Usable_file_MB already accounts for NORMAL/HIGH mirroring; never multiply it.
reclaim=sum(r['bytes']//1048576 for r in files if r['path'].upper().startswith(sys.argv[3].upper()+'/')) if sys.argv[4]=='before' else 0
print('usable_mb=%s verified_reclaim_mb=%s required_mb=%s' % (cap,reclaim,sys.argv[5]))
sys.exit(0 if cap+reclaim>=int(sys.argv[5]) else 1)
PY
) || die "Insufficient/unknown $stage capacity in $group (only exact manifest files count as reclaim)."
        log "CDB capacity $group $stage: $result."
        [[ $AUX_DATA_DEST != "$AUX_RECO_DEST" ]] || break
    done
}

cdb_delete_old() {
    [[ ${CDB_BACKUPS_READY:-0} == 1 && ${CDB_WALLET_READY:-0} == 1 && $DRY_RUN == 0 ]] || die 'Deletion requires verified backups, staged wallet and execution mode.'
    cdb_stopped
    cdb_services_held
    cdb_retained predelete
    cmp -s "$RUN/old-files.json" "$RUN/old-files.frozen.json" || die 'Frozen deletion manifest changed.'
    local count index=0 file
    count=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$RUN/old-files.frozen.json")
    : > "$RUN/deletion.results"
    cdb_state deleting-old-files
    while ((index < count)); do
        file=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[int(sys.argv[2])]["path"])' "$RUN/old-files.frozen.json" "$index")
        printf '%s|%s|ATTEMPTED-result-unknown\n' "$index" "$file" >> "$RUN/deletion.results"
        touch "$RUN/deletion.started"
        cdb_file delete "$RUN/deletion.$index.json" manifest_file "$RUN/old-files.frozen.json" index "$index" protected_file "$RUN/protected.paths"
        printf '%s|%s|DELETED\n' "$index" "$file" >> "$RUN/deletion.results"
        if ((index == 0)); then
            touch "$RUN/destructive-boundary"
            log 'DESTRUCTIVE BOUNDARY: first old database file deleted. Old target is unusable; no retained-datafile rollback.'
        fi
        ((index+=1))
    done
    printf '%s\n' "$count" > "$RUN/deletion.complete"
    cdb_state old-files-deleted
}
cdb_wallets() {
    local action=$1 inst host _state _version
    while IFS='|' read -r inst host _state _version; do
        printf '%s|%s|ATTEMPTED-result-unknown\n' "$inst" "$action" >> "$RUN/wallet.results"
        case $action in
            backup) cdb_file wallet-backup "$RUN/wallet.$inst.backup.json" host "$host" root "$TARGET_WALLET" work "$CDB_WORK/wallet_$inst" ;;
            install) cdb_file wallet-install "$RUN/wallet.$inst.install.json" host "$host" root "$TARGET_WALLET" work "$CDB_WORK/wallet_$inst" staged "$CDB_WORK/source-tde" ;;
            verify) cdb_file wallet-verify "$RUN/wallet.$inst.verify.json" host "$host" root "$TARGET_WALLET" inventory_file "$RUN/source-tde.inventory.json" ;;
        esac
        printf '%s|%s|VERIFIED\n' "$inst" "$action" >> "$RUN/wallet.results"
    done < "$TARGET_RAC_FILE"
}
cdb_build_pfile() {
    # The derived target settings file stays outside log/report packaging.
    sql "$TARGET_SID" "$RUN/pfile-export.out" <<SQL
create pfile='$CDB_WORK/target-memory.ora' from memory;
SQL
    cdb_file pfile "$RUN/pfile-derived.json" source "$CDB_WORK/target-memory.ora" dest "$CDB_WORK/init.ora" sid "$TARGET_SID" \
        db "$TARGET_CDB" unique "$DB_UNIQUE_NAME" root "$TARGET_WALLET" data "$AUX_DATA_DEST" reco "$AUX_RECO_DEST" \
        number "$CDB_NUMBER" thread "$CDB_THREAD" undo "$CDB_UNDO" controls_file "$RUN/controls.paths"
}
cdb_build_duplicate() {
    local channel tempfile
    [[ -s $RUN/tempfiles.normalized.out && -s $RUN/source-files.expected ]] || die 'Complete source manifests required for RMAN generation.'
    printf '%s\n' 'run {'
    for ((channel=1; channel<=DUP_RESTORE_PARALLELISM; channel++)); do
        cat <<EOF
  allocate auxiliary channel ra$channel device type sbt_tape
    parms "SBT_LIBRARY=$ORACLE_HOME/lib/libra.so, ENV=(RA_WALLET='location=file:$WALLET credential_alias=$RA_ALIAS')";
EOF
    done
    printf '%s\n' '  set newname for database to new;'
    while IFS= read -r tempfile; do
        [[ $tempfile =~ ^[1-9][0-9]*$ ]] || die 'Invalid tempfile number.'
        printf '  set newname for tempfile %s to new;\n' "$tempfile"
    done < "$RUN/tempfiles.normalized.out"
    printf "  duplicate database '%s' dbid %s to '%s'\n    pfile='%s/init.ora'\n" "$SOURCE_CDB" "$SOURCE_DBID" "$TARGET_CDB" "$CDB_WORK"
    [[ -z $RECOVERY_TIME ]] || printf '    until time "to_date('\''%s'\'','\''YYYY-MM-DD HH24:MI:SS'\'')"\n' "$RECOVERY_TIME"
    printf '%s\n' '    noopen;' '}'
}
cdb_start_controlled() {
    [[ -s $RUN/deletion.complete && ${CDB_WALLET_READY:-0} == 1 ]] || die 'Restore cannot start before deletion and wallet verification complete.'
    local rc=0
    cdb_state controlled-startup-attempted
    # sql() has an ALTER SESSION preamble and cannot address an idle instance.
    {
        printf '%s\n' 'whenever oserror exit failure' 'whenever sqlerror exit failure' 'connect / as sysdba'
        printf "startup nomount pfile='%s/init.ora';\nexit success\n" "$CDB_WORK"
    } | env "ORACLE_SID=$TARGET_SID" "$ORACLE_HOME/bin/sqlplus" -L -s /nolog 2>&1 | redact | tee "$RUN/controlled-startup.out" >> "$LOG" || rc=$?
    ((rc == 0)) && ! grep -Eq 'ORA-|SP2-|LRM-' "$RUN/controlled-startup.out" || die 'Controlled target NOMOUNT failed.'
}
cdb_coverage() {
    local stage=$1
    sql "$TARGET_SID" "$RUN/source-files.$stage" <<'SQL'
select file#||'|'||creation_change#||'|'||con_id from v$datafile order by file#;
SQL
    # Use numeric order, not locale or lexicographic order, for file numbers.
    sort -t'|' -k1,1n "$RUN/source-files.$stage" > "$RUN/source-files.$stage.sorted"
    cmp -s "$RUN/source-files.expected" "$RUN/source-files.$stage.sorted" || die 'Incomplete/changed source CDB file coverage (including offline/read-only omissions); manual file attachment is unsupported.'
}
cdb_file_mapping() {
    local stage=$1
    sql "$TARGET_SID" "$RUN/new-files.$stage" <<'SQL'
select 'DATA|'||name from v$datafile union all select 'TEMP|'||name from v$tempfile union all select 'REDO|'||member from v$logfile;
SQL
    python3 - "$RUN/new-files.$stage" "$RUN/old-files.frozen.json" "$AUX_DATA_DEST" "$DB_UNIQUE_NAME" "$stage" <<'PY' || die 'Unsafe or incomplete restored file mappings.'
import json,re,sys
from pathlib import Path
old={r['path'].upper() for r in json.loads(Path(sys.argv[2]).read_text())}
rows=[r.split('|') for r in Path(sys.argv[1]).read_text().splitlines()]
if not rows or any(len(r)!=2 or r[0] not in ('DATA','TEMP','REDO') for r in rows):
    sys.exit('Unknown new database file mapping')
namespace=(sys.argv[3]+'/'+sys.argv[4]+'/').upper()
for kind,name in rows:
    # NOOPEN may leave deferred tempfile entries at source names; never access
    # them. SET NEWNAME supplies new OMF names at first open, checked afterward.
    if kind in ('TEMP','REDO') and sys.argv[5]=='mounted' and (kind=='TEMP' or name.upper()==sys.argv[3].upper()):
        continue
    if not name.upper().startswith(namespace) or not re.search(r'\.[0-9]+\.[0-9]+$', name) or name.upper() in old:
        sys.exit('Non-OMF, old, source, or unexpected new file destination')
if sys.argv[5]!='mounted' and not all(any(k==kind for k,n in rows) for kind in ('DATA','TEMP','REDO')):
    sys.exit('Missing recreated data/redo/tempfile inventory')
PY
    if [[ $stage != mounted ]]; then
        sql "$TARGET_SID" "$RUN/tempfiles.$stage.raw" <<'SQL'
select file# from v$tempfile order by file#;
SQL
        normalize_tempfile_ids "$RUN/tempfiles.$stage.raw" "$RUN/tempfiles.$stage.ids"
        cmp -s "$RUN/tempfiles.normalized.out" "$RUN/tempfiles.$stage.ids" || die 'Recreated tempfile coverage differs from source catalog.'
    fi
}
cdb_validate_mounted() {
    cdb_coverage mounted
    cdb_file_mapping mounted
    sql "$TARGET_SID" "$RUN/redo-size.mounted" <<'SQL'
select ceil(nvl(sum(l.bytes),0)/1048576) from v$log l join v$logfile f on f.group#=l.group#;
SQL
    one_line "$RUN/redo-size.mounted"
    [[ $RESULT =~ ^[0-9]+$ ]] && ((RESULT > 0 && RESULT <= CDB_REDO_MB)) || die 'Restored redo definitions exceed the pre-deletion catalog budget; keep copy mounted.'
    sql "$TARGET_SID" "$RUN/recovery-point.out" <<SQL
select 'RECOVERED_CHECKPOINT_SCN|'||checkpoint_change# from v\$database;
select 'FILE|'||file#||'|'||checkpoint_change#||'|'||to_char(checkpoint_time,'YYYY-MM-DD HH24:MI:SS')||'|'||fuzzy||'|'||recover from v\$datafile_header order by file#;
select 'LAST_APPLIED_REDO|'||to_char(timestamp,'YYYY-MM-DD HH24:MI:SS')||'|'||comments from v\$recovery_progress where item='Last Applied Redo';
declare n number;
begin
 select count(*) into n from v\$database where name='$TARGET_CDB' and db_unique_name='$DB_UNIQUE_NAME' and dbid not in ($SOURCE_DBID,$TARGET_DBID) and cdb='YES' and open_mode='MOUNTED' and resetlogs_change#=$SOURCE_RESET;
 if n<>1 then raise_application_error(-20100,'Duplicate identity/incarnation mismatch'); end if;
 select count(*) into n from v\$parameter where
 (name='db_create_file_dest' and value='$AUX_DATA_DEST') or
 (name='db_create_online_log_dest_1' and value='$AUX_DATA_DEST') or
 (name='wallet_root' and value='$TARGET_WALLET') or
 (name='cluster_database' and value='FALSE') or
 (name='job_queue_processes' and value='0') or
 (name='dg_broker_start' and value='FALSE');
 if n<>6 then raise_application_error(-20114,'Controlled OMF/isolation settings lost'); end if;
 select count(*) into n from v\$parameter where value is not null and
 (name in ('db_file_name_convert','log_file_name_convert','remote_listener','listener_networks','dispatchers') or
 regexp_like(name,'^db_create_online_log_dest_[2-5]$'));
 if n>0 then raise_application_error(-20115,'Conflicting controlled file/listener settings'); end if;
 select count(*) into n from v\$datafile_header where error is not null or recover='YES' or fuzzy='YES';
 if n<>0 then raise_application_error(-20101,'Incomplete datafile recovery'); end if;
 select count(*) into n from v\$recover_file;
 if n<>0 then raise_application_error(-20102,'Files still require recovery'); end if;
 select count(*) into n from v\$datafile where status not in ('SYSTEM','ONLINE');
 if n<>0 then raise_application_error(-20103,'Unsupported offline source files'); end if;
end;
/
select 'THREAD|'||thread# from v\$thread order by thread#;
select name from v\$controlfile order by name;
SQL
    sql "$TARGET_SID" "$RUN/controls.mounted" <<'SQL'
select name from v$controlfile order by name;
SQL
    cmp -s "$RUN/controls.paths" "$RUN/controls.mounted" || die 'Controlfile locations differ from original configuration.'
    sql "$TARGET_SID" "$RUN/new-identity" <<'SQL'
select dbid from v$database;
SQL
    one_line "$RUN/new-identity"; CDB_NEW_DBID=$RESULT
    [[ $CDB_NEW_DBID =~ ^[0-9]+$ && $CDB_NEW_DBID != "$TARGET_DBID" && $CDB_NEW_DBID != "$SOURCE_DBID" ]] || die 'New DBID not established.'
    cdb_state source-controlfile-and-datafiles-verified
}
cdb_reconcile() {
    local pdb svc enabled running association
    sql "$TARGET_SID" "$RUN/restricted-open.out" <<'SQL'
alter system enable restricted session;
alter database open resetlogs;
alter pluggable database all open restricted;
select 'RESETLOGS_SCN|'||resetlogs_change# from v$database;
SQL
    cdb_state copy-open-restricted
    sql "$TARGET_SID" "$RUN/copied-pdbs.out" <<'SQL'
select name from v$pdbs where con_id>2 order by name;
SQL
    grep -Fxq "$SOURCE_PDB" "$RUN/copied-pdbs.out" || die 'Requested source application PDB absent.'
    if [[ $SOURCE_PDB != "$TARGET_PDB" ]]; then
        ! grep -Fxq "$TARGET_PDB" "$RUN/copied-pdbs.out" || die 'Conflicting destination PDB name.'
        sql "$TARGET_SID" "$RUN/rename-pdb.out" <<SQL
alter session set container=$SOURCE_PDB;
alter pluggable database rename global_name to $TARGET_PDB;
alter session set container=CDB\$ROOT;
alter pluggable database $TARGET_PDB close immediate;
alter pluggable database $TARGET_PDB open restricted;
SQL
    fi
    # Delete copied custom services in every container while listeners, jobs and
    # all CRS application resources are isolated. No post-plug key import.
    sql "$TARGET_SID" "$RUN/containers.out" <<'SQL'
select name from v$containers where con_id<>2 order by con_id;
SQL
    while IFS= read -r pdb; do
        [[ $pdb == 'CDB$ROOT' ]] || identifier "$pdb" 30 || die 'Unsupported copied container name.'
        sql "$TARGET_SID" "$RUN/services.clean.$pdb.out" <<SQL
alter session set container=$pdb;
begin
 for s in (select name from dba_services where upper(name) not in ('SYS\$BACKGROUND','SYS\$USERS','$pdb','$TARGET_CDB','${DB_UNIQUE_NAME^^}')) loop
  for a in (select name from v\$active_services where name=s.name) loop dbms_service.stop_service(a.name); end loop;
  dbms_service.delete_service(s.name);
 end loop;
end;
/
SQL
    done < "$RUN/containers.out"
    while IFS='|' read -r svc enabled running association; do
        pdb=$association; [[ $pdb != - ]] || pdb='CDB$ROOT'
        sql "$TARGET_SID" "$RUN/service.$svc.dictionary" <<SQL
alter session set container=$pdb;
declare n number;
begin
 select count(*) into n from dba_services where name='$svc';
 if n=0 then dbms_service.create_service(service_name=>'$svc',network_name=>'$svc'); end if;
end;
/
SQL
    done < "$RUN/services.tsv"
    sql "$TARGET_SID" "$RUN/patches.copied" <<'SQL'
select 'PATCH|'||patch_id||'|'||action||'|'||status from dba_registry_sqlpatch order by action_time,patch_id;
SQL
    grep '^PATCH|' "$RUN/node.$TARGET_SID.config" > "$RUN/patches.target" || die 'Target SQL patch evidence missing.'
    cmp -s "$RUN/patches.target" "$RUN/patches.copied" || die 'Source SQL patch history differs from retained target Oracle home; reconcile outside this script.'
    cdb_dictionary_ready
    cdb_coverage opened
    cdb_file_mapping opened
    printf '%s\n' 'validate check logical database;' > "$RUN/validate-cdb.rman"
    rman "$TARGET_SID" local "$RUN/validate-cdb.rman" "$RUN/validate-cdb.out"
    cdb_key_check "$TARGET_SID" '' controlled
    # Require the retained per-node undo names to exist in the copied root. This
    # is authoritative only after restore; never edit the retained parameters.
    local inst host _state _version undo thread number
    while IFS='|' read -r inst host _state _version; do
        undo=$(sed -n 's/^SETTING|undo_tablespace|//p' "$RUN/node.$inst.config")
        thread=$(sed -n 's/^SETTING|thread|//p' "$RUN/node.$inst.config")
        number=$(sed -n 's/^SETTING|instance_number|//p' "$RUN/node.$inst.config")
        sql "$TARGET_SID" "$RUN/rac-compatibility.$inst" <<SQL
declare n number;
begin
 select count(*) into n from dba_tablespaces where tablespace_name='$undo' and contents='UNDO' and status='ONLINE';
 if n<>1 then raise_application_error(-20104,'Retained RAC undo tablespace absent'); end if;
 select count(*) into n from v\$thread where thread#=$thread and enabled<>'DISABLED';
 if n<>1 then raise_application_error(-20105,'Retained RAC thread absent'); end if;
end;
/
SQL
    done < "$TARGET_RAC_FILE"
    # All copied jobs/states remain untouched. Original target settings govern
    # their execution after the final RAC startup.
    cdb_state copy-readiness-verified
}
cdb_dictionary_ready() {
    local svc enabled running pdb
    sql "$TARGET_SID" "$RUN/services.dictionary" <<'SQL'
select name||'|'||nvl(pdb,'-') from cdb_services order by name;
SQL
    while IFS='|' read -r svc enabled running pdb; do
        grep -Fxiq "$svc|$pdb" "$RUN/services.dictionary" || die "Retained service $svc has no correct dictionary association."
    done < "$RUN/services.tsv"
    sql "$TARGET_SID" "$RUN/pdb-ready.out" <<SQL
declare n number;
begin
 select count(*) into n from v\$pdbs where name='$TARGET_PDB' and open_mode='READ WRITE';
 if n<>1 then raise_application_error(-20106,'Target PDB name/open mode invalid'); end if;
 select count(*) into n from pdb_plug_in_violations where type='ERROR' and status<>'RESOLVED';
 if n>0 then raise_application_error(-20107,'Unresolved CDB compatibility errors'); end if;
end;
/
SQL
}
cdb_key_check() {
    local inst=$1 host=$2 stage=$3
    sql "$inst" "$RUN/keys.$inst.$stage" "$host" <<'SQL'
declare n number;
begin
 select count(*) into n from v$database_block_corruption;
 if n>0 then raise_application_error(-20108,'Copied database corruption'); end if;
 select count(*) into n from v$encryption_wallet where status='OPEN' and wrl_type='HSM' and con_id=1;
 if n=0 then raise_application_error(-20109,'Root source HSM authentication unavailable'); end if;
 for p in (select name from v$pdbs where con_id>2) loop
  execute immediate 'alter session set container='||dbms_assert.enquote_name(p.name,false);
  select count(*) into n from v$encryption_wallet where status='OPEN' and wrl_type='HSM' and keystore_mode='UNITED';
  if n=0 then raise_application_error(-20110,'PDB source HSM authentication unavailable'); end if;
  -- Count encrypted table blocks, forcing actual encrypted reads on this node.
  -- RMAN CHECK LOGICAL above additionally reads the complete copied database.
  for t in (select owner,table_name from dba_tables where tablespace_name in
   (select tablespace_name from dba_tablespaces where encrypted='YES') and temporary='N' and nested='NO' and secondary='N' and iot_type is null) loop
   execute immediate 'select /*+ full(t) no_parallel(t) no_result_cache */ count(*) from '||dbms_assert.enquote_name(t.owner,false)||'.'||dbms_assert.enquote_name(t.table_name,false)||' t' into n;
  end loop;
  execute immediate 'alter session set container=CDB$ROOT';
 end loop;
end;
/
SQL
}
cdb_final_rac() {
    local inst host _state _version
    cdb_services_held
    cdb_retained prerestart
    cdb_wallets verify
    sql "$TARGET_SID" "$RUN/controlled-shutdown.out" <<'SQL'
shutdown immediate;
SQL
    grep -Fxq 'ORACLE instance shut down.' "$RUN/controlled-shutdown.out" || die 'Controlled shutdown unconfirmed.'
    cdb_stopped
    srv "$RUN/database.enable" enable database -db "$DB_UNIQUE_NAME"
    cdb_state original-configuration-rac-startup
    srv "$RUN/database.start" start database -db "$DB_UNIQUE_NAME"
    cdb_services_held
    discover_target_rac "$RUN/target-rac.after"
    cmp -s "$TARGET_RAC_FILE" "$RUN/target-rac.after" || die 'Final RAC inventory/version differs.'
    while IFS='|' read -r inst host _state _version; do
        sql "$inst" "$RUN/final.$inst" "$host" <<SQL
declare n number;
begin
 select count(*) into n from v\$database d cross join v\$instance i where d.name='$TARGET_CDB' and d.db_unique_name='$DB_UNIQUE_NAME' and d.dbid=$CDB_NEW_DBID and d.database_role='PRIMARY' and d.open_mode='READ WRITE' and i.instance_name='$inst';
 if n<>1 then raise_application_error(-20111,'Final RAC identity/readiness mismatch'); end if;
 select count(*) into n from v\$passwordfile_info where file_name='$CDB_PASSWORD';
 if n<>1 then raise_application_error(-20113,'Final password-file registration mismatch'); end if;
 select count(*) into n from v\$parameter where name='spfile' and nvl(value,'<NULL>')='$CDB_PARAM_VALUE';
 if n<>1 then raise_application_error(-20112,'Final startup did not use retained parameter file'); end if;
end;
/
alter pluggable database all open;
SQL
        rman "$inst" local "$RUN/validate-cdb.rman" "$RUN/validate-final.$inst.out" "$host"
        cdb_key_check "$inst" "$host" final
        # Verify effective settings from the original file, including jobs,
        # instance/thread/undo and transport; never edit them.
        sql "$inst" "$RUN/final-settings.$inst" "$host" <<'SQL'
select 'SETTING|'||name||'|'||nvl(value,'<NULL>') from v$parameter where name in
('db_block_size','db_files','compatible','spfile','wallet_root','tde_configuration','instance_number','thread','undo_tablespace','cluster_database','job_queue_processes','aq_tm_processes','dg_broker_start','service_names','local_listener','remote_listener') or regexp_like(name,'^log_archive_dest(_state)?_([1-9]|[12][0-9]|3[01])$') order by name;
SQL
        grep '^SETTING|' "$RUN/node.$inst.config" > "$RUN/expected-settings.$inst"
        cmp -s "$RUN/expected-settings.$inst" "$RUN/final-settings.$inst" || die 'Retained RAC settings not restored.'
    done < "$TARGET_RAC_FILE"
    cdb_dictionary_ready
    cdb_coverage final
    cdb_file_mapping final
    cdb_wallets verify
    cdb_retained final
    cdb_dbconfig "$RUN/database.after"
    cmp -s "$RUN/database.before" "$RUN/database.after" || die 'Database resource configuration changed.'
    cdb_resource final 1
    touch "$RUN/database-ready"
    cdb_state rac-readiness-verified-services-held
}
cdb_release_services() {
    [[ -f $RUN/database-ready ]] || die 'Cannot release services before final database readiness.'
    local svc enabled running pdb inst
    CDB_RELEASE_ATTEMPTED=1
    while IFS='|' read -r svc enabled running pdb; do
        [[ $enabled != enabled ]] || srv "$RUN/service.$svc.enable" enable service -db "$DB_UNIQUE_NAME" -service "$svc"
        if [[ $running != - ]]; then
            local -a members
            IFS=',' read -r -a members <<< "$running"
            for inst in "${members[@]}"; do
                srv "$RUN/service.$svc.start.$inst" start service -db "$DB_UNIQUE_NAME" -service "$svc" -instance "$inst"
            done
        fi
        srv "$RUN/service.$svc.after" config service -db "$DB_UNIQUE_NAME" -service "$svc" -verbose
        cmp -s "$RUN/service.$svc.before" "$RUN/service.$svc.after" || die 'Service resource configuration changed on release.'
        srv "$RUN/service.$svc.status.after" status service -db "$DB_UNIQUE_NAME" -service "$svc" -force
        cmp -s "$RUN/service.$svc.status.before" "$RUN/service.$svc.status.after" || die 'Actual service running placement differs from snapshot.'
    done < "$RUN/services.tsv"
}

cdb_main() {
    umask 077
    phase cdb-preflight 'Planning full target CDB replacement; catalog-only source access.'
    cdb_warn
    command -v python3 >/dev/null && [[ -r $CDB_FILE_TOOL && -x $ORACLE_HOME/bin/asmcmd ]] || die 'CDB mode needs Python 3 and 19c ASMCMD on both target hosts.'
    target_identity "$RUN/identity.before"; validate_target_identity "$RUN/identity.before"
    local matches path index=0
    matches=$(printf '%s\n' "${DB_UNIQUE_NAME^^}" | grep -oE 'M[12]' || true)
    [[ $matches == M1 || $matches == M2 ]] || die 'Target unique name must contain exactly one M1 or M2 marker.'
    SOURCE_UNIQUE="$SOURCE_CDB$matches"
    discover_target_settings "$RUN/target-settings.out"
    TARGET_RAC_FILE="$RUN/target-rac.before"; discover_target_rac "$TARGET_RAC_FILE"
    [[ $(cut -d'|' -f2 "$TARGET_RAC_FILE" | sort -u | wc -l) -eq 2 ]] || die 'CDB mode requires two distinct target RAC hosts.'
    cdb_dbconfig "$RUN/database.before"; cdb_config_paths
    [[ -d $CDB_WORK_PARENT && -w $CDB_WORK_PARENT && ! -L $CDB_WORK_PARENT ]] || die 'Provision the CDB work parent first (no symlink).'
    CDB_WORK_PARENT=$(cd "$CDB_WORK_PARENT" && pwd -P)
    safe_path "$CDB_WORK_PARENT" || die 'Unsafe resolved CDB work parent.'
    cdb_file probe "$RUN/local-paths.json" parent "$CDB_WORK_PARENT" root "$TARGET_WALLET" source "$SOURCE_WALLET_DIR"
    [[ $CDB_WORK_PARENT != "$TARGET_WALLET" && $CDB_WORK_PARENT != "$TARGET_WALLET/"* ]] || die 'CDB work parent must be outside active wallet root.'
    CDB_WORK=$(mktemp -d "$CDB_WORK_PARENT/cdb_copy_XXXXXX")
    printf '%s\n' "$CDB_WORK" > "$RUN/cdb-private-work"
    cdb_node_prepare
    cdb_file stage "$RUN/source-tde.inventory.json" source "$SOURCE_WALLET_DIR" dest "$CDB_WORK/source-tde" root "$TARGET_WALLET"
    printf '%s\n' "$TARGET_WALLET" "$CDB_WORK" "$SOURCE_WALLET_DIR" "$ORACLE_HOME/dbs" > "$RUN/excluded.paths"
    cdb_retained before
    cdb_inventory "$RUN/old-files.raw"
    cdb_normalize_inventory "$RUN/old-files.raw" "$RUN/old-files.json"
    cp "$RUN/old-files.json" "$RUN/old-files.frozen.json"
    cdb_snapshot_services
    cdb_catalog
    cdb_compatibility
    cdb_capacity before
    cdb_build_duplicate > "$RUN/duplicate.rman"
    log "CDB execution plan: retain original registered parameter/password files; hold all services and database disabled; stop both RAC nodes; protect controlfiles and old TDE; quarantine stale tde_seps; install source tde on both nodes; delete exact old-files.frozen.json; recheck actual space; duplicate all source CDB files into $AUX_DATA_DEST/$DB_UNIQUE_NAME with $DUP_RESTORE_PARALLELISM SBT channels; validate restricted; restart original RAC; release captured services only after readiness."
    log 'Pending actual restore: controlfile/dictionary compatibility, source SQL RU/COMPATIBLE, complete historical file coverage, SBT/redo continuity, source CKMS key access and encrypted reads on both nodes. These can fail AFTER old-file deletion. No automatic rollback or backup registration.'
    if ((DRY_RUN)); then
        phase dry-run-complete "CDB dry run complete; no resource, active-wallet, database, RMAN or file-deletion changes. Private staged material: $CDB_WORK"
        return
    fi
    cdb_build_pfile
    cdb_services_frozen
    target_identity "$RUN/identity.freeze"; cmp -s "$RUN/identity.before" "$RUN/identity.freeze" || die 'Target identity changed before shutdown.'
    discover_target_rac "$RUN/rac.freeze"; cmp -s "$TARGET_RAC_FILE" "$RUN/rac.freeze" || die 'RAC inventory changed before shutdown.'
    cdb_dbconfig "$RUN/database.freeze"; cmp -s "$RUN/database.before" "$RUN/database.freeze" || die 'Database resource changed before shutdown.'
    cdb_inventory "$RUN/old-files.freeze.raw"
    cdb_normalize_inventory "$RUN/old-files.freeze.raw" "$RUN/old-files.freeze.json"
    cmp -s "$RUN/old-files.frozen.json" "$RUN/old-files.freeze.json" || die 'Old file identity/inventory changed; refusing shutdown/deletion.'
    cdb_retained freeze
    phase cdb-shutdown 'Holding all application services and database resources disabled; stopping complete RAC.'
    cdb_stop
    # Controlfile byte copies must be made after complete clean shutdown.
    while IFS= read -r path; do
        cdb_file snapshot "$RUN/control-backup.$index.json" kind CONTROL source "$path" dest "$CDB_WORK/control_$index"
        ((index+=1))
    done < "$RUN/controls.paths"
    index=0
    while IFS= read -r path; do
        cdb_file snapshot "$RUN/control-backup.$index.verify.json" kind CONTROL source "$path" dest "$CDB_WORK/control_${index}_verify"
        cmp -s "$RUN/control-backup.$index.json" "$RUN/control-backup.$index.verify.json" || die 'Controlfile backup byte verification failed.'
        ((index+=1))
    done < "$RUN/controls.paths"
    cdb_state old-controlfiles-protected
    cdb_wallets backup
    CDB_BACKUPS_READY=1
    cdb_state old-wallets-protected
    cdb_wallets install
    cdb_wallets verify
    CDB_WALLET_READY=1
    cdb_state source-wallet-active
    phase cdb-deletion 'Deleting exact verified old database files before duplication; no retained-datafile rollback.'
    cdb_delete_old
    cdb_capacity after
    phase cdb-restore 'Restoring source controlfile and ALL source CDB datafiles directly into target.'
    cdb_start_controlled
    cdb_state source-controlfile-replacement-attempted
    rman "$TARGET_SID" duplicate "$RUN/duplicate.rman" "$RUN/duplicate.out"
    cdb_retained postduplicate
    cdb_validate_mounted
    phase cdb-validation 'Opening under restriction; checking full source file coverage, encrypted blocks, PDB names and services.'
    cdb_reconcile
    phase cdb-rac 'Restarting existing RAC resources with the original retained configuration; services held disabled.'
    cdb_final_rac
    phase cdb-services 'Restoring captured target service enablement and running placement after readiness.'
    cdb_release_services
    cdb_state complete
    touch "$RUN/complete"
    phase complete "Full CDB copy completed; old DBID=$TARGET_DBID new DBID=$CDB_NEW_DBID. Source TDE remains active."
    log "Recovery endpoint request=${RECOVERY_TIME:-latest recoverable}; SCN evidence=$RUN/recovery-point.out; private protected configuration/controlfiles/old TDE=$CDB_WORK. Copied Scheduler/DBMS_JOB states remain unchanged; external application procedure owns job handling. Backup registration and standby recreation require separate procedures."
}
