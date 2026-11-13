#!/usr/bin/env bash
# Optional target PDB fixtures. Every Oracle/SSH command is replaced locally.
set -Eeuo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../dup_db.sh
source "$root/dup_db.sh"
tmp=$(mktemp -d /tmp/zdlra-pdb.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
checks=0
ok() { ((checks+=1)); }
reject() {
    if ("$@") > "$tmp/rejected" 2>&1; then printf 'Expected rejection: %s\n' "$*" >&2; exit 1; fi
    ok
}
TARGET_PDB=APPTEST TARGET_SID=PRE1 RUN=$tmp
printf 'PRE1|node1.example|OPEN|19.0.0.0.0\nPRE2|node2.example|OPEN|19.0.0.0.0\n' > "$tmp/rac"
TARGET_RAC_FILE=$tmp/rac
: > "$tmp/pdb"
validate_target_pdb "$tmp/pdb" "$tmp/rac"
[[ $PDB_STATE == ABSENT && -z $PDB_GUID ]]; ok
printf 'PRE1|node1.example|READ WRITE|NO|0123456789ABCDEF0123456789ABCDEF\nPRE2|node2.example|MOUNTED|NO|0123456789ABCDEF0123456789ABCDEF\n' > "$tmp/pdb"
validate_target_pdb "$tmp/pdb" "$tmp/rac"
[[ $PDB_STATE == PRESENT && $PDB_GUID == 0123456789ABCDEF0123456789ABCDEF ]]; ok
cp "$tmp/pdb" "$tmp/pdb.good"
for error in partial duplicate guid wrong-host bad-mode bad-restricted extra-column empty-extra-column delimiters; do
    case $error in
        partial) sed -n '1p' "$tmp/pdb.good" > "$tmp/pdb" ;;
        duplicate) sed 's/PRE2|node2/PRE1|node1/' "$tmp/pdb.good" > "$tmp/pdb" ;;
        guid) sed '2s/0123456789ABCDEF0123456789ABCDEF/FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF/' "$tmp/pdb.good" > "$tmp/pdb" ;;
        wrong-host) sed 's/node2/other/' "$tmp/pdb.good" > "$tmp/pdb" ;;
        bad-mode) sed 's/MOUNTED/UNKNOWN/' "$tmp/pdb.good" > "$tmp/pdb" ;;
        bad-restricted) sed 's/|NO|/|UNKNOWN|/' "$tmp/pdb.good" > "$tmp/pdb" ;;
        extra-column) sed 's/$/|unexpected/' "$tmp/pdb.good" > "$tmp/pdb" ;;
        empty-extra-column) sed 's/$/|/' "$tmp/pdb.good" > "$tmp/pdb" ;;
        delimiters) printf '|||||\n' > "$tmp/pdb" ;;
    esac
    reject validate_target_pdb "$tmp/pdb" "$tmp/rac"
done
for error in missing offline duplicate malformed empty-extra-column; do
    case $error in
        missing) sed -n '1p' "$tmp/rac" > "$tmp/rac.bad" ;;
        offline) sed 's/|OPEN|/|MOUNTED|/' "$tmp/rac" > "$tmp/rac.bad" ;;
        duplicate) sed 's/PRE2/PRE1/' "$tmp/rac" > "$tmp/rac.bad" ;;
        malformed) sed 's/$/|extra/' "$tmp/rac" > "$tmp/rac.bad" ;;
        empty-extra-column) sed 's/$/|/' "$tmp/rac" > "$tmp/rac.bad" ;;
    esac
    reject validate_target_rac "$tmp/rac.bad"
done

printf '||||\n' > "$tmp/pdb"
reject validate_target_pdb "$tmp/pdb" "$tmp/rac"
printf 'PRE1|OPEN|NO\nPRE1|OPEN|NO\n' > "$tmp/saved"
reject validate_saved_states "$tmp/saved" "$tmp/rac" PRESENT
printf 'PRE2|OPEN|NO|\n' > "$tmp/saved"
reject validate_saved_states "$tmp/saved" "$tmp/rac" PRESENT
printf 'PRE2|OPEN|NO\n' > "$tmp/saved"
reject validate_saved_states "$tmp/saved" "$tmp/rac" ABSENT
printf 'PDB\n' > "$tmp/standby"
reject validate_standby_observation "$tmp/standby"

