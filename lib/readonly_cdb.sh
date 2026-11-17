#!/usr/bin/env bash
# Collector-only CDB diagnostics. No execution workflow or mutable client calls.
# Raw evidence remains private until the collector's report sanitizer packages it.
# shellcheck disable=SC2015,SC2016

diag_cdb_save() {
    local name
    for name in "$@"; do printf '%s=%q\n' "$name" "${!name}"; done > "$DIAG_CDB_STATE"
}

diag_cdb_step() {
    local name=$1 description=$2; shift 2
    rm -f -- "$DIAG_CDB_STATE"
    diag_check "$name" "$description" "$@"
    DIAG_CDB_RC=$DIAG_LAST_RC
    if ((DIAG_CDB_RC == 0)) && [[ -f $DIAG_CDB_STATE ]]; then
        # Only our printf %q assignments are loaded, never database/client text.
        # shellcheck disable=SC1090
        source "$DIAG_CDB_STATE"
    fi
    rm -f -- "$DIAG_CDB_STATE"
}

diag_cdb_identity() {
    RUN=$DIAG_CDB_RUN
    target_identity "$RUN/identity.before"
    validate_target_identity "$RUN/identity.before"
    diag_cdb_save TARGET_DBID
}
diag_cdb_rac() {
    RUN=$DIAG_CDB_RUN
    discover_target_rac "$TARGET_RAC_FILE"
    [[ $(cut -d'|' -f2 "$TARGET_RAC_FILE" | sort -u | wc -l) -eq 2 ]] || die 'CDB mode requires two distinct target RAC hosts.'
}
diag_cdb_settings() {
    RUN=$DIAG_CDB_RUN
    discover_target_settings "$RUN/target-settings.out"
    diag_cdb_save TARGET_DEST AUX_DATA_DEST AUX_RECO_DEST COMPATIBLE TDE_CONFIGURATION TARGET_WALLET
}

diag_cdb_health() {
    local inst=$1 host=$2 index=$3 file
    RUN=$DIAG_CDB_RUN file=$DIAG_CDB_RUN/health.$index.out
    sql "$inst" "$file" "$host" <<'SQL'
select 'IDENTITY|'||d.name||'|'||d.db_unique_name||'|'||d.dbid||'|'||d.database_role||'|'||d.cdb||'|'||d.open_mode||'|'||i.instance_name||'|'||i.status||'|'||i.version_full from v$database d cross join v$instance i;
select 'CONTAINER|'||sys_context('USERENV','CON_NAME') from dual;
select 'DATABASE|'||platform_name||'|'||log_mode||'|'||force_logging||'|'||flashback_on from v$database;
select 'WALLET|'||con_id||'|'||status||'|'||wrl_type||'|'||keystore_mode||'|'||wallet_type from v$encryption_wallet order by con_id,wrl_type;
select 'PDB|'||con_id||'|'||open_mode||'|'||nvl(restricted,'NO') from v$pdbs order by con_id;
select 'CHARSET|'||parameter||'|'||value from nls_database_parameters where parameter in ('NLS_CHARACTERSET','NLS_NCHAR_CHARACTERSET') order by parameter;
select 'TIMEZONE|'||version from v$timezone_file;
select 'COMPONENT|'||comp_id||'|'||version||'|'||status from dba_registry order by comp_id;
select 'SQLPATCH|'||patch_id||'|'||action||'|'||status from dba_registry_sqlpatch order by action_time,patch_id;
select 'CORRUPTION|'||count(*) from v$database_block_corruption;
SQL
    grep -Fiq "IDENTITY|$TARGET_CDB|$DB_UNIQUE_NAME|$TARGET_DBID|PRIMARY|YES|READ WRITE|$inst|OPEN|19." "$file" &&
        grep -Fxq 'CONTAINER|CDB$ROOT' "$file" || die 'Target node identity, version or root verification failed.'
    grep -Eq '^WALLET\|1\|OPEN\|HSM\|' "$file" || die 'Target root HSM keystore is not OPEN.'
    grep -Fxq 'CORRUPTION|0' "$file" || die 'Target has recorded block corruption or incomplete corruption evidence.'
    awk -F'|' '
      $1=="CHARSET" {if (NF!=3 || $3=="" || seen[$2]++) bad=1; if ($2=="NLS_CHARACTERSET" || $2=="NLS_NCHAR_CHARACTERSET") charset++}
      $1=="TIMEZONE" {if (NF!=2 || $2!~/^[1-9][0-9]*$/) bad=1; timezone++}
      $1=="COMPONENT" {if (NF!=4 || $2=="" || $3=="" || $4=="") bad=1; component++}
      END {exit (bad || charset!=2 || timezone!=1 || component<1)}
    ' "$file" || die 'Incomplete target charset, timezone or component inventory.'
    if awk -F'|' '$1=="COMPONENT" && $4!="VALID" {found=1} END {exit !found}' "$file"; then
        printf 'Review component statuses; this inventory describes the old target, whose dictionary is replaced.\n'
    fi
    printf 'Target health is observed on this node. Source historical keys, source components/charset/timezone/RU/COMPATIBLE and encrypted reads remain unverified.\n'
}

