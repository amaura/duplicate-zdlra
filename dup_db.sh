#!/usr/bin/env bash
# Oracle 19c / ZDLRA PDB refresh. See README.md before running as oracle.
# Never run with a production ORACLE_SID. All source access is through the catalog.
# Chained predicates below intentionally fail if ANY validation fails.
# shellcheck disable=SC2015
set +x                         # Credentials must never enter a shell trace.

usage() {
    cat <<'EOF'
Usage: dup_db.sh --source-cdb NAME --target-cdb NAME \
                 --source-pdb NAME --target-pdb NAME \
                 --aux-cdb NAME --aux-base PATH [--aux-wallet-root PARENT] \
                 [--zdlra-alias ALIAS] [--aux-sga-mb MIB] [--aux-pga-mb MIB] \
                 [--redo-reserve-mb MIB] \
                 [--time "YYYY-MM-DD HH:MM:SS"] [--do-duplicate] [--debug] [--purge-log DAYS]

CDB arguments are DB_NAME. Time is fixed UTC+02:00; no DST conversion.
Default log retention: 7 days. Run as oracle on the designated target primary node.
Auxiliary name and filesystem work directory are required.
The complete target WALLET_ROOT is copied privately for each run, including dry run.
--aux-wallet-root optionally selects an existing parent for that fresh copy.
Default copy parent: auxiliary work directory (dry run: --aux-base).
Auxiliary ASM groups are discovered from target DB_CREATE_FILE_DEST/DB_RECOVERY_FILE_DEST.
Default auxiliary SGA/PGA/redo reserve: 4096/1024/10240 MiB.
Use --zdlra-alias when the SEPS wallet has multiple credentials.
The standard /home/oracle/<TARGET_CDB>.env supplies Oracle settings; do not edit it.
An existing target CDB is required; the requested target PDB may be absent.
An old target PDB is dropped only after auxiliary recovery and validation.
Default mode is dry run: check environment, catalog connectivity, target PDB and backup range.
Use --do-duplicate for target PDB replacement or initial creation.
Initial creation opens READ WRITE unrestricted and saves state on both verified RAC instances.
No-standby targets require complete runtime/SPFILE topology evidence on both RAC instances.
DGMGRL is required only for enabled broker discovery; unresolved topology blocks cutover.
There is no automatic rollback. Configured standby refresh is a separate operation.
EOF
}

die() {
    if [[ -n ${LOG:-} ]]; then
        printf 'ERROR: %s\n' "$*" | redact | tee -a "$LOG" >&2
    else
        printf 'ERROR: %s\n' "$*" >&2
    fi
    exit 1
}
identifier() { [[ $1 =~ ^[A-Za-z][A-Za-z0-9_]*$ && ${#1} -le $2 ]]; }
positive() { [[ $1 =~ ^[1-9][0-9]*$ && ${#1} -le 9 ]]; }
safe_path() { [[ $1 =~ ^/[A-Za-z0-9_./-]+$ && $1 != *'/../'* && $1 != */.. ]]; }

load_environment() {
    [[ -r $1 ]] || die "Missing/unreadable environment file: $1"
    # Keep any legacy refresh assignments in the sourced file local to this
    # function. Only CLI arguments/defaults configure the refresh operation.
    local DUP_AUX_CDB DUP_AUX_BASE DUP_AUX_WALLET_ROOT DUP_ZDLRA_ALIAS
    local DUP_AUX_SGA_MB DUP_AUX_PGA_MB DUP_REDO_RESERVE_MB
    # Trusted ExaCC shell configuration, never catalog data. Read unchanged.
    # shellcheck disable=SC1090
    source "$1"
    set +x
    DB_UNIQUE_NAME=${DB_UNIQUE_NAME:-${ORACLE_UNQNAME:-}}
}

parse_args() {
    if (($# == 0)); then
        usage >&2
        exit 1
    fi
    SOURCE_CDB='' TARGET_CDB='' SOURCE_PDB='' TARGET_PDB='' RECOVERY_TIME=''
    DEBUG=0 RETENTION=7 DRY_RUN=1
    DUP_AUX_CDB='' DUP_AUX_BASE='' DUP_AUX_WALLET_ROOT='' DUP_ZDLRA_ALIAS=''
    DUP_AUX_SGA_MB=4096 DUP_AUX_PGA_MB=1024 DUP_REDO_RESERVE_MB=10240
    local opt val seen=' '
    while (($#)); do
        opt=$1; shift
        [[ $seen != *" $opt "* ]] || die "Repeated option: $opt"
        seen+="$opt "
        case $opt in
            --help) usage; exit 0 ;;
            --debug) DEBUG=1 ;;
            --do-duplicate) DRY_RUN=0 ;;
            --source-cdb|--target-cdb|--source-pdb|--target-pdb|--time|--purge-log|\
            --aux-cdb|--aux-base|--aux-wallet-root|--zdlra-alias|--aux-sga-mb|--aux-pga-mb|--redo-reserve-mb)
                (($#)) && [[ -n $1 && $1 != --* ]] || die "Missing value for $opt"
                val=$1; shift
                case $opt in
                    --source-cdb) SOURCE_CDB=${val^^} ;;
                    --target-cdb) TARGET_CDB=${val^^} ;;
                    --source-pdb) SOURCE_PDB=${val^^} ;;
                    --target-pdb) TARGET_PDB=${val^^} ;;
                    --time) RECOVERY_TIME=$val ;;
                    --purge-log) RETENTION=$val ;;
                    --aux-cdb) DUP_AUX_CDB=${val^^} ;;
                    --aux-base) DUP_AUX_BASE=$val ;;
                    --aux-wallet-root) DUP_AUX_WALLET_ROOT=$val ;;
                    --zdlra-alias) DUP_ZDLRA_ALIAS=$val ;;
                    --aux-sga-mb) DUP_AUX_SGA_MB=$val ;;
                    --aux-pga-mb) DUP_AUX_PGA_MB=$val ;;
                    --redo-reserve-mb) DUP_REDO_RESERVE_MB=$val ;;
                esac ;;
            *) die "Unknown argument: $opt (see --help)" ;;
        esac
    done
    identifier "$SOURCE_CDB" 8 && identifier "$TARGET_CDB" 8 || die 'CDB names must be 1-8 simple Oracle identifier characters.'
    identifier "$SOURCE_PDB" 30 && identifier "$TARGET_PDB" 30 || die 'PDB names must be 1-30 simple Oracle identifier characters.'
    [[ $SOURCE_CDB != "$TARGET_CDB" ]] || die 'Source and target DB_NAME must differ.'
    positive "$RETENTION" || die '--purge-log requires a positive integer.'
    [[ -n $DUP_AUX_CDB ]] || die '--aux-cdb is required.'
    [[ -n $DUP_AUX_BASE ]] || die '--aux-base is required.'
    identifier "$DUP_AUX_CDB" 8 || die '--aux-cdb must be 1-8 simple Oracle identifier characters.'
    [[ $DUP_AUX_CDB != "$SOURCE_CDB" && $DUP_AUX_CDB != "$TARGET_CDB" ]] || die 'Auxiliary identity must be distinct from source and target.'
    safe_path "$DUP_AUX_BASE" || die '--aux-base must be an absolute path without whitespace, parent traversal or SQL metacharacters.'
    [[ -z $DUP_AUX_WALLET_ROOT ]] || safe_path "$DUP_AUX_WALLET_ROOT" || die '--aux-wallet-root must be an absolute parent path without whitespace, parent traversal or SQL metacharacters.'
    [[ -z $DUP_ZDLRA_ALIAS || $DUP_ZDLRA_ALIAS =~ ^[A-Za-z0-9_.:/-]+$ ]] || die '--zdlra-alias contains unsupported characters.'
    positive "$DUP_AUX_SGA_MB" || die '--aux-sga-mb requires a positive MiB integer.'
    positive "$DUP_AUX_PGA_MB" || die '--aux-pga-mb requires a positive MiB integer.'
    positive "$DUP_REDO_RESERVE_MB" || die '--redo-reserve-mb requires a positive MiB integer.'
    if [[ -n $RECOVERY_TIME ]]; then
        [[ $RECOVERY_TIME =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}$ ]] || die 'Quote --time as "YYYY-MM-DD HH:MM:SS".'
        local y m d maxday
        y=$((10#${RECOVERY_TIME:0:4})); m=$((10#${RECOVERY_TIME:5:2})); d=$((10#${RECOVERY_TIME:8:2}))
        ((y >= 1 && m >= 1 && m <= 12 && d >= 1 && 10#${RECOVERY_TIME:11:2} < 24 && 10#${RECOVERY_TIME:14:2} < 60 && 10#${RECOVERY_TIME:17:2} < 60)) || die 'Invalid recovery timestamp.'
        case $m in
            4|6|9|11) maxday=30 ;;
            2) maxday=28; if ((y % 4 == 0 && (y % 100 != 0 || y % 400 == 0))); then maxday=29; fi ;;
            *) maxday=31 ;;
        esac
        ((d <= maxday)) || die 'Invalid recovery calendar date.'
    fi
}

log() { printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S +02:00')" "$PHASE" "$*" | tee -a "$LOG"; }
phase() { PHASE=$1; log "$2"; printf '%s\n' "$PHASE" > "$RUN/phase"; }
redact() {
    local line
    while IFS= read -r line || [[ -n $line ]]; do
        if [[ -n ${VPC_PASSWORD:-} ]]; then line=${line//"$VPC_PASSWORD"/[REDACTED]}; fi
        printf '%s\n' "$line"
    done
}
finish() {
    local rc=$?
    trap - EXIT
    set +e
    unset VPC_PASSWORD
    if ((rc)); then
        log "FAILED (exit $rc). Phase: $PHASE. Cutover state: $CUTOVER. Evidence: $RUN"
        if [[ ${TARGET_PDB_STATE:-UNKNOWN} == ABSENT ]]; then
            log 'Initial creation path: no old target PDB was captured or dropped. Check whether CREATE completed before manual recovery.'
        fi
        if (( ${DRY_RUN:-0} )); then
            log 'Dry-run check failed; no restore or cutover was attempted.'
        else
            log 'Retain the auxiliary and snapshots. Follow README.md manual recovery; do not rerun blindly.'
        fi
        if grep -Eq 'ORA-(283[0-9]{2}|284[0-9]{2}|466[0-9]{2}|20003|20008)' "$LOG"; then
            log 'TDE/HSM diagnostic: the exact redacted Oracle/RMAN error is above. A copy of target WALLET_ROOT does not prove access to historical production keys. Check HSM/provider access using the established operator procedure; catalog SEPS authentication is separate.'
        fi
    fi
    if (( ${DRY_RUN:-0} )); then
        log "Dry run: wallet copy status=${AUX_WALLET_STATUS:-not-created}; no auxiliary startup, service, PDB or Data Guard changes performed."
    elif [[ ${DG_HANDOFF:-not-checked} == no-standby && ${DG_TOPOLOGY:-UNKNOWN} == NONE ]]; then
        log "Data Guard: no configured physical standby; evidence=${DG_TOPOLOGY_EVIDENCE:-unresolved}; no apply change or standby refresh handoff."
    elif [[ ${DG_APPLY_ATTEMPTED:-0} == 0 && ! -s $RUN/dg.preflight.standbys ]]; then
        log "Data Guard topology=${DG_TOPOLOGY:-UNKNOWN}; no apply stop was attempted. Inspect retained discovery evidence."
    else
        log "Data Guard handoff: ${DG_HANDOFF:-not-checked}. See $RUN/dg* for original/resulting states; UNKNOWN requires investigation."
        log 'Apply is never restarted automatically. Leave any stopped apply OFF for the separate standby-refresh procedure, including after failure; do not resume it blindly.'
    fi
    cleanup_aux_wallet || rc=1
    [[ -n ${LOCK:-} ]] && rm -f "$LOCK/owner" && rmdir "$LOCK"
    exit "$rc"
}

# SQL is read from stdin. Authentication is sent through a pipe, never argv/files.
# Output files contain only redacted output. SQL*Plus errors that escape WHENEVER
# (notably SP2 errors) are checked as well as the process exit status.
sql() {
    local db=$1 out=$2 host=${3:-} force_remote=${4:-0} rc=0
    local -a command
    if [[ -n $host && ( $db != "$TARGET_SID" || $force_remote == 1 ) ]]; then
        command=(ssh -o BatchMode=yes -o ConnectTimeout=10 "oracle@$host"
            "set -e; . /home/oracle/$TARGET_CDB.env >/dev/null; set +x; unset TWO_TASK LOCAL SQLPATH; export ORACLE_SID='$db' TZ=Etc/GMT-2 NLS_LANG=AMERICAN_AMERICA.AL32UTF8; exec \"\$ORACLE_HOME/bin/sqlplus\" -L -s /nolog")
    else
        command=(env "ORACLE_SID=$db" "$ORACLE_HOME/bin/sqlplus" -L -s /nolog)
    fi
    {
        printf '%s\n' 'whenever oserror exit failure rollback' 'whenever sqlerror exit failure rollback'
        printf '%s\n' 'set echo off verify off feedback off heading off pagesize 0 linesize 32767 trimspool on tab off define off serveroutput on'
        if [[ $db == CATALOG ]]; then
            printf 'connect %s/"%s"@"%s"\n' "$VPC_USER" "$VPC_PASSWORD" "$RA_ALIAS"
        else
            printf '%s\n' 'connect / as sysdba'
        fi
        printf '%s\n' "alter session set nls_date_format='YYYY-MM-DD HH24:MI:SS';" "alter session set time_zone='+02:00';"
        cat
        printf '\nexit success\n'
    } | "${command[@]}" 2>&1 | redact | tee "$out" >> "$LOG" || rc=$?
    if ((rc)) || grep -Eq '(^|[[:space:]])(ORA-|SP2-|TNS-)[0-9]+' "$out"; then
        cat "$out" >&2; die "SQL*Plus failed in $PHASE (database/instance $db)."
    fi
    ((DEBUG == 0)) || cat "$out"
}

rman() {
    local sid=$1 mode=$2 script=$3 out=$4 rc=0
    {
        if [[ $mode == duplicate ]]; then
            printf 'connect catalog %s/"%s"@"%s";\n' "$VPC_USER" "$VPC_PASSWORD" "$RA_ALIAS"
            printf '%s\n' 'connect auxiliary /;'
        else
            # This TARGET is the LOCAL auxiliary or destination, NEVER production.
            printf '%s\n' 'connect target /;'
        fi
        cat "$script"
        printf '\nexit;\n'
    } | env "ORACLE_SID=$sid" "$ORACLE_HOME/bin/rman" 2>&1 | redact | tee "$out" >> "$LOG" || rc=$?
    if ((rc)) || grep -Eq 'RMAN-00569|RMAN-03002|RMAN-03009|ORA-[0-9]+|LRM-[0-9]+' "$out"; then
        cat "$out" >&2; die "RMAN failed in $PHASE (local instance $sid)."
    fi
    ((DEBUG == 0)) || cat "$out"
}

srv() {
    local out=$1; shift
    local rc=0
    "$ORACLE_HOME/bin/srvctl" "$@" 2>&1 | redact | tee "$out" >> "$LOG" || rc=$?
    ((rc == 0)) || { cat "$out" >&2; die "srvctl failed in $PHASE (exit $rc)."; }
}

one_line() {
    local file=$1
    RESULT=$(sed '/^[[:space:]]*$/d; s/^[[:space:]]*//; s/[[:space:]]*$//' "$file")
    [[ -n $RESULT && $RESULT != *$'\n'* ]] || die "Expected exactly one result in $file."
}

# SQL*Plus pads numeric columns. Keep its redacted raw output unchanged, and
# publish a consumer inventory only after every nonblank row is a positive ID.
# Never remove interior whitespace or interpret returned IDs as shell arithmetic.
normalize_tempfile_ids() {
    local raw=$1 normalized=$2
    [[ $raw != "$normalized" ]] || die 'Tempfile raw and normalized artifacts must differ.'
    if ! awk '
      {sub(/^[[:space:]]+/, ""); sub(/[[:space:]]+$/, "")}
      !length {next}
      !/^[1-9][0-9]*$/ {bad=1; exit}
      {print; count++}
      END {if (bad || !count) exit 1}
    ' "$raw" > "$normalized"; then
        rm -f -- "$normalized"
        die "Missing/unrecognized catalog tempfile numbers; raw output retained in $raw."
    fi
}

# The CDB instance inventory must never depend on an optional PDB. Retain the
# query output and reject partial, duplicate, offline or malformed RAC metadata.
discover_target_rac() {
    sql "$TARGET_SID" "$1" <<'SQL'
select instance_name||'|'||host_name||'|'||status||'|'||version from gv$instance order by instance_name;
SQL
    validate_target_rac "$1"
}

validate_target_rac() {
    local inst host status version extra count=0 seen='|'
    awk -F'|' 'NF!=4 {exit 1}' "$1" || die 'Malformed target RAC column count.'
    while IFS='|' read -r inst host status version extra || [[ -n $inst ]]; do
        identifier "$inst" 30 && [[ $host =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ && $status == OPEN && $version =~ ^19\.[0-9]+(\.[0-9]+)*$ && -z $extra ]] || die 'Malformed/offline target RAC inventory.'
        [[ $seen != *"|${inst^^}|"* ]] || die 'Duplicate target RAC instance.'
        seen+="${inst^^}|"; ((count+=1))
    done < "$1"
    ((count == 2)) || die 'Both target RAC instances must be online independently of target PDB presence.'
    awk -F'|' -v sid="$TARGET_SID" '$1==sid {found=1} END {exit !found}' "$1" || die 'Local target SID is absent from the verified RAC inventory.'
}

query_target_pdb() {
    sql "$TARGET_SID" "$1" <<SQL
select i.instance_name||'|'||i.host_name||'|'||p.open_mode||'|'||nvl(p.restricted,'NO')||'|'||rawtohex(p.guid)
from gv\$pdbs p join gv\$instance i on i.inst_id=p.inst_id
where p.name='$TARGET_PDB' and p.con_id>2 order by i.instance_name;
SQL
}

# Successful empty SQL output means ABSENT only with a complete verified CDB
# inventory. The caller separately verifies each node's identity and HSM access.
validate_target_pdb() {
    local file=$1 rac=$2 inst host mode restricted guid extra count=0 seen='|'
    validate_target_rac "$rac"
    awk -F'|' 'length && (NF!=5 || $1=="") {exit 1}' "$file" || die 'Malformed target PDB column count/instance.'
    PDB_STATE=ABSENT PDB_GUID=''
    while IFS='|' read -r inst host mode restricted guid extra || [[ -n $inst ]]; do
        [[ -n $inst || -n $host || -n $mode || -n $restricted || -n $guid || -n $extra ]] || continue
        identifier "$inst" 30 && [[ $guid =~ ^[0-9A-F]{32}$ && -z $extra ]] || die 'Malformed target PDB inventory/GUID.'
        [[ $seen != *"|${inst^^}|"* ]] || die 'Duplicate target PDB instance.'
        seen+="${inst^^}|"; ((count+=1))
        awk -F'|' -v i="$inst" -v h="$host" '$1==i && $2==h {ok=1} END {exit !ok}' "$rac" || die 'Target PDB instance/host differs from CDB inventory.'
        [[ $restricted == YES || $restricted == NO ]] || die 'Malformed target PDB restricted state.'
        open_sql "$mode" "$restricted" >/dev/null
        [[ -z $PDB_GUID || $PDB_GUID == "$guid" ]] || die 'Target PDB GUID differs between RAC instances.'
        PDB_GUID=$guid
    done < "$file"
    if ((count)); then
        ((count == 2)) || die 'Partial target PDB presence across verified RAC instances.'
        PDB_STATE=PRESENT
    fi
}

check_target_pdb_identity() {
    local out=$1 expected=${2:-$TARGET_PDB_STATE} guid=${3:-${TARGET_PDB_GUID:-}}
    query_target_pdb "$out"
    validate_target_pdb "$out" "$TARGET_RAC_FILE"
    [[ $PDB_STATE == "$expected" ]] || die "Target PDB presence changed: expected $expected, observed $PDB_STATE; refusing cutover/create."
    [[ $expected == ABSENT || $PDB_GUID == "$guid" ]] || die 'Target PDB GUID changed; refusing cutover.'
}

prepare_pdb_policy() {
    if [[ $TARGET_PDB_STATE == PRESENT ]]; then
        cp "$RUN/pdb.before" "$RUN/pdb.expected"
        cp "$RUN/saved.before" "$RUN/saved.expected"
    else
        # These are the new-PDB policy, not snapshots of a nonexistent old PDB.
        awk -F'|' '{print $1 "|" $2 "|READ WRITE|NO"}' "$TARGET_RAC_FILE" > "$RUN/pdb.expected"
        awk -F'|' '{print $1 "|OPEN|NO"}' "$TARGET_RAC_FILE" > "$RUN/saved.expected"
    fi
}

validate_saved_states() {
    local file=$1 rac=$2 state=$3 inst saved restricted seen='|'
    [[ $state != ABSENT || ! -s $file ]] || die 'Saved state exists for an absent target PDB.'
    awk -F'|' 'NF!=3 {exit 1}' "$file" || die 'Malformed saved-state columns.'
    while IFS='|' read -r inst saved restricted; do
        [[ $seen != *"|${inst^^}|"* ]] || die 'Duplicate saved-state instance.'
        seen+="${inst^^}|"
        awk -F'|' -v i="$inst" '$1==i {found=1} END {exit !found}' "$rac" || die 'Saved PDB state references an unavailable RAC instance.'
        [[ $restricted == YES || $restricted == NO ]] || die 'Malformed saved restricted state.'
        open_sql "$saved" "$restricted" >/dev/null
    done < "$file"
}

# Shared by refresh, dry run and the diagnostic collector. Discovery depends
# only on the verified primary CDB, never on the requested PDB's presence.
read_target_settings() {
    local -a settings
    mapfile -t settings < "$1"
    ((${#settings[@]} == 5)) || die 'Missing target OMF/compatible/TDE/wallet settings.'
    TARGET_DEST=${settings[0]}; COMPATIBLE=${settings[1]}; TDE_CONFIGURATION=${settings[2]}; TARGET_WALLET=${settings[3]}
    discover_aux_storage "$TARGET_DEST" "${settings[4]}"
    [[ $TARGET_DEST =~ ^\+[A-Za-z0-9_/]+$ ]] || safe_path "$TARGET_DEST" || die 'Unsupported target OMF destination.'
    [[ $COMPATIBLE =~ ^19\.[0-9.]+$ && $TDE_CONFIGURATION =~ ^[A-Za-z_=\|]+$ && ${TDE_CONFIGURATION^^} == *HSM* ]] || die 'This workflow requires 19c compatibility and an HSM TDE configuration.'
    safe_path "$TARGET_WALLET" || die 'Unsupported target WALLET_ROOT path.'
}

discover_target_settings() {
    sql "$TARGET_SID" "$1" <<'SQL'
select value from v$parameter where name='db_create_file_dest';
select value from v$parameter where name='compatible';
select value from v$parameter where name='tde_configuration';
select value from v$parameter where name='wallet_root';
select nvl(value,'UNSET') from v$parameter where name='db_recovery_file_dest';
SQL
    read_target_settings "$1"
}

# TLS credentials are unrelated to duplication. Share this inventory across
# validation, copying and verification so the exclusion and counts agree.
wallet_tree_entries() {
    find "$1" -path "$1/tls" -prune -o -print0
}

wallet_tree_check() {
    local root=$1 entry walker
    WALLET_ENTRY_COUNT=0
    [[ -d $root && ! -L $root ]] || die 'Missing or unsafe wallet root directory.'
    # Outside the excluded top-level tls entry, reject all links, special
    # files and inaccessible entries. No wallet listing/content enters evidence.
    while IFS= read -r -d '' entry; do
        ((WALLET_ENTRY_COUNT+=1))
        [[ ! -L $entry ]] || die 'Wallet tree contains a symlink; supply a complete tree of independent regular files/directories.'
        if [[ -d $entry ]]; then
            [[ -r $entry && -x $entry ]] || die 'Wallet tree contains an inaccessible directory.'
        else
            [[ -f $entry && -r $entry ]] || die 'Wallet tree contains an unreadable or nonregular file.'
        fi
    done < <(wallet_tree_entries "$root" 2>/dev/null)
    walker=$!
    wait "$walker" || die 'Unable to inspect the complete wallet tree.'
    [[ -s $root/tde/cwallet.sso && -s $root/tde_seps/cwallet.sso ]] || die 'Missing/empty required target wallet file: tde/cwallet.sso or tde_seps/cwallet.sso.'
}

check_aux_wallet() {
    local parent=${DUP_AUX_WALLET_ROOT:-${AUX:-$DUP_AUX_BASE}} evidence ancestor
    [[ -d $DUP_AUX_BASE && -r $DUP_AUX_BASE && -w $DUP_AUX_BASE && -x $DUP_AUX_BASE ]] || die 'Provision an accessible writable auxiliary filesystem work directory first.'
    AUX_BASE_PHYSICAL=$(cd -- "$DUP_AUX_BASE" && pwd -P)
    safe_path "$TARGET_WALLET" && [[ -d $TARGET_WALLET ]] || die 'Missing or unsafe discovered target WALLET_ROOT directory.'
    WALLET_SOURCE=$(cd -- "$TARGET_WALLET" && pwd -P)
    safe_path "$parent" && [[ -d $parent && -r $parent && -w $parent && -x $parent ]] || die 'Wallet copy parent must be an existing accessible writable directory.'
    AUX_WALLET_PARENT=$(cd -- "$parent" && pwd -P)
    safe_path "$WALLET_SOURCE" && safe_path "$AUX_BASE_PHYSICAL" && safe_path "$AUX_WALLET_PARENT" || die 'Unsafe physical wallet/work path (filesystem root is refused).'
    [[ $AUX_BASE_PHYSICAL != "$WALLET_SOURCE" && $AUX_BASE_PHYSICAL != "$WALLET_SOURCE/"* && $AUX_WALLET_PARENT != "$WALLET_SOURCE" && $AUX_WALLET_PARENT != "$WALLET_SOURCE/"* ]] || die 'Auxiliary working space and wallet copy parent must be outside target WALLET_ROOT, including aliases.'
    for ancestor in "$AUX_BASE_PHYSICAL" "$AUX_WALLET_PARENT"; do
        while [[ $ancestor != / ]]; do
            [[ ! $ancestor -ef $WALLET_SOURCE ]] || die 'Auxiliary work/copy parent aliases target WALLET_ROOT or its subtree.'
            ancestor=${ancestor%/*}; ancestor=${ancestor:-/}
        done
    done
    for evidence in "$RUN" "${DIAG_WORK:-$RUN}"; do
        evidence=$(cd -- "$evidence" && pwd -P)
        [[ $AUX_WALLET_PARENT != "$evidence" && $AUX_WALLET_PARENT != "$evidence/"* && $AUX_BASE_PHYSICAL != "$evidence" && $AUX_BASE_PHYSICAL != "$evidence/"* ]] || die 'Wallet working space must be outside report/evidence packaging.'
    done
    wallet_tree_check "$WALLET_SOURCE"
    log "Target WALLET_ROOT source=$WALLET_SOURCE; fresh private copy parent=$AUX_WALLET_PARENT."
}

wallet_status() {
    AUX_WALLET_STATUS=$1
    printf '%s\n' "$AUX_WALLET_ROOT" > "$RUN/auxiliary-wallet-path"
    printf '%s|auxiliary=%s\n' "$AUX_WALLET_STATUS" "$AUXILIARY_STATE" > "$RUN/auxiliary-wallet-status"
    log "Auxiliary wallet copy: $AUX_WALLET_STATUS; path=$AUX_WALLET_ROOT; auxiliary=$AUXILIARY_STATE."
}

create_aux_wallet() {
    [[ -z ${AUX_WALLET_DIR:-} ]] || die 'This run already has a wallet copy; never reuse or overwrite it.'
    check_aux_wallet
    local expected_entries=$WALLET_ENTRY_COUNT validated=0
    # The outer directory stays 0700 throughout copying, even if source file
    # modes are permissive. Existing contents of the parent are never reused.
    AUX_WALLET_DIR=$(mktemp -d "$AUX_WALLET_PARENT/aux_wallet_${DUP_AUX_CDB}_XXXXXX") || die 'Unable to create private wallet working directory.'
    AUX_WALLET_ROOT=$AUX_WALLET_DIR/wallet_root
    wallet_status creating
    chmod 700 "$AUX_WALLET_DIR"
    mkdir -m 700 "$AUX_WALLET_ROOT"
    local entry relative dest walker
    # Copy each regular file independently; never follow links or preserve hard
    # links. Fresh private directories preserve the included relative layout.
    while IFS= read -r -d '' entry; do
        [[ $entry != "$WALLET_SOURCE" ]] || continue
        relative=${entry#"$WALLET_SOURCE/"}; dest=$AUX_WALLET_ROOT/$relative
        [[ ! -L $entry && ! -e $dest && ! -L $dest ]] || die 'Wallet tree changed or copy destination already exists; copy incomplete.'
        if [[ -d $entry ]]; then
            mkdir -m 700 "$dest" || die 'Unable to copy complete wallet directory layout.'
        else
            [[ -f $entry && -r $entry ]] || die 'Wallet source became unreadable/nonregular; copy incomplete.'
            cp -P "$entry" "$dest" >/dev/null 2>&1 || die 'Wallet file copy failed; auxiliary startup is blocked.'
            [[ -f $dest && ! -L $dest && ! $dest -ef $entry ]] || die 'Wallet copy is not an independent regular file.'
            chmod u+rw,go-rwx "$dest" || die 'Cannot protect copied wallet file owner access.'
            cmp -s "$entry" "$dest" || die 'Wallet copy byte verification failed; auxiliary startup is blocked.'
        fi
    done < <(wallet_tree_entries "$WALLET_SOURCE" 2>/dev/null)
    walker=$!
    wait "$walker" || die 'Incomplete wallet source traversal; auxiliary startup is blocked.'
    wallet_tree_check "$AUX_WALLET_ROOT"
    [[ $WALLET_ENTRY_COUNT == "$expected_entries" ]] || die 'Wallet inventory changed or copy is incomplete.'
    # Recheck the source inventory too, detecting files added/removed during copy.
    while IFS= read -r -d '' entry; do
        ((validated+=1))
        relative=${entry#"$WALLET_SOURCE"}; dest=$AUX_WALLET_ROOT$relative
        [[ ! -L $entry && ! -L $dest ]] || die 'Wallet tree changed to contain a symlink during copying.'
        if [[ -d $entry ]]; then
            [[ -d $dest ]] || die 'Wallet copy directory verification failed.'
        else
            [[ -f $entry && -r $entry && -f $dest && ! $entry -ef $dest ]] && cmp -s "$entry" "$dest" || die 'Wallet copy completeness verification failed.'
        fi
    done < <(wallet_tree_entries "$WALLET_SOURCE" 2>/dev/null)
    walker=$!
    wait "$walker" || die 'Unable to verify complete wallet source inventory.'
    [[ $validated == "$expected_entries" ]] || die 'Wallet source inventory changed during copying.'
    wallet_status ready
}

cleanup_aux_wallet() {
    [[ -n ${AUX_WALLET_DIR:-} ]] || return 0
    [[ ${AUX_WALLET_STATUS:-} != removed ]] || return 0
    case ${AUXILIARY_STATE:-unknown} in
        not-started|stopped)
            if [[ ! -L $AUX_WALLET_DIR && -d $AUX_WALLET_DIR && -O $AUX_WALLET_DIR && ${AUX_WALLET_DIR%/*} == "$AUX_WALLET_PARENT" && ${AUX_WALLET_DIR##*/} == aux_wallet_"$DUP_AUX_CDB"_* && $AUX_WALLET_DIR != "$WALLET_SOURCE" && $AUX_WALLET_DIR != "$WALLET_SOURCE/"* ]] &&
                rm -rf -- "$AUX_WALLET_DIR" 2>/dev/null && [[ ! -e $AUX_WALLET_DIR && ! -L $AUX_WALLET_DIR ]]; then
                wallet_status removed
                return 0
            fi
            wallet_status cleanup-failed ;;
        *) wallet_status retained ;;
    esac
    log "Retained private wallet: $AUX_WALLET_ROOT. Confirm auxiliary SID $DUP_AUX_CDB is shut down before manual cleanup: rm -rf -- '$AUX_WALLET_DIR'"
    [[ $AUX_WALLET_STATUS != cleanup-failed ]]
}

shutdown_auxiliary() {
    AUXILIARY_STATE=unknown
    sql "$DUP_AUX_CDB" "$RUN/aux-shutdown.out" <<'SQL'
shutdown immediate;
SQL
    grep -Eq '^[[:space:]]*ORACLE instance shut down\.[[:space:]]*$' "$RUN/aux-shutdown.out" || die 'Auxiliary shutdown was not confirmed; retain its private wallet.'
    AUXILIARY_STATE=stopped
    cleanup_aux_wallet
}

start_auxiliary() {
    [[ ${AUX_WALLET_STATUS:-} == ready && -d $AUX_WALLET_ROOT && ! $AUX_WALLET_ROOT -ef $WALLET_SOURCE ]] || die 'A verified independent wallet copy is required before auxiliary startup.'
    # STARTUP without FORCE fails if the SID is in use. Never shut down an
    # unknown SID. sql() cannot be used: its preamble needs a running instance.
    local startup_rc=0
    AUXILIARY_STATE=unknown
    {
        printf '%s\n' 'whenever oserror exit failure' 'whenever sqlerror exit failure' 'connect / as sysdba'
        printf "startup nomount pfile='%s';\nexit success\n" "$AUX/init.ora"
    } | env "ORACLE_SID=$DUP_AUX_CDB" "$ORACLE_HOME/bin/sqlplus" -L -s /nolog 2>&1 | redact | tee "$RUN/startup.out" >> "$LOG" || startup_rc=$?
    if ((startup_rc)) || grep -Eq 'ORA-|SP2-|LRM-' "$RUN/startup.out"; then cat "$RUN/startup.out" >&2; die 'Auxiliary startup failed.'; fi
    AUXILIARY_STATE=running
    wallet_status in-use
}

target_identity() {
    sql "$TARGET_SID" "$1" <<'SQL'
select name||'|'||db_unique_name||'|'||dbid||'|'||database_role||'|'||cdb||'|'||open_mode from v$database;
select 'CONTAINER|'||sys_context('USERENV','CON_NAME') from dual;
select 'FILE|'||con_id||'|'||file#||'|'||name from v$datafile where con_id in (1,2) order by con_id,file#;
select 'CONFIG|'||name||'|'||value from v$rman_configuration order by name;
SQL
}

validate_target_identity() {
    local name unique dbid role cdb state
    IFS='|' read -r name unique dbid role cdb state < "$1"
    [[ $name == "$TARGET_CDB" && ${unique^^} == "${DB_UNIQUE_NAME^^}" && $role == 'PRIMARY' && $cdb == YES && $state == 'READ WRITE' && $dbid =~ ^[0-9]+$ ]] || die 'Destination is not the requested read-write PRIMARY CDB.'
    grep -Fxq "CONTAINER|CDB\$ROOT" "$1" || die 'Destination connection must be the CDB root.'
    TARGET_DBID=$dbid
}

# Ordinary broker SHOW/EDIT sessions use local authentication on the verified target SID.
# Single-command mode plus output checks: DGMGRL can print errors with exit 0.
broker() {
    local out=$1 statement=$2 rc=0
    env "ORACLE_SID=$TARGET_SID" "$ORACLE_HOME/bin/dgmgrl" -silent / "$statement" 2>&1 | redact | tee "$out" >> "$LOG" || rc=$?
    if ((rc)) || grep -Eqi '(ORA-|DGM-|TNS-)[0-9]+|(^|[[:space:]])(Error:|Failed\.|Unable to|not connected|syntax error|unrecognized command)' "$out"; then
        cat "$out" >&2
        return 1
    fi
    ((DEBUG == 0)) || cat "$out"
}

# A fixed interactive SHOW followed by EXIT separates successful client
# completion from the documented ORA-16532 command result. No mutation command
# or caller-supplied statement can enter this probe.
broker_config_command() {
    local inst=$1 host=$2
    if [[ $inst == "$TARGET_SID" ]]; then
        BROKER_CONFIG_COMMAND=(env "ORACLE_SID=$inst" "$ORACLE_HOME/bin/dgmgrl" -silent /)
    else
        BROKER_CONFIG_COMMAND=(ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=yes -o UpdateHostKeys=no "oracle@$host"
            "set -e; . /home/oracle/$TARGET_CDB.env >/dev/null; set +x; unset TWO_TASK LOCAL SQLPATH; export ORACLE_SID='$inst'; exec \"\$ORACLE_HOME/bin/dgmgrl\" -silent /")
    fi
}

broker_config_probe() {
    local out=$1 inst=$2 host=$3 rc=0
    broker_config_command "$inst" "$host"
    printf '%s\n' 'SHOW CONFIGURATION VERBOSE;' 'EXIT;' |
        "${BROKER_CONFIG_COMMAND[@]}" 2>&1 | redact | tee "$out" >> "$LOG" || rc=$?
    ((rc == 0))
}

broker_unconfigured_output() {
    awk -v unq="$DB_UNIQUE_NAME" -v db="$TARGET_CDB" '
      /^[[:space:]]*$/ {next}
      /^(Error: )?ORA-16532: (Oracle )?Data Guard broker configuration does not exist\.?$/ {n++; next}
      /(ORA-|DGM-|TNS-)[0-9]+|Error:|Failed\.|Unable to|not connected|syntax error|unrecognized command/ {bad=1; next}
      /^Connected to / {
        name=$0; sub(/^Connected to /,"",name); gsub(/[".]$/,"",name); sub(/^"/,"",name)
        if (toupper(name)!=toupper(unq) && toupper(name)!=toupper(db)) bad=1
        next
      }
      /^Configuration details cannot be determined by DGMGRL\.?$/ {next}
      /^DGMGRL for .*Release 19\./ || /^Version 19\.[0-9.]+$/ || /^Copyright \(c\)/ {next}
      /^Connected as (SYSDBA|SYSDG)\.?$/ {next}
      {bad=1}
      END {exit (bad || n!=1)}' "$1"
}

# Complete read-only configuration evidence from each independently verified
# primary instance. Never filter destinations by ENABLE/VALID or current role.
collect_topology_node() {
    local inst=$1 host=$2 out=$3
    sql "$inst" "$out" "$host" <<'SQL'
select 'IDENTITY|'||d.name||'|'||d.db_unique_name||'|'||d.dbid||'|'||d.database_role||'|'||d.cdb||'|'||i.instance_name from v$database d cross join v$instance i;
select 'CONTAINER|'||sys_context('USERENV','CON_NAME') from dual;
select 'PARAM|'||name||'|'||nvl(value,'<NULL>') from v$system_parameter
where name in ('dg_broker_start','spfile','log_archive_config','fal_server','fal_client','log_archive_dest','log_archive_duplex_dest')
or regexp_like(name,'^log_archive_dest(_state)?_([1-9]|[12][0-9]|3[01])$') order by name;
select 'PRESENCE|'||name||'|'||case when value is null then 'ABSENT' else 'PRESENT' end from v$system_parameter where name in ('spfile','fal_server','fal_client') order by name;
select 'PERSISTENT_FAL|'||count(*) from v$spparameter where isspecified='TRUE' and name in ('fal_server','fal_client') and value is not null;
select 'SPFILE|'||sid||'|'||name||'|'||ordinal||'|'||nvl(value,'<NULL>') from v$spparameter
where isspecified='TRUE' and (name in ('dg_broker_start','log_archive_config','fal_server','fal_client','log_archive_dest','log_archive_duplex_dest')
or regexp_like(name,'^log_archive_dest(_state)?_([1-9]|[12][0-9]|3[01])$')) order by sid,name,ordinal;
select 'DEST|'||d.dest_id||'|'||d.status||'|'||nvl(d.target,'<NULL>')||'|'||nvl(d.destination,'<NULL>')||'|'||nvl(d.db_unique_name,'<NULL>')||'|'||nvl(s.type,'UNKNOWN')
from v$archive_dest d left join v$archive_dest_status s on s.dest_id=d.dest_id order by d.dest_id;
select 'MEMBER|'||db_unique_name||'|'||nvl(dest_role,'UNKNOWN')||'|'||nvl(parent_dbun,'<NULL>') from v$dataguard_config order by db_unique_name;
select 'END|TOPOLOGY' from dual;
SQL
}

# Resolve endpoint roles only from documented database metadata, never from
# host/service spelling. SPFILE values can expose dormant relationships.
# v$archive_dest_status is runtime-only, so persistent SERVICE definitions must
# match a known DB_UNIQUE_NAME or the same effective, positively typed endpoint.
parse_topology_node() {
    local file=$1 inst=$2 expected_broker=$3
    awk -F'|' -v inst="$inst" -v db="$TARGET_CDB" -v unq="$DB_UNIQUE_NAME" -v dbid="$TARGET_DBID" -v broker="$expected_broker" '
      function fail(s) {print "UNKNOWN: " s > "/dev/stderr"; bad=1}
      function ident(s) {return s ~ /^[A-Z][A-Z0-9_]*$/ && length(s)<=30}
      function pname(s) {return s ~ /^(dg_broker_start|spfile|log_archive_config|fal_server|fal_client|log_archive_dest|log_archive_duplex_dest)$/ ||
        s ~ /^log_archive_dest(_state)?_([1-9]|[12][0-9]|3[01])$/}
      function ref(name,why) {
        name=toupper(name)
        if (!ident(name) || !(name in roles)) {fail("unresolved database relationship " name " in " why); return}
        if (name!=toupper(unq)) relations[name]=roles[name]
      }
      function config(value,why, n,a,i,rest) {
        value=toupper(value); gsub(/[[:space:]]/,"",value)
        if (value=="<NULL>") return
        rest=value
        if (match(rest,/DG_CONFIG=\([^()]+\)/)) {
          value=substr(rest,RSTART+11,RLENGTH-12); rest=substr(rest,1,RSTART-1) substr(rest,RSTART+RLENGTH)
          n=split(value,a,","); for (i=1;i<=n;i++) ref(a[i],why)
        }
        gsub(/(NOSEND|SEND|NORECEIVE|RECEIVE|NODG_CONFIG|,)/,"",rest)
        if (length(rest)) fail("unrecognized LOG_ARCHIVE_CONFIG in " why)
      }
      function setting(name,value,why,remote,id,token,upper) {
        upper=toupper(value)
        if (value=="<NULL>") return
        if (name=="log_archive_config") {config(value,why); return}
        if (name=="fal_server" || name=="fal_client") {hints=1; return}
        if (name=="dg_broker_start") {if (upper!=broker) fail("runtime/persistent broker settings disagree"); return}
        if (name ~ /^log_archive_dest_state_/) {
          if (upper !~ /^(ENABLE|DEFER|ALTERNATE|RESET)$/) fail("unrecognized destination state"); return
        }
        if (name ~ /^log_archive_dest_[0-9]+$/) {
          if (upper ~ /^[[:space:]]*SERVICE[[:space:]]*=/) {
            token=upper
            if (match(token,/(^|[[:space:]])DB_UNIQUE_NAME[[:space:]]*=[[:space:]]*[A-Z][A-Z0-9_]*/)) {
              token=substr(token,RSTART,RLENGTH); sub(/^.*=[[:space:]]*/,"",token); ref(token,why)
            } else {
              id=name; sub(/^log_archive_dest_/,"",id)
              if (value!=params[name] || dtype[id]!="BACKUP APPLIANCE") fail("unresolved remote SERVICE in " why)
            }
          } else if (upper !~ /^[[:space:]]*LOCATION[[:space:]]*=/) fail("unrecognized destination definition in " why)
        }
      }
      !length {next}
      $1=="IDENTITY" && NF==7 {
        if (++identity!=1 || toupper($2)!=toupper(db) || toupper($3)!=toupper(unq) || $4!=dbid || $5!="PRIMARY" || $6!="YES" || $7!=inst) fail("primary instance identity mismatch")
        next
      }
      $1=="CONTAINER" && NF==2 {if (++container!=1 || $2!="CDB$ROOT") fail("not in target root"); next}
      $1=="PARAM" && NF==3 && pname($2) {
        if ($2 in params) fail("duplicate runtime parameter")
        params[$2]=$3; count++; next
      }
      $1=="PRESENCE" && NF==3 && $2 ~ /^(spfile|fal_server|fal_client)$/ && $3 ~ /^(ABSENT|PRESENT)$/ {
        if ($2 in presence) fail("duplicate parameter presence")
        presence[$2]=$3; presence_count++; next
      }
      $1=="PERSISTENT_FAL" && NF==2 && $2 ~ /^[0-9]+$/ {
        if (++fal_count!=1) fail("duplicate persistent FAL presence")
        persistent_fal=$2; next
      }
      $1=="SPFILE" && NF==5 && pname($3) && $4 ~ /^[0-9]+$/ {
        key=toupper($2) SUBSEP $3 SUBSEP $4
        if (key in persisted || length($5)>=255) fail("duplicate or possibly truncated persistent setting")
        persisted[key]=$5; pnames[key]=$3; psids[key]=toupper($2); next
      }
      $1=="DEST" && NF==7 && $2 ~ /^([1-9]|[12][0-9]|3[01])$/ {
        if ($2 in dtype) fail("duplicate destination")
        if ($3 !~ /^(VALID|INACTIVE|DEFERRED|ERROR|DISABLED|BAD PARAM|ALTERNATE|FULL)$/) fail("unknown destination status")
        dtype[$2]=$7; dtarget[$2]=$4; dname[$2]=toupper($6); dvalue[$2]=$5; destinations++; next
      }
      $1=="MEMBER" && NF==4 && ident(toupper($2)) {
        key=toupper($2)
        if (key in roles) fail("duplicate Data Guard member")
        if ($3 !~ /^(PRIMARY DATABASE|PHYSICAL STANDBY|BACKUP APPLIANCE|FAR SYNC STANDBY|LOGICAL STANDBY|SNAPSHOT STANDBY|UNKNOWN)$/) fail("unknown member role")
        roles[key]=$3; parents[key]=toupper($4); next
      }
      $0=="END|TOPOLOGY" {ending++; next}
      {fail("malformed topology observation")}
      END {
        if (identity!=1 || container!=1 || ending!=1 || count!=69 || destinations!=31 || presence_count!=3 || fal_count!=1) fail("incomplete per-instance topology inventory")
        if (toupper(params["dg_broker_start"])!=broker) fail("per-instance broker value changed")
        if (!(toupper(unq) in roles) || roles[toupper(unq)]!="PRIMARY DATABASE" || parents[toupper(unq)]!="<NULL>") fail("missing or contradictory primary membership")
        for (name in roles) if (name!=toupper(unq)) {
          if (roles[name]=="PRIMARY DATABASE" || roles[name]=="UNKNOWN") fail("unresolved/contradictory remote member")
          ref(name,"Data Guard membership")
        }
        for (name in roles) {
          parent=parents[name]; chain="," name ","
          while (parent!="<NULL>") {
            if (!(parent in roles) || index(chain,"," parent ",") || roles[parent]=="BACKUP APPLIANCE") {fail("unresolved, cyclic or unsupported membership parent"); break}
            chain=chain parent ","; parent=parents[parent]
          }
        }
        for (id=1;id<=31;id++) {
          type=dtype[id]; name=dname[id]
          remote=(dtarget[id]=="STANDBY" || dtarget[id]=="REMOTE")
          if (dtarget[id] !~ /^(PRIMARY|STANDBY|LOCAL|REMOTE|<NULL>)$/) fail("unknown destination target")
          if (type ~ /^(PHYSICAL|LOGICAL|SNAPSHOT|FAR SYNC|DOWNSTREAM)$/) {
            if (!remote || name=="<NULL>") fail("unresolved/contradictory replication destination")
            else {
              ref(name,"redo destination")
              if ((type=="PHYSICAL" && roles[name]!="PHYSICAL STANDBY") ||
                  (type=="LOGICAL" && roles[name]!="LOGICAL STANDBY") ||
                  (type=="SNAPSHOT" && roles[name]!="SNAPSHOT STANDBY") ||
                  (type=="FAR SYNC" && roles[name]!="FAR SYNC STANDBY") || type=="DOWNSTREAM") fail("unsupported/contradictory replication type")
            }
          } else if (type=="BACKUP APPLIANCE") {
            if (!remote) fail("backup destination is not remote")
            if (name!="<NULL>") {ref(name,"backup destination"); if (roles[name]!="BACKUP APPLIANCE") fail("contradictory appliance role")}
          } else if (remote || (name!="<NULL>" && name!=toupper(unq))) fail("unresolved remote destination")
          else if (type!="LOCAL" && type!="UNKNOWN" && type!="<NULL>" && type!="CROSS-INSTANCE") fail("unsupported destination type")
        }
        if (presence["fal_server"]=="PRESENT" || presence["fal_client"]=="PRESENT" || persistent_fal!="0") hints=1
        for (name in params) setting(name,params[name],"runtime " name)
        for (key in persisted) {
          setting(pnames[key],persisted[key],"SPFILE " pnames[key])
        }
        if (bad) exit 1
        print "BROKER|" broker
        print "SPFILE|" (presence["spfile"]=="ABSENT" ? "MISSING" : "PRESENT")
        print "HINTS|" (hints ? "PRESENT" : "NONE")
        for (name in relations) print "RELATION|" name "|" relations[name] "|" parents[name]
      }
    ' "$file" > "$file.resolved" || die 'Topology UNKNOWN: unresolved, unsupported or contradictory metadata; see raw observations.'
}

topology_no_standby() {
    local stage=$1 reason=$2
    # SQL/SPFILE evidence must be complete on both nodes even when broker says
    # no configuration. Runtime-only views cannot rule out dormant settings.
    if grep -Eq '^SPFILE\|MISSING$|^HINTS\|PRESENT$|^RELATION\|[^|]+\|(PHYSICAL STANDBY|FAR SYNC STANDBY|LOGICAL STANDBY|SNAPSHOT STANDBY)\|' "$RUN/dg.$stage.resolved"; then
        die 'Topology UNKNOWN/unsupported: standalone proof requires SPFILE evidence, no FAL hints and no configured standby/replication relationships.'
    fi
    DG_TOPOLOGY=NONE DG_TOPOLOGY_EVIDENCE=$reason
    printf 'NONE|%s\n' "$reason" > "$RUN/dg.$stage.mode"
    : > "$RUN/dg.$stage.standbys"
    printf '%s|PRIMARY\n' "$DB_UNIQUE_NAME" > "$RUN/dg.$stage.members"
}

freeze_topology() {
    local stage=$1
    {
        cat "$RUN/dg.$stage.mode" "$RUN/dg.$stage.members"
        # Preserve configuration and endpoint identity, excluding transient
        # runtime transport status; no redo sequence/SCN counters are queried.
        awk -F'|' 'BEGIN {OFS="|"} $2=="DEST" {$4="-"} {$1=$1; print}' "$RUN/dg.$stage.observations"
    } | sort > "$RUN/dg.$stage.topology"
}

verify_topology_freeze() {
    cmp -s "$RUN/dg.preflight.topology" "$RUN/dg.$1.topology" || die 'Target topology/configuration changed during preparation; refusing cutover/create.'
}

discover_standbys() {
    local stage=$1 db role primary='' inst host state version value first='' key sid previous='' parent
    DG_TOPOLOGY=UNKNOWN DG_TOPOLOGY_EVIDENCE=unresolved
    printf 'UNKNOWN|discovery incomplete\n' > "$RUN/dg.$stage.mode"
    discover_target_rac "$RUN/dg.$stage.rac"
    : > "$RUN/dg.$stage.observations"
    : > "$RUN/dg.$stage.resolved"
    # shellcheck disable=SC2094
    while IFS='|' read -r inst host state version; do
        collect_topology_node "$inst" "$host" "$RUN/dg.$stage.$inst.metadata"
        one_line <(sed -n 's/^PARAM|dg_broker_start|//p' "$RUN/dg.$stage.$inst.metadata")
        value=${RESULT^^}
        [[ $value == TRUE || $value == FALSE ]] || die 'Topology UNKNOWN: invalid per-instance DG_BROKER_START.'
        [[ -z $first || $first == "$value" ]] || die 'Topology UNKNOWN: inconsistent DG_BROKER_START across target RAC instances.'
        first=$value
        parse_topology_node "$RUN/dg.$stage.$inst.metadata" "$inst" "$value"
        # All specified SIDs must belong to the independently verified RAC.
        while IFS='|' read -r key sid; do
            [[ $sid == '*' ]] || awk -F'|' -v s="$sid" 'toupper($1)==toupper(s) {ok=1} END {exit !ok}' "$RUN/dg.$stage.rac" ||
                die 'Topology UNKNOWN: persistent settings reference an unverified RAC SID.'
        done < <(awk -F'|' '$1=="SPFILE" {print $1 "|" $2}' "$RUN/dg.$stage.$inst.metadata" | sort -u)
        sort "$RUN/dg.$stage.$inst.metadata.resolved" > "$RUN/dg.$stage.$inst.resolved"
        if [[ -n $previous ]]; then
            cmp -s "$previous" "$RUN/dg.$stage.$inst.resolved" || die 'Topology UNKNOWN: contradictory per-node membership, roles or configuration evidence.'
        fi
        previous="$RUN/dg.$stage.$inst.resolved"
        cat "$previous" >> "$RUN/dg.$stage.resolved"
        # Node framing makes a per-instance setting change visible in freeze checks.
        sed "s/^/$inst|/" "$RUN/dg.$stage.$inst.metadata" >> "$RUN/dg.$stage.observations"
    done < "$RUN/dg.$stage.rac"
    if [[ $first == FALSE ]]; then
        topology_no_standby "$stage" STANDALONE_DISABLED
        freeze_topology "$stage"
        return
    fi
    [[ -x $ORACLE_HOME/bin/dgmgrl ]] || die 'Topology UNKNOWN: DGMGRL is required for enabled broker discovery.'
    broker_config_probe "$RUN/dg.$stage.configuration" "$TARGET_SID" '' ||
        die 'Target broker client failed/timed out; topology remains UNKNOWN.'
    if broker_unconfigured_output "$RUN/dg.$stage.configuration"; then
        # Confirm the exact documented no-configuration response with a fully
        # completed client on EVERY verified RAC node, not another local SID.
        while IFS='|' read -r inst host state version; do
            broker_config_probe "$RUN/dg.$stage.$inst.unconfigured" "$inst" "$host" &&
                broker_unconfigured_output "$RUN/dg.$stage.$inst.unconfigured" ||
                die 'Target broker no-configuration confirmation failed; topology remains UNKNOWN.'
        done < "$RUN/dg.$stage.rac"
        topology_no_standby "$stage" STANDALONE_UNCONFIGURED
        freeze_topology "$stage"
        return
    fi
    if grep -Eqi '(ORA-|DGM-|TNS-)[0-9]+|(^|[[:space:]])(Error:|Failed\.|Unable to|not connected|syntax error|unrecognized command)' "$RUN/dg.$stage.configuration"; then
        die 'Target broker discovery failed; standby absence is NOT established.'
    fi
    # Parse the complete Members section, not a grep whose empty result could
    # hide disabled management, an unknown role, or truncated/error output.
    awk '
      /^[[:space:]]*Configuration - / {header++; next}
      /^[[:space:]]*Members:[[:space:]]*$/ {members++; inside=1; next}
      /^[[:space:]]*(Properties:|Fast-Start Failover:|Configuration Status:)/ {inside=0}
      /^[[:space:]]*Configuration Status:/ {status=1; next}
      status && NF {if ($1!="SUCCESS") bad=1; status=0; complete++; next}
      inside && NF {
        line=$0; sub(/^[[:space:]]*/, "", line); sub(/[[:space:]]*$/, "", line)
        n=split(line,a,/[[:space:]]*-[[:space:]]*/)
        sub(/^\(\*\)[[:space:]]*/, "", a[2])
        if (n!=2 || seen[toupper(a[1])]++) {bad=1; next}
        if (a[2]=="Primary database") role="PRIMARY"
        else if (a[2]=="Physical standby database") role="PHYSICAL"
        else if (a[2]=="Far sync instance") role="FAR_SYNC"
        else if (a[2]=="Oracle Backup Appliance") role="BACKUP"
        else {bad=1; next}
        print a[1] "|" role
      }
      END {if (bad || header!=1 || members!=1 || complete!=1) exit 1}
    ' "$RUN/dg.$stage.configuration" > "$RUN/dg.$stage.members.unsorted" || die 'Incomplete, disabled, unhealthy or unsupported broker configuration.'
    sort "$RUN/dg.$stage.members.unsorted" > "$RUN/dg.$stage.members"
    : > "$RUN/dg.$stage.standbys"
    while IFS='|' read -r db role; do
        identifier "$db" 30 || die 'Unsafe broker DB_UNIQUE_NAME.'
        [[ ${db^^} != "$SOURCE_UNIQUE" && ${db^^} != "$SOURCE_CDB" ]] || die 'Production identity found in target broker configuration; refusing access.'
        case $role in
            PRIMARY) [[ -z $primary ]] || die 'Multiple broker primaries.'; primary=$db ;;
            PHYSICAL) printf '%s\n' "$db" >> "$RUN/dg.$stage.standbys" ;;
        esac
    done < "$RUN/dg.$stage.members"
    [[ ${primary^^} == "${DB_UNIQUE_NAME^^}" ]] || die 'Broker primary does not match the verified target DB_UNIQUE_NAME.'
    # SQL membership/transport must not contradict a primary-only broker list.
    while IFS='|' read -r key db role parent; do
        [[ $key == RELATION ]] || continue
        case $role in
            'PHYSICAL STANDBY')
                awk -F'|' -v d="$db" 'toupper($1)==d && $2=="PHYSICAL" {ok=1} END {exit !ok}' "$RUN/dg.$stage.members" ||
                    die 'Topology UNKNOWN: SQL identifies a physical standby absent from broker membership.' ;;
            'BACKUP APPLIANCE')
                if awk -F'|' -v d="$db" 'toupper($1)==d && ($2=="PHYSICAL" || $2=="FAR_SYNC") {ok=1} END {exit !ok}' "$RUN/dg.$stage.members"; then
                    die 'Topology UNKNOWN: broker physical standby contradicts SQL appliance role.'
                fi ;;
            'FAR SYNC STANDBY')
                awk -F'|' -v d="$db" 'toupper($1)==d && $2=="FAR_SYNC" {ok=1} END {exit !ok}' "$RUN/dg.$stage.members" ||
                    die 'Topology UNKNOWN: unmanaged far sync relationship.' ;;
            *) die 'Topology UNKNOWN/unsupported: configured unmanaged or nonphysical replication.' ;;
        esac
    done < "$RUN/dg.$stage.resolved"
    if [[ -s $RUN/dg.$stage.standbys ]]; then
        DG_TOPOLOGY=MANAGED DG_TOPOLOGY_EVIDENCE=BROKER
        printf 'MANAGED|BROKER\n' > "$RUN/dg.$stage.mode"
    else
        if grep -q '^HINTS|PRESENT$' "$RUN/dg.$stage.resolved"; then
            die 'Topology UNKNOWN: FAL relationship hints contradict a primary-only broker inventory.'
        fi
        if grep -q '|FAR_SYNC$' "$RUN/dg.$stage.members" || grep -q '^RELATION|[^|]*|FAR SYNC STANDBY|' "$RUN/dg.$stage.resolved"; then
            die 'Topology UNKNOWN: far sync without complete physical standby membership.'
        fi
        DG_TOPOLOGY=NONE DG_TOPOLOGY_EVIDENCE=BROKER
        printf 'NONE|BROKER\n' > "$RUN/dg.$stage.mode"
    fi
    freeze_topology "$stage"
}

