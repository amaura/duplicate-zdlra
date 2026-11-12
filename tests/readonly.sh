#!/usr/bin/env bash
# Offline deployment fixtures. Never invoke installed Oracle clients or SSH.
set -Eeuo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../test_readonly.sh
source "$root/test_readonly.sh"
tmp=$(mktemp -d)
tmp=$(cd "$tmp" && pwd -P)
trap 'rm -rf "$tmp"' EXIT
cp "$root/tests/fixtures/topology-19c.sh" "$tmp/topology-fixture.sh"
cp "$root/tests/fixtures/tempfile-ids-padded.txt" "$tmp/tempfile-ids-padded.txt"
export DIAG_FIXTURE_ROOT=$tmp DIAG_FIXTURE_CASE=healthy DIAG_FIXTURE_CALLS="$tmp/calls"
# shellcheck disable=SC2016
export DIAG_FIXTURE_SECRET='offline*a[1]&/$secret\value'
mkdir -p "$tmp/bin" "$tmp/oracle/bin" "$tmp/oracle/lib" "$tmp/seps" "$tmp/aux" "$tmp/target/tde" "$tmp/target/tde_seps" "$tmp/target/provider/nested" "$tmp/stage"
touch "$tmp/oracle/lib/libra.so" "$tmp/seps/cwallet.sso"
printf 'wallet-fixture-secret\000\377\n' > "$tmp/target/tde/cwallet.sso"
cp "$tmp/target/tde/cwallet.sso" "$tmp/target/tde_seps/cwallet.sso"
cp "$tmp/target/tde/cwallet.sso" "$tmp/target/provider/nested/binary"
cksum "$tmp/seps/cwallet.sso" "$tmp/target/tde/cwallet.sso" "$tmp/target/tde_seps/cwallet.sso" "$tmp/target/provider/nested/binary" > "$tmp/before"
cp "$root/tests/fixtures/service-admin-19c.txt" "$tmp/service.txt"

# Test-only timeout implementation for hosts without GNU coreutils (e.g. macOS).
# Uses a real deadline and process group termination, with no third-party modules.
cat > "$tmp/bin/timeout" <<'EOF'
#!/usr/bin/env python3
import os
import signal
import subprocess
import sys

assert sys.argv[1] == '--kill-after=5s'
seconds = float(sys.argv[2].removesuffix('s'))
child = subprocess.Popen(sys.argv[3:], start_new_session=True)
try:
    sys.exit(child.wait(timeout=seconds))
except subprocess.TimeoutExpired:
    os.killpg(child.pid, signal.SIGTERM)
    try:
        child.wait(timeout=5)
    except subprocess.TimeoutExpired:
        os.killpg(child.pid, signal.SIGKILL)
        child.wait()
    sys.exit(124)
EOF
cat > "$tmp/bin/id" <<'EOF'
#!/usr/bin/env bash
if [[ ${1:-} == -un ]]; then printf 'oracle\n'; else /usr/bin/id "$@"; fi
EOF
cat > "$tmp/bin/ps" <<'EOF'
#!/usr/bin/env bash
[[ $* == '-eo args=' ]] || exit 89
printf 'ora_pmon_PRE1\n'
if [[ $DIAG_FIXTURE_CASE == aux-in-use ]]; then printf 'ora_pmon_RFRAUX\n'; fi
EOF
cat > "$tmp/bin/ssh" <<'EOF'
#!/usr/bin/env bash
set -eu
[[ $* == *StrictHostKeyChecking=yes* && $* == *UpdateHostKeys=no* && $* == *BatchMode=yes* ]] || exit 90
printf 'ssh %s\n' "$*" >> "$DIAG_FIXTURE_CALLS"
case $* in
    *oracle@node2.example*) export ORACLE_SID=PRE2 ;;
    *oracle@standby1.example*) export ORACLE_SID=ST1 ;;
    *oracle@standby2.example*) export ORACLE_SID=ST2 ;;
    *) exit 91 ;;
