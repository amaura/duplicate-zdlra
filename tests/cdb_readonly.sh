#!/usr/bin/env bash
# Exercise real collector guards and CDB routing with offline-only clients.
set -Eeuo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../test_readonly.sh
source "$root/test_readonly.sh"
tmp=$(mktemp -d /tmp/zdlra-cdb-diag.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
reject() { if ("$@") > "$tmp/rejected" 2>&1; then printf 'Expected guard failure\n' >&2; exit 1; fi; }
base=(--mode cdb --source-cdb PROD --target-cdb PRE --source-pdb APP --target-pdb APPTEST --work-dir /stage --source-wallet-dir /source)
diag_parse_args "${base[@]}"
[[ $MODE == cdb && $DRY_RUN == 1 ]]
for action in delete wallet-backup wallet-install wallet-verify pfile stopped; do
    reject cdb_file "$action" "$tmp/forbidden"
    grep -q 'Read-only guard' "$tmp/rejected"
done
reject diag_parse_args "${base[@]}" --do-duplicate
reject sql PRE1 "$tmp/forbidden-sql" <<< 'shutdown immediate;'
reject srv "$tmp/forbidden-srv" disable database -db PREM1
reject rman PRE1 duplicate /forbidden /forbidden
# PDB deployments need the report renderer, but do not acquire the CDB helpers.
mkdir -p "$tmp/standalone/lib"
cp "$root/dup_db.sh" "$root/test_readonly.sh" "$tmp/standalone/"
cp "$root/lib/readonly_report.py" "$tmp/standalone/lib/"
bash -c 'source "$1"; shift; parse_args "$@"; [[ $MODE == pdb ]]' -- "$tmp/standalone/dup_db.sh" --source-cdb PROD --target-cdb PRE --source-pdb APP --target-pdb APPTEST --aux-cdb AUX --aux-base /stage
bash "$tmp/standalone/test_readonly.sh" --help > "$tmp/standalone-help"
reject bash "$tmp/standalone/dup_db.sh" "${base[@]}"
grep -q 'CDB mode requires lib/cdb_copy.sh' "$tmp/rejected"
# Guarding cdb_main must not let an incomplete CDB collector package connect.
cp "$root/lib/readonly_cdb.sh" "$tmp/standalone/lib/"
reject bash "$tmp/standalone/test_readonly.sh" "${base[@]}" --output "$tmp/incomplete.txt"
grep -q 'CDB diagnostics require' "$tmp/rejected"
[[ ! -e $tmp/incomplete.txt ]]
# Route through diag_main without any host/Oracle/network dependency. The real
# SELECT/config guards and report assembly still run with fake bounded clients.
diag_os() { printf 'offline host fixture\n'; }
diag_load_environment() { ORACLE_HOME=$tmp/oracle TARGET_SID=PRE1 DB_UNIQUE_NAME=PREM1 SOURCE_UNIQUE=PRODM1; }
diag_clients() { printf 'offline clients\n'; }
mkdir -p "$tmp/oracle/bin" "$tmp/bin"
cat > "$tmp/bin/timeout" <<'CLIENT'
#!/usr/bin/env bash
shift 2
exec "$@"
CLIENT
chmod +x "$tmp/bin/timeout"
export PATH="$tmp/bin:$PATH"
cat > "$tmp/oracle/bin/sqlplus" <<'CLIENT'
#!/usr/bin/env bash
cat >/dev/null
printf '1\n'
CLIENT
cat > "$tmp/oracle/bin/srvctl" <<'CLIENT'
#!/usr/bin/env bash
[[ $* == 'config database -db PREM1' ]] || exit 99
printf 'Database unique name: PREM1\n'
CLIENT
chmod +x "$tmp/oracle/bin/"*
cdb_main() { die 'Deployment CDB workflow invoked by collector'; }
# shellcheck disable=SC2031
diag_cdb_fixture() {
    [[ $MODE == cdb && $DRY_RUN == 1 ]]
    printf 'Full CDB fixture: no source database or standby connection\n'
    sql "$TARGET_SID" "$RUN/select.out" <<< 'select 1 from dual;'
    srv "$RUN/config.out" config database -db "$DB_UNIQUE_NAME"
    cdb_warn
}
diag_cdb() { diag_check cdb 'CDB routing fixture' diag_cdb_fixture; }
diag_target() { die 'PDB diagnostic branch invoked'; }
discover_standbys() { die 'Standby discovery invoked'; }
(diag_main "${base[@]}" --output "$tmp/report.txt" --timeout 5) > "$tmp/console" 2>&1 || { cat "$tmp/console" "$tmp/report.txt"; exit 1; }
[[ $(awk '/SUMMARY:/ {print $0}' "$tmp/report.txt") == *'FAIL=0'* ]]
grep -q '\[PASS\] cdb' "$tmp/report.txt"
grep -q 'CDB NOT RUN' "$tmp/report.txt"
grep -q 'all existing target physical standbys require recreation' "$tmp/report.txt"
if grep -Eq '\[PASS\] (pdb|broker|standby)' "$tmp/report.txt"; then exit 1; fi
if grep -Eq 'PROD|PREM1|PRE1|APPTEST|/stage|/source' "$tmp/report.txt"; then exit 1; fi
# Interrupted CDB collection must package shared evidence, mask it and remove
# raw files even before the orchestrator's normal final packaging step.
mkdir "$tmp/scratch"
diag_cdb() {
    DIAG_CDB_RUN=$DIAG_WORK/cdb-evidence DIAG_CDB_PACKAGED=0
    mkdir "$DIAG_CDB_RUN"
    printf 'IDENTITY|PRE|PREM1|42|PRIMARY|PRE1\nCORRUPTION|0\n' > "$DIAG_CDB_RUN/health.out"
    kill -TERM "$BASHPID"
}
set +e
(TMPDIR="$tmp/scratch"; diag_main "${base[@]}" --output "$tmp/interrupted.txt" --timeout 5) > "$tmp/console" 2>&1
rc=$?
set -e
[[ $rc == 143 ]]
grep -q 'ABORTED (exit 143)' "$tmp/interrupted.txt"
grep -Fq 'CORRUPTION|0' "$tmp/interrupted.txt"
if grep -Eq 'PROD|PREM1|PRE1|APPTEST|/stage|/source' "$tmp/interrupted.txt"; then exit 1; fi
[[ -z $(find "$tmp/scratch" -mindepth 1 -print -quit) ]]
printf 'Passed offline CDB collector routing, guards, report and standby-policy checks. No Oracle or SSH connections performed.\n'
