#!/usr/bin/env bash
# shellcheck disable=SC2016
# Full CDB offline flows. All Oracle/Clusterware/SSH clients are local fixtures.
set -Eeuo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../dup_db.sh
source "$root/dup_db.sh"
tmp=$(mktemp -d /tmp/zdlra-cdb.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
checks=0
ok() { ((checks+=1)); }
reject() {
    if ("$@") > "$tmp/rejected" 2>&1; then printf 'Expected rejection: %s\n' "$*" >&2; exit 1; fi
    ok
}
names=(--source-cdb PROD --target-cdb PRE --source-pdb APP --target-pdb APPTEST)
base=("${names[@]}" --mode cdb --work-dir /stage --source-wallet-dir /source)
parse_args "${base[@]}"
[[ $MODE == cdb && $DRY_RUN == 1 && -z $DUP_AUX_CDB && $CDB_WORK_PARENT == /stage ]]; ok
for opt in --aux-cdb --aux-base --aux-wallet-root --aux-sga-mb --aux-pga-mb; do reject parse_args "${base[@]}" "$opt" AUX; done
for opt in --work-dir --source-wallet-dir; do
    reject parse_args "${names[@]}" --mode cdb "$opt" /only-one
    reject parse_args "${names[@]}" --aux-cdb AUX --aux-base /stage "$opt" /source
    reject parse_args "${base[@]}" "$opt" /repeat
    reject parse_args "${names[@]}" --mode cdb --work-dir /stage --source-wallet-dir /source/../unsafe
 done
reject parse_args "${names[@]}" --mode unknown
# The real catalog validator rejects unsafe and incomplete coverage evidence.
RUN=$tmp LOG=$tmp/log PHASE=fixture
printf '1|10|1|1048576|8192|0|0|1\n2|20|2|1048576|8192|1|10|1\n3|30|3|1048576|8192|0|0|1\n4|40|4|1048576|8192|0|0|1\n' > "$tmp/source.good"
cp "$tmp/source.good" "$RUN/source-files.out"
cdb_source_manifest
[[ $SOURCE_MB == 4 && $CDB_MAX_FILE == 4 ]]; ok
for fault in omitted-root omitted-seed duplicate missing-backup offline-clean malformed; do
    cp "$tmp/source.good" "$RUN/source-files.out"
    case $fault in
        omitted-root) sed '1d' "$tmp/source.good" > "$RUN/source-files.out" ;;
        omitted-seed) sed '2d' "$tmp/source.good" > "$RUN/source-files.out" ;;
        duplicate) cat "$tmp/source.good" >> "$RUN/source-files.out" ;;
        missing-backup) sed '4s/|1$/|0/' "$tmp/source.good" > "$RUN/source-files.out" ;;
        offline-clean) sed '4s/|0|0|1$/|0|50|1/' "$tmp/source.good" > "$RUN/source-files.out" ;;
        malformed) printf '1|bad\n' >> "$RUN/source-files.out" ;;
    esac
    reject cdb_source_manifest
 done