esac
if [[ $* == *dgmgrl* ]]; then exec "$DIAG_FIXTURE_ROOT/oracle/bin/dgmgrl" -silent /; fi
exec "$DIAG_FIXTURE_ROOT/oracle/bin/sqlplus" -L -s /nolog
EOF
cat > "$tmp/oracle/bin/sqlplus" <<'EOF'
#!/usr/bin/env bash
set -eu
printf 'sqlplus %s sid=%s\n' "$*" "${ORACLE_SID:-unset}" >> "$DIAG_FIXTURE_CALLS"
[[ $* != *"$DIAG_FIXTURE_SECRET"* ]] || exit 92
if [[ $* == -V ]]; then printf 'SQL*Plus: Release 19.0.0.0.0\n'; exit; fi
[[ $# == 3 && $1 == -L && $2 == -s && $3 == /nolog ]] || exit 93
query=$(cat)
if printf '%s\n' "$query" | grep -Eiq '^[[:space:]]*(alter|create|drop|startup|shutdown|execute|begin|declare|insert|update|delete|merge|@|host|!)'; then
    printf 'Attempted unsafe SQL in fixture\n' >&2; exit 94
fi
if [[ $query == *'max(root_block)'* && $DIAG_FIXTURE_CASE == failures ]]; then
    printf 'ORA-20000: catalog fixture %s\n' "$DIAG_FIXTURE_SECRET"; exit 0
fi
if [[ ${ORACLE_SID:-} == PRE2 && $DIAG_FIXTURE_CASE == failures ]]; then
    printf 'ORA-28365: fixture HSM failure\n'; exit 0
fi
if [[ $query == *'END|TOPOLOGY'* ]]; then
    source "$DIAG_FIXTURE_ROOT/topology-fixture.sh"
    physical=PREST
    case $DIAG_FIXTURE_CASE in no-standby|pdb-absent-none|pdb-absent-stopped|pdb-absent-disabled|pdb-absent-running) physical='' ;; esac
    broker=TRUE mode=healthy
    case $DIAG_FIXTURE_CASE in
        topology-standalone|pdb-absent-standalone) broker=FALSE; physical='' ;;
        topology-appliance) broker=FALSE; physical=''; mode=appliance ;;
        topology-unconfigured) physical='' ;;
        topology-unmanaged) broker=FALSE ;;
        topology-query-error) printf 'ORA-00942: topology inventory unavailable\n'; exit ;;
        topology-inconsistent) [[ $ORACLE_SID == PRE1 ]] || broker=FALSE ;;
    esac
    TOPOLOGY_FIXTURE_MODE=$mode topology_fixture "$ORACLE_SID" "$broker" "$physical"
elif [[ $query == *'v$dataguard_process'* ]]; then
    mode=MOUNTED
    [[ $DIAG_FIXTURE_CASE != standby-open || $ORACLE_SID != ST1 ]] || mode='READ ONLY'
    printf 'IDENTITY|PRE|PREST|42|PHYSICAL STANDBY|YES|%s\nCONTAINER|CDB$ROOT\nBROKER|TRUE\n' "$ORACLE_SID"
    printf 'RAC|ST1|standby1.example\nRAC|ST2|standby2.example\nAPPLY|1\n'
    if [[ $DIAG_FIXTURE_CASE != pdb-absent-* || $DIAG_FIXTURE_CASE == pdb-absent-conflict ]]; then
        printf 'PDB|0123456789ABCDEF0123456789ABCDEF|%s\n' "$mode"
    fi
elif [[ $query == *"select 'IDENTITY|'"* ]]; then
    printf 'IDENTITY|PRE|PREM1|42|PRIMARY|%s|19.0.0.0.0\nCONTAINER|CDB$ROOT\nWALLET|1|OPEN|HSM|UNITED\nPATCH|123|APPLY|SUCCESS|fixture\n' "$ORACLE_SID"
elif [[ $query == *"select name||'|'||db_unique_name"* ]]; then
    role=PRIMARY
    [[ $DIAG_FIXTURE_CASE != bad-identity ]] || role='PHYSICAL STANDBY'
    printf 'PRE|PREM1|42|%s|YES|READ WRITE\nCONTAINER|CDB$ROOT\n' "$role"
elif [[ $query == *"select instance_name||'|'||host_name||'|'||status"* ]]; then
    printf 'PRE1|node1.example|OPEN|19.0.0.0.0\nPRE2|node2.example|OPEN|19.0.0.0.0\n'
elif [[ $query == *"p.name||'|'||p.open_mode"* ]]; then
    printf 'PRE1|CDB$ROOT|READ WRITE\nPRE1|PDB$SEED|READ ONLY\nPRE1|OTHERPDB|READ WRITE\nPRE2|CDB$ROOT|READ WRITE\nPRE2|PDB$SEED|READ ONLY\nPRE2|OTHERPDB|READ WRITE\n'
elif [[ $query == *'from gv$pdbs'* ]]; then
    if [[ $DIAG_FIXTURE_CASE == pdb-query-error ]]; then printf 'ORA-00942: offline PDB inventory failure\n'; exit; fi
    [[ $DIAG_FIXTURE_CASE != pdb-absent-* ]] || exit 0
    if [[ $DIAG_FIXTURE_CASE == pdb-partial ]]; then printf 'PRE1|node1.example|READ WRITE|NO|0123456789ABCDEF0123456789ABCDEF\n'; exit; fi
    if [[ $DIAG_FIXTURE_CASE == pdb-guid ]]; then printf 'PRE1|node1.example|READ WRITE|NO|0123456789ABCDEF0123456789ABCDEF\nPRE2|node2.example|READ WRITE|NO|FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF\n'; exit; fi
    printf 'PRE1|node1.example|READ WRITE|NO|0123456789ABCDEF0123456789ABCDEF\nPRE2|node2.example|READ WRITE|NO|0123456789ABCDEF0123456789ABCDEF\n'
elif [[ $query == *'from dba_pdb_saved_states'* ]]; then
    [[ $DIAG_FIXTURE_CASE != pdb-absent-* ]] || exit 0
    printf 'PRE1|OPEN|NO\nPRE2|OPEN|NO\n'
