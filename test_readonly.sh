#!/usr/bin/env bash
# Collect deployment evidence. Never call dup_db.sh's main/refresh workflow.
# Chained validation predicates intentionally reject any failed prerequisite.
# shellcheck disable=SC2015
set +x
if ((BASH_VERSINFO[0] < 4)); then
    printf 'Bash 4 or newer is required.\n' >&2
    exit 2
fi
DIAG_SCRIPT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_readonly.sh
DIAG_LIB=${DIAG_SCRIPT%/*}/dup_db.sh
[[ -r $DIAG_LIB ]] || { printf 'Keep test_readonly.sh beside dup_db.sh.\n' >&2; exit 2; }
# Reuse the refresh validators and read-only inventory parsers, without main().
# shellcheck source-path=SCRIPTDIR
# shellcheck source=dup_db.sh
source "$DIAG_LIB"
LOG='' VPC_PASSWORD=''

diag_usage() {
    cat <<'EOF'
Usage: bash test_readonly.sh --source-cdb NAME --target-cdb NAME \
       --source-pdb NAME --target-pdb NAME \
       --aux-cdb NAME --aux-base PATH [--aux-wallet-root PARENT] \
       [--zdlra-alias ALIAS] [--time "YYYY-MM-DD HH:MM:SS"] \
       [--aux-sga-mb MIB] [--aux-pga-mb MIB] [--redo-reserve-mb MIB] \
       [--output FILE] [--timeout SECONDS]

Run manually as oracle on the designated target primary RAC node, with Bash 4+.
Keep this script beside dup_db.sh. No internet access or extra Python packages.
Uses /home/oracle/<TARGET_CDB>.env unchanged; it must be trusted and side-effect free.
Only SELECT queries, srvctl config/status and broker SHOW commands against Oracle.
Never starts an auxiliary, runs RMAN, takes a refresh lock, or changes apply/PDBs/services.
Writes one private report plus temporary evidence, removed after inclusion in the report.
Also copies the complete target WALLET_ROOT privately, validates it, then removes the copy.
--aux-wallet-root optionally selects an existing copy parent (default: --aux-base).
Wallet contents are never included in the report; no pre-provisioned auxiliary wallet is needed.
Default output: ./readonly_<source>_to_<target>_<UTC timestamp>_<pid>.txt
Existing output files are refused. The output's parent directory must already exist.
Default timeout: 60 seconds per client command (1-3600); requires GNU timeout/gtimeout.
--aux-base is a small filesystem work directory (PFILE, XML, audit and diagnostics).
Auxiliary ASM groups are discovered from target DB_CREATE_FILE_DEST and DB_RECOVERY_FILE_DEST.
Checks combined auxiliary/target data capacity and recovery-group redo reserve.
Recovery timestamps use fixed UTC+02:00, matching dup_db.sh.
Exit 0: collected checks passed; 1: failed checks/invalid arguments; 2: setup failure.
EOF
}

diag_parse_args() {
    DIAG_OUTPUT='' DIAG_TIMEOUT=60
    local seen=' ' opt value
    local -a forward=()
    while (($#)); do
        opt=$1; shift
        case $opt in
            --help) diag_usage; exit 0 ;;
            --do-duplicate|--purge-log|--debug)
                die "$opt is not accepted by the read-only collector." ;;
            --output|--timeout)
                [[ $seen != *" $opt "* ]] || die "Repeated option: $opt"
                seen+="$opt "
                (($#)) && [[ -n $1 && $1 != --* ]] || die "Missing value for $opt"
                value=$1; shift
                if [[ $opt == --output ]]; then DIAG_OUTPUT=$value; else DIAG_TIMEOUT=$value; fi ;;
            *) forward+=("$opt") ;;
        esac
    done
    if ((${#forward[@]} == 0)); then
        diag_usage >&2
        exit 1
    fi
    parse_args "${forward[@]}"
    positive "$DIAG_TIMEOUT" && ((DIAG_TIMEOUT <= 3600)) || die '--timeout must be 1-3600 seconds.'
    [[ $DIAG_OUTPUT != *$'\n'* && $DIAG_OUTPUT != *$'\r'* ]] || die 'Invalid output filename.'
}

diag_timeout() {
    "$DIAG_TIMEOUT_BIN" --kill-after=5s "${DIAG_TIMEOUT}s" "$@"
}

# These replace the client wrappers from dup_db.sh. Refuse mutating operations
# even if a reused helper is subsequently changed to request one.
sql() {
    local db=$1 out=$2 host=${3:-} remote=${4:-0} query rc=0
    local -a command
    query=$(cat)
    printf '%s\n' "$query" | awk '
      BEGIN {RS=";"}
      {sub(/^[[:space:]]*/, ""); if (length && tolower($0)!~/^select[[:space:]]/) exit 1}
    ' || die 'Read-only guard: SQL must contain SELECT statements only.'
    if printf '%s\n' "$query" | grep -Eiq '^[[:space:]]*([@!\/]|(host|connect|execute|exec|start|set|spool|exit|quit|startup|shutdown)([[:space:]]|$))'; then
        die 'Read-only guard: SQL*Plus commands are not accepted in queries.'
    fi
    [[ $db == CATALOG ]] || identifier "$db" 30 || die 'Unsafe instance name.'
    [[ ${db^^} != "$DUP_AUX_CDB" ]] || die 'Read-only guard: no auxiliary connection is allowed.'
    if [[ -n $host && ( $db != "$TARGET_SID" || $remote == 1 ) ]]; then
        [[ $host =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || die 'Unsafe SSH hostname.'
        command=(ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o UpdateHostKeys=no
            -o ConnectTimeout=10 -o ControlMaster=no -o ControlPath=none "oracle@$host"
            "set -e; . /home/oracle/$TARGET_CDB.env >/dev/null 2>&1; set +x; unset TWO_TASK LOCAL SQLPATH ORACLE_PATH; cd /; export ORACLE_SID='$db' TZ=Etc/GMT-2 NLS_LANG=AMERICAN_AMERICA.AL32UTF8; exec \"\$ORACLE_HOME/bin/sqlplus\" -L -s /nolog")
    else
        command=(env "ORACLE_SID=$db" "$ORACLE_HOME/bin/sqlplus" -L -s /nolog)
    fi
    printf '%s\n' "$query" > "$out.sql"
    printf 'SQL instance=%s host=%s\n' "$db" "${host:-local}" >> "$LOG"
    {
        printf '%s\n' 'whenever oserror exit failure rollback' 'whenever sqlerror exit failure rollback'
        printf '%s\n' 'set echo off verify off feedback off heading off pagesize 0 linesize 32767 trimspool on tab off define off'
        if [[ $db == CATALOG ]]; then
            printf 'connect %s/"%s"@"%s"\n' "$VPC_USER" "$VPC_PASSWORD" "$RA_ALIAS"
        else
            printf '%s\n' 'connect / as sysdba'
        fi
        printf '%s\n' "$query" 'exit success rollback'
    } | diag_timeout "${command[@]}" 2>&1 | redact | tee "$out" >> "$LOG" || rc=$?
    if ((rc)) || grep -Eq '(^|[[:space:]])(ORA-|SP2-|TNS-|LRM-)[0-9]+' "$out"; then
        cat "$out" >&2
        die "SQL*Plus failed for $db (exit $rc; 124/137 indicates a timeout)."
    fi
}

srv() {
    local out=$1 rc=0; shift
    case ${1:-}:${2:-} in
        config:database|config:service|status:database|status:service) ;;
        *) die 'Read-only guard: srvctl permits config/status database/service only.' ;;
    esac
    diag_timeout "$ORACLE_HOME/bin/srvctl" "$@" 2>&1 | redact | tee "$out" >> "$LOG" || rc=$?
    ((rc == 0)) || die "srvctl failed (exit $rc; 124/137 indicates a timeout)."
}