standby_database() {
    local db=$1 stage=$2 out="$RUN/dg.$1.$2.database"
    broker "$out" "SHOW DATABASE '$db';" || die "Cannot inspect target standby $db."
    [[ $(sed -n 's/^[[:space:]]*Database - //p' "$out") == "$db" ]] || die 'Broker database identity is missing/mismatched.'
    [[ $(sed -n 's/^[[:space:]]*Role:[[:space:]]*//p' "$out") == 'PHYSICAL STANDBY' ]] || die "$db is not a physical standby."
    one_line <(sed -n 's/^[[:space:]]*Intended State:[[:space:]]*//p' "$out")
    DG_INTENDED=$RESULT
    [[ $DG_INTENDED == APPLY-ON || $DG_INTENDED == APPLY-OFF ]] || die "Unknown/disabled apply state for $db."
    awk '/^[[:space:]]*Instance\(s\):/ {inside=1; next}
         /^[[:space:]]*Database Status:/ {inside=0; status=1; next}
         inside && NF {if (seen[toupper($1)]++ || (NF!=1 && !(NF==3 && $2=="(apply" && $3=="instance)"))) exit 1; print $1; n++}
         status && NF {if ($1!="SUCCESS") exit 1; good=1; status=0}
         END {if (!n || !good) exit 1}' "$out" > "$RUN/dg.$db.$stage.instances" || die "Incomplete/disabled broker instance inventory for $db."
}