# Exercise the real main(), SQL/RMAN/srvctl/broker wrappers, generated SQL,
# wallet lifecycle, cutover gates and final verification against fake clients.
cp "$root/tests/fixtures/topology-19c.sh" "$tmp/topology-fixture.sh"
cp "$root/tests/fixtures/tempfile-ids-padded.txt" "$tmp/tempfile-ids-padded.txt"
printf '1\n2\n4\n5\n6\n7\n' > "$tmp/expected-ids"
printf '  set newname for tempfile %s to new;\n' 1 2 4 5 6 7 > "$tmp/expected-newnames"
export PDB_FIXTURE_ROOT=$tmp PDB_FIXTURE_CASE PDB_FIXTURE_DIR
mkdir -p "$tmp/bin" "$tmp/oracle/bin" "$tmp/oracle/lib" "$tmp/wallet/tde" "$tmp/wallet/tde_seps" "$tmp/stage"
printf 'offline-wallet\n' > "$tmp/wallet/tde/cwallet.sso"
cp "$tmp/wallet/tde/cwallet.sso" "$tmp/wallet/tde_seps/cwallet.sso"
touch "$tmp/oracle/lib/libra.so"
cat > "$tmp/bin/id" <<'CLIENT'
#!/usr/bin/env bash
if [[ ${1:-} == -un ]]; then printf 'oracle\n'; else /usr/bin/id "$@"; fi
CLIENT
cat > "$tmp/bin/ssh" <<'CLIENT'
#!/usr/bin/env bash
set -eu
case $* in
    *oracle@node2.example*) export ORACLE_SID=PRE2 ;;
    *oracle@standby1.example*) export ORACLE_SID=ST1 ;;
    *oracle@standby2.example*) export ORACLE_SID=ST2 ;;
    *) exit 90 ;;
esac
printf 'ssh sid=%s\n' "$ORACLE_SID" >> "$PDB_FIXTURE_DIR/calls"
exec "$PDB_FIXTURE_ROOT/oracle/bin/sqlplus" -L -s /nolog
CLIENT
cat > "$tmp/oracle/bin/sqlplus" <<'CLIENT'
#!/usr/bin/env bash
set -eu
if [[ $* == -V ]]; then printf 'SQL*Plus: Release 19.0.0.0.0\n'; exit; fi
query=$(cat)
printf '\nSQL sid=%s\n%s\n' "$ORACLE_SID" "$query" >> "$PDB_FIXTURE_DIR/calls"
if [[ $query == *'END|TOPOLOGY'* ]]; then
    source "$PDB_FIXTURE_ROOT/topology-fixture.sh"
    physical='' broker=TRUE
    [[ $PDB_FIXTURE_CASE != *standalone* ]] || broker=FALSE
    if [[ $PDB_FIXTURE_CASE == *standalone-new-relationship && -f $PDB_FIXTURE_DIR/prepared ]]; then physical=PREST; fi
    [[ $PDB_FIXTURE_CASE != absent-managed && $PDB_FIXTURE_CASE != absent-standby-conflict ]] || physical=PREST
    topology_fixture "$ORACLE_SID" "$broker" "$physical"
elif [[ $query == *'v$dataguard_process'* ]]; then
    count=1; [[ ! -f $PDB_FIXTURE_DIR/apply-off ]] || count=0
    printf 'IDENTITY|PRE|PREST|42|PHYSICAL STANDBY|YES|%s\nCONTAINER|CDB$ROOT\nBROKER|TRUE\nRAC|ST1|standby1.example\nRAC|ST2|standby2.example\nAPPLY|%s\n' "$ORACLE_SID" "$count"
    [[ $PDB_FIXTURE_CASE != absent-standby-conflict ]] || printf 'PDB|FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF|MOUNTED\n'
elif [[ $query == *"select name||'|'||db_unique_name"* ]]; then
    printf 'PRE|PREM1|42|PRIMARY|YES|READ WRITE\nCONTAINER|CDB$ROOT\nFILE|1|1|+DATA/root\nCONFIG|BACKUP RETENTION POLICY|RECOVERY WINDOW OF 7 DAYS\n'
elif [[ $query == *"select instance_name||'|'||host_name||'|'||status"* ]]; then
    printf 'PRE1|node1.example|OPEN|19.0.0.0.0\nPRE2|node2.example|OPEN|19.0.0.0.0\n'