elif [[ $query == *"select value from v\$parameter"* ]]; then
    data=+DATA recovery=+RECO
    case $DIAG_FIXTURE_CASE in
        asm-custom) data=+DBSTORE/target_alias; recovery=+ARCHSTORE/target_alias ;;
        asm-shared) data=+SHARED/target_alias; recovery=+shared/recovery_alias ;;
        asm-missing-recovery) recovery=UNSET ;;
        asm-filesystem-recovery) recovery=/filesystem/recovery ;;
    esac
    printf '%s\n19.0.0\nKEYSTORE_CONFIGURATION=HSM\n%s/target\n%s\n' "$data" "$DIAG_FIXTURE_ROOT" "$recovery"
elif [[ $query == *'from cdb_services'* ]]; then
    [[ $DIAG_FIXTURE_CASE != pdb-absent-* ]] || exit 0
    printf 'pre_app\n'
elif [[ $query == *'from gv$parameter'* ]]; then printf 'ENABLED\n'
elif [[ $query == *'from rc_database d'* ]]; then printf '1|77\n'
elif [[ $query == *'from rc_database_incarnation'* ]]; then printf '2|100|2024-01-01 00:00:00\n'
elif [[ $query == *'max(earliest)'* ]]; then printf '2024-10-01 00:00:00\n'
elif [[ $query == *'from rc_backup_datafile'* ]]; then printf '1024|8192\n'
elif [[ $query == *'from rc_backup_redolog'* ]]; then
    printf '1|10|20|2024-10-02 00:00:00\n2|10|19|2024-10-01 23:00:00\n'
elif [[ $query == *'from rc_backup_controlfile'* ]]; then printf '1\n'
elif [[ $query == *'select distinct file# from rc_tempfile'* ]]; then
    printf 'tempfile-ids\n' >> "$DIAG_FIXTURE_CALLS"
    if [[ $DIAG_FIXTURE_CASE == tempfiles-invalid ]]; then printf '  1\n  2\n  1 2\n'
    elif [[ $DIAG_FIXTURE_CASE == tempfiles-error ]]; then printf '  1\nORA-00942: fixture %s\n' "$DIAG_FIXTURE_SECRET"
    else cat "$DIAG_FIXTURE_ROOT/tempfile-ids-padded.txt"; fi
elif [[ $query == *'from rc_tempfile'* ]]; then
    printf 'tempfile-size\n' >> "$DIAG_FIXTURE_CALLS"
    case $DIAG_FIXTURE_CASE in
        temp-size-zero) printf ' \t0 \t\r\n' ;;
        temp-size-error) printf 'ORA-00942: fixture %s\n' "$DIAG_FIXTURE_SECRET" ;;
        temp-size-sp2) printf 'SP2-0734: offline size failure\n' ;;
        temp-size-tns) printf 'TNS-12541: offline size failure\n' ;;
        temp-size-exit) printf ' \t10 \t\r\n'; exit 7 ;;
        temp-size-timeout) printf ' \t10 \t\r\n'; sleep 10 ;;
        temp-size-malformed) printf ' 1 2 \r\n' ;;
        *) printf ' \t10 \t\r\n' ;;
    esac
elif [[ $query == *'from v$asm_diskgroup_stat'* ]]; then
    printf 'asm-space %s\n' "$query" >> "$DIAG_FIXTURE_CALLS"
    if [[ $DIAG_FIXTURE_CASE == asm-low-recovery && $query == *"upper('RECO')"* ]]; then printf '1\n'
    elif [[ $DIAG_FIXTURE_CASE == asm-low-data && $query == *"upper('DATA')"* ]]; then printf '2500\n'
    else printf '    999999\n'; fi
else printf 'Unhandled SQL fixture\n' >&2; exit 95
fi
EOF
cat > "$tmp/oracle/bin/srvctl" <<'EOF'
#!/usr/bin/env bash
set -eu
printf 'srvctl %s\n' "$*" >> "$DIAG_FIXTURE_CALLS"
case $* in
    'config database') printf 'PREM1\n' ;;
    'config database -db PREM1 -verbose') printf 'Database unique name: PREM1\nDatabase is administrator managed\n' ;;
    'status database -db PREM1 -verbose') printf 'Instance PRE1 is running on node node1\nInstance PRE2 is running on node node2\n' ;;
    'config service -db PREM1'|'config service -db PREM1 -service pre_app -verbose')
        if [[ $DIAG_FIXTURE_CASE == pdb-absent-standalone || $DIAG_FIXTURE_CASE == pdb-absent-none || $DIAG_FIXTURE_CASE == pdb-absent-managed || $DIAG_FIXTURE_CASE == pdb-absent-conflict ]]; then exit 0; fi
        if [[ $DIAG_FIXTURE_CASE == pdb-absent-disabled ]]; then sed 's/^Service is enabled$/Service is disabled/' "$DIAG_FIXTURE_ROOT/service.txt"
        else cat "$DIAG_FIXTURE_ROOT/service.txt"; fi ;;
    'status service -db PREM1 -service pre_app -force')
        if [[ $DIAG_FIXTURE_CASE == pdb-absent-stopped || $DIAG_FIXTURE_CASE == pdb-absent-disabled ]]; then printf 'Service pre_app is not running.\n'
        else printf 'Service pre_app is running on instance(s) PRE2\n'; fi ;;
    *) printf 'Unexpected/unsafe srvctl operation\n' >&2; exit 96 ;;