validate_standby_observation() {
    # Concat queries produce framed rows. Unknown text must not masquerade as
    # zero matching PDB rows on the initial-creation path.
    awk -F'|' '
      !length {next}
      $1=="IDENTITY" && NF==7 {next}
      $1=="CONTAINER" && NF==2 {next}
      $1=="BROKER" && NF==2 {next}
      $1=="RAC" && NF==3 {next}
      $1=="APPLY" && NF==2 {next}
      $1=="PDB" && NF==3 {next}
      {exit 1}' "$1" || die 'Malformed standby observation; PDB absence cannot be inferred.'
}

# Read-only OS-authenticated SQL on every broker-listed standby instance. No
# standby DDL is issued here. All listed instances must be reachable/online.
observe_standby() {
    local db=$1 stage=$2 require_off=$3 inst host count guid mode out invalid=0
    if ((require_off)); then
        printf 'UNKNOWN; %s verification incomplete; inspect broker/SQL observations\n' "$stage" > "$RUN/dg.$db.result"
    fi
    standby_database "$db" "$stage"
    cmp -s "$RUN/dg.$db.inventory.instances" "$RUN/dg.$db.$stage.instances" || die "Standby instance inventory changed for $db."
    printf '%s|%s|%s|-|-|-|-\n' "$stage" "$db" "$DG_INTENDED" >> "$RUN/dg-states.tsv"
    # shellcheck disable=SC2094 # SQL output and the immutable nodes inventory are distinct.
    while IFS='|' read -r inst host; do
        out="$RUN/dg.$db.$stage.$inst.out"
        # Force SSH even if a standby reuses the target primary SID.
        sql "$inst" "$out" "$host" 1 <<SQL
select 'IDENTITY|'||d.name||'|'||d.db_unique_name||'|'||d.dbid||'|'||d.database_role||'|'||d.cdb||'|'||i.instance_name from v\$database d cross join v\$instance i;
select 'CONTAINER|'||sys_context('USERENV','CON_NAME') from dual;
select 'BROKER|'||upper(value) from v\$parameter where name='dg_broker_start';
select 'RAC|'||instance_name||'|'||host_name from gv\$instance order by instance_name;
select 'APPLY|'||count(*) from v\$dataguard_process where name='MRP0' or lower(role) like '%recovery%';
select 'PDB|'||rawtohex(guid)||'|'||open_mode from v\$pdbs where name='$TARGET_PDB' and con_id>2;
SQL
        validate_standby_observation "$out"
        grep -Fxiq "IDENTITY|$TARGET_CDB|$db|$TARGET_DBID|PHYSICAL STANDBY|YES|$inst" "$out" &&
            grep -Fxq "CONTAINER|CDB\$ROOT" "$out" && grep -Fxq 'BROKER|TRUE' "$out" || die "Standby identity/root/broker check failed for $db/$inst."
        sed -n 's/^RAC|//p' "$out" | sort > "$RUN/dg.$db.$stage.$inst.rac"
        cmp -s "$RUN/dg.$db.nodes" "$RUN/dg.$db.$stage.$inst.rac" || die "Not all configured standby RAC instances are online/matched for $db."
        one_line <(sed -n 's/^APPLY|//p' "$out"); count=$RESULT
        [[ $count =~ ^[0-9]+$ ]] || die "Unknown actual apply state for $db/$inst."
        if [[ ${TARGET_PDB_STATE:-PRESENT} == ABSENT ]]; then
            # No old primary PDB means there must be no same-name standby PDB;
            # never invent an old GUID to make an orphaned row appear matched.
            guid=ABSENT mode=-
            if grep -q '^PDB|' "$out"; then
                log "Conflicting standby PDB inventory on $db/$inst: target name was initially absent."
                invalid=1
            fi
        else
            one_line <(sed -n 's/^PDB|//p' "$out"); IFS='|' read -r guid mode <<< "$RESULT"
            if [[ $guid != "$TARGET_PDB_GUID" || $mode != MOUNTED ]]; then
                log "Old target PDB must already be closed (MOUNTED), with matching GUID, on $db/$inst; APPLY-OFF does not close it."
                invalid=1
            fi
        fi
        printf '%s|%s|%s|%s|%s|%s|%s\n' "$stage" "$db" "$DG_INTENDED" "$inst" "$count" "$guid" "$mode" >> "$RUN/dg-states.tsv"
        if ((require_off)); then
            if [[ $DG_INTENDED != APPLY-OFF || $count != 0 ]]; then
                log "Apply stop verification failed on $db/$inst; refusing target PDB cutover."
                invalid=1
            fi
        fi
    done < "$RUN/dg.$db.nodes"
    ((invalid == 0)) || die "Standby apply/PDB inventory prerequisite failed for $db; inspect recorded per-instance states."
    if ((require_off)); then
        printf 'APPLY-OFF; verified no recovery processes on every configured RAC instance; target PDB observation=%s; stage=%s\n' "${TARGET_PDB_STATE:-PRESENT}" "$stage" > "$RUN/dg.$db.result"
    fi
}