# Reuse real private file operations for wallets, retained bytes and manifest
# deletion; the adapter strips fictional hosts and substitutes ASM capacity.
eval "$(declare -f cdb_file | sed '1s/cdb_file/real_cdb_file/')"
cdb_file() {
    local action=$1 out=$2; shift 2
    local -a args=()
    while (($#)); do
        if [[ $1 == host ]]; then shift 2; else args+=("$1" "$2"); shift 2; fi
    done
    printf 'FILE %s %s\n' "$action" "$out" >> "$F_DIR/calls"
    case $action in
        resource)
            local enabled=1
            [[ $(cat "$F_DIR/db-enabled") != disabled ]] || enabled=0
            printf '{"enabled":%s,"configuration_sha256":"unchanged"}\n' "$enabled" > "$out" ;;
        capacity)
            if [[ $F_CASE == post-delete-space && -e $RUN/deletion.complete ]]; then printf '{"usable_mb":0,"type":"NORMAL"}\n' > "$out"
            elif [[ $F_CASE == pre-delete-space ]]; then printf '{"usable_mb":0,"type":"NORMAL"}\n' > "$out"
            else printf '{"usable_mb":500000,"type":"NORMAL"}\n' > "$out"; fi ;;
        stopped)
            [[ ! -e $F_DIR/running && ! -e $F_DIR/controlled && $F_CASE != unmanaged-instance ]] || die 'fixture: instance still running'
            printf '{}\n' > "$out" ;;
        delete)
            if [[ $F_CASE == partial-delete && -e $RUN/destructive-boundary ]]; then die 'fixture: partial deletion'; fi
            real_cdb_file "$action" "$out" "${args[@]}" ;;
        wallet-install)
            [[ $F_CASE != node2-wallet-failure || $out != *PRE2* ]] || die 'fixture: node2 install failed'
            real_cdb_file "$action" "$out" "${args[@]}" ;;
        snapshot)
            [[ $F_CASE != control-backup-failure || $out != *control-backup* ]] || die 'fixture: backup failed'
            if [[ $F_CASE == parameter-drift && $out == *freeze* ]]; then printf 'changed\n' > "$F_DIR/spfile"; fi
            real_cdb_file "$action" "$out" "${args[@]}" ;;
        *) real_cdb_file "$action" "$out" "${args[@]}" ;;
    esac
}
target_identity() {
    printf 'PRE|PREM1|42|PRIMARY|YES|READ WRITE\nCONTAINER|CDB$ROOT\n' > "$1"
}
discover_target_settings() {
    TARGET_DEST=+DATA AUX_DATA_DEST=+DATA AUX_RECO_DEST=+RECO COMPATIBLE=19.0.0 TDE_CONFIGURATION=KEYSTORE_CONFIGURATION=HSM TARGET_WALLET=$F_DIR/wallet
    printf '+DATA\n19.0.0\nKEYSTORE_CONFIGURATION=HSM\n%s\n+RECO\n' "$TARGET_WALLET" > "$1"
}
discover_target_rac() {
    printf 'PRE1|node1|OPEN|19.0.0.0.0\nPRE2|node2|OPEN|19.0.0.0.0\n' > "$1"
    validate_target_rac "$1"
}
discover_credentials() { WALLET=$F_DIR/wallet/server_seps RA_ALIAS=fake-catalog VPC_USER=VPC VPC_PASSWORD=offline-password; }
# Standby/Broker discovery is forbidden in this mode, even if unreachable.
broker() { die 'fixture: forbidden Broker access'; }
discover_standbys() { die 'fixture: forbidden standby discovery'; }
stop_target_apply() { die 'fixture: forbidden apply management'; }
settings() {
    local inst=$1 num=1
    [[ $inst != PRE2 ]] || num=2
    local parameter=$F_DIR/spfile
    [[ $F_CASE != pfile ]] || parameter='<NULL>'
    printf 'SETTING|cluster_database|TRUE\nSETTING|compatible|19.0.0\nSETTING|db_block_size|8192\nSETTING|db_files|200\nSETTING|instance_number|%s\nSETTING|spfile|%s\nSETTING|tde_configuration|KEYSTORE_CONFIGURATION=HSM\nSETTING|thread|%s\nSETTING|undo_tablespace|UNDOTBS%s\nSETTING|wallet_root|%s/wallet\n' "$num" "$parameter" "$num" "$num" "$F_DIR"
}
sql() {
    local sid=$1 out=$2 host=${3:-} query num=1
    query=$(cat)
    printf 'SQL %s %s\n%s\n' "$sid" "${out##*/}" "$query" >> "$F_DIR/calls"
    [[ $sid == CATALOG || $sid == PRE1 || $sid == PRE2 ]] || die 'fixture: non-target/source SQL connection'
    : > "$out"
    case ${out##*/} in
        config-paths.out) printf '%s\n%s/password\n%s/control\n' "$CDB_PARAM_VALUE" "$F_DIR" "$F_DIR" > "$out" ;;
        node.*.config) printf 'IDENTITY|PRE|PREM1|42|PRIMARY|%s\n' "$sid" > "$out"; settings "$sid" >> "$out"; printf 'PASSWORD|%s/password\nVERSION|19.27.0.0.0\nPATCH|123|APPLY|SUCCESS\n' "$F_DIR" >> "$out" ;;
        node.*.pfile-source) printf '%s/dbs/init%s.ora\n' "$ORACLE_HOME" "$sid" > "$out" ;;
        source.out) printf '9|999\n' > "$out" ;;
        incarnation.out) printf '7|1|2024-01-01 00:00:00\n' > "$out" ;;
        source-files.out) cp "$tmp/source.good" "$out" ;;
        source-online-redo.out) printf '4|2|4\n' > "$out" ;;
        redo-size.mounted) printf '4\n' > "$out" ;;
        redo-inventory.out) printf '1|1|100|2024-12-01 00:00:00\n2|1|100|2024-12-01 00:00:00\n' > "$out" ;;
        restore-range.out) printf '2024-01-01 01:00:00\n' > "$out" ;;
        controlfile-count.out) printf '1\n' > "$out" ;;
        tempfiles.raw.out|tempfiles.opened.raw|tempfiles.final.raw) printf '1\n2\n' > "$out" ;;
        temp-size.out) printf '20\n' > "$out" ;;
        pfile-export.out) printf "*.sga_target=4000M\n*.job_queue_processes=1000\n*.db_file_name_convert='PROD','PRE'\n" > "$CDB_WORK/target-memory.ora" ;;
        source-files.mounted|source-files.opened|source-files.final)
            cut -d'|' -f1-3 "$tmp/source.good" > "$out"
            if [[ $F_CASE == missing-source-file ]]; then sed '4d' "$out" > "$out.edit"; mv "$out.edit" "$out"; fi ;;
        new-files.*)
            printf 'DATA|+DATA/PREM1/DATAFILE/system.20.100\nDATA|+DATA/PREM1/DATAFILE/seed.21.100\nDATA|+DATA/PREM1/DATAFILE/app.22.100\nDATA|+DATA/PREM1/DATAFILE/other.23.100\nTEMP|+DATA/PREM1/TEMPFILE/temp.24.100\nREDO|+DATA/PREM1/ONLINELOG/group.25.100\n' > "$out"
            if [[ $F_CASE == source-path && $out == *mounted ]]; then printf 'DATA|+DATA/PRODM1/DATAFILE/bad.26.100\n' >> "$out"; fi ;;
        new-identity) printf '1000\n' > "$out" ;;
        controls.mounted) printf '%s/control\n' "$F_DIR" > "$out" ;;
        copied-pdbs.out) printf '%s\nOTHER\n' "$SOURCE_PDB" > "$out"; if [[ $F_CASE == conflicting-pdb ]]; then printf '%s\n' "$TARGET_PDB" >> "$out"; fi ;;
        containers.out) printf 'CDB$ROOT\n%s\nOTHER\n' "$TARGET_PDB" > "$out" ;;
        patches.copied) printf 'PATCH|123|APPLY|SUCCESS\n' > "$out" ;;
        services.dictionary) printf 'pre_app|APPTEST\npre_batch|APPTEST\npre_other|OTHER\npre_root|-\n' > "$out" ;;
        controlled-shutdown.out) rm -f "$F_DIR/controlled"; printf 'ORACLE instance shut down.\n' > "$out" ;;
        final-settings.*) settings "$sid" > "$out" ;;
        final.PRE2) [[ $F_CASE != final-node2-failure ]] || die 'fixture: final node not ready' ;;
        keys.*) [[ $F_CASE != ckms-failure ]] || die 'fixture: source key inaccessible' ;;
        *) ;;
    esac
}
rman() {
    printf 'RMAN %s %s\n' "$1" "$2" >> "$F_DIR/calls"
    [[ ! -e $F_DIR/DATA && ! -e $F_DIR/TEMP && ! -e $F_DIR/REDO && ! -e $F_DIR/STANDBY_REDO && -e $RUN/deletion.complete ]] || die 'fixture: restore started before full deletion'
    [[ $F_CASE != restore-failure ]] || die 'fixture: restore interrupted'
    printf 'fixture RMAN succeeded\n' > "$4"
}
srv() {
    local out=$1; shift
    printf 'SRV %s\n' "$*" >> "$F_DIR/calls"
    : > "$out"
    case $1:$2 in
        config:database)
            local registered_parameter=$F_DIR/spfile
            [[ $F_CASE != pfile ]] || registered_parameter=''
            printf 'Oracle home: %s\nType: RAC\nDatabase is administrator managed\nDatabase instances: PRE1,PRE2\nSpfile: %s\nPassword file: %s/password\n' "$ORACLE_HOME" "$registered_parameter" "$F_DIR" > "$out" ;;
        config:service)
            if (($# == 4)); then
                printf 'Service name: %s\n' pre_app pre_batch pre_other pre_root > "$out"
            else
                local svc=$6 pdb=APPTEST
                [[ $svc != pre_other ]] || pdb=OTHER
                [[ $svc != pre_root ]] || pdb=''
                printf 'Service name: %s\nPluggable database name: %s\nPreferred instances: PRE1,PRE2\nServer pool: PREM1_%s\nService is %s\n' "$svc" "$pdb" "$svc" "$(cat "$F_DIR/$svc.enabled")" > "$out"
            fi ;;
        status:service)
            local svc=$6 running
            running=$(cat "$F_DIR/$svc.running")
            if [[ $running == - ]]; then printf 'Service %s is not running.\n' "$svc" > "$out"
            else printf 'Service %s is running on instance(s) %s\n' "$svc" "$running" > "$out"; fi ;;
        status:database) printf 'Instance PRE1 is not running on node node1\nInstance PRE2 is not running on node node2\n' > "$out" ;;
        disable:database) printf 'disabled\n' > "$F_DIR/db-enabled" ;;
        enable:database) printf 'enabled\n' > "$F_DIR/db-enabled" ;;
        stop:database) rm -f "$F_DIR/running" ;;
        start:database)
            [[ -e $RUN/cutover && ! -e $F_DIR/controlled ]] || die 'fixture: uncontrolled RAC restart'
            [[ $(cat "$F_DIR/pre_app.enabled") == disabled && $(cat "$F_DIR/pre_app.running") == - ]] || die 'fixture: automatic service exposed copy'
            touch "$F_DIR/running" ;;
        disable:service) printf 'disabled\n' > "$F_DIR/$6.enabled" ;;
        enable:service) [[ -e $RUN/database-ready ]] || die 'fixture: services released early'; printf 'enabled\n' > "$F_DIR/$6.enabled" ;;
        stop:service) printf '%s\n' - > "$F_DIR/$6.running" ;;
        start:service)
            [[ -e $RUN/database-ready ]] || die 'fixture: services started early'
            printf '%s\n' "$8" > "$F_DIR/$6.running"
            [[ $F_CASE != service-release-failure ]] || die 'fixture: start state unknown' ;;
        *) die "fixture: unexpected srvctl $*" ;;
    esac
}
export F_DIR F_CASE
mkdir -p "$tmp/oracle/bin"
cat > "$tmp/oracle/bin/sqlplus" <<'CLIENT'
#!/usr/bin/env bash
set -eu
input=$(cat)
[[ $input == *'startup nomount pfile='* ]] || exit 90
[[ ! -f $F_DIR/running && ! -f $F_DIR/DATA ]] || exit 91
printf 'NOMOUNT\n'
touch "$F_DIR/controlled"
CLIENT
printf '#!/usr/bin/env bash\nexit 95\n' > "$tmp/oracle/bin/asmcmd"
chmod +x "$tmp/oracle/bin/"*
run_case() {
    F_CASE=$1 F_DIR=$tmp/$1
    mkdir -p "$F_DIR/work" "$F_DIR/source" "$F_DIR/evidence" "$F_DIR/wallet/tde" "$F_DIR/wallet/tde_seps" "$F_DIR/wallet/tls" "$F_DIR/wallet/server_seps"
    : > "$F_DIR/calls"
    printf 'source-CKMS\0\377' > "$F_DIR/source/cwallet.sso"
    printf 'old-TDE' > "$F_DIR/wallet/tde/cwallet.sso"
    printf 'stale-target-credentials' > "$F_DIR/wallet/tde_seps/cwallet.sso"
    printf 'catalog-wallet' > "$F_DIR/wallet/server_seps/cwallet.sso"
    printf 'retain-TLS' > "$F_DIR/wallet/tls/cwallet.sso"
    printf 'original-parameter-file' > "$F_DIR/spfile"
    printf 'original-password-file' > "$F_DIR/password"
    printf 'old-controlfile' > "$F_DIR/control"
    for kind in DATA TEMP REDO STANDBY_REDO; do printf 'old-database' > "$F_DIR/$kind"; done
    printf 'enabled\n' > "$F_DIR/db-enabled"
    touch "$F_DIR/running"
    for svc in pre_app pre_batch pre_other pre_root; do printf 'enabled\n' > "$F_DIR/$svc.enabled"; printf '%s\n' - > "$F_DIR/$svc.running"; done
    printf 'disabled\n' > "$F_DIR/pre_other.enabled"
    printf 'PRE1\n' > "$F_DIR/pre_app.running"
    # cdb_inventory is the frozen target SQL inventory, including standby redo.
    cdb_inventory() {
        printf 'DATA|%s/DATA|12\nTEMP|%s/TEMP|12\nREDO|%s/REDO|12\nREDO|%s/STANDBY_REDO|12\n' "$F_DIR" "$F_DIR" "$F_DIR" "$F_DIR" > "$1"
    }
    set +e
    (
        set -Eeuo pipefail
        RUN=$F_DIR/evidence LOG=$RUN/run.log PHASE=fixture CUTOVER=untouched ORACLE_HOME=$tmp/oracle DB_UNIQUE_NAME=PREM1 TARGET_SID=PRE1 LOCK=''
        local -a requested_names=("${names[@]}") time_args=(--time '2024-10-01 10:20:05')
        [[ $F_CASE != same-name ]] || requested_names=(--source-cdb PROD --target-cdb PRE --source-pdb APPTEST --target-pdb APPTEST)
        [[ $F_CASE != latest ]] || time_args=()
        if [[ $F_CASE == pfile ]]; then
            ORACLE_HOME=$F_DIR/oracle
            mkdir -p "$ORACLE_HOME/dbs" "$ORACLE_HOME/bin"
            cp "$tmp/oracle/bin/"* "$ORACLE_HOME/bin/"
            printf "*.db_name='PRE'\n" > "$ORACLE_HOME/dbs/initPRE1.ora"
            cp "$ORACLE_HOME/dbs/initPRE1.ora" "$ORACLE_HOME/dbs/initPRE2.ora"
        fi
        parse_args "${requested_names[@]}" --mode cdb --work-dir "$F_DIR/work" --source-wallet-dir "$F_DIR/source" --restore-parallelism 4 "${time_args[@]}"
        [[ $F_CASE == dry-run ]] || DRY_RUN=0
        trap finish EXIT
        cdb_main
    ) > "$F_DIR/console" 2>&1
    F_RC=$?
    set -e
}
# Reclaim credit belongs only to exact files in that ASM group. The same
# manifest gets no credit after deletion; unrelated filesystem bytes never count.
F_DIR=$tmp/capacity F_CASE=pre-delete-space
mkdir -p "$F_DIR"
: > "$F_DIR/calls"
RUN=$F_DIR LOG=$F_DIR/log PHASE=capacity ORACLE_HOME=$tmp/oracle
SOURCE_MB=60 CDB_TEMP_MB=0 CDB_REDO_MB=5 DUP_REDO_RESERVE_MB=1 AUX_DATA_DEST=+DATA AUX_RECO_DEST=+RECO
printf '[{"path":"+DATA/PREM1/DATAFILE/old.1.1","bytes":104857600},{"path":"+RECO/PREM1/ONLINELOG/old.2.1","bytes":10485760},{"path":"/unrelated/large","bytes":1099511627776}]' > "$RUN/old-files.json"
cdb_capacity before > "$tmp/capacity-console"
reject cdb_capacity after
sed 's/+DATA/+OTHER/' "$RUN/old-files.json" > "$RUN/changed"
mv "$RUN/changed" "$RUN/old-files.json"
reject cdb_capacity before
ok
for scenario in dry-run complete same-name latest pfile pre-delete-space parameter-drift unmanaged-instance control-backup-failure node2-wallet-failure partial-delete post-delete-space restore-failure missing-source-file source-path conflicting-pdb ckms-failure final-node2-failure service-release-failure; do
    run_case "$scenario"
    if [[ $scenario == complete || $scenario == same-name || $scenario == latest || $scenario == pfile || $scenario == dry-run ]]; then
        if ((F_RC)); then cat "$F_DIR/console"; exit 1; fi
    else
        ((F_RC != 0)) || { printf 'Expected failure: %s\n' "$scenario"; exit 1; }
        [[ ! -e $F_DIR/evidence/complete ]]
    fi
    [[ $(cat "$F_DIR/password") == original-password-file && $(cat "$F_DIR/wallet/server_seps/cwallet.sso") == catalog-wallet && $(cat "$F_DIR/wallet/tls/cwallet.sso") == retain-TLS ]]
    grep -q 'all existing target physical standbys require recreation' "$F_DIR/console"
    if grep -Eqi 'drop database|unplug|create pluggable database|import encryption keys|dbms_scheduler.disable|dbms_job.broken|APPLY-OFF' "$F_DIR/calls"; then cat "$F_DIR/calls"; exit 1; fi
    case $scenario in
        dry-run)
            [[ -e $F_DIR/DATA && $(cat "$F_DIR/wallet/tde/cwallet.sso") == old-TDE && -e $F_DIR/running ]]
            ! grep -Eq 'SRV (stop|start|enable|disable)|RMAN' "$F_DIR/calls" ;;
        complete|same-name|latest|pfile)
            [[ -e $F_DIR/evidence/complete && -e $F_DIR/running && ! -e $F_DIR/wallet/tde_seps ]]
            [[ $(cat "$F_DIR/pre_app.running") == PRE1 && $(cat "$F_DIR/pre_other.enabled") == disabled && $(cat "$F_DIR/pre_batch.running") == - ]]
            [[ $(grep -c 'DELETED$' "$F_DIR/evidence/deletion.results") == 4 ]]
            [[ $(grep -c 'allocate auxiliary channel' "$F_DIR/evidence/duplicate.rman") == 4 ]]
            grep -Fq "duplicate database 'PROD' dbid 999 to 'PRE'" "$F_DIR/evidence/duplicate.rman"
            ! grep -Eqi 'spfile|password file|for standby|from active|skip|pluggable database' "$F_DIR/evidence/duplicate.rman"
            [[ $(grep -c '^RMAN ' "$F_DIR/calls") == 4 ]]
            if [[ $scenario == same-name ]]; then
                if grep -q 'rename global_name' "$F_DIR/calls"; then exit 1; fi
            else grep -q 'rename global_name to APPTEST' "$F_DIR/calls"; fi
            [[ $scenario != latest ]] || ! grep -qi 'until' "$F_DIR/evidence/duplicate.rman" ;;
        pre-delete-space|parameter-drift|unmanaged-instance|control-backup-failure|node2-wallet-failure)
            [[ -e $F_DIR/DATA && ! -e $F_DIR/evidence/deletion.started ]]
            ! grep -q '^RMAN ' "$F_DIR/calls" ;;
        partial-delete)
            [[ -e $F_DIR/evidence/destructive-boundary && ! -e $F_DIR/evidence/deletion.complete ]]
            [[ $(grep -c 'DELETED$' "$F_DIR/evidence/deletion.results") == 1 ]]
            ! grep -q '^RMAN ' "$F_DIR/calls" ;;
        post-delete-space)
            [[ -e $F_DIR/evidence/deletion.complete && ! -e $F_DIR/controlled ]]
            ! grep -q '^RMAN ' "$F_DIR/calls" ;;
        missing-source-file|source-path)
            ! grep -q 'alter database open resetlogs' "$F_DIR/calls" ;;
        final-node2-failure)
            [[ ! -e $F_DIR/evidence/database-ready && $(cat "$F_DIR/pre_app.enabled") == disabled ]] ;;
        service-release-failure)
            [[ -e $F_DIR/evidence/database-ready && $(cat "$F_DIR/pre_app.enabled") == disabled && $(cat "$F_DIR/pre_app.running") == - ]] ;;
    esac
    ok
 done
printf 'Passed %s CDB argument, manifest and full-workflow/failure fixtures. No Oracle, RAC or network operations performed.\n' "$checks"