esac
EOF
cat > "$tmp/oracle/bin/dgmgrl" <<'EOF'
#!/usr/bin/env bash
set -eu
if [[ $# == 2 ]]; then
    input=$(cat)
    [[ $input == $'SHOW CONFIGURATION VERBOSE;\nEXIT;' ]] || exit 99
    set -- "$@" 'SHOW CONFIGURATION VERBOSE;'
fi
[[ $# == 3 && $1 == -silent && $2 == / && ( $ORACLE_SID == PRE1 || ( $ORACLE_SID == PRE2 && $DIAG_FIXTURE_CASE == topology-unconfigured ) ) ]] || exit 97
printf 'dgmgrl %s\n' "$3" >> "$DIAG_FIXTURE_CALLS"
if [[ $DIAG_FIXTURE_CASE == topology-unconfigured ]]; then
    printf 'Error: ORA-16532: Data Guard broker configuration does not exist\n\nConfiguration details cannot be determined by DGMGRL\n'; exit 0
fi
if [[ $DIAG_FIXTURE_CASE == failures ]]; then printf 'DGM-17016: fixture broker unavailable\n'; exit 0; fi
case $3 in
    'SHOW CONFIGURATION VERBOSE;')
        printf 'Configuration - pre_dg\n  Members:\n    PREM1 - Primary database\n'
        [[ $DIAG_FIXTURE_CASE == no-standby || $DIAG_FIXTURE_CASE == pdb-absent-standalone || $DIAG_FIXTURE_CASE == pdb-absent-none || $DIAG_FIXTURE_CASE == pdb-absent-stopped || $DIAG_FIXTURE_CASE == pdb-absent-disabled || $DIAG_FIXTURE_CASE == pdb-absent-running ]] || printf '      PREST - Physical standby database\n'
        printf '  Properties:\nConfiguration Status:\nSUCCESS\n' ;;
    "SHOW DATABASE 'PREST';")
        printf 'Database - PREST\n  Role: PHYSICAL STANDBY\n  Intended State: APPLY-ON\n  Instance(s):\n    ST1\n    ST2\nDatabase Status:\nSUCCESS\n' ;;
    "SHOW INSTANCE VERBOSE 'ST1' ON DATABASE 'PREST';") printf "HostName = 'standby1.example'\n" ;;
    "SHOW INSTANCE VERBOSE 'ST2' ON DATABASE 'PREST';") printf "HostName = 'standby2.example'\n" ;;
    *) printf 'Unexpected/unsafe broker operation\n' >&2; exit 98 ;;
esac
EOF
cat > "$tmp/oracle/bin/mkstore" <<'EOF'
#!/usr/bin/env bash
set -eu
printf 'mkstore %s\n' "$*" >> "$DIAG_FIXTURE_CALLS"
[[ $1 == -wrl && $2 == "$DIAG_FIXTURE_ROOT/seps" ]] || exit 99
case $3 in
    -listCredential)
        if [[ $DIAG_FIXTURE_CASE == timeout ]]; then sleep 10; fi
        printf '2: ra.example:1521/catalog VPC\n'
        [[ $DIAG_FIXTURE_CASE != ambiguous ]] || printf '7: other.example:1521/catalog VPC\n' ;;
    -viewEntry)
        [[ $4 == oracle.security.client.password2 ]] || exit 100
        printf 'oracle.security.client.password2 = %s\n' "$DIAG_FIXTURE_SECRET" ;;
    *) exit 101 ;;
esac
EOF
cat > "$tmp/oracle/bin/rman" <<'EOF'
#!/usr/bin/env bash
printf 'FORBIDDEN RMAN INVOCATION\n' >> "$DIAG_FIXTURE_CALLS"
exit 102
EOF
chmod +x "$tmp/bin/"* "$tmp/oracle/bin/"*
export PATH="$tmp/bin:$PATH"

# Only the fixed deployment environment/wallet locations are redirected to
# fixtures. Exercise the real client wrappers, validators and report writer.
load_environment() {
    ORACLE_HOME="$DIAG_FIXTURE_ROOT/oracle" ORACLE_SID=PRE1 DB_UNIQUE_NAME=PREM1
    export ORACLE_HOME ORACLE_SID DB_UNIQUE_NAME
}
eval "$(declare -f diag_credentials | sed '1s/diag_credentials/fixture_credentials/')"
diag_credentials() { fixture_credentials "$DIAG_FIXTURE_ROOT/seps"; }
base=(--source-cdb PROD --target-cdb PRE --source-pdb APP --target-pdb APPTEST
    --aux-cdb RFRAUX --aux-base "$tmp/stage" --redo-reserve-mb 1)