preflight_broker() {
    local db inst host
    discover_standbys preflight
    DG_HANDOFF=discovered
    printf 'stage|db_unique_name|broker_intended|instance|recovery_process_count|pdb_guid|pdb_open_mode\n' > "$RUN/dg-states.tsv"
    if [[ ! -s $RUN/dg.preflight.standbys ]]; then
        DG_HANDOFF=no-standby
        printf 'preflight|NONE|NONE|-|0|-|-\n' >> "$RUN/dg-states.tsv"
        log "No physical standby configured; topology evidence=$DG_TOPOLOGY_EVIDENCE (both verified target RAC instances)."
        return
    fi
    if [[ ${TARGET_PDB_STATE:-PRESENT} == PRESENT ]]; then
    local captured_guid=${TARGET_PDB_GUID:-}
    sql "$TARGET_SID" "$RUN/dg.pdb-guid" <<SQL
select rawtohex(guid) from v\$pdbs where name='$TARGET_PDB' and con_id>2;
SQL
    one_line "$RUN/dg.pdb-guid"; TARGET_PDB_GUID=$RESULT
    [[ $TARGET_PDB_GUID =~ ^[0-9A-F]{32}$ ]] || die 'Cannot establish old target PDB GUID.'
    [[ -z $captured_guid || $captured_guid == "$TARGET_PDB_GUID" ]] || die 'Old target PDB GUID changed before standby preflight.'
    fi
    while IFS= read -r db; do
        printf 'NOT_ATTEMPTED; resulting apply state UNKNOWN\n' > "$RUN/dg.$db.result"
        standby_database "$db" inventory
        : > "$RUN/dg.$db.nodes.unsorted"
        while IFS= read -r inst; do
            identifier "$inst" 30 || die 'Unsafe standby instance name.'
            broker "$RUN/dg.$db.$inst.broker" "SHOW INSTANCE VERBOSE '$inst' ON DATABASE '$db';" || die "Cannot discover standby host for $db/$inst."
            host=$(sed -n "s/^[[:space:]]*HostName[[:space:]]*=[[:space:]]*'\([^']*\)'[[:space:]]*$/\1/p" "$RUN/dg.$db.$inst.broker")
            [[ $host =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || die "Missing/unsafe standby hostname for $db/$inst."
            printf '%s|%s\n' "$inst" "$host" >> "$RUN/dg.$db.nodes.unsorted"
        done < "$RUN/dg.$db.inventory.instances"
        sort -u "$RUN/dg.$db.nodes.unsorted" > "$RUN/dg.$db.nodes"
        observe_standby "$db" preflight 0
    done < "$RUN/dg.preflight.standbys"
}

stop_target_apply() {
    local db rc
    DG_HANDOFF='preflight evidence retained; cutover broker discovery incomplete; no apply stop attempted'
    discover_standbys precutover
    verify_topology_freeze precutover
    if [[ ! -s $RUN/dg.preflight.standbys ]]; then DG_HANDOFF=no-standby; return 0; fi
    if [[ -n ${TARGET_RAC_FILE:-} ]]; then
        check_target_pdb_identity "$RUN/dg.pdb.precutover"
    elif [[ ${TARGET_PDB_STATE:-PRESENT} == PRESENT ]]; then
    sql "$TARGET_SID" "$RUN/dg.pdb-guid.precutover" <<SQL
select rawtohex(guid) from v\$pdbs where name='$TARGET_PDB' and con_id>2;
SQL
    one_line "$RUN/dg.pdb-guid.precutover"
    [[ $RESULT == "$TARGET_PDB_GUID" ]] || die 'Old target PDB GUID changed during auxiliary preparation.'
    fi
    # Verify all standby identities and closure before changing any apply state.
    while IFS= read -r db; do observe_standby "$db" before 0; done < "$RUN/dg.preflight.standbys"
    DG_HANDOFF='stop attempted; apply may be OFF or UNKNOWN'
    DG_APPLY_ATTEMPTED=1
    while IFS= read -r db; do
        printf 'APPLY-OFF requested; resulting apply state UNKNOWN until verified\n' > "$RUN/dg.$db.result"
        rc=0
        broker "$RUN/dg.$db.stop" "EDIT DATABASE '$db' SET STATE='APPLY-OFF';" || rc=$?
        # Even a broker command error can follow a partial state change. Capture
        # actual resulting state; never infer success from exit status alone.
        observe_standby "$db" after 1
        ((rc == 0)) || die "Broker reported a stop error for $db; states recorded, cutover aborted."
    done < "$RUN/dg.preflight.standbys"
    DG_HANDOFF='APPLY-OFF verified on all target standbys; retained for separate standby refresh'
    log "$DG_HANDOFF. Original/resulting states: $RUN/dg-states.tsv"
}

# Use only disk-group roots: target-specific ASM aliases must never be reused.
asm_group() {
    [[ $1 =~ ^\+([A-Za-z][A-Za-z0-9_]{0,29})(/[A-Za-z0-9_/-]+)?$ ]] || die 'Missing or unsupported ASM destination; configure target DB_CREATE_FILE_DEST and DB_RECOVERY_FILE_DEST.'
    RESULT=+${BASH_REMATCH[1]^^}
}

discover_aux_storage() {
    asm_group "$1"; AUX_DATA_DEST=$RESULT
    asm_group "$2"; AUX_RECO_DEST=$RESULT
    log "Discovered auxiliary ASM destinations: data=$AUX_DATA_DEST recovery=$AUX_RECO_DEST."
}

check_refresh_space() {
    local need_mb=$1
    # Budget for peak coexistence during MOVE; old target files are not reclaimable yet.
    space_check "$AUX_DATA_DEST" "$((2 * need_mb + DUP_REDO_RESERVE_MB))"
    if [[ $AUX_DATA_DEST != "$AUX_RECO_DEST" ]]; then
        space_check "$AUX_RECO_DEST" "$DUP_REDO_RESERVE_MB"
    fi
}

validate_aux_files() {
    local file upper
    [[ -s $1 ]] || die 'Auxiliary file inventory is empty.'
    while IFS= read -r file; do
        upper=${file^^}
        [[ $upper == "$AUX_DATA_DEST/${AUX_UNIQUE^^}/"* || $upper == "$AUX_RECO_DEST/${AUX_UNIQUE^^}/"* ]] || die "Auxiliary file is outside its isolated ASM namespace: $file"
    done < "$1"
}

space_check() {
    local dest=$1 need_mb=$2 available dg
    if [[ $dest == +* ]]; then
        dg=${dest#+}; dg=${dg%%/*}
        identifier "$dg" 30 || die 'Unsupported ASM disk group name.'
        sql "$TARGET_SID" "$RUN/space.out" <<SQL
select trunc(usable_file_mb) from v\$asm_diskgroup_stat where name=upper('$dg') and state='CONNECTED';
SQL
        one_line "$RUN/space.out"; available=$RESULT
    else
        [[ -d $dest && -w $dest ]] || die "Storage directory is not writable: $dest"
        available=$(df -Pm "$dest" | awk 'NR==2 {print $4}')
    fi
    positive "$available" && ((available >= need_mb)) || die "Insufficient/unknown usable space in $dest: need ${need_mb} MiB, available ${available:-unknown}."
    log "Space $dest: $available MiB usable; estimated requirement $need_mb MiB."
}

discover_credentials() {
    local listing entry index count
    WALLET="/var/opt/oracle/dbaas_acfs/$TARGET_CDB/wallet_root/server_seps"
    [[ -r $WALLET/cwallet.sso && -r $ORACLE_HOME/lib/libra.so ]] || die 'Missing SEPS auto-login wallet or libra.so.'
    # No prompts: the established notes_zdlra.md wallet must support unattended reads.
    listing=$("$ORACLE_HOME/bin/mkstore" -wrl "$WALLET" -listCredential </dev/null 2>&1) || die 'mkstore -listCredential failed; check SEPS wallet access.'
    listing=$(printf '%s\n' "$listing" | awk '/^[[:space:]]*[0-9]+:/ {gsub(/^[ \t]+/, ""); print}')
    if [[ -n ${DUP_ZDLRA_ALIAS:-} ]]; then
        listing=$(printf '%s\n' "$listing" | awk -v alias="$DUP_ZDLRA_ALIAS" '$2==alias')
    fi
    count=$(printf '%s\n' "$listing" | awk 'NF {n++} END {print n+0}')
    [[ $count == 1 ]] || die 'SEPS credential selection is ambiguous or empty; use --zdlra-alias with the exact ZDLRA connect string.'
    read -r index RA_ALIAS VPC_USER <<< "$listing"
    index=${index%:}
    [[ $index =~ ^[0-9]+$ && $RA_ALIAS =~ ^[A-Za-z0-9_.:/-]+$ ]] && identifier "$VPC_USER" 128 || die 'Unsupported SEPS alias or username syntax.'
    entry=$("$ORACLE_HOME/bin/mkstore" -wrl "$WALLET" -viewEntry "oracle.security.client.password$index" </dev/null 2>&1) || die 'mkstore password lookup failed.'
    local prefix="oracle.security.client.password$index = " line matches=0
    VPC_PASSWORD=
    while IFS= read -r line; do
        if [[ $line == "$prefix"* ]]; then VPC_PASSWORD=${line#"$prefix"}; ((matches+=1)); fi
    done <<< "$entry"
    unset entry listing line
    [[ $matches == 1 && -n $VPC_PASSWORD && $VPC_PASSWORD != *'"'* && $VPC_PASSWORD != *$'\r'* && $VPC_PASSWORD != *$'\n'* ]] || die 'Cannot safely read/quote the SEPS password (no double quotes or line breaks supported).'
    export -n VPC_PASSWORD
    log "Selected SEPS credential index $index, catalog alias $RA_ALIAS, user $VPC_USER."
}

snapshot_services() {
    # Deployment assumption: administrator-managed Oracle 19c RAC only.
    # Its service output can contain both Server pool and Preferred instances;
    # neither the pool name nor these text fields are a topology detector.
    local svc pdb cfg status running
    srv "$RUN/services.all" config service -db "$DB_UNIQUE_NAME"
    : > "$RUN/services.tsv"
    while IFS= read -r svc; do
        [[ $svc =~ ^[A-Za-z][A-Za-z0-9_.-]*$ ]] || die "Unsupported service name: $svc"
        cfg="$RUN/service.$svc.before"
        srv "$cfg" config service -db "$DB_UNIQUE_NAME" -service "$svc" -verbose
        grep -q '^Pluggable database name:' "$cfg" || die "Cannot identify PDB association for service $svc with this srvctl output."
        pdb=$(sed -n 's/^Pluggable database name: *//p' "$cfg")
        [[ ${pdb^^} == "$TARGET_PDB" ]] || continue
        grep -q '^Preferred instances:' "$cfg" || die "Missing expected 19c administrator-managed service output for $svc (Preferred instances)."
        if grep -Eqi '^Global: true|^Service is .* on ' "$cfg"; then
            die "Service $svc has unsupported global/per-instance enablement; preserve it manually before using this script."
        fi
        status=$(sed -nE 's/^Service is (enabled|disabled)\.?$/\1/p' "$cfg")
        [[ $status == enabled || $status == disabled ]] || die "Cannot determine enablement for $svc."
        srv "$RUN/service.$svc.status.before" status service -db "$DB_UNIQUE_NAME" -service "$svc" -force
        one_line "$RUN/service.$svc.status.before"
        if [[ $RESULT == "Service $svc is not running." || $RESULT == "Service $svc is not running" ]]; then
            running=-
        elif [[ $RESULT == "Service $svc is running on instance(s) "* ]]; then
            running=${RESULT#"Service $svc is running on instance(s) "}; running=${running%.}; running=${running// /}
            [[ $running =~ ^[A-Za-z][A-Za-z0-9_]*(,[A-Za-z][A-Za-z0-9_]*)*$ ]] || die "Unrecognized running instances for $svc."
            [[ $status == enabled ]] || die "Service $svc is running but disabled; reconcile it before refresh."
        else
            die "Unrecognized 19c service status for $svc."
        fi
        [[ ${TARGET_PDB_STATE:-PRESENT} != ABSENT || $running == - ]] || die "Service $svc is running with no corresponding target PDB."
        printf '%s|%s|%s\n' "$svc" "$status" "$running" >> "$RUN/services.tsv"
    done < <(sed -n 's/^Service name: *//p' "$RUN/services.all")
    # Every non-default SQL service must have a CRS resource; no silent omission.
    sql "$TARGET_SID" "$RUN/pdb-services.out" <<SQL
select name from cdb_services where pdb='$TARGET_PDB' and upper(name)<>'$TARGET_PDB' order by name;
SQL
    while IFS= read -r svc; do
        [[ -z $svc ]] && continue
        awk -F'|' -v s="$svc" '$1==s {found=1} END {exit !found}' "$RUN/services.tsv" || die "PDB service $svc is not captured in srvctl; cannot preserve it."
    done < "$RUN/pdb-services.out"
}

restore_services() {
    local svc enabled running inst
    while IFS='|' read -r svc enabled running; do
        # Resource stays in OCR: placement, roles, policies, TAF/AC, edition, etc.
        # are not reconstructed from a lossy subset of srvctl text fields.
        srv "$RUN/service.$svc.reconcile" modify service -db "$DB_UNIQUE_NAME" -service "$svc" -pdb "$TARGET_PDB"
        [[ $enabled != enabled ]] || srv "$RUN/service.$svc.enable" enable service -db "$DB_UNIQUE_NAME" -service "$svc"
        if [[ $running != - ]]; then
            local -a instances
            IFS=',' read -r -a instances <<< "$running"
            for inst in "${instances[@]}"; do
                srv "$RUN/service.$svc.start.$inst" start service -db "$DB_UNIQUE_NAME" -service "$svc" -instance "$inst"
            done
        fi
        srv "$RUN/service.$svc.after" config service -db "$DB_UNIQUE_NAME" -service "$svc" -verbose
        cmp -s "$RUN/service.$svc.before" "$RUN/service.$svc.after" || die "Service $svc configuration was not preserved exactly."
        srv "$RUN/service.$svc.status.after" status service -db "$DB_UNIQUE_NAME" -service "$svc" -force
        cmp -s "$RUN/service.$svc.status.before" "$RUN/service.$svc.status.after" || die "Service $svc running placement differs; inspect snapshots."
    done < "$RUN/services.tsv"
}

build_aux_pfile() {
    cat <<EOF
*.db_name='$DUP_AUX_CDB'
*.db_unique_name='$AUX_UNIQUE'
*.enable_pluggable_database=true
*.cluster_database=false
*.compatible='$COMPATIBLE'
*.db_block_size=$BLOCK_SIZE
*.db_files=4096
*.processes=300
*.sga_target=${DUP_AUX_SGA_MB}M
*.pga_aggregate_target=${DUP_AUX_PGA_MB}M
*.control_files='$AUX_DATA_DEST'
*.db_create_file_dest='$AUX_DATA_DEST'
*.db_create_online_log_dest_1='$AUX_DATA_DEST'
*.log_archive_dest_1='LOCATION=$AUX_RECO_DEST'
*.diagnostic_dest='$AUX/diag'
*.audit_file_dest='$AUX/audit'
*.wallet_root='$AUX_WALLET_ROOT'
*.tde_configuration='$TDE_CONFIGURATION'
*.local_listener='(ADDRESS=(PROTOCOL=IPC)(KEY=DUP_NO_LISTENER_${DUP_AUX_CDB}_$$))'
*.remote_listener=''
*.service_names='$DUP_AUX_CDB'
*.dg_broker_start=false
*.job_queue_processes=0
*.aq_tm_processes=0
EOF
}

build_duplicate() {
    [[ -s $RUN/tempfiles.normalized.out ]] || die 'Normalized catalog tempfile inventory is missing.'
    cat <<EOF
run {
  allocate auxiliary channel ra1 device type sbt_tape
    parms "SBT_LIBRARY=$ORACLE_HOME/lib/libra.so, ENV=(RA_WALLET='location=file:$WALLET credential_alias=$RA_ALIAS')";
  set newname for database to new;
EOF
    local tempfile
    while IFS= read -r tempfile || [[ -n $tempfile ]]; do
        [[ $tempfile =~ ^[1-9][0-9]*$ ]] || die 'Invalid normalized catalog tempfile number.'
        printf '  set newname for tempfile %s to new;\n' "$tempfile"
    done < "$RUN/tempfiles.normalized.out"
    printf "  duplicate database '%s' dbid %s to '%s'\n    pfile='%s/init.ora'\n" "$SOURCE_CDB" "$SOURCE_DBID" "$DUP_AUX_CDB" "$AUX"
    if [[ -n $RECOVERY_TIME ]]; then
        printf '    until time "to_date('\''%s'\'','\''YYYY-MM-DD HH24:MI:SS'\'')"\n' "$RECOVERY_TIME"
    fi
    printf '%s\n' '    noopen;' '}'
}

build_plug() {
    cat <<SQL
create pluggable database $TARGET_PDB using '$AUX/pdb.xml' move create_file_dest='$TARGET_DEST' standbys=none;
alter pluggable database $TARGET_PDB open restricted;
alter session set container=$TARGET_PDB;
administer key management import encryption keys with secret "HSM" from 'HSM' identified by external store;
alter session set container=CDB\$ROOT;
alter pluggable database $TARGET_PDB close immediate;
alter pluggable database $TARGET_PDB open restricted instances=all;
SQL
}

open_sql() {
    local mode=$1 restricted=$2
    case $mode in
        MOUNTED) return ;;
        OPEN|'READ WRITE') mode='READ WRITE' ;;
        'OPEN READ ONLY'|'READ ONLY') mode='READ ONLY' ;;
        *) die "Unsupported PDB open state: $mode" ;;
    esac
    [[ $restricted == YES || $restricted == NO ]] || die 'Unsupported restricted state.'
    printf 'alter pluggable database %s open %s%s;\n' "$TARGET_PDB" "$mode" "$([[ $restricted == YES ]] && printf ' restricted')"
}

restore_pdb_states() {
    local inst host mode restricted saved sr
    while IFS='|' read -r inst host mode restricted; do
        saved=$(awk -F'|' -v i="$inst" '$1==i {print $2}' "$RUN/saved.expected")
        sr=$(awk -F'|' -v i="$inst" '$1==i {print $3}' "$RUN/saved.expected")
        {
            printf 'alter pluggable database %s discard state;\n' "$TARGET_PDB"
            if [[ -n $saved ]]; then
                open_sql "$saved" "$sr"
                printf 'alter pluggable database %s save state;\n' "$TARGET_PDB"
                [[ $saved == MOUNTED ]] || printf 'alter pluggable database %s close immediate;\n' "$TARGET_PDB"
            fi
            open_sql "$mode" "$restricted"
        } > "$RUN/state.$inst.sql"
        sql "$inst" "$RUN/state.$inst.out" "$host" < "$RUN/state.$inst.sql"
    done < "$RUN/pdb.expected"
}

# Catalog bounds describe candidates, not a guarantee of continuous recovery.
dry_run_range() {
    sql CATALOG "$RUN/restore-range.out" <<SQL
select to_char(max(earliest),'YYYY-MM-DD HH24:MI:SS') from (
 select file#,min(checkpoint_time) earliest from rc_backup_datafile b
 where db_key=$SOURCE_DBKEY and dbinc_key=$SOURCE_INC and status='A' and file#>0
 and checkpoint_time < $point and (incremental_level is null or incremental_level=0)
 and exists (select 1 from rc_backup_piece p where p.bs_key=b.bs_key and p.status='A' and p.device_type='SBT_TAPE')
 group by file#);
SQL
    one_line "$RUN/restore-range.out"
    local lower=$RESULT upper through thread first last
    [[ $lower =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}$ ]] || die 'No full/level-0 SBT backup checkpoint range.'
    upper=9999-12-31\ 23:59:59
    while IFS='|' read -r thread first last through; do
        [[ $through =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}$ ]] || die 'Unknown redo endpoint.'
        [[ $through > "$upper" ]] || upper=$through
        log "Thread $thread: catalogued sequences $first..$last through $through."
    done < "$RUN/redo-inventory.out"
    [[ $lower < "$upper" ]] || die 'No overlapping candidate backup/redo time range.'
    log "Candidate restore range (UTC+02:00): $lower to $upper (redo upper bound exclusive)."
    [[ -z $RECOVERY_TIME || ( $RECOVERY_TIME > "$lower" && $RECOVERY_TIME < "$upper" ) ]] || die 'Requested time lies outside the candidate restore range.'
    sql CATALOG "$RUN/controlfile-count.out" <<SQL
select count(*) from rc_backup_controlfile b where db_key=$SOURCE_DBKEY and dbinc_key=$SOURCE_INC
and status='A' and checkpoint_time < $point
and exists (select 1 from rc_backup_piece p where p.bs_key=b.bs_key and p.status='A' and p.device_type='SBT_TAPE');
SQL
    one_line "$RUN/controlfile-count.out"
    positive "$RESULT" || die 'No available SBT controlfile backup before the requested point.'
    log 'Available SBT datafile and controlfile metadata found. Range may contain gaps; file coverage, SBT reads and redo continuity are not validated by dry run.'
}