broker() {
    local out=$1 statement=$2 rc=0
    local db_pattern="^SHOW DATABASE '[A-Za-z][A-Za-z0-9_]*';$"
    local inst_pattern="^SHOW INSTANCE VERBOSE '[A-Za-z][A-Za-z0-9_]*' ON DATABASE '[A-Za-z][A-Za-z0-9_]*';$"
    [[ $statement == 'SHOW CONFIGURATION VERBOSE;' || $statement =~ $db_pattern || $statement =~ $inst_pattern ]] || die 'Read-only guard: broker permits SHOW commands only.'
    diag_timeout env "ORACLE_SID=$TARGET_SID" "$ORACLE_HOME/bin/dgmgrl" -silent / "$statement" 2>&1 |
        redact | tee "$out" >> "$LOG" || rc=$?
    if ((rc)) || grep -Eqi '(ORA-|DGM-|TNS-)[0-9]+|(^|[[:space:]])(Error:|Failed\.|Unable to|not connected|syntax error|unrecognized command)' "$out"; then
        printf 'Broker failure (exit %s; 124/137 indicates a timeout).\n' "$rc" >&2
        return 1
    fi
}

# Fixed, non-parameterized read-only probe inherited from the library command
# builder; run it with the collector deadline just like every other client.
broker_config_probe() {
    local out=$1 inst=$2 host=$3 rc=0
    broker_config_command "$inst" "$host"
    printf '%s\n' 'SHOW CONFIGURATION VERBOSE;' 'EXIT;' |
        diag_timeout "${BROKER_CONFIG_COMMAND[@]}" 2>&1 | redact | tee "$out" >> "$LOG" || rc=$?
    ((rc == 0))
}

rman() { die 'Read-only guard: this collector never runs RMAN.'; }

diag_load_environment() {
    [[ $(id -un) == oracle ]] || die 'Run as oracle on the designated target primary node.'
    # Never retain arbitrary environment-file output, which could contain secrets.
    load_environment "/home/oracle/$TARGET_CDB.env" >/dev/null 2>&1 || die 'Target environment file could not be loaded.'
    set +x
    set -Eeuo pipefail
    umask 077
    export TZ=Etc/GMT-2 LC_ALL=C NLS_LANG=AMERICAN_AMERICA.AL32UTF8
    unset TWO_TASK LOCAL SQLPATH ORACLE_PATH
    [[ -n ${ORACLE_HOME:-} && -n ${ORACLE_SID:-} && -n ${DB_UNIQUE_NAME:-} ]] || die 'Missing ORACLE_HOME, ORACLE_SID or DB_UNIQUE_NAME/ORACLE_UNQNAME in target environment.'
    TARGET_SID=$ORACLE_SID
    safe_path "$ORACLE_HOME" && identifier "$TARGET_SID" 30 && identifier "$DB_UNIQUE_NAME" 30 || die 'Unsafe Oracle environment values.'
    [[ $DUP_AUX_CDB != "${TARGET_SID^^}" && $DUP_AUX_CDB != "${DB_UNIQUE_NAME^^}" ]] || die 'Auxiliary identity collides with target.'
    local marker
    marker=$(printf '%s\n' "${DB_UNIQUE_NAME^^}" | grep -oE 'M[12]' || true)
    [[ $marker == M1 || $marker == M2 ]] || die 'Target unique name must contain exactly one M1 or M2 marker.'
    SOURCE_UNIQUE="$SOURCE_CDB$marker"
    [[ $DUP_AUX_CDB != "$SOURCE_UNIQUE" ]] || die 'Auxiliary identity collides with source.'
}