checks=0
ok() { ((checks+=1)); }
run_fixture() {
    DIAG_FIXTURE_CASE=$1
    local expected=$2; shift 2
    : > "$DIAG_FIXTURE_CALLS"
    set +e
    (diag_main "${base[@]}" --output "$tmp/$DIAG_FIXTURE_CASE.txt" "$@") > "$tmp/console" 2>&1
    local rc=$?
    set -e
    if ((rc != expected)); then cat "$tmp/console"; cat "$tmp/$DIAG_FIXTURE_CASE.txt"; exit 1; fi
    grep -q 'SUMMARY:' "$tmp/$DIAG_FIXTURE_CASE.txt"
    [[ $(python3 -c 'import os,stat,sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode)))' "$tmp/$DIAG_FIXTURE_CASE.txt") == 0o600 ]]
    if grep -Fq "$DIAG_FIXTURE_SECRET" "$tmp/$DIAG_FIXTURE_CASE.txt" "$tmp/console" "$DIAG_FIXTURE_CALLS"; then exit 1; fi
    if grep -Fq 'wallet-fixture-secret' "$tmp/$DIAG_FIXTURE_CASE.txt" "$tmp/console"; then exit 1; fi
    [[ -z $(find "$tmp/stage" "$tmp/aux" -mindepth 1 -print -quit) ]]
    if grep -Eq 'FORBIDDEN|^dgmgrl (EDIT|ENABLE|DISABLE)|^srvctl (stop|start|modify|add|remove)' "$DIAG_FIXTURE_CALLS"; then exit 1; fi
    ok
}

# Report evidence retains SQL bytes (including CRLF), while downstream
# arithmetic and ID consumers use separately labelled normalized artifacts.
check_tempfile_evidence() {
    python3 - "$1" "$tmp/tempfile-ids-padded.txt" "${2:-10}" <<'PY'
import pathlib, sys
report = pathlib.Path(sys.argv[1]).read_bytes()
def artifact(name):
    marker = b'\n--- ' + name.encode() + b' ---\n'
    assert report.count(marker) == 1, name
    start = report.index(marker) + len(marker)
    return report[start:report.index(b'\n--- ', start)]
assert artifact('tempfiles.raw.txt') == pathlib.Path(sys.argv[2]).read_bytes()
assert artifact('tempfiles.normalized.txt') == b'1\n2\n4\n5\n6\n7\n'
size = sys.argv[3].encode()
assert artifact('temp-size.raw.txt') == b' \t' + size + b' \t\r\n'
assert artifact('temp-size.normalized.txt') == size + b'\n'
PY
    [[ $(grep -c '^tempfile-ids$' "$DIAG_FIXTURE_CALLS") == 1 && $(grep -c '^tempfile-size$' "$DIAG_FIXTURE_CALLS") == 1 ]]
    [[ $(grep -c '^asm-space ' "$DIAG_FIXTURE_CALLS") == 2 ]]
    grep -Fq "upper('DATA')" "$DIAG_FIXTURE_CALLS"
    grep -Fq "upper('RECO')" "$DIAG_FIXTURE_CALLS"
    ok
}