main() {
    set -Eeuo pipefail
    umask 077
    ((BASH_VERSINFO[0] >= 4)) || die 'Bash 4 or newer is required.'
    parse_args "$@"
    [[ $(id -un) == oracle ]] || die 'Run as oracle on the designated target RAC primary node.'
    local envfile="/home/oracle/$TARGET_CDB.env"
    load_environment "$envfile"
    set -Eeuo pipefail
    export TZ=Etc/GMT-2 LC_ALL=C NLS_LANG=AMERICAN_AMERICA.AL32UTF8
    export NLS_DATE_FORMAT='YYYY-MM-DD HH24:MI:SS'
    unset TWO_TASK LOCAL SQLPATH
    : "${ORACLE_HOME:?ORACLE_HOME missing from target env}" "${ORACLE_SID:?ORACLE_SID missing from target env}" "${DB_UNIQUE_NAME:?DB_UNIQUE_NAME or ORACLE_UNQNAME missing from target env}"
    TARGET_SID=$ORACLE_SID
    safe_path "$ORACLE_HOME" && identifier "$TARGET_SID" 30 && identifier "$DB_UNIQUE_NAME" 30 || die 'Unsafe Oracle environment names/paths.'
    local tool
    for tool in sqlplus rman mkstore srvctl; do [[ -x $ORACLE_HOME/bin/$tool ]] || die "Missing $ORACLE_HOME/bin/$tool"; done
    for tool in ssh awk sed grep tee df date find mktemp cmp sort cp chmod rm mkdir cut; do command -v "$tool" >/dev/null || die "Missing $tool"; done
    [[ $("$ORACLE_HOME/bin/sqlplus" -V) == *'Release 19.'* ]] || die 'Oracle Database 19c tools are required.'

    # Syntax/defaults come from parse_args; verify target-dependent prerequisites.
    [[ $DUP_AUX_CDB != "${TARGET_SID^^}" && $DUP_AUX_CDB != "${DB_UNIQUE_NAME^^}" ]] || die 'Auxiliary identity must be distinct from source and target.'

    local logbase=/home/oracle/duplicate_logs stamp
    [[ ! -L $logbase ]] || die 'Log directory must not be a symlink.'
    mkdir -p "$logbase"
    [[ -O $logbase ]] || die 'Log directory must belong to oracle.'
    chmod 700 "$logbase"
    LOCK="$logbase/.${DB_UNIQUE_NAME^^}.lock"
    mkdir "$LOCK" 2>/dev/null || die "Target lock exists: $LOCK (verify owner; never remove a live lock)."
    printf '%s %s\n' "$(hostname)" "$$" > "$LOCK/owner"
    PHASE=initialization CUTOVER=untouched DG_HANDOFF=not-checked DG_TOPOLOGY=UNKNOWN DG_TOPOLOGY_EVIDENCE=unresolved DG_APPLY_ATTEMPTED=0 RUN=$logbase LOG=/dev/null VPC_PASSWORD=
    TARGET_PDB_STATE=UNKNOWN TARGET_PDB_GUID='' TARGET_RAC_FILE=''
    AUX='' AUX_WALLET_DIR='' AUX_WALLET_ROOT='' AUX_WALLET_STATUS=not-created AUXILIARY_STATE=not-started
    trap finish EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP
    stamp=$(date '+%Y%m%dT%H%M%S')
    RUN=$(mktemp -d "$logbase/dup_${SOURCE_CDB}_${SOURCE_PDB}_to_${TARGET_CDB}_${TARGET_PDB}_${stamp}_XXXXXX")
    LOG="$RUN/run.log"; : > "$LOG"
    # Only completed runs' run.log is purged. Snapshots/auxiliaries and incomplete
    # logs are never purged automatically, even when old.
    local marker
    while IFS= read -r marker; do
        [[ $marker == "$RUN/complete" ]] || rm -f "${marker%/complete}/run.log"
    done < <(if (( ! DRY_RUN )); then find "$logbase" -mindepth 2 -maxdepth 2 -type f -path '*/dup_*/complete' -mmin "+$((RETENTION * 1440))"; fi)
    phase preflight "Dry run=$DRY_RUN: $SOURCE_CDB/$SOURCE_PDB -> $TARGET_CDB/$TARGET_PDB. Logs: $RUN"
    log 'Fixed UTC+02:00 timestamps. Local lock only: run exclusively on the designated node.'

    target_identity "$RUN/identity.before"
    local site matches
    validate_target_identity "$RUN/identity.before"
    matches=$(printf '%s\n' "${DB_UNIQUE_NAME^^}" | grep -oE 'M[12]' || true)
    [[ $matches == M1 || $matches == M2 ]] || die 'Target DB_UNIQUE_NAME must contain exactly one M1 or M2 marker.'
    site=$matches; SOURCE_UNIQUE="$SOURCE_CDB$site"
    [[ ${DUP_AUX_CDB^^} != "$SOURCE_UNIQUE" ]] || die 'Auxiliary name collides with source unique name.'
    discover_target_settings "$RUN/target-settings.out"
    check_aux_wallet
    TARGET_RAC_FILE="$RUN/target-rac.before"
    discover_target_rac "$TARGET_RAC_FILE"
    query_target_pdb "$RUN/pdb-inventory.before"
    validate_target_pdb "$RUN/pdb-inventory.before" "$TARGET_RAC_FILE"
    TARGET_PDB_STATE=$PDB_STATE TARGET_PDB_GUID=$PDB_GUID
    printf '%s\n' "$TARGET_PDB_STATE" > "$RUN/target-pdb-state"
    printf '%s\n' "${TARGET_PDB_GUID:-NONE}" > "$RUN/target-pdb-guid"
    cut -d'|' -f1-4 "$RUN/pdb-inventory.before" > "$RUN/pdb.before"
    sql "$TARGET_SID" "$RUN/saved.before" <<SQL
select instance_name||'|'||state||'|'||restricted from dba_pdb_saved_states where con_name='$TARGET_PDB' order by instance_name;
SQL
    validate_saved_states "$RUN/saved.before" "$TARGET_RAC_FILE" "$TARGET_PDB_STATE"
    local inst host svc enabled running state version pdb_action
    while IFS='|' read -r inst host state version; do
        sql "$inst" "$RUN/node.$inst.out" "$host" <<SQL
select d.dbid||'|'||d.database_role||'|'||i.instance_name||'|'||i.version from v\$database d cross join v\$instance i;
select 'WALLET|'||count(*) from v\$encryption_wallet where status='OPEN' and wrl_type='HSM' and con_id=1;
SQL
        grep -Eq "^$TARGET_DBID\|PRIMARY\|$inst\|19\." "$RUN/node.$inst.out" && grep -Eq '^WALLET\|[1-9][0-9]*$' "$RUN/node.$inst.out" || die "Identity/19c/HSM check failed on $inst."
    done < "$TARGET_RAC_FILE"
    prepare_pdb_policy
    if [[ $TARGET_PDB_STATE == ABSENT ]]; then
        pdb_action='initial creation'
        log 'target PDB absent; initial creation path. No old GUID/open-state/saved-state snapshot to restore.'
        sql "$TARGET_SID" "$RUN/current-pdb-inventory.out" <<'SQL'
select i.instance_name||'|'||p.name||'|'||p.open_mode from gv$pdbs p join gv$instance i on i.inst_id=p.inst_id order by i.instance_name,p.con_id;
SQL
    else
        pdb_action=replacement
        log "Target PDB $TARGET_PDB PRESENT; captured GUID=$TARGET_PDB_GUID and per-instance open/saved states."
    fi
    if (( DRY_RUN )); then
        log 'Environment checks passed.'
    else
    preflight_broker

    if [[ -n $RECOVERY_TIME ]]; then
        sql "$TARGET_SID" "$RUN/time.out" <<SQL
select to_char(to_date('$RECOVERY_TIME','FXYYYY-MM-DD HH24:MI:SS'),'YYYY-MM-DD HH24:MI:SS') from dual;
SQL
        one_line "$RUN/time.out"; [[ $RESULT == "$RECOVERY_TIME" ]] || die 'Invalid recovery time.'
    fi

    snapshot_services
    while IFS='|' read -r svc enabled running; do
        if [[ $running != - ]]; then
            local -a running_instances
            IFS=',' read -r -a running_instances <<< "$running"
            for inst in "${running_instances[@]}"; do
                awk -F'|' -v i="$inst" '$1==i && $3!="MOUNTED" && $4=="NO" {ok=1} END {exit !ok}' "$RUN/pdb.before" || die "Running service $svc has an inconsistent/restricted PDB state on $inst."
            done
        fi
    done < "$RUN/services.tsv"

    fi # normal refresh target/service preflight

    phase catalog 'Resolving source identity, incarnation, backup inventory and RAC redo through ZDLRA.'
    discover_credentials
    sql CATALOG "$RUN/source.out" <<SQL
select distinct d.db_key||'|'||d.dbid from rc_database d join rc_site s on s.db_key=d.db_key
where upper(d.name)='$SOURCE_CDB' and upper(s.db_unique_name)='$SOURCE_UNIQUE';
SQL
    log "ZDLRA catalog connection and source lookup succeeded."
    one_line "$RUN/source.out"
    IFS='|' read -r SOURCE_DBKEY SOURCE_DBID <<< "$RESULT"
    positive "$SOURCE_DBKEY" && [[ $SOURCE_DBID =~ ^[0-9]+$ && $SOURCE_DBID != "$TARGET_DBID" ]] || die 'Source/target DBID mismatch or unsafe identity.'
    local point predicate
    point="to_date('${RECOVERY_TIME:-9999-12-31 23:59:59}','YYYY-MM-DD HH24:MI:SS')"
    predicate="resetlogs_time <= $point"
    [[ -n $RECOVERY_TIME ]] || predicate="status='CURRENT'"
    sql CATALOG "$RUN/incarnation.out" <<SQL
select dbinc_key||'|'||resetlogs_change#||'|'||to_char(resetlogs_time,'YYYY-MM-DD HH24:MI:SS')
from rc_database_incarnation where db_key=$SOURCE_DBKEY and status in ('CURRENT','PARENT') and $predicate
and resetlogs_time=(select max(resetlogs_time) from rc_database_incarnation where db_key=$SOURCE_DBKEY and status in ('CURRENT','PARENT') and $predicate);
SQL
    one_line "$RUN/incarnation.out"
    IFS='|' read -r SOURCE_INC SOURCE_RESET SOURCE_RESET_TIME <<< "$RESULT"
    [[ $SOURCE_INC =~ ^[0-9]+$ && $SOURCE_RESET =~ ^[0-9]+$ ]] || die 'Unresolved source incarnation.'
    log "Source $SOURCE_UNIQUE DBID=$SOURCE_DBID incarnation=$SOURCE_INC resetlogs=$SOURCE_RESET_TIME."
    sql CATALOG "$RUN/backup-size.out" <<SQL
select ceil(sum(bytes)/1048576)||'|'||max(root_block) from (
 select file#, max(datafile_blocks*block_size) bytes, max(case when file#=1 then block_size end) root_block
 from rc_backup_datafile b where db_key=$SOURCE_DBKEY and dbinc_key=$SOURCE_INC
 and status='A' and file#>0 and checkpoint_time < $point
 and exists (select 1 from rc_backup_piece p where p.bs_key=b.bs_key and p.status='A' and p.device_type='SBT_TAPE')
 group by file#);
SQL
    one_line "$RUN/backup-size.out"
    IFS='|' read -r SOURCE_MB BLOCK_SIZE <<< "$RESULT"
    positive "$SOURCE_MB" && [[ $BLOCK_SIZE =~ ^(2048|4096|8192|16384|32768)$ ]] || die 'No usable SBT datafile inventory/root block size.'
    sql CATALOG "$RUN/redo-inventory.out" <<SQL
select thread#||'|'||min(sequence#)||'|'||max(sequence#)||'|'||to_char(max(next_time),'YYYY-MM-DD HH24:MI:SS')
from rc_backup_redolog r where db_key=$SOURCE_DBKEY and dbinc_key=$SOURCE_INC and status='A'
and exists (select 1 from rc_backup_piece p where p.bs_key=r.bs_key and p.status='A' and p.device_type='SBT_TAPE')
group by thread# order by thread#;
SQL
    [[ $(wc -l < "$RUN/redo-inventory.out") -ge 2 ]] || die 'Catalog must expose redo for both source RAC threads.'
    local thread first last through
    while IFS='|' read -r thread first last through; do
        [[ $thread =~ ^[0-9]+$ && $first =~ ^[0-9]+$ && $last =~ ^[0-9]+$ ]] || die 'Unrecognized redo inventory.'
        [[ -z $RECOVERY_TIME || $through > "$RECOVERY_TIME" || $through == "$RECOVERY_TIME" ]] || die "Thread $thread has no catalogued redo through the requested time."
    done < "$RUN/redo-inventory.out"
    if (( DRY_RUN )); then
        create_aux_wallet
        dry_run_range
        cleanup_aux_wallet
        phase dry-run-complete "Dry-run checks completed. Evidence: $RUN"
        return 0
    fi
    log 'Catalog inventory is preliminary; successful auxiliary recovery is the backup/redo continuity check.'
    sql CATALOG "$RUN/tempfiles.raw.out" <<SQL
select distinct file# from rc_tempfile where db_key=$SOURCE_DBKEY and dbinc_key=$SOURCE_INC
and creation_time <= $point and (drop_time is null or drop_time > $point) order by file#;
SQL
    normalize_tempfile_ids "$RUN/tempfiles.raw.out" "$RUN/tempfiles.normalized.out"
    sql CATALOG "$RUN/temp-size.out" <<SQL
select ceil(nvl(sum(bytes),0)/1048576) from (
select file#,max(bytes) bytes from rc_tempfile where db_key=$SOURCE_DBKEY and dbinc_key=$SOURCE_INC
and creation_time <= $point and (drop_time is null or drop_time > $point) group by file#);
SQL
    one_line "$RUN/temp-size.out"
    [[ $RESULT =~ ^[0-9]+$ ]] || die 'Unknown tempfile space requirement.'
    SOURCE_MB=$((SOURCE_MB + RESULT))
    check_refresh_space "$((SOURCE_MB + SOURCE_MB / 4))"

    phase auxiliary "Recovering an isolated temporary CDB; target PDB discovery=$TARGET_PDB_STATE."
    AUX=$(mktemp -d "$AUX_BASE_PHYSICAL/dup_${DUP_AUX_CDB}_${stamp}_XXXXXX")
    printf '%s\n' "$AUX" > "$RUN/auxiliary-path"
    # A new OMF namespace for every run, including repeated runs with the same SID.
    AUX_UNIQUE="${DUP_AUX_CDB}_${stamp//T/}_${AUX##*_}"
    identifier "$AUX_UNIQUE" 30 || die 'Invalid auxiliary OMF namespace.'
    [[ ${AUX_UNIQUE^^} != "${SOURCE_UNIQUE^^}" && ${AUX_UNIQUE^^} != "${DB_UNIQUE_NAME^^}" ]] || die 'Auxiliary OMF namespace collides with source/target.'
    printf '%s|%s|%s\n' "$AUX_UNIQUE" "$AUX_DATA_DEST" "$AUX_RECO_DEST" > "$RUN/auxiliary-asm"
    create_aux_wallet
    mkdir "$AUX/audit" "$AUX/diag"
    build_aux_pfile > "$AUX/init.ora"
    start_auxiliary
    build_duplicate > "$RUN/duplicate.rman"
    rman "$DUP_AUX_CDB" duplicate "$RUN/duplicate.rman" "$RUN/duplicate.out"
    sql "$DUP_AUX_CDB" "$RUN/recovery-point.out" <<SQL
select 'RECOVERED_CHECKPOINT_SCN|'||checkpoint_change# from v\$database;
select 'SOURCE_RESETLOGS_SCN|'||resetlogs_change# from v\$database;
select 'FILE|'||file#||'|'||checkpoint_change#||'|'||to_char(checkpoint_time,'YYYY-MM-DD HH24:MI:SS')||'|'||fuzzy||'|'||recover from v\$datafile_header order by file#;
select 'LAST_APPLIED_REDO|'||to_char(timestamp,'YYYY-MM-DD HH24:MI:SS')||'|'||comments from v\$recovery_progress where item='Last Applied Redo';
select 'THREAD|'||thread#||'|'||enabled from v\$thread order by thread#;
declare n number;
begin
 select count(*) into n from v\$database where resetlogs_change#=$SOURCE_RESET and name=upper('$DUP_AUX_CDB') and dbid<>$TARGET_DBID and dbid<>$SOURCE_DBID;
 if n<>1 then raise_application_error(-20009,'Recovered auxiliary identity/incarnation mismatch'); end if;
end;
/
SQL
    while IFS='|' read -r _ thread _; do
        [[ $thread =~ ^[0-9]+$ ]] || die 'Unexpected recovered RAC thread.'
        grep -q "^$thread|" "$RUN/redo-inventory.out" || die "Recovered RAC thread $thread is absent from the catalog redo inventory."
    done < <(grep '^THREAD|' "$RUN/recovery-point.out")
    sql "$DUP_AUX_CDB" "$RUN/aux-files.out" <<'SQL'
select name from v$datafile union all select name from v$tempfile union all select member from v$logfile union all select name from v$controlfile;
SQL
    validate_aux_files "$RUN/aux-files.out"
    sql "$DUP_AUX_CDB" "$RUN/aux-open.out" <<SQL
alter database open resetlogs;
select 'RESETLOGS_SCN|'||resetlogs_change# from v\$database;
declare n number;
begin
 select count(*) into n from v\$pdbs where con_id>2;
 if n<>1 then raise_application_error(-20001,'Expected exactly one source application PDB'); end if;
 select count(*) into n from v\$pdbs where name='$SOURCE_PDB' and con_id>2;
 if n<>1 then raise_application_error(-20002,'Requested source PDB absent'); end if;
 for p in (select name from v\$pdbs where name='$SOURCE_PDB' and open_mode<>'MOUNTED') loop
  execute immediate 'alter pluggable database $SOURCE_PDB close immediate';
 end loop;
end;
/
alter pluggable database $SOURCE_PDB open restricted;
alter session set container=$SOURCE_PDB;
declare n number;
begin
 select count(*) into n from v\$encryption_wallet where status='OPEN' and wrl_type='HSM' and keystore_mode='UNITED';
 if n=0 then raise_application_error(-20003,'Source PDB requires an open united-mode HSM keystore'); end if;
end;
/
-- This auxiliary is single-instance and unmanaged by Clusterware.
-- Delete copied application services here, before any target registration.
begin
 for s in (select name from dba_services where upper(name) not in ('$SOURCE_PDB','SYS\$BACKGROUND','SYS\$USERS')) loop
  for a in (select name from v\$active_services where name=s.name) loop dbms_service.stop_service(a.name); end loop;
  dbms_service.delete_service(s.name);
 end loop;
end;
/
SQL
    printf 'validate check logical pluggable database %s;\n' "$SOURCE_PDB" > "$RUN/validate-aux.rman"
    rman "$DUP_AUX_CDB" local "$RUN/validate-aux.rman" "$RUN/validate-aux.out"
    sql "$DUP_AUX_CDB" "$RUN/aux-check.out" <<SQL
declare n number;
begin
 select count(*) into n from v\$database_block_corruption;
 if n>0 then raise_application_error(-20004,'Auxiliary has corrupt blocks'); end if;
end;
/
alter pluggable database $SOURCE_PDB close immediate;
alter pluggable database $SOURCE_PDB unplug into '$AUX/pdb.xml';
SQL
    sql "$TARGET_SID" "$RUN/compatibility.out" <<SQL
declare ok boolean;
begin
 ok:=dbms_pdb.check_plug_compatibility(pdb_descr_file=>'$AUX/pdb.xml',pdb_name=>'$TARGET_PDB');
 if ok then dbms_output.put_line('COMPATIBLE'); else dbms_output.put_line('INCOMPATIBLE'); end if;
end;
/
select type||'|'||cause||'|'||message||'|'||action from pdb_plug_in_violations where name='$TARGET_PDB' and status<>'RESOLVED' order by time;
SQL
    grep -Fxq COMPATIBLE "$RUN/compatibility.out" || die 'Plug compatibility failed; inspect compatibility.out before retrying.'
    if [[ $TARGET_PDB_STATE == PRESENT ]]; then
        printf 'drop pluggable database %s including datafiles;\n' "$TARGET_PDB" > "$RUN/drop-old.sql"
    fi
    build_plug > "$RUN/plug.sql"

    phase cutover "Auxiliary recovery validated. Checking target before apply/service gate and PDB $pdb_action."
    target_identity "$RUN/identity.precutover"
    cmp -s "$RUN/identity.before" "$RUN/identity.precutover" || die 'Target identity/root/seed/backup configuration changed during preparation.'
    discover_target_rac "$RUN/target-rac.precutover"
    cmp -s "$TARGET_RAC_FILE" "$RUN/target-rac.precutover" || die 'Target RAC inventory changed during preparation.'
    check_target_pdb_identity "$RUN/pdb-inventory.precutover"
    cut -d'|' -f1-4 "$RUN/pdb-inventory.precutover" > "$RUN/pdb.precutover"
    cmp -s "$RUN/pdb.before" "$RUN/pdb.precutover" || die 'Target PDB open state changed during recovery.'
    sql "$TARGET_SID" "$RUN/saved.precutover" <<SQL
select instance_name||'|'||state||'|'||restricted from dba_pdb_saved_states where con_name='$TARGET_PDB' order by instance_name;
SQL
    cmp -s "$RUN/saved.before" "$RUN/saved.precutover" || die 'Target PDB saved state changed during recovery.'
    space_check "$TARGET_DEST" "$((SOURCE_MB + SOURCE_MB / 4))"
    # Freeze check: resource definitions must still be exactly the captured ones.
    while IFS='|' read -r svc enabled running; do
        srv "$RUN/service.$svc.check" config service -db "$DB_UNIQUE_NAME" -service "$svc" -verbose
        cmp -s "$RUN/service.$svc.before" "$RUN/service.$svc.check" || die "Service $svc changed during recovery."
        srv "$RUN/service.$svc.status.check" status service -db "$DB_UNIQUE_NAME" -service "$svc" -force
        cmp -s "$RUN/service.$svc.status.before" "$RUN/service.$svc.status.check" || die "Service $svc running state changed during recovery."
    done < "$RUN/services.tsv"
    stop_target_apply
    CUTOVER=services-stopped
    while IFS='|' read -r svc enabled running; do
        [[ $enabled != enabled ]] || srv "$RUN/service.$svc.disable" disable service -db "$DB_UNIQUE_NAME" -service "$svc"
        [[ $running == - ]] || srv "$RUN/service.$svc.stop" stop service -db "$DB_UNIQUE_NAME" -service "$svc" -stopoption IMMEDIATE -force
    done < "$RUN/services.tsv"
    if [[ $TARGET_PDB_STATE == PRESENT ]]; then
    sql "$TARGET_SID" "$RUN/close-old.out" <<SQL
begin
 for p in (select i.instance_name from gv\$pdbs p join gv\$instance i on i.inst_id=p.inst_id where p.name='$TARGET_PDB' and p.open_mode<>'MOUNTED') loop
  execute immediate 'alter pluggable database $TARGET_PDB close immediate instances=('''||p.instance_name||''')';
 end loop;
end;
/
SQL
    fi
    # APPLY-OFF leaves read-only standby PDBs open. Recheck the independently
    # established closure and actual apply state immediately before DROP.
    local standby
    DG_HANDOFF='prior broker/apply evidence retained; final verification incomplete; investigate any UNKNOWN states'
    discover_standbys predrop
    verify_topology_freeze predrop
    while IFS= read -r standby; do observe_standby "$standby" predrop 1; done < "$RUN/dg.preflight.standbys"
    if [[ -s $RUN/dg.preflight.standbys ]]; then
        DG_HANDOFF='APPLY-OFF verified on all target standbys; retained for separate standby refresh'
    else
        DG_HANDOFF=no-standby
    fi
    # Recheck the same identity after closing, or continued absence for creation,
    # immediately before the first destructive/create statement.
    check_target_pdb_identity "$RUN/pdb-inventory.prechange"
    if [[ $TARGET_PDB_STATE == PRESENT ]]; then
    CUTOVER=drop-issued; printf '%s\n' "$CUTOVER" > "$RUN/cutover"
    sql "$TARGET_SID" "$RUN/drop-old.out" < "$RUN/drop-old.sql"
    CUTOVER=old-pdb-removed; printf '%s\n' "$CUTOVER" > "$RUN/cutover"
    fi
    check_target_pdb_identity "$RUN/pdb-inventory.precreate" ABSENT
    discover_standbys precreate
    verify_topology_freeze precreate
    CUTOVER=create-issued; printf '%s\n' "$CUTOVER" > "$RUN/cutover"
    sql "$TARGET_SID" "$RUN/plug.out" < "$RUN/plug.sql"
    CUTOVER='pdb-plugged'; printf '%s\n' "$CUTOVER" > "$RUN/cutover"
    phase verification 'Checking created PDB encryption, datafiles, plug status and primary-side recovery status.'
    printf 'validate check logical pluggable database %s;\n' "$TARGET_PDB" > "$RUN/validate-target.rman"
    rman "$TARGET_SID" local "$RUN/validate-target.rman" "$RUN/validate-target.out"
    sql "$TARGET_SID" "$RUN/verify-pdb.out" <<SQL
select type||'|'||cause||'|'||message||'|'||action from pdb_plug_in_violations where name='$TARGET_PDB' and status<>'RESOLVED' order by time;
declare n number;
begin
 select count(*) into n from pdb_plug_in_violations where name='$TARGET_PDB' and type='ERROR' and status<>'RESOLVED';
 if n>0 then raise_application_error(-20005,'Unresolved plug-in errors'); end if;
 select count(*) into n from v\$database_block_corruption where con_id=(select con_id from v\$pdbs where name='$TARGET_PDB');
 if n>0 then raise_application_error(-20006,'Replacement has corrupt blocks'); end if;
 select count(*) into n from (select name,con_id from v\$datafile union all select name,con_id from v\$tempfile)
 where con_id=(select con_id from v\$pdbs where name='$TARGET_PDB') and instr(upper(name),upper('$TARGET_DEST/'))<>1;
 if n>0 then raise_application_error(-20007,'Target file outside its OMF destination'); end if;
end;
/
select 'PDB|'||name||'|'||guid||'|'||open_mode||'|'||recovery_status from v\$pdbs where name='$TARGET_PDB';
select 'FILE|'||name from v\$datafile where con_id=(select con_id from v\$pdbs where name='$TARGET_PDB');
select 'TEMPFILE|'||name from v\$tempfile where con_id=(select con_id from v\$pdbs where name='$TARGET_PDB');
SQL
    while IFS='|' read -r inst host state version; do
        sql "$inst" "$RUN/tde.$inst.out" "$host" <<SQL
alter session set container=$TARGET_PDB;
declare n number;
begin
 select count(*) into n from v\$encryption_wallet where status='OPEN' and wrl_type='HSM';
 if n=0 then raise_application_error(-20008,'Replacement HSM wallet is not open on this instance'); end if;
end;
/
SQL
    done < "$TARGET_RAC_FILE"
    sql "$TARGET_SID" "$RUN/close-new.out" <<SQL
alter pluggable database $TARGET_PDB close immediate instances=all;
SQL
    restore_pdb_states
    phase services 'Reconciling preserved Clusterware services and restoring their captured running instances.'
    restore_services
    query_target_pdb "$RUN/pdb-inventory.after"
    validate_target_pdb "$RUN/pdb-inventory.after" "$TARGET_RAC_FILE"
    [[ $PDB_STATE == PRESENT ]] || die 'Created target PDB is absent during final verification.'
    cut -d'|' -f1-4 "$RUN/pdb-inventory.after" > "$RUN/pdb.after"
    cmp -s "$RUN/pdb.expected" "$RUN/pdb.after" || die 'PDB RAC open state differs from the captured/initial policy.'
    sql "$TARGET_SID" "$RUN/saved.after" <<SQL
select instance_name||'|'||state||'|'||restricted from dba_pdb_saved_states where con_name='$TARGET_PDB' order by instance_name;
SQL
    cmp -s "$RUN/saved.expected" "$RUN/saved.after" || die 'PDB saved state differs from the captured/initial policy.'
    sql "$TARGET_SID" "$RUN/services.sql.after" <<SQL
select name from cdb_services where pdb='$TARGET_PDB' and upper(name)<>'$TARGET_PDB' order by name;
SQL
    while IFS= read -r svc; do
        [[ -z $svc ]] && continue
        awk -F'|' -v s="$svc" '$1==s {ok=1} END {exit !ok}' "$RUN/services.tsv" || die "Unexpected service $svc in refreshed PDB."
    done < "$RUN/services.sql.after"
    target_identity "$RUN/identity.after"
    cmp -s "$RUN/identity.before" "$RUN/identity.after" || die 'Target CDB/root/seed/backup configuration differs.'
    shutdown_auxiliary
    CUTOVER=complete
    printf '%s\n' complete > "$RUN/cutover"
    touch "$RUN/complete"
    phase complete "Primary PDB $pdb_action completed. CDB identity/configuration and RAC services verified."
    log "Recovery evidence: $RUN/recovery-point.out and $RUN/aux-open.out (source SCNs, fixed UTC+02:00 where available)."
    log "Auxiliary shut down; recovered PDB files moved to $TARGET_DEST. Working files retained at $AUX; remaining auxiliary ASM files under $AUX_DATA_DEST/$AUX_UNIQUE and $AUX_RECO_DEST/$AUX_UNIQUE. Review target file inventory before manual cleanup; the unplug XML still references pre-MOVE paths."
    if [[ -s $RUN/dg.preflight.standbys ]]; then
        log 'STANDBYS=NONE was used. The separate standby-refresh procedure owns standby refresh, safe apply resumption and standby validation.'
    else
        log "STANDBYS=NONE was used. No physical standby configured; evidence=$DG_TOPOLOGY_EVIDENCE. No standby apply or refresh handoff is required."
    fi
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