diag_credentials() {
    # No raw mkstore output (especially viewEntry) is ever written to a file.
    local listing entry index count line matches=0 prefix
    WALLET=${1:-"/var/opt/oracle/dbaas_acfs/$TARGET_CDB/wallet_root/server_seps"}
    [[ -r $WALLET/cwallet.sso && -r $ORACLE_HOME/lib/libra.so ]] || die 'Missing SEPS auto-login wallet or libra.so.'
    listing=$(diag_timeout "$ORACLE_HOME/bin/mkstore" -wrl "$WALLET" -listCredential </dev/null 2>&1) || die 'Timed out or failed to list SEPS credentials.'
    listing=$(printf '%s\n' "$listing" | awk '/^[[:space:]]*[0-9]+:/ {sub(/^[ \t]+/, ""); print}')
    if [[ -n $DUP_ZDLRA_ALIAS ]]; then listing=$(printf '%s\n' "$listing" | awk -v alias="$DUP_ZDLRA_ALIAS" '$2==alias'); fi
    count=$(printf '%s\n' "$listing" | awk 'NF {n++} END {print n+0}')
    [[ $count == 1 ]] || die 'SEPS credential selection is empty/ambiguous; supply --zdlra-alias.'
    read -r index RA_ALIAS VPC_USER <<< "$listing"; index=${index%:}
    [[ $index =~ ^[0-9]+$ && $RA_ALIAS =~ ^[A-Za-z0-9_.:/-]+$ ]] && identifier "$VPC_USER" 128 || die 'Unsupported SEPS alias/username.'
    entry=$(diag_timeout "$ORACLE_HOME/bin/mkstore" -wrl "$WALLET" -viewEntry "oracle.security.client.password$index" </dev/null 2>&1) || die 'Timed out or failed to read selected SEPS credential.'
    VPC_PASSWORD='' prefix="oracle.security.client.password$index = "
    while IFS= read -r line; do
        if [[ $line == "$prefix"* ]]; then VPC_PASSWORD=${line#"$prefix"}; ((matches+=1)); fi
    done <<< "$entry"
    unset entry listing line
    [[ $matches == 1 && -n $VPC_PASSWORD && $VPC_PASSWORD != *'"'* && $VPC_PASSWORD != *$'\r'* && $VPC_PASSWORD != *$'\n'* ]] || die 'Cannot safely read/quote selected SEPS password.'
    export -n VPC_PASSWORD
    printf 'Catalog alias=%s user=%s credential-index=%s (password omitted)\n' "$RA_ALIAS" "$VPC_USER" "$index"
}

diag_with_catalog() { diag_credentials; "$@"; }

diag_os() {
    date -u '+UTC time: %Y-%m-%dT%H:%M:%SZ'
    uname -sr
    hostname
    id
    printf 'Bash: %s\n' "$BASH_VERSION"
    cksum "$DIAG_SCRIPT" "$DIAG_LIB"
    if [[ -r /proc/meminfo ]]; then sed -n '1,6p' /proc/meminfo; fi
}

diag_syntax() { bash -n "$DIAG_LIB"; bash -n "$DIAG_SCRIPT"; }
diag_environment() {
    printf 'Loading /home/oracle/%s.env (file output suppressed).\n' "$TARGET_CDB"
    diag_load_environment
    printf 'Environment: /home/oracle/%s.env\nORACLE_HOME=%s\nORACLE_SID=%s\nDB_UNIQUE_NAME=%s\nExpected source unique name=%s\n' "$TARGET_CDB" "$ORACLE_HOME" "$TARGET_SID" "$DB_UNIQUE_NAME" "$SOURCE_UNIQUE"
}

diag_clients() {
    local tool failed=0
    for tool in sqlplus rman mkstore srvctl; do
        if [[ -x $ORACLE_HOME/bin/$tool ]]; then printf 'FOUND %s\n' "$ORACLE_HOME/bin/$tool"
        else printf 'MISSING %s\n' "$ORACLE_HOME/bin/$tool"; failed=1; fi
    done
    if [[ -x $ORACLE_HOME/bin/dgmgrl ]]; then printf 'OPTIONAL (topology-dependent) %s\n' "$ORACLE_HOME/bin/dgmgrl"
    else printf 'DGMGRL absent; permitted only for verified standalone metadata path.\n'; fi
    if [[ -x $ORACLE_HOME/bin/sqlplus ]]; then
        diag_timeout "$ORACLE_HOME/bin/sqlplus" -V > "$RUN/sqlplus-version.txt"
        grep -q 'Release 19\.' "$RUN/sqlplus-version.txt" || failed=1
    fi
    ((failed == 0)) || die 'Missing or unsupported Oracle 19c clients; remaining checks will still be attempted.'
}

diag_wallet_finish() {
    local rc=$?
    trap - EXIT
    set +e
    cleanup_aux_wallet || rc=1
    exit "$rc"
}

diag_auxiliary() {
    local failed=0
    AUX='' AUX_WALLET_DIR='' AUX_WALLET_ROOT='' AUX_WALLET_STATUS=not-created AUXILIARY_STATE=not-started
    trap diag_wallet_finish EXIT
    read_target_settings "$1"
    printf 'Requested auxiliary SGA/PGA: %s/%s; redo reserve: %s\n' "$(format_gib "$DUP_AUX_SGA_MB")" "$(format_gib "$DUP_AUX_PGA_MB")" "$(format_gib "$DUP_REDO_RESERVE_MB")"
    create_aux_wallet
    cleanup_aux_wallet
    trap - EXIT
    df -Pm "$DUP_AUX_BASE" | LC_ALL=C awk '
        NR==1 {print "Filesystem Size(GiB) Used(GiB) Available(GiB) Use% Mounted on"; next}
        {printf "%s %.2f %.2f %.2f %s %s\n", $1, $2/1024, $3/1024, $4/1024, $5, $6}
    '
    local df_status=("${PIPESTATUS[@]}")
    ((df_status[0] == 0 && df_status[1] == 0)) || failed=1
    ps -eo args= | awk -v sid="$DUP_AUX_CDB" 'toupper($1)=="ORA_PMON_"sid {print $1}' > "$RUN/aux-pmon.txt"
    if [[ -s $RUN/aux-pmon.txt ]]; then printf 'Auxiliary SID already has a local PMON.\n'; failed=1; fi
    srv "$RUN/cluster-databases.txt" config database
    if awk -v sid="$DUP_AUX_CDB" 'toupper($0)==sid {found=1} END {exit !found}' "$RUN/cluster-databases.txt"; then
        printf 'Auxiliary name is already registered with Clusterware.\n'; failed=1
    fi
    printf 'Filesystem capacity here is for working files only; database capacity is checked in discovered ASM groups.\n'
    printf 'Private target wallet copy validated and removed; no auxiliary started. PMON check covers this node only.\n'
    ((failed == 0)) || die 'Auxiliary provisioning checks failed.'
}

diag_target() { target_identity "$RUN/identity.txt"; validate_target_identity "$RUN/identity.txt"; }
diag_rac_inventory() {
    discover_target_rac "$RUN/rac.txt"
}

diag_pdb() {
    query_target_pdb "$RUN/pdb.txt"
    validate_target_pdb "$RUN/pdb.txt" "$DIAG_RAC_FILE"
    printf '%s\n' "$PDB_STATE" > "$RUN/pdb-state.txt"
    printf '%s\n' "${PDB_GUID:-NONE}" > "$RUN/pdb-guid.txt"
    sql "$TARGET_SID" "$RUN/saved-state.txt" <<SQL
select instance_name||'|'||state||'|'||restricted from dba_pdb_saved_states where con_name='$TARGET_PDB' order by instance_name;
SQL
    validate_saved_states "$RUN/saved-state.txt" "$DIAG_RAC_FILE" "$PDB_STATE"
    if [[ $PDB_STATE == ABSENT ]]; then
        [[ ! -s $RUN/saved-state.txt ]] || die 'Saved state exists for an absent target PDB.'
        printf 'target PDB absent; initial creation path\nInitial policy: READ WRITE, unrestricted, saved on both verified target RAC instances.\n'
        sql "$TARGET_SID" "$RUN/current-pdb-inventory.txt" <<'SQL'
select i.instance_name||'|'||p.name||'|'||p.open_mode from gv$pdbs p join gv$instance i on i.inst_id=p.inst_id order by i.instance_name,p.con_id;
SQL
    else
        printf 'target PDB present; preserve captured open/restricted/saved states and Clusterware resources.\n'
    fi
}

diag_settings() {
    discover_target_settings "$RUN/settings.txt"
    printf 'Target DB_CREATE_FILE_DEST=%s\nTarget DB_RECOVERY_FILE_DEST=%s\nTarget WALLET_ROOT=%s\n' "$TARGET_DEST" "$AUX_RECO_DEST" "$TARGET_WALLET"
}

diag_refresh_space() {
    local -a settings
    mapfile -t settings < "$1"
    ((${#settings[@]} == 5)) || die 'Incomplete verified target storage settings.'
    printf 'Estimated per-copy data/temp capacity including headroom: %s; auxiliary redo reserve: %s.\n' "$(format_gib "$2")" "$(format_gib "$DUP_REDO_RESERVE_MB")"
    discover_aux_storage "${settings[0]}" "${settings[4]}"
    check_refresh_space "$2"
}

diag_primary_node() {
    local inst=$1 host=$2
    sql "$inst" "$RUN/node.txt" "$host" <<'SQL'
select 'IDENTITY|'||d.name||'|'||d.db_unique_name||'|'||d.dbid||'|'||d.database_role||'|'||i.instance_name||'|'||i.version from v$database d cross join v$instance i;
select 'CONTAINER|'||sys_context('USERENV','CON_NAME') from dual;
select 'WALLET|'||con_id||'|'||status||'|'||wrl_type||'|'||keystore_mode from v$encryption_wallet order by con_id;
select 'PARAM|'||name||'|'||value from v$parameter where name in ('compatible','wallet_root','tde_configuration','db_create_file_dest') order by name;
select 'PATCH|'||patch_id||'|'||action||'|'||status||'|'||description from dba_registry_sqlpatch order by action_time,patch_id;
SQL
    grep -Fiq "IDENTITY|$TARGET_CDB|$DB_UNIQUE_NAME|$TARGET_DBID|PRIMARY|$inst|19." "$RUN/node.txt" &&
        grep -Fxq "CONTAINER|CDB\$ROOT" "$RUN/node.txt" || die "Target identity/19c/root mismatch on $inst."
    grep -Eq '^WALLET\|1\|OPEN\|HSM\|' "$RUN/node.txt" || die "Root HSM keystore not OPEN on $inst."
}

diag_services() {
    srv "$RUN/database-config.txt" config database -db "$DB_UNIQUE_NAME" -verbose
    srv "$RUN/database-status.txt" status database -db "$DB_UNIQUE_NAME" -verbose
    snapshot_services
    local svc _enabled running inst
    while IFS='|' read -r svc _enabled running; do
        [[ $running != - ]] || continue
        local -a instances
        IFS=',' read -r -a instances <<< "$running"
        for inst in "${instances[@]}"; do
            awk -F'|' -v i="$inst" '$1==i && $3!="MOUNTED" && $4=="NO" {ok=1} END {exit !ok}' "$DIAG_PDB_FILE" || die "Service $svc has an inconsistent/restricted PDB state on $inst."
        done
    done < "$RUN/services.tsv"
}

diag_broker_inventory() { discover_standbys diagnostic; }
diag_standby_inventory() {
    local db=$1 inst host
    standby_database "$db" inventory
    while IFS= read -r inst; do
        identifier "$inst" 30 || die 'Unsafe standby instance name.'
        broker "$RUN/$inst.txt" "SHOW INSTANCE VERBOSE '$inst' ON DATABASE '$db';" || die "Standby host discovery failed for $db/$inst."
        host=$(sed -n "s/^[[:space:]]*HostName[[:space:]]*=[[:space:]]*'\([^']*\)'[[:space:]]*$/\1/p" "$RUN/$inst.txt")
        [[ $host =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || die 'Missing/unsafe standby host.'
        printf '%s|%s\n' "$inst" "$host" >> "$RUN/nodes.txt"
    done < "$RUN/dg.$db.inventory.instances"
}

diag_standby_node() {
    local db=$1 inst=$2 host=$3 nodes=$4 guid=$5 count
    sql "$inst" "$RUN/standby.txt" "$host" 1 <<SQL
select 'IDENTITY|'||d.name||'|'||d.db_unique_name||'|'||d.dbid||'|'||d.database_role||'|'||d.cdb||'|'||i.instance_name from v\$database d cross join v\$instance i;
select 'CONTAINER|'||sys_context('USERENV','CON_NAME') from dual;
select 'BROKER|'||upper(value) from v\$parameter where name='dg_broker_start';
select 'RAC|'||instance_name||'|'||host_name from gv\$instance order by instance_name;
select 'APPLY|'||count(*) from v\$dataguard_process where name='MRP0' or lower(role) like '%recovery%';
select 'PDB|'||rawtohex(guid)||'|'||open_mode from v\$pdbs where name='$TARGET_PDB' and con_id>2;
SQL
    validate_standby_observation "$RUN/standby.txt"
    grep -Fxiq "IDENTITY|$TARGET_CDB|$db|$TARGET_DBID|PHYSICAL STANDBY|YES|$inst" "$RUN/standby.txt" &&
        grep -Fxq "CONTAINER|CDB\$ROOT" "$RUN/standby.txt" && grep -Fxq 'BROKER|TRUE' "$RUN/standby.txt" || die 'Standby identity/root/broker mismatch.'
    sed -n 's/^RAC|//p' "$RUN/standby.txt" | sort > "$RUN/rac.txt"
    sort "$nodes" > "$RUN/expected-rac.txt"
    cmp -s "$RUN/rac.txt" "$RUN/expected-rac.txt" || die 'Incomplete/mismatched standby RAC inventory.'
    one_line <(sed -n 's/^APPLY|//p' "$RUN/standby.txt"); count=$RESULT
    [[ $count =~ ^[0-9]+$ ]] || die 'Unknown actual recovery-process count.'
    printf 'Observed recovery process count=%s; no apply change was requested.\n' "$count"
    if [[ ${TARGET_PDB_STATE:-PRESENT} == ABSENT ]]; then
        ! grep -q '^PDB|' "$RUN/standby.txt" || die 'Conflicting same-name standby PDB while the target primary PDB is absent.'
        printf 'Requested PDB absent on this verified standby; no old GUID/closure prerequisite. Apply count remains observed.\n'
    else
        one_line <(sed -n 's/^PDB|//p' "$RUN/standby.txt")
        [[ $RESULT == "$guid|MOUNTED" ]] || die 'Old standby PDB is absent, GUID mismatched or open; refresh requires matching GUID/MOUNTED. No close was attempted.'
    fi
}

diag_catalog_identity() {
    sql CATALOG "$RUN/source.txt" <<SQL
select distinct d.db_key||'|'||d.dbid from rc_database d join rc_site s on s.db_key=d.db_key
where upper(d.name)='$SOURCE_CDB' and upper(s.db_unique_name)='$SOURCE_UNIQUE';
SQL
    one_line "$RUN/source.txt"
    IFS='|' read -r SOURCE_DBKEY SOURCE_DBID <<< "$RESULT"
    positive "$SOURCE_DBKEY" && [[ $SOURCE_DBID =~ ^[0-9]+$ && $SOURCE_DBID != "$TARGET_DBID" ]] || die 'Invalid/ambiguous source identity or matching source/target DBIDs.'
    local predicate="status='CURRENT'"
    [[ -z $RECOVERY_TIME ]] || predicate="resetlogs_time <= $point"
    sql CATALOG "$RUN/incarnation.txt" <<SQL
select dbinc_key||'|'||resetlogs_change#||'|'||to_char(resetlogs_time,'YYYY-MM-DD HH24:MI:SS')
from rc_database_incarnation where db_key=$SOURCE_DBKEY and status in ('CURRENT','PARENT') and $predicate
and resetlogs_time=(select max(resetlogs_time) from rc_database_incarnation where db_key=$SOURCE_DBKEY and status in ('CURRENT','PARENT') and $predicate);
SQL
    one_line "$RUN/incarnation.txt"
    IFS='|' read -r SOURCE_INC SOURCE_RESET SOURCE_RESET_TIME <<< "$RESULT"
    [[ $SOURCE_INC =~ ^[0-9]+$ && $SOURCE_RESET =~ ^[0-9]+$ ]] || die 'Unresolved source incarnation.'
}

diag_backup_size() {
    sql CATALOG "$RUN/backup-size.txt" <<SQL
select ceil(sum(bytes)/1048576)||'|'||max(root_block) from (
select file#,max(datafile_blocks*block_size) bytes,max(case when file#=1 then block_size end) root_block
from rc_backup_datafile b where db_key=$SOURCE_DBKEY and dbinc_key=$SOURCE_INC and status='A' and file#>0 and checkpoint_time < $point
and exists (select 1 from rc_backup_piece p where p.bs_key=b.bs_key and p.status='A' and p.device_type='SBT_TAPE') group by file#);
SQL
    one_line "$RUN/backup-size.txt"
    local size block
    IFS='|' read -r size block <<< "$RESULT"
    positive "$size" && [[ $block =~ ^(2048|4096|8192|16384|32768)$ ]] || die 'No usable SBT datafile inventory/root block size.'
}

diag_redo() {
    sql CATALOG "$RUN/redo-inventory.out" <<SQL
select thread#||'|'||min(sequence#)||'|'||max(sequence#)||'|'||to_char(max(next_time),'YYYY-MM-DD HH24:MI:SS')
from rc_backup_redolog r where db_key=$SOURCE_DBKEY and dbinc_key=$SOURCE_INC and status='A'
and exists (select 1 from rc_backup_piece p where p.bs_key=r.bs_key and p.status='A' and p.device_type='SBT_TAPE') group by thread# order by thread#;
SQL
    [[ $(wc -l < "$RUN/redo-inventory.out") -ge 2 ]] || die 'Missing redo inventory for both source RAC threads.'
    local thread first last through
    while IFS='|' read -r thread first last through; do
        [[ $thread =~ ^[0-9]+$ && $first =~ ^[0-9]+$ && $last =~ ^[0-9]+$ && $through =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}$ ]] || die 'Unrecognized redo metadata.'
    done < "$RUN/redo-inventory.out"
}

diag_range() { cp "$DIAG_REDO_FILE" "$RUN/redo-inventory.out"; dry_run_range; }
diag_tempfiles() {
    sql CATALOG "$RUN/tempfiles.raw.txt" <<SQL
select distinct file# from rc_tempfile where db_key=$SOURCE_DBKEY and dbinc_key=$SOURCE_INC
and creation_time <= $point and (drop_time is null or drop_time > $point) order by file#;
SQL
    normalize_tempfile_ids "$RUN/tempfiles.raw.txt" "$RUN/tempfiles.normalized.txt"
    sql CATALOG "$RUN/temp-size.raw.txt" <<SQL
select ceil(nvl(sum(bytes),0)/1048576) from (select file#,max(bytes) bytes from rc_tempfile where db_key=$SOURCE_DBKEY and dbinc_key=$SOURCE_INC
and creation_time <= $point and (drop_time is null or drop_time > $point) group by file#);
SQL
    one_line "$RUN/temp-size.raw.txt"
    [[ $RESULT =~ ^[0-9]+$ ]] || die 'Unknown tempfile size.'
    # diag_check runs in a subshell: persist the validated scalar, rather than
    # rereading SQL*Plus formatting (notably CRLF) for later capacity arithmetic.
    printf '%s\n' "$RESULT" > "$RUN/temp-size.normalized.txt"
}

diag_append_evidence() {
    local dir=$1 file
    for file in "$dir"/*; do
        [[ -f $file ]] || continue
        printf '\n--- %s ---\n' "${file##*/}"
        cat "$file"
    done >> "$DIAG_OUTPUT"
}

diag_check() {
    local name=$1 description=$2 rc; shift 2
    ((DIAG_TOTAL+=1))
    DIAG_LAST_DIR="$DIAG_WORK/$DIAG_TOTAL.$name"
    mkdir "$DIAG_LAST_DIR"
    DIAG_ACTIVE=$DIAG_LAST_DIR
    printf 'Checking: %s\n' "$description"
    printf '\n=== %s: %s ===\n' "$name" "$description" >> "$DIAG_OUTPUT"
    # Do not put the checked function in an if/|| expression: that disables
    # Bash errexit inside functions, potentially misreporting a failed check.
    set +e
    (
        set -Eeuo pipefail
        RUN=$DIAG_LAST_DIR LOG=$DIAG_LAST_DIR/client.log PHASE=$name DEBUG=0
        cd "$RUN"  # No user login.sql from the launch directory.
        "$@"
    ) > "$DIAG_LAST_DIR/console.txt" 2>&1
    rc=$?
    set -e
    DIAG_LAST_RC=$rc
    if ((rc == 0)); then
        ((DIAG_PASSED+=1)); printf '[PASS] %s\n' "$name" | tee -a "$DIAG_OUTPUT"
    else
        ((DIAG_FAILED+=1)); printf '[FAIL] %s (exit %s)\n' "$name" "$rc" | tee -a "$DIAG_OUTPUT"
    fi
    diag_append_evidence "$DIAG_LAST_DIR"
    DIAG_ACTIVE=''
}

diag_skip() {
    ((DIAG_TOTAL+=1)); ((DIAG_SKIPPED+=1))
    printf '[SKIP] %s: %s\n' "$1" "$2" | tee -a "$DIAG_OUTPUT"
}

diag_finish() {
    local rc=$?
    trap - EXIT
    set +e
    if [[ -n ${DIAG_ACTIVE:-} ]]; then diag_append_evidence "$DIAG_ACTIVE"; fi
    if [[ ${DIAG_FINALIZED:-0} != 1 ]]; then
        printf '\nABORTED (exit %s). The report may be incomplete.\n' "$rc" >> "$DIAG_OUTPUT"
    fi
    unset VPC_PASSWORD
    [[ -z ${DIAG_WORK:-} ]] || rm -rf -- "$DIAG_WORK"
    printf 'Report: %s\n' "$DIAG_OUTPUT"
    exit "$rc"
}

diag_main() {
    set -Eeuo pipefail
    umask 077
    diag_parse_args "$@"
    DIAG_OUTPUT=${DIAG_OUTPUT:-"$PWD/readonly_${SOURCE_CDB}_to_${TARGET_CDB}_$(date -u '+%Y%m%dT%H%M%SZ')_$$.txt"}
    DIAG_OUTPUT=$(cd "$(dirname "$DIAG_OUTPUT")" && printf '%s/%s' "$PWD" "$(basename "$DIAG_OUTPUT")") || die 'Output parent directory does not exist.'
    (set -C; : > "$DIAG_OUTPUT") || { printf 'Refusing to overwrite output: %s\n' "$DIAG_OUTPUT" >&2; exit 2; }
    DIAG_TOTAL=0 DIAG_PASSED=0 DIAG_FAILED=0 DIAG_SKIPPED=0 DIAG_FINALIZED=0 DIAG_ACTIVE='' DIAG_WORK=''
    trap diag_finish EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP
    printf 'ZDLRA read-only diagnostics v1\nSource: %s/%s (catalog only)\nTarget: %s/%s\nRequested recovery time (UTC+02:00): %s\nTimeout per client command: %ss (+5s kill grace)\n' "$SOURCE_CDB" "$SOURCE_PDB" "$TARGET_CDB" "$TARGET_PDB" "${RECOVERY_TIME:-latest available}" "$DIAG_TIMEOUT" >> "$DIAG_OUTPUT"
    DIAG_WORK=$(mktemp -d "${TMPDIR:-/tmp}/zdlra_readonly.XXXXXX")
    DIAG_WORK=$(cd "$DIAG_WORK" && pwd)
    local tool
    for tool in awk sed grep tee df date find mktemp cmp sort cksum ps ls cp chmod bash hostname id uname wc rm mkdir; do
        command -v "$tool" >/dev/null || { printf 'Missing required utility: %s\n' "$tool" >> "$DIAG_OUTPUT"; exit 2; }
    done
    DIAG_TIMEOUT_BIN=$(command -v timeout || command -v gtimeout) || { printf 'GNU timeout/gtimeout is required.\n' >> "$DIAG_OUTPUT"; exit 2; }
    diag_check os 'Host, account, memory and script fingerprints' diag_os
    diag_check syntax 'Bash syntax of both scripts' diag_syntax
    diag_check environment 'Load and validate standard target environment' diag_environment
    if ((DIAG_LAST_RC)); then
        diag_skip oracle-checks 'Target environment failed; Oracle/SSH/catalog checks cannot safely proceed.'
    else
        diag_load_environment >/dev/null 2>&1
        diag_check clients 'Oracle client availability and SQL*Plus version' diag_clients
        diag_check identity 'Verify requested target primary CDB/root/DBID' diag_target
        local identity_dir=$DIAG_LAST_DIR
        if ((DIAG_LAST_RC)); then
            diag_skip target-and-catalog 'Target identity failed; further database and broker connections suppressed.'
        else
            TARGET_DBID=$(awk -F'|' 'NR==1 {print $3}' "$identity_dir/identity.txt")
            diag_check rac 'Target RAC instance and hostname inventory' diag_rac_inventory
            local rac_dir=$DIAG_LAST_DIR rac_rc=$DIAG_LAST_RC inst host state version
            DIAG_RAC_FILE=$rac_dir/rac.txt
            local primary_rc=0
            if ((rac_rc == 0)); then
                while IFS='|' read -r inst host state version; do
                    diag_check "primary-$inst" "Primary node $inst: OS authentication, version, HSM and SQL patches" diag_primary_node "$inst" "$host"
                    ((DIAG_LAST_RC == 0)) || primary_rc=1
                done < "$DIAG_RAC_FILE"
            else diag_skip primary-nodes 'Complete verified RAC inventory unavailable.'; primary_rc=1; fi
            local pdb_rc=1
            TARGET_PDB_STATE=UNKNOWN TARGET_PDB_GUID=''
            if ((rac_rc == 0 && primary_rc == 0)); then
                diag_check pdb 'Target PDB presence, open modes, GUID and saved state' diag_pdb
                DIAG_PDB_FILE=$DIAG_LAST_DIR/pdb.txt
                pdb_rc=$DIAG_LAST_RC
                if ((pdb_rc == 0)); then
                    read -r TARGET_PDB_STATE < "$DIAG_LAST_DIR/pdb-state.txt"
                    read -r TARGET_PDB_GUID < "$DIAG_LAST_DIR/pdb-guid.txt"
                fi
            else diag_skip pdb 'Required target RAC node verification failed; PDB absence cannot be established.'; fi
            diag_check settings 'Target ASM data/recovery destinations, compatibility and HSM/external-store configuration' diag_settings
            local settings_dir=$DIAG_LAST_DIR settings_rc=$DIAG_LAST_RC
            if ((settings_rc == 0)); then
                diag_check auxiliary 'Private target wallet copy/cleanup, auxiliary working space and observed name occupancy' diag_auxiliary "$settings_dir/settings.txt"
            else diag_skip auxiliary 'Verified target WALLET_ROOT settings unavailable; wallet copying suppressed.'; fi
            if ((pdb_rc == 0)); then diag_check services 'Clusterware service snapshots and PDB/service consistency' diag_services
            else diag_skip services 'Target PDB inventory failed.'; fi
            diag_check broker 'Classify target topology from both-node configuration and broker membership where applicable' diag_broker_inventory
            local broker_dir=$DIAG_LAST_DIR broker_rc=$DIAG_LAST_RC db nodes_dir
            if ((broker_rc == 0)); then
                if [[ ! -s $broker_dir/dg.diagnostic.standbys ]]; then
                    printf 'No physical standby configured; topology classification: %s\nStandby SSH, old-PDB closure and apply checks: NOT APPLICABLE.\n' "$(cat "$broker_dir/dg.diagnostic.mode")" >> "$DIAG_OUTPUT"
                fi
                while IFS= read -r db; do
                    diag_check "standby-$db" "Standby $db: broker state, configured instances and hosts" diag_standby_inventory "$db"
                    nodes_dir=$DIAG_LAST_DIR
                    if ((DIAG_LAST_RC == 0 && pdb_rc == 0)); then
                        # Each check writes to a fresh directory; nodes.txt is an immutable input.
                        # shellcheck disable=SC2094
                        while IFS='|' read -r inst host; do
                            diag_check "standby-$db-$inst" "Standby $db/$inst: identity, actual apply count and target PDB observation" diag_standby_node "$db" "$inst" "$host" "$nodes_dir/nodes.txt" "$TARGET_PDB_GUID"
                        done < "$nodes_dir/nodes.txt"
                    else diag_skip "standby-$db-nodes" 'Complete broker node or target PDB inventory unavailable.'; fi
                done < "$broker_dir/dg.diagnostic.standbys"
            else diag_skip standby-nodes 'Topology discovery failed/UNKNOWN; standby absence is not established.'; fi
            point="to_date('${RECOVERY_TIME:-9999-12-31 23:59:59}','YYYY-MM-DD HH24:MI:SS')"
            diag_check catalog 'SEPS authentication, source DBID and incarnation through ZDLRA' diag_with_catalog diag_catalog_identity
            local catalog_dir=$DIAG_LAST_DIR
            if ((DIAG_LAST_RC == 0)); then
                IFS='|' read -r SOURCE_DBKEY SOURCE_DBID < "$catalog_dir/source.txt"
                IFS='|' read -r SOURCE_INC SOURCE_RESET SOURCE_RESET_TIME < "$catalog_dir/incarnation.txt"
                diag_check backups 'Available SBT datafile sizes and source root block size' diag_with_catalog diag_backup_size
                local backup_dir=$DIAG_LAST_DIR backup_rc=$DIAG_LAST_RC
                diag_check redo 'Source RAC thread redo metadata' diag_with_catalog diag_redo
                DIAG_REDO_FILE=$DIAG_LAST_DIR/redo-inventory.out
                if ((DIAG_LAST_RC == 0)); then diag_check range 'Candidate recovery range and SBT controlfile metadata' diag_with_catalog diag_range
                else diag_skip range 'Complete source RAC redo metadata unavailable.'; fi
                diag_check tempfiles 'Source tempfile inventory and size' diag_with_catalog diag_tempfiles
                local temp_dir=$DIAG_LAST_DIR temp_rc=$DIAG_LAST_RC size block temp_mb need
                if ((backup_rc == 0 && temp_rc == 0)); then
                    IFS='|' read -r size block < "$backup_dir/backup-size.txt"
                    read -r temp_mb < "$temp_dir/temp-size.normalized.txt"
                    need=$((size + temp_mb + (size + temp_mb) / 4))
                    if ((settings_rc == 0)); then
                        diag_check target-space 'Combined auxiliary and target ASM capacity including redo reserve' diag_refresh_space "$settings_dir/settings.txt" "$need"
                    else diag_skip target-space 'Verified ASM data/recovery destinations unavailable.'; fi
                else diag_skip capacity 'Source datafile/tempfile size metadata unavailable.'; fi
            else diag_skip catalog-metadata 'Catalog authentication or source identity/incarnation failed.'; fi
        fi
    fi
    printf '\nNOT RUN (requires a later operational test): SBT allocation/media reads, complete source PDB/file coverage, redo continuity, auxiliary startup/recovery, historical HSM key access/key import, encrypted block validation, plug compatibility, service restoration and cutover/apply changes.\nNo application validation performed. Metadata space/range checks are estimates.\n' >> "$DIAG_OUTPUT"
    printf '\nSUMMARY: total=%s PASS=%s FAIL=%s SKIP=%s\n' "$DIAG_TOTAL" "$DIAG_PASSED" "$DIAG_FAILED" "$DIAG_SKIPPED" | tee -a "$DIAG_OUTPUT"
    date -u '+Completed UTC: %Y-%m-%dT%H:%M:%SZ' >> "$DIAG_OUTPUT"
    DIAG_FINALIZED=1
    ((DIAG_FAILED == 0))
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then diag_main "$@"; fi