run_fixture healthy 0
grep -q '\[PASS\] standby-PREST-ST2' "$tmp/healthy.txt"
grep -q '\[PASS\] target-space' "$tmp/healthy.txt"
grep -q 'FAIL=0 SKIP=0' "$tmp/healthy.txt"
grep -q 'NOT RUN.*SBT allocation/media reads' "$tmp/healthy.txt"; ok
grep -q '\[PASS\] tempfiles' "$tmp/healthy.txt"
grep -Fq 'Space +DATA: 999999 MiB usable; estimated requirement 2585 MiB.' "$tmp/healthy.txt"
check_tempfile_evidence "$tmp/healthy.txt"
grep -q '\[PASS\] auxiliary' "$tmp/healthy.txt"
grep -q 'Auxiliary wallet copy: ready;' "$tmp/healthy.txt"
grep -q 'removed|auxiliary=not-started' "$tmp/healthy.txt"; ok
run_fixture wallet-parent 0 --aux-wallet-root "$tmp/aux"
grep -Fq "fresh private copy parent=$tmp/aux" "$tmp/wallet-parent.txt"; ok
mv "$tmp/target/tde/cwallet.sso" "$tmp/target/tde/temporarily-hidden"
run_fixture wallet-missing 1
grep -q '\[FAIL\] auxiliary' "$tmp/wallet-missing.txt"
grep -q '\[PASS\] catalog' "$tmp/wallet-missing.txt"
mv "$tmp/target/tde/temporarily-hidden" "$tmp/target/tde/cwallet.sso"; ok
ln -s "$tmp/target/tde/cwallet.sso" "$tmp/target/provider/link"
run_fixture wallet-symlink 1
grep -q 'Wallet tree contains a symlink' "$tmp/wallet-symlink.txt"
rm "$tmp/target/provider/link"; ok
run_fixture aux-in-use 1
grep -q '\[FAIL\] auxiliary' "$tmp/aux-in-use.txt"
grep -q '\[PASS\] target-space' "$tmp/aux-in-use.txt"; ok
run_fixture healthy-time 0 --time '2024-10-01 12:00:00'
grep -Fq "resetlogs_time <= to_date('2024-10-01 12:00:00'" "$tmp/healthy-time.txt"; ok
check_tempfile_evidence "$tmp/healthy-time.txt"
run_fixture temp-size-zero 0
grep -q '\[PASS\] tempfiles' "$tmp/temp-size-zero.txt"
grep -q '\[PASS\] target-space' "$tmp/temp-size-zero.txt"
grep -Fq 'Space +DATA: 999999 MiB usable; estimated requirement 2561 MiB.' "$tmp/temp-size-zero.txt"
check_tempfile_evidence "$tmp/temp-size-zero.txt" 0
run_fixture temp-size-error 1
grep -q '\[FAIL\] tempfiles' "$tmp/temp-size-error.txt"
grep -q '\[SKIP\] capacity' "$tmp/temp-size-error.txt"
grep -Fq -- '--- temp-size.raw.txt ---' "$tmp/temp-size-error.txt"
grep -Fq 'ORA-00942: fixture [REDACTED]' "$tmp/temp-size-error.txt"
if grep -Eq 'temp-size.normalized.txt|^asm-space ' "$tmp/temp-size-error.txt" "$DIAG_FIXTURE_CALLS"; then exit 1; fi
ok
run_fixture tempfiles-invalid 1
grep -q '\[FAIL\] tempfiles' "$tmp/tempfiles-invalid.txt"
grep -q '\[SKIP\] capacity' "$tmp/tempfiles-invalid.txt"
grep -Fq -- '--- tempfiles.raw.txt ---' "$tmp/tempfiles-invalid.txt"
if grep -Eq 'tempfiles.normalized.txt|^tempfile-size$|^asm-space ' "$tmp/tempfiles-invalid.txt" "$DIAG_FIXTURE_CALLS"; then exit 1; fi
ok
run_fixture asm-low-data 1
grep -q '\[PASS\] tempfiles' "$tmp/asm-low-data.txt"
grep -q '\[FAIL\] target-space' "$tmp/asm-low-data.txt"
grep -q 'Insufficient/unknown usable space' "$tmp/asm-low-data.txt"; ok
run_fixture failures 1
grep -q '\[FAIL\] primary-PRE2' "$tmp/failures.txt"
grep -q '\[FAIL\] broker' "$tmp/failures.txt"
grep -q '\[FAIL\] backups' "$tmp/failures.txt"
grep -q '\[PASS\] tempfiles' "$tmp/failures.txt"
grep -q '\[PASS\] range' "$tmp/failures.txt"
grep -q '\[SKIP\] capacity' "$tmp/failures.txt"
grep -Fq 'ORA-20000: catalog fixture [REDACTED]' "$tmp/failures.txt"; ok
run_fixture standby-open 1
grep -q '\[FAIL\] standby-PREST-ST1' "$tmp/standby-open.txt"
grep -q '\[PASS\] standby-PREST-ST2' "$tmp/standby-open.txt"
grep -q '\[PASS\] catalog' "$tmp/standby-open.txt"; ok
run_fixture no-standby 0
grep -q 'No physical standby configured' "$tmp/no-standby.txt"
if grep -q 'oracle@standby' "$DIAG_FIXTURE_CALLS"; then exit 1; fi; ok
for scenario in topology-standalone topology-appliance topology-unconfigured pdb-absent-standalone; do
    if [[ $scenario != topology-unconfigured ]]; then mv "$tmp/oracle/bin/dgmgrl" "$tmp/dgmgrl-unused"; fi
    run_fixture "$scenario" 0
    if [[ $scenario != topology-unconfigured ]]; then mv "$tmp/dgmgrl-unused" "$tmp/oracle/bin/dgmgrl"; fi
    grep -q '\[PASS\] broker' "$tmp/$scenario.txt"
    grep -q 'Standby SSH, old-PDB closure and apply checks: NOT APPLICABLE' "$tmp/$scenario.txt"
    grep -q '\[PASS\] target-space' "$tmp/$scenario.txt"
    if [[ $scenario == pdb-absent-standalone ]]; then
        # Combined handoff remains read-only while planning/copying/cleaning
        # the wallet and proceeding from padded IDs/sizes to ASM checks.
        grep -q '\[PASS\] pdb' "$tmp/$scenario.txt"
        grep -q 'target PDB absent; initial creation path' "$tmp/$scenario.txt"
        grep -Fq 'NONE|STANDALONE_DISABLED' "$tmp/$scenario.txt"
        grep -q '\[PASS\] auxiliary' "$tmp/$scenario.txt"
        grep -Fq "fresh private copy parent=$tmp/stage" "$tmp/$scenario.txt"
        grep -q 'Auxiliary wallet copy: ready;' "$tmp/$scenario.txt"
        grep -q 'removed|auxiliary=not-started' "$tmp/$scenario.txt"
        grep -q '\[PASS\] tempfiles' "$tmp/$scenario.txt"
        if grep -q '^dgmgrl ' "$DIAG_FIXTURE_CALLS"; then exit 1; fi
        check_tempfile_evidence "$tmp/$scenario.txt"
    fi
    if grep -q 'oracle@standby' "$DIAG_FIXTURE_CALLS"; then exit 1; fi
    ok