elif [[ $query == *'rawtohex(p.guid)'* ]]; then
    if [[ $PDB_FIXTURE_CASE == query-error ]]; then printf 'ORA-00942: offline inventory failure\n'; exit; fi
    present=0 guid=0123456789ABCDEF0123456789ABCDEF mode='READ WRITE'
    [[ $PDB_FIXTURE_CASE != present* ]] || present=1
    [[ ! -f $PDB_FIXTURE_DIR/dropped ]] || present=0
    if [[ -f $PDB_FIXTURE_DIR/prepared ]]; then
        [[ $PDB_FIXTURE_CASE != absent-appears ]] || present=1
        [[ $PDB_FIXTURE_CASE != present-disappears ]] || present=0
        [[ $PDB_FIXTURE_CASE != present-guid-change ]] || guid=FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF
    fi
    if [[ -f $PDB_FIXTURE_DIR/closed-old ]]; then
        mode=MOUNTED
        [[ $PDB_FIXTURE_CASE != present-guid-after-close ]] || guid=FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF
    fi
    if [[ -f $PDB_FIXTURE_DIR/created ]]; then present=1; mode='READ WRITE'; guid=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA; fi
    if ((present)); then
        printf 'PRE1|node1.example|%s|NO|%s\nPRE2|node2.example|%s|NO|%s\n' "$mode" "$guid" "$mode" "$guid"
    fi
elif [[ $query == *"p.name||'|'||p.open_mode"* ]]; then
    printf 'PRE1|CDB$ROOT|READ WRITE\nPRE1|PDB$SEED|READ ONLY\nPRE1|OTHERPDB|READ WRITE\nPRE2|CDB$ROOT|READ WRITE\nPRE2|PDB$SEED|READ ONLY\nPRE2|OTHERPDB|READ WRITE\n'
elif [[ $query == *'from dba_pdb_saved_states'* ]]; then
    if [[ $PDB_FIXTURE_CASE == present* || -f $PDB_FIXTURE_DIR/created ]]; then printf 'PRE1|OPEN|NO\nPRE2|OPEN|NO\n'; fi
elif [[ $query == *'select d.dbid'* ]]; then
    if [[ $PDB_FIXTURE_CASE == node-unavailable && $ORACLE_SID == PRE2 ]]; then printf 'ORA-01034: offline instance unavailable\n'; exit; fi
    printf '42|PRIMARY|%s|19.0.0.0.0\nWALLET|1\n' "$ORACLE_SID"
elif [[ $query == *'select value from v$parameter'* ]]; then
    printf '+DATA\n19.0.0\nKEYSTORE_CONFIGURATION=HSM\n%s/wallet\n+RECO\n' "$PDB_FIXTURE_ROOT"
elif [[ $query == *'from gv$parameter'* ]]; then printf 'ENABLED\n'
elif [[ $query == *'select rawtohex(guid)'* ]]; then printf '0123456789ABCDEF0123456789ABCDEF\n'
elif [[ $query == *'from cdb_services'* ]]; then :
elif [[ $query == *'select to_char(to_date('* ]]; then printf '2024-10-01 10:20:05\n'
elif [[ $query == *'from rc_database d'* ]]; then printf '1|77\n'
elif [[ $query == *'from rc_database_incarnation'* ]]; then printf '2|100|2024-01-01 00:00:00\n'
elif [[ $query == *'from rc_backup_datafile'* ]]; then printf '1024|8192\n'
elif [[ $query == *'from rc_backup_redolog'* ]]; then printf '1|10|20|2024-10-02 00:00:00\n2|10|19|2024-10-02 00:00:00\n'
elif [[ $query == *'select distinct file# from rc_tempfile'* ]]; then cat "$PDB_FIXTURE_ROOT/tempfile-ids-padded.txt"
elif [[ $query == *'from rc_tempfile'* ]]; then printf ' \t10 \t\r\n'
elif [[ $query == *'from v$asm_diskgroup_stat'* ]]; then printf '    999999\n'
elif [[ $query == *'startup nomount'* ]]; then
    pfile=$(printf '%s\n' "$query" | sed -n "s/.*startup nomount pfile='\([^']*\)';.*/\1/p")
    sed -n "s/^\*.db_unique_name='\([^']*\)'/\1/p" "$pfile" > "$PDB_FIXTURE_DIR/aux-unique"