diag_cdb_node_clients() {
    local host=$1 index=$2
    RUN=$DIAG_CDB_RUN
    cdb_file clients "$RUN/clients.$index.json" host "$host"
    python3 - "$RUN/clients.$index.json" <<'PYCLIENTS' || die 'Target node requires Python 3.8+, all CDB clients and readable libra.so.'
import json,sys
from pathlib import Path
info=json.loads(Path(sys.argv[1]).read_text())
clients=info.get('clients',{})
ok=all(clients.get(name) is True for name in ('sqlplus','rman','mkstore','srvctl','asmcmd'))
ok=ok and info.get('sbt_library_readable') is True and tuple(info.get('python',[])) >= (3,8)
sys.exit(0 if ok else 1)
PYCLIENTS
}
diag_cdb_node_asm() {
    local host=$1 index=$2 group
    RUN=$DIAG_CDB_RUN
    for group in "$AUX_DATA_DEST" "$AUX_RECO_DEST"; do
        cdb_file capacity "$RUN/asm.$index.${group#+}.json" host "$host" group "$group"
        [[ $AUX_DATA_DEST != "$AUX_RECO_DEST" ]] || break
    done
    printf 'Discovered ASM groups queried through this host with local ASM OS authentication; no files changed.\n'
}
diag_cdb_config() {
    RUN=$DIAG_CDB_RUN
    cdb_dbconfig "$RUN/database.before"
    cdb_config_paths
    diag_cdb_save CDB_PARAM CDB_PARAM_KIND CDB_PARAM_VALUE CDB_PASSWORD
}
diag_cdb_work() {
    RUN=$DIAG_CDB_RUN
    command -v python3 >/dev/null && [[ -r $CDB_FILE_TOOL && -x $ORACLE_HOME/bin/asmcmd ]] || die 'CDB diagnostics need Python 3, the file helper and ASMCMD.'
    [[ -d $CDB_WORK_PARENT && -w $CDB_WORK_PARENT && ! -L $CDB_WORK_PARENT ]] || die 'Provision the CDB work parent first (no symlink).'
    CDB_WORK_PARENT=$(cd "$CDB_WORK_PARENT" && pwd -P)
    safe_path "$CDB_WORK_PARENT" || die 'Unsafe resolved CDB work parent.'
    cdb_file probe "$RUN/local-paths.json" parent "$CDB_WORK_PARENT" root "$TARGET_WALLET" source "$SOURCE_WALLET_DIR"
    CDB_WORK=$(mktemp -d "$CDB_WORK_PARENT/cdb_copy_XXXXXX")
    printf '%s\n' "$CDB_WORK" > "$RUN/cdb-private-work"
    printf '%s\n' "$TARGET_WALLET" "$CDB_WORK" "$SOURCE_WALLET_DIR" "$ORACLE_HOME/dbs" > "$RUN/excluded.paths"
    diag_cdb_save CDB_WORK_PARENT CDB_WORK
}
diag_cdb_stage_wallet() {
    RUN=$DIAG_CDB_RUN
    cdb_file stage "$RUN/source-tde.inventory.json" source "$SOURCE_WALLET_DIR" dest "$CDB_WORK/source-tde" root "$TARGET_WALLET"
    printf 'Private source TDE copy verified. File presence and copy equality do not establish portable auto-login authentication or key access.\n'
}
diag_cdb_node_config() {
    local index=$1
    RUN=$DIAG_CDB_RUN TARGET_RAC_FILE=$DIAG_CDB_RUN/target-node.$index
    cdb_node_prepare
}
diag_cdb_node_retained() {
    local index=$1
    RUN=$DIAG_CDB_RUN TARGET_RAC_FILE=$DIAG_CDB_RUN/target-node.$index
    cdb_retained before
}
diag_cdb_files() {
    RUN=$DIAG_CDB_RUN
    cdb_inventory "$RUN/old-files.raw"
    cdb_normalize_inventory "$RUN/old-files.raw" "$RUN/old-files.json"
    cp "$RUN/old-files.json" "$RUN/old-files.frozen.json"
    printf 'Exact old-target file manifest validated, including root/seed, other PDBs, online and standby redo. No deletion attempted.\n'
}
diag_cdb_services() { RUN=$DIAG_CDB_RUN; cdb_snapshot_services; }