done
for scenario in topology-unmanaged topology-query-error topology-inconsistent; do
    run_fixture "$scenario" 1
    grep -q '\[FAIL\] broker' "$tmp/$scenario.txt"
    grep -q 'UNKNOWN' "$tmp/$scenario.txt"
    ok
done
for scenario in pdb-absent-none pdb-absent-stopped pdb-absent-disabled pdb-absent-managed; do
    run_fixture "$scenario" 0
    grep -q '\[PASS\] pdb' "$tmp/$scenario.txt"
    grep -q 'target PDB absent; initial creation path' "$tmp/$scenario.txt"
    grep -Fq 'PRE2|OTHERPDB|READ WRITE' "$tmp/$scenario.txt"
    grep -q '\[PASS\] services' "$tmp/$scenario.txt"
    grep -q '\[PASS\] primary-PRE2' "$tmp/$scenario.txt"
    grep -q '\[PASS\] target-space' "$tmp/$scenario.txt"
    if [[ $scenario == pdb-absent-managed ]]; then
        grep -q '\[PASS\] standby-PREST-ST2' "$tmp/$scenario.txt"
        grep -q 'Requested PDB absent on this verified standby' "$tmp/$scenario.txt"
    else
        if grep -q 'oracle@standby' "$DIAG_FIXTURE_CALLS"; then exit 1; fi
    fi
    ok
done
run_fixture pdb-absent-running 1
grep -q '\[FAIL\] services' "$tmp/pdb-absent-running.txt"
grep -q 'running with no corresponding target PDB' "$tmp/pdb-absent-running.txt"; ok
run_fixture pdb-absent-conflict 1
grep -q '\[FAIL\] standby-PREST-ST1' "$tmp/pdb-absent-conflict.txt"
grep -q '\[FAIL\] standby-PREST-ST2' "$tmp/pdb-absent-conflict.txt"; ok
for scenario in pdb-partial pdb-guid pdb-query-error; do
    run_fixture "$scenario" 1
    grep -q '\[FAIL\] pdb' "$tmp/$scenario.txt"
    grep -q '\[SKIP\] services' "$tmp/$scenario.txt"
    grep -q '\[PASS\] catalog' "$tmp/$scenario.txt"; ok
done
run_fixture bad-identity 1
grep -q '\[SKIP\] target-and-catalog' "$tmp/bad-identity.txt"
if grep -Eq '^(dgmgrl|mkstore|ssh) ' "$DIAG_FIXTURE_CALLS"; then exit 1; fi; ok
run_fixture ambiguous 1
grep -q 'empty/ambiguous' "$tmp/ambiguous.txt"
if grep -q -- '-viewEntry' "$DIAG_FIXTURE_CALLS"; then exit 1; fi; ok
run_fixture timeout 1 --timeout 1
grep -q 'Timed out or failed to list SEPS credentials' "$tmp/timeout.txt"; ok

# Refuse an existing report without modifying it.
cksum "$tmp/healthy.txt" > "$tmp/report-before"
set +e
(diag_main "${base[@]}" --output "$tmp/healthy.txt") > "$tmp/rejected" 2>&1
rc=$?
set -e
[[ $rc == 2 ]]
cksum "$tmp/healthy.txt" > "$tmp/report-after"
cmp "$tmp/report-before" "$tmp/report-after"; ok