elif [[ $query == *'RECOVERED_CHECKPOINT_SCN'* ]]; then printf 'RECOVERED_CHECKPOINT_SCN|200\nSOURCE_RESETLOGS_SCN|100\nTHREAD|1|PUBLIC\nTHREAD|2|PUBLIC\n'
elif [[ $query == *'select name from v$datafile union all'* ]]; then printf '+DATA/%s/datafile/example\n' "$(cat "$PDB_FIXTURE_DIR/aux-unique")"
elif [[ $query == *'dbms_pdb.check_plug_compatibility'* ]]; then printf 'COMPATIBLE\n'; touch "$PDB_FIXTURE_DIR/prepared"
elif [[ $query == *'drop pluggable database APPTEST including datafiles;'* ]]; then touch "$PDB_FIXTURE_DIR/dropped"
elif [[ $query == *'create pluggable database APPTEST using'* ]]; then touch "$PDB_FIXTURE_DIR/created"
elif [[ $query == *'for p in (select i.instance_name from gv$pdbs'* ]]; then touch "$PDB_FIXTURE_DIR/closed-old"
elif [[ $query == *'shutdown immediate;'* ]]; then printf 'ORACLE instance shut down.\n'
elif [[ $query == *'alter '* || $query == *'declare '* || $query == *'begin'* ]]; then :
else printf 'Unhandled offline SQL\n' >&2; exit 91
fi
CLIENT
cat > "$tmp/oracle/bin/dgmgrl" <<'CLIENT'
#!/usr/bin/env bash
set -eu
if [[ $# == 2 ]]; then
    input=$(cat)
    [[ $input == $'SHOW CONFIGURATION VERBOSE;\nEXIT;' ]] || exit 99
    set -- "$@" 'SHOW CONFIGURATION VERBOSE;'
fi
printf 'BROKER %s\n' "$3" >> "$PDB_FIXTURE_DIR/calls"
case $3 in
    'SHOW CONFIGURATION VERBOSE;')
        printf 'Configuration - pre_dg\n  Members:\n    PREM1 - Primary database\n'
        [[ $PDB_FIXTURE_CASE != absent-managed && $PDB_FIXTURE_CASE != absent-standby-conflict ]] || printf '    PREST - Physical standby database\n'
        printf '  Properties:\nConfiguration Status:\nSUCCESS\n' ;;
    "SHOW DATABASE 'PREST';")
        state=APPLY-ON; [[ ! -f $PDB_FIXTURE_DIR/apply-off ]] || state=APPLY-OFF
        printf 'Database - PREST\n  Role: PHYSICAL STANDBY\n  Intended State: %s\n  Instance(s):\n    ST1\n    ST2\nDatabase Status:\nSUCCESS\n' "$state" ;;
    "SHOW INSTANCE VERBOSE 'ST1' ON DATABASE 'PREST';") printf "HostName = 'standby1.example'\n" ;;
    "SHOW INSTANCE VERBOSE 'ST2' ON DATABASE 'PREST';") printf "HostName = 'standby2.example'\n" ;;
    "EDIT DATABASE 'PREST' SET STATE='APPLY-OFF';") touch "$PDB_FIXTURE_DIR/apply-off" ;;
    *) exit 92 ;;
esac
CLIENT
cat > "$tmp/oracle/bin/srvctl" <<'CLIENT'
#!/usr/bin/env bash
set -eu
printf 'SRV %s\n' "$*" >> "$PDB_FIXTURE_DIR/calls"
case $* in
    'config service -db PREM1'|'config service -db PREM1 -service pre_app -verbose')
        [[ $PDB_FIXTURE_CASE != absent-*stopped && $PDB_FIXTURE_CASE != absent-running ]] || cat "$PDB_FIXTURE_DIR/service" ;;
    'status service -db PREM1 -service pre_app -force')
        if [[ $PDB_FIXTURE_CASE == absent-running ]]; then printf 'Service pre_app is running on instance(s) PRE2\n'
        else printf 'Service pre_app is not running.\n'; fi ;;
    'disable service -db PREM1 -service pre_app') sed 's/^Service is enabled$/Service is disabled/' "$PDB_FIXTURE_DIR/service" > "$PDB_FIXTURE_DIR/edited"; mv "$PDB_FIXTURE_DIR/edited" "$PDB_FIXTURE_DIR/service" ;;
    'enable service -db PREM1 -service pre_app') sed 's/^Service is disabled$/Service is enabled/' "$PDB_FIXTURE_DIR/service" > "$PDB_FIXTURE_DIR/edited"; mv "$PDB_FIXTURE_DIR/edited" "$PDB_FIXTURE_DIR/service" ;;
    'modify service -db PREM1 -service pre_app -pdb APPTEST') : ;;
    *) exit 93 ;;