diag_cdb_catalog_identity() {
    RUN=$DIAG_CDB_RUN
    diag_credentials
    diag_catalog_identity
    diag_cdb_save SOURCE_DBKEY SOURCE_DBID SOURCE_INC SOURCE_RESET SOURCE_RESET_TIME
}
diag_cdb_catalog_files() {
    RUN=$DIAG_CDB_RUN
    diag_credentials
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
    diag_cdb_save SOURCE_MB BLOCK_SIZE CDB_MAX_FILE
}
# RC_DATAFILE labels can lag historical PDB renames; aggregate evidence is
# advisory and never substitutes for the restored dictionary's name checks.
diag_cdb_catalog_pdbs() {
    local source_count target_count unnamed
    RUN=$DIAG_CDB_RUN
    diag_credentials
    sql CATALOG "$RUN/source-pdb-candidates.out" <<SQL
select count(distinct case when con_id>2 and upper(pdb_name)='$SOURCE_PDB' then con_id end)||'|'||
count(distinct case when con_id>2 and upper(pdb_name)='$TARGET_PDB' then con_id end)||'|'||
count(case when con_id>2 and pdb_name is null then 1 end)
from rc_datafile where db_key=$SOURCE_DBKEY and dbinc_key=$SOURCE_INC
and upper(db_unique_name)='$SOURCE_UNIQUE' and creation_time <= $point and (drop_time is null or drop_time > $point);
SQL
    one_line "$RUN/source-pdb-candidates.out"
    IFS='|' read -r source_count target_count unnamed <<< "$RESULT"
    [[ $RESULT =~ ^[0-9]+\|[0-9]+\|[0-9]+$ ]] || die 'Malformed catalog PDB-name candidate counts.'
    printf 'Advisory catalog counts: requested source containers=%s; requested destination containers=%s; application files without PDB labels=%s.\n' "$source_count" "$target_count" "$unnamed"
    if [[ $source_count != 1 || ( $SOURCE_PDB != "$TARGET_PDB" && $target_count != 0 ) || $unnamed != 0 ]]; then
        printf 'POTENTIAL BLOCKER: missing/ambiguous source PDB, destination-name collision, or incomplete catalog labels.\n'
    fi
    printf 'Historical PDB renames are not established by these labels; restored dictionary verification remains required.\n'
}
diag_cdb_online_redo() {
    local redo_threads redo_groups
    RUN=$DIAG_CDB_RUN
    diag_credentials
    sql CATALOG "$RUN/source-online-redo.out" <<SQL
select case when count(*)>0 and count(bytes)=count(*) and min(bytes)>0 then ceil(sum(bytes)/1048576) else -1 end||'|'||count(distinct thread#)||'|'||count(distinct group#) from (
select distinct l.thread#,l.group#,l.name,l.bytes from rc_redo_log l join rc_site s on s.site_key=l.site_key and s.db_key=l.db_key
where l.db_key=$SOURCE_DBKEY and l.dbinc_key=$SOURCE_INC and upper(s.db_unique_name)='$SOURCE_UNIQUE' and l.type='ONLINE');
SQL
    one_line "$RUN/source-online-redo.out"
    IFS='|' read -r CDB_REDO_MB redo_threads redo_groups <<< "$RESULT"
    positive "$CDB_REDO_MB" && [[ $redo_threads == 2 ]] && positive "$redo_groups" && ((redo_groups >= 4)) || die 'Unknown source online redo recreation budget.'
    diag_cdb_save CDB_REDO_MB
}
diag_cdb_catalog_redo() {
    RUN=$DIAG_CDB_RUN
    diag_credentials
    diag_redo
    awk -F'|' 'NF!=4 || $1!~/^[1-9][0-9]*$/ || seen[$1]++ {bad=1} {n++} END {exit (bad || n!=2)}' "$RUN/redo-inventory.out" || die 'Expected two distinct source RAC redo threads.'
}
diag_cdb_catalog_range() { RUN=$DIAG_CDB_RUN; diag_credentials; dry_run_range; }
diag_cdb_catalog_temp() {
    RUN=$DIAG_CDB_RUN
    diag_credentials
    sql CATALOG "$RUN/tempfiles.raw.out" <<SQL
select distinct file# from rc_tempfile where db_key=$SOURCE_DBKEY and dbinc_key=$SOURCE_INC
and creation_time <= $point and (drop_time is null or drop_time > $point) order by file#;
SQL
    normalize_tempfile_ids "$RUN/tempfiles.raw.out" "$RUN/tempfiles.normalized.out"
    sql CATALOG "$RUN/temp-size.out" <<SQL
select case when count(*)>0 and count(bytes)=count(*) and min(bytes)>0 then ceil(sum(bytes)/1048576) else -1 end from (select file#,max(bytes) bytes from rc_tempfile where db_key=$SOURCE_DBKEY and dbinc_key=$SOURCE_INC
and creation_time <= $point and (drop_time is null or drop_time > $point) group by file#);
SQL
    one_line "$RUN/temp-size.out"
    CDB_TEMP_MB=$RESULT
    positive "$CDB_TEMP_MB" || die 'CDB mode requires complete positive source tempfile sizes.'
    diag_cdb_save CDB_TEMP_MB
}
diag_cdb_compatibility() {
    RUN=$DIAG_CDB_RUN
    grep -q '^PATCH|' "$RUN/node.$TARGET_SID.config" || die 'Target SQL patch history required by the restore workflow is missing.'
    cdb_compatibility
    diag_cdb_save CDB_NUMBER CDB_THREAD CDB_UNDO
}
diag_cdb_capacity() { RUN=$DIAG_CDB_RUN; cdb_capacity before; }
diag_cdb_plan() {
    RUN=$DIAG_CDB_RUN
    diag_credentials
    cdb_build_duplicate > "$RUN/duplicate.rman"
    printf 'RMAN command generation passed; RMAN has not been invoked.\n'
}

# Separate phases let catalog/other-node observations survive independent
# wallet, retained-file, service, health or capacity failures.
diag_cdb() {
    local identity_rc rac_rc=1 settings_rc=1 config_rc=1 work_rc=1 files_rc=1
    local nodes_rc=0 retained_rc=0 catalog_rc=1 source_rc=1 redo_rc=1 online_rc=1 temp_rc=1
    local inst host state version index=0
    DIAG_CDB_RUN=$DIAG_WORK/cdb-evidence DIAG_CDB_STATE=$DIAG_WORK/cdb-state DIAG_CDB_PACKAGED=0
    mkdir "$DIAG_CDB_RUN"
    printf "CDB COPY: all existing target physical standbys require recreation by the separate script. No standby connections or management are performed. Final original settings may reactivate Broker/transport.\n" >> "$DIAG_OUTPUT"
    TARGET_RAC_FILE=$DIAG_CDB_RUN/target-rac.before
    point="to_date('${RECOVERY_TIME:-9999-12-31 23:59:59}','YYYY-MM-DD HH24:MI:SS')"
    diag_cdb_step cdb-identity 'Verify target primary CDB/root/DBID' diag_cdb_identity
    identity_rc=$DIAG_CDB_RC
    if ((identity_rc == 0)); then
        diag_cdb_step cdb-rac 'Verify both target RAC instances and distinct hosts' diag_cdb_rac; rac_rc=$DIAG_CDB_RC
        diag_cdb_step cdb-settings 'Discover target ASM, compatibility and TDE settings' diag_cdb_settings; settings_rc=$DIAG_CDB_RC
        if ((rac_rc == 0)); then
            while IFS='|' read -r inst host state version; do
                ((index+=1))
                printf '%s|%s|%s|%s\n' "$inst" "$host" "$state" "$version" > "$DIAG_CDB_RUN/target-node.$index"
                diag_cdb_step "cdb-health-$index" "Target RAC node $index: root, TDE, version and database health evidence" diag_cdb_health "$inst" "$host" "$index"
                diag_cdb_step "cdb-clients-$index" "Target RAC node $index: Python, CDB clients and SBT library availability" diag_cdb_node_clients "$host" "$index"
                if ((settings_rc == 0)); then
                    diag_cdb_step "cdb-asm-$index" "Target RAC node $index: ASMCMD OS authentication and discovered group capacity" diag_cdb_node_asm "$host" "$index"
                else diag_skip "cdb-asm-$index" 'Verified target ASM destinations unavailable.'; fi
            done < "$TARGET_RAC_FILE"
            diag_cdb_step cdb-config 'Registered database, retained startup/password/control paths and resource enablement' diag_cdb_config; config_rc=$DIAG_CDB_RC
            diag_cdb_step cdb-services 'Complete target service configuration and placement' diag_cdb_services
        else
            diag_skip cdb-nodes-and-config 'Complete verified RAC inventory unavailable; per-node and resource checks suppressed.'
        fi
        if ((settings_rc == 0)); then
            diag_cdb_step cdb-work 'Private work paths and source/active wallet separation' diag_cdb_work; work_rc=$DIAG_CDB_RC
            if ((work_rc == 0)); then
                diag_cdb_step cdb-source-wallet 'Stage and verify source TDE privately without installing it' diag_cdb_stage_wallet
            else diag_skip cdb-source-wallet 'Verified private work paths unavailable.'; fi
        else diag_skip cdb-work-and-wallet 'Verified target storage/wallet settings unavailable.'; fi
        if ((rac_rc == 0 && config_rc == 0 && work_rc == 0)); then
            for ((index=1; index<=2; index++)); do
                diag_cdb_step "cdb-node-config-$index" "Target RAC node $index: configuration, SSH/Python and private work directory" diag_cdb_node_config "$index"
                ((DIAG_CDB_RC == 0)) || nodes_rc=1
                if ((DIAG_CDB_RC == 0)); then
                    diag_cdb_step "cdb-retained-$index" "Target RAC node $index: private parameter/password/startup snapshots" diag_cdb_node_retained "$index"
                    ((DIAG_CDB_RC == 0)) || retained_rc=1
                else diag_skip "cdb-retained-$index" 'Verified node configuration/private work directory unavailable.'; retained_rc=1; fi
            done
            if ((retained_rc == 0)); then
                diag_cdb_step cdb-files 'Exact whole-target file manifest and protected-file exclusions' diag_cdb_files; files_rc=$DIAG_CDB_RC
            else diag_skip cdb-files 'Complete retained-file protection evidence unavailable.'; fi
        else
            nodes_rc=1 retained_rc=1
            diag_skip cdb-node-files 'Verified RAC, registered paths and private work directory required.'
        fi
        diag_cdb_step cdb-catalog 'SEPS authentication, source identity and incarnation' diag_cdb_catalog_identity; catalog_rc=$DIAG_CDB_RC
        if ((catalog_rc == 0)); then
            diag_cdb_step cdb-source-files 'Every source CDB file, creation identity, block size and SBT full/level-0 candidate' diag_cdb_catalog_files; source_rc=$DIAG_CDB_RC
            diag_cdb_step cdb-pdb-candidates 'Catalog PDB-name candidate counts (advisory; restored dictionary authoritative)' diag_cdb_catalog_pdbs
            diag_cdb_step cdb-online-redo 'Source online redo recreation budget' diag_cdb_online_redo; online_rc=$DIAG_CDB_RC
            diag_cdb_step cdb-redo 'Both source archived redo thread endpoints' diag_cdb_catalog_redo; redo_rc=$DIAG_CDB_RC
            if ((redo_rc == 0)); then diag_cdb_step cdb-range 'Candidate recovery time range and SBT controlfile metadata' diag_cdb_catalog_range
            else diag_skip cdb-range 'Complete source redo endpoint metadata unavailable.'; fi
            diag_cdb_step cdb-tempfiles 'Source tempfile identifiers and capacity' diag_cdb_catalog_temp; temp_rc=$DIAG_CDB_RC
        else diag_skip cdb-source-metadata 'Source catalog identity/incarnation could not be established.'; fi
        if ((nodes_rc == 0 && source_rc == 0 && redo_rc == 0)); then
            diag_cdb_step cdb-compatibility 'Retained block size/file limit/RAC threads and matching target SQL patch histories' diag_cdb_compatibility
        else diag_skip cdb-compatibility 'Complete source manifests/redo and both-node configuration required.'; fi
        if ((settings_rc == 0 && files_rc == 0 && source_rc == 0 && online_rc == 0 && temp_rc == 0)); then
            diag_cdb_step cdb-capacity 'ASM capacity including only exact old-target file reclaim and redo reserve' diag_cdb_capacity
        else diag_skip cdb-capacity 'Verified target file manifest and source data/redo/temp budgets required.'; fi
        if ((work_rc == 0 && source_rc == 0 && temp_rc == 0)); then
            diag_cdb_step cdb-plan 'Generate the complete RMAN command without invoking RMAN' diag_cdb_plan
        else diag_skip cdb-plan 'Private work and complete source data/temp manifests required.'; fi
    else
        diag_skip cdb-dependent 'Target identity failed; further database, SSH and catalog access suppressed.'
    fi
    rm -f -- "$DIAG_CDB_STATE"
    diag_append_evidence "$DIAG_CDB_RUN"
    # Consumed by the collector EXIT trap when interrupted.
    # shellcheck disable=SC2034
    DIAG_CDB_PACKAGED=1
    printf '\nCDB evidence limits: catalog candidates are not SBT media verification or proof of redo continuity. Source RU/COMPATIBLE, character sets, timezone/components, retained undo-name compatibility, historical PDB names/service associations, portable wallet authentication and historical key access require restored-dictionary/operational verification. Target health describes the old target only. Private file copies under the work parent are retained outside the report.\n' >> "$DIAG_OUTPUT"
}