# Guard rejection must happen before ANY external client runs.
reject() {
    set +e
    ("$@") > "$tmp/rejected" 2>&1
    local rc=$?
    set -e
    ((rc != 0)); ok
}
ORACLE_HOME="$tmp/oracle" TARGET_SID=PRE1 DUP_AUX_CDB=RFRAUX RUN=$tmp LOG="$tmp/guard.log"
: > "$DIAG_FIXTURE_CALLS"
reject sql PRE1 "$tmp/unsafe" <<< 'alter database open;'
reject sql PRE1 "$tmp/unsafe" <<< $'select 1 from dual;\n@unsafe.sql'
reject sql PRE1 "$tmp/unsafe" <<< $'select 1\nhost touch unsafe\nfrom dual;'
reject broker "$tmp/unsafe" "EDIT DATABASE 'PREST' SET STATE='APPLY-OFF';"
reject srv "$tmp/unsafe" stop service -db PREM1
reject rman RFRAUX duplicate /dev/null "$tmp/unsafe"
reject diag_parse_args "${base[@]}" --do-duplicate
reject diag_parse_args "${base[@]}" --timeout 0
reject diag_parse_args "${base[@]}" --timeout 3601
reject diag_parse_args "${base[@]}" --output
[[ ! -s $DIAG_FIXTURE_CALLS ]]; ok
cksum "$tmp/seps/cwallet.sso" "$tmp/target/tde/cwallet.sso" "$tmp/target/tde_seps/cwallet.sso" "$tmp/target/provider/nested/binary" > "$tmp/after"
cmp "$tmp/before" "$tmp/after"; ok
# Focused storage checks use the real read-only SQL wrapper and fake clients.
DIAG_TIMEOUT_BIN=$(command -v timeout) DIAG_TIMEOUT=5 PHASE=asm
# Focused tempfile probes cover failed/erroring/timed-out SQL clients without
# repeating the full collector for every malformed result. Valid IDs cannot
# make a failed size query produce a normalized capacity input.
SOURCE_DBKEY=1 SOURCE_INC=2 point="to_date('2024-10-02','YYYY-MM-DD')"
VPC_USER=VPC VPC_PASSWORD=$DIAG_FIXTURE_SECRET RA_ALIAS=ra.example:1521/catalog
probe_tempfiles() { RUN=$probe_dir LOG=$probe_dir/client.log DIAG_TIMEOUT=1 diag_tempfiles; }
for DIAG_FIXTURE_CASE in tempfiles-error temp-size-sp2 temp-size-tns temp-size-exit temp-size-timeout temp-size-malformed; do
    probe_dir=$tmp/$DIAG_FIXTURE_CASE
    mkdir "$probe_dir"
    : > "$DIAG_FIXTURE_CALLS"
    reject probe_tempfiles
    [[ -s $probe_dir/tempfiles.raw.txt && ! -e $probe_dir/temp-size.normalized.txt ]]
    if [[ $DIAG_FIXTURE_CASE == tempfiles-error ]]; then
        [[ ! -e $probe_dir/tempfiles.normalized.txt && ! -e $probe_dir/temp-size.raw.txt ]]
        grep -Fq 'ORA-00942: fixture [REDACTED]' "$probe_dir/tempfiles.raw.txt"
    else
        cmp "$tmp/tempfile-ids-padded.txt" "$probe_dir/tempfiles.raw.txt"
        [[ -s $probe_dir/tempfiles.normalized.txt && -s $probe_dir/temp-size.raw.txt ]]
    fi
    if [[ $DIAG_FIXTURE_CASE == temp-size-malformed ]]; then grep -q 'Unknown tempfile size' "$tmp/rejected"
    else grep -q 'SQL\*Plus failed' "$tmp/rejected"; fi
    if [[ $DIAG_FIXTURE_CASE == temp-size-timeout ]]; then grep -q 'exit 124;' "$tmp/rejected"; fi
    if grep -Fq "$DIAG_FIXTURE_SECRET" "$probe_dir/"* "$tmp/rejected" "$DIAG_FIXTURE_CALLS"; then exit 1; fi
    ok
done
DUP_AUX_WALLET_ROOT="$tmp/aux" DUP_REDO_RESERVE_MB=100
for DIAG_FIXTURE_CASE in asm-custom asm-shared; do
    : > "$DIAG_FIXTURE_CALLS"
    diag_settings > "$tmp/settings-report"
    diag_refresh_space "$RUN/settings.txt" 1000 > "$tmp/space-report"
    if [[ $DIAG_FIXTURE_CASE == asm-custom ]]; then
        grep -Fq 'data=+DBSTORE recovery=+ARCHSTORE' "$tmp/settings-report"
        grep -Fq 'Space +DBSTORE: 999999 MiB usable; estimated requirement 2100 MiB.' "$tmp/space-report"
        grep -Fq 'Space +ARCHSTORE: 999999 MiB usable; estimated requirement 100 MiB.' "$tmp/space-report"
        [[ $(grep -c '^asm-space ' "$DIAG_FIXTURE_CALLS") == 2 ]]
    else
        grep -Fq 'data=+SHARED recovery=+SHARED' "$tmp/settings-report"
        [[ $(grep -c '^asm-space ' "$DIAG_FIXTURE_CALLS") == 1 ]]
    fi
    ok
done
for DIAG_FIXTURE_CASE in asm-missing-recovery asm-filesystem-recovery; do
    reject diag_settings
    grep -q 'Missing or unsupported ASM destination' "$tmp/rejected"
done
for DIAG_FIXTURE_CASE in asm-low-data asm-low-recovery; do
    diag_settings > "$tmp/settings-report"
    # 2500 MiB fits either individual copy, but cannot fit both plus reserve.
    reject diag_refresh_space "$RUN/settings.txt" 1250
    grep -q 'Insufficient/unknown usable space' "$tmp/rejected"
done
printf 'incomplete\n' > "$tmp/incomplete-settings"
reject diag_refresh_space "$tmp/incomplete-settings" 1000
printf 'Passed %s offline read-only collector checks. No Oracle or SSH connections performed.\n' "$checks"