esac
CLIENT
cat > "$tmp/oracle/bin/rman" <<'CLIENT'
#!/usr/bin/env bash
cat >> "$PDB_FIXTURE_DIR/rman-calls"
CLIENT
cat > "$tmp/oracle/bin/mkstore" <<'CLIENT'
#!/usr/bin/env bash
exit 94
CLIENT
chmod +x "$tmp/bin/"* "$tmp/oracle/bin/"*
export PATH="$tmp/bin:$PATH"
load_environment() {
    ORACLE_HOME=$PDB_FIXTURE_ROOT/oracle ORACLE_SID=PRE1 DB_UNIQUE_NAME=PREM1
    export ORACLE_HOME ORACLE_SID DB_UNIQUE_NAME
}
discover_credentials() { WALLET=$PDB_FIXTURE_ROOT/wallet RA_ALIAS=offline VPC_USER=VPC VPC_PASSWORD=offline; }
# Redirect only main's fixed log root; implementation and all client wrappers run unchanged.
eval "$(declare -f main | sed "s@local logbase=/home/oracle/duplicate_logs@local logbase=$tmp/logs@")"
base=(--source-cdb PROD --target-cdb PRE --source-pdb APP --target-pdb APPTEST --aux-cdb RFRAUX --aux-base "$tmp/stage" --do-duplicate)
run_fixture() {
    PDB_FIXTURE_CASE=$1 PDB_FIXTURE_DIR=$tmp/$1
    mkdir -p "$PDB_FIXTURE_DIR"
    cp "$root/tests/fixtures/service-admin-19c.txt" "$PDB_FIXTURE_DIR/service"
    if [[ $1 == absent-disabled-stopped ]]; then
        sed 's/^Service is enabled$/Service is disabled/' "$PDB_FIXTURE_DIR/service" > "$PDB_FIXTURE_DIR/edited"
        mv "$PDB_FIXTURE_DIR/edited" "$PDB_FIXTURE_DIR/service"
    fi
    : > "$PDB_FIXTURE_DIR/calls"
    local expected=$2 rc; shift 2
    set +e
    if [[ $PDB_FIXTURE_CASE == *standalone* ]]; then mv "$PDB_FIXTURE_ROOT/oracle/bin/dgmgrl" "$PDB_FIXTURE_ROOT/dgmgrl-unused"; fi
    (main "${base[@]}" "$@") > "$PDB_FIXTURE_DIR/console" 2>&1
    rc=$?
    if [[ $PDB_FIXTURE_CASE == *standalone* ]]; then mv "$PDB_FIXTURE_ROOT/dgmgrl-unused" "$PDB_FIXTURE_ROOT/oracle/bin/dgmgrl"; fi
    set -e
    if ((rc != expected)); then cat "$PDB_FIXTURE_DIR/console"; exit 1; fi
    fixture_run=$(sed -n 's/.*Logs: //p' "$PDB_FIXTURE_DIR/console" | head -n 1)
    [[ -d $fixture_run ]]; ok
}
for scenario in absent absent-enabled-stopped absent-disabled-stopped absent-managed absent-standalone; do
    if [[ $scenario == absent-standalone ]]; then run_fixture "$scenario" 0 --time '2024-10-01 10:20:05'
    else run_fixture "$scenario" 0; fi
    [[ -f $PDB_FIXTURE_DIR/created && -f $fixture_run/complete && ! -f $fixture_run/drop-old.sql && ! -f $fixture_run/close-old.out && ! -f $PDB_FIXTURE_DIR/dropped ]]
    if [[ $scenario == absent-standalone ]]; then
        # Combined handoff: initial creation, positively established no standby,
        # automatic wallet planning/copy/cleanup, and padded numeric metadata.
        grep -Fxq 'NONE|STANDALONE_DISABLED' "$fixture_run/dg.preflight.mode"
        cmp "$tmp/tempfile-ids-padded.txt" "$fixture_run/tempfiles.raw.out"
        cmp "$tmp/expected-ids" "$fixture_run/tempfiles.normalized.out"
        grep 'set newname for tempfile' "$fixture_run/duplicate.rman" > "$tmp/actual-newnames"
        cmp "$tmp/expected-newnames" "$tmp/actual-newnames"
        grep -Fq "until time \"to_date('2024-10-01 10:20:05','YYYY-MM-DD HH24:MI:SS')\"" "$fixture_run/duplicate.rman"
        grep -Fq 'Space +DATA: 976.56 GiB usable; estimated requirement 12.52 GiB.' "$fixture_run/run.log"
        grep -Fq 'Space +RECO: 976.56 GiB usable; estimated requirement 10.00 GiB.' "$fixture_run/run.log"
        aux_path=$(cat "$fixture_run/auxiliary-path")
        wallet_path=$(cat "$fixture_run/auxiliary-wallet-path")
        [[ $wallet_path == "$aux_path/aux_wallet_RFRAUX_"*/wallet_root && ! -e $wallet_path ]]
        grep -Fq "fresh private copy parent=$aux_path" "$fixture_run/run.log"
        grep -Fq 'Auxiliary wallet copy: ready;' "$fixture_run/run.log"
        grep -Fxq 'removed|auxiliary=stopped' "$fixture_run/auxiliary-wallet-status"
        grep -Fxq "*.wallet_root='$wallet_path'" "$aux_path/init.ora"
        if grep -Eq '^BROKER|ssh sid=ST' "$PDB_FIXTURE_DIR/calls"; then exit 1; fi
        if grep -Eq 'Leave any stopped apply|separate standby-refresh procedure' "$PDB_FIXTURE_DIR/console"; then exit 1; fi
    fi
    grep -Fxq ABSENT "$fixture_run/target-pdb-state"
    cmp "$fixture_run/pdb.expected" "$fixture_run/pdb.after"
    cmp "$fixture_run/saved.expected" "$fixture_run/saved.after"
    for inst in PRE1 PRE2; do
        [[ -f $fixture_run/node.$inst.out && -f $fixture_run/tde.$inst.out && -f $fixture_run/state.$inst.sql ]]
        grep -Fxq 'alter pluggable database APPTEST save state;' "$fixture_run/state.$inst.sql"
        grep -Fxq 'alter pluggable database APPTEST open READ WRITE;' "$fixture_run/state.$inst.sql"
    done
    if grep -Eqi 'drop pluggable database APPTEST|close immediate instances=\(' "$PDB_FIXTURE_DIR/calls"; then exit 1; fi
    if [[ $scenario == absent-managed ]]; then
        grep -Fq "BROKER EDIT DATABASE 'PREST' SET STATE='APPLY-OFF';" "$PDB_FIXTURE_DIR/calls"
        grep -Fq 'predrop|PREST|APPLY-OFF|ST2|0|ABSENT|-' "$fixture_run/dg-states.tsv"
    fi
    ok
done
run_fixture present-standalone 0
grep -Fxq 'NONE|STANDALONE_DISABLED' "$fixture_run/dg.preflight.mode"
if grep -Eq '^BROKER|ssh sid=ST' "$PDB_FIXTURE_DIR/calls"; then exit 1; fi
[[ -f $PDB_FIXTURE_DIR/dropped ]]; ok
run_fixture present 0
[[ -f $PDB_FIXTURE_DIR/dropped && -f $fixture_run/drop-old.sql && -f $fixture_run/close-old.out ]]
cmp "$fixture_run/pdb.before" "$fixture_run/pdb.after"
cmp "$fixture_run/saved.before" "$fixture_run/saved.after"; ok
for scenario in query-error node-unavailable absent-running absent-appears present-disappears present-guid-change present-guid-after-close absent-standby-conflict absent-standalone-new-relationship present-standalone-new-relationship; do
    run_fixture "$scenario" 1
    [[ ! -f $PDB_FIXTURE_DIR/created && ! -f $PDB_FIXTURE_DIR/dropped ]]; ok
done
printf 'Passed %s optional-PDB fixture checks, including full fake-client main flows. No Oracle/SSH operations performed.\n' "$checks"
