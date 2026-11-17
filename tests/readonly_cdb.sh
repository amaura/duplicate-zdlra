#!/usr/bin/env bash
# Collector-only orchestration and query checks. All deployment probes are fixtures.
# shellcheck disable=SC2016,SC2031,SC2034,SC2329
set -Eeuo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../test_readonly.sh
source "$root/test_readonly.sh"
# shellcheck source=lib/readonly_cdb.sh
source "$root/lib/readonly_cdb.sh"
tmp=$(mktemp -d /tmp/zdlra-readonly-cdb.XXXXXX)
trap 'rc=$?; if ((rc)); then cat "${DIAG_OUTPUT:-/dev/null}" "${calls:-/dev/null}" >&2; fi; rm -rf "$tmp"' EXIT
fixture_mark() {
    printf '%s\n' "$PHASE" >> "$calls"
    [[ $PHASE != "$fail_phase" ]] || die 'offline fixture failure'
}
diag_cdb_identity() { fixture_mark; TARGET_DBID=42; diag_cdb_save TARGET_DBID; }
diag_cdb_rac() {
    fixture_mark
    printf 'PRE1|node1|OPEN|19.0.0.0.0\nPRE2|node2|OPEN|19.0.0.0.0\n' > "$TARGET_RAC_FILE"
}
diag_cdb_settings() { fixture_mark; TARGET_WALLET=/wallet; diag_cdb_save TARGET_WALLET; }
diag_cdb_health() { [[ $TARGET_DBID == 42 ]]; fixture_mark; }
diag_cdb_node_clients() { fixture_mark; }
diag_cdb_node_asm() { fixture_mark; }
diag_cdb_config() { fixture_mark; CDB_PARAM=/original; diag_cdb_save CDB_PARAM; }
diag_cdb_services() { fixture_mark; }
diag_cdb_work() { fixture_mark; CDB_WORK=/private; diag_cdb_save CDB_WORK; }
diag_cdb_stage_wallet() { [[ $CDB_WORK == /private && $TARGET_WALLET == /wallet ]]; fixture_mark; }
diag_cdb_node_config() { [[ $CDB_PARAM == /original && -s $DIAG_CDB_RUN/target-node.$1 ]]; fixture_mark; }
diag_cdb_node_retained() { fixture_mark; }
diag_cdb_files() { fixture_mark; }
diag_cdb_catalog_identity() { fixture_mark; SOURCE_DBID=999; diag_cdb_save SOURCE_DBID; }
diag_cdb_catalog_files() { [[ $SOURCE_DBID == 999 ]]; fixture_mark; printf 'one-copy-only\n' > "$DIAG_CDB_RUN/manifest"; }
diag_cdb_catalog_pdbs() { fixture_mark; }
diag_cdb_online_redo() { fixture_mark; }
diag_cdb_catalog_redo() { fixture_mark; }
diag_cdb_catalog_range() { fixture_mark; }
diag_cdb_catalog_temp() { fixture_mark; }
diag_cdb_compatibility() { fixture_mark; }
diag_cdb_capacity() { fixture_mark; }
diag_cdb_plan() { fixture_mark; }
cdb_main() { die 'deployment workflow must never be called'; }
run_fixture() {
    fail_phase=$1
    local dir=$tmp/${fail_phase:-success}
    mkdir "$dir"
    DIAG_WORK=$dir DIAG_OUTPUT=$dir/report DIAG_TOTAL=0 DIAG_PASSED=0 DIAG_FAILED=0 DIAG_SKIPPED=0
    calls=$dir/calls LOG='' RECOVERY_TIME=''
    : > "$calls"
    : > "$DIAG_OUTPUT"
    diag_cdb > "$dir/console"
    [[ ! -e $DIAG_CDB_STATE && $DIAG_CDB_PACKAGED == 1 ]]
    if [[ -z $fail_phase ]]; then [[ $DIAG_FAILED == 0 && $DIAG_SKIPPED == 0 ]]; else [[ $DIAG_FAILED == 1 ]]; fi
}
called() { grep -Fxq "$1" "$calls"; }
skipped() { grep -Fq "[SKIP] $1:" "$DIAG_OUTPUT"; }
run_fixture ''
[[ $(grep -c '^one-copy-only$' "$DIAG_OUTPUT") == 1 ]]
called cdb-plan
called cdb-capacity
grep -q 'standbys require recreation' "$DIAG_OUTPUT"
for fail_phase in cdb-health-1 cdb-clients-1 cdb-asm-1 cdb-source-wallet; do
    run_fixture "$fail_phase"
    called cdb-health-2
    called cdb-node-config-2
    called cdb-tempfiles
    called cdb-capacity
done
run_fixture cdb-settings
called cdb-clients-1
called cdb-clients-2
called cdb-catalog
skipped cdb-asm-1
skipped cdb-asm-2
run_fixture cdb-node-config-1
called cdb-node-config-2
called cdb-retained-2
called cdb-catalog
called cdb-redo
called cdb-tempfiles
skipped cdb-files
skipped cdb-compatibility
skipped cdb-capacity
run_fixture cdb-online-redo
called cdb-redo
called cdb-range
called cdb-tempfiles
skipped cdb-capacity
run_fixture cdb-source-files
called cdb-pdb-candidates
called cdb-redo
called cdb-range
called cdb-tempfiles
skipped cdb-compatibility
skipped cdb-capacity
skipped cdb-plan
run_fixture cdb-catalog
skipped cdb-source-metadata
if called cdb-source-files || called cdb-redo || called cdb-tempfiles; then exit 1; fi
run_fixture cdb-rac
called cdb-catalog
called cdb-tempfiles
skipped cdb-nodes-and-config
if called cdb-health-1 || called cdb-services; then exit 1; fi
run_fixture cdb-identity
(( $(wc -l < "$calls") == 1 ))
skipped cdb-dependent
# Reload the real new probe and validate fixed, name-minimizing SQL plus guards.
# shellcheck source=lib/readonly_cdb.sh
source "$root/lib/readonly_cdb.sh"
DIAG_CDB_RUN=$tmp/health
mkdir "$DIAG_CDB_RUN"
TARGET_CDB=PRE DB_UNIQUE_NAME=PREM1 TARGET_DBID=42
health_case=good
sql() {
    local inst=$1 out=$2 host=$3 query
    query=$(cat)
    [[ $inst == PRE1 && $host == node1 ]]
    printf '%s\n' "$query" > "$tmp/health-query"
    printf 'IDENTITY|PRE|PREM1|42|PRIMARY|YES|READ WRITE|PRE1|OPEN|19.27.0.0.0\nCONTAINER|CDB$ROOT\nCORRUPTION|0\n' > "$out"
    if [[ $health_case != no-wallet ]]; then printf 'WALLET|1|OPEN|HSM|NONE|AUTOLOGIN\n' >> "$out"; fi
    if [[ $health_case != no-charset ]]; then printf 'CHARSET|NLS_CHARACTERSET|AL32UTF8\nCHARSET|NLS_NCHAR_CHARACTERSET|AL16UTF16\n' >> "$out"; fi
    if [[ $health_case != no-timezone ]]; then printf 'TIMEZONE|42\n' >> "$out"; fi
    if [[ $health_case != no-components ]]; then printf 'COMPONENT|CATPROC|19.0.0.0.0|VALID\n' >> "$out"; fi
    if [[ $health_case == corrupt ]]; then sed 's/CORRUPTION|0/CORRUPTION|1/' "$out" > "$out.edit"; mv "$out.edit" "$out"; fi
}
diag_cdb_health PRE1 node1 1 > "$tmp/health-console"
if grep -Eqi 'wrl_parameter|select.*(table_name|owner|username|job_name)' "$tmp/health-query"; then exit 1; fi
for health_case in no-wallet no-charset no-timezone no-components corrupt; do
    if (diag_cdb_health PRE1 node1 1) > "$tmp/health-console" 2>&1; then printf 'Expected failed health check: %s\n' "$health_case" >&2; exit 1; fi
done
# PDB labels are collected as aggregate candidates, without returning names;
# missing/colliding labels remain advisory because historical renames can lag.
diag_credentials() { :; }
SOURCE_PDB=APP TARGET_PDB=APPTEST SOURCE_DBKEY=9 SOURCE_INC=7 SOURCE_UNIQUE=PRODM1
point="to_date('2024-10-01','YYYY-MM-DD')"
pdb_counts='1|0|0'
sql() { cat > "$tmp/pdb-query"; printf '%s\n' "$pdb_counts" > "$2"; }
diag_cdb_catalog_pdbs > "$tmp/pdb-console"
grep -q 'count(distinct case' "$tmp/pdb-query"
if grep -qi 'select.*pdb_name[[:space:]]*from' "$tmp/pdb-query"; then exit 1; fi
pdb_counts='0|1|2'
diag_cdb_catalog_pdbs > "$tmp/pdb-console"
grep -q 'POTENTIAL BLOCKER' "$tmp/pdb-console"
pdb_counts='bad'
if (diag_cdb_catalog_pdbs) > "$tmp/pdb-console" 2>&1; then exit 1; fi
# A partial/unknown CDB tempfile budget cannot pass merely because some bytes sum.
temp_budget=5
sql() {
    cat > "$tmp/temp-query"
    if [[ $2 == */tempfiles.raw.out ]]; then printf '1\n2\n' > "$2"
    else printf '%s\n' "$temp_budget" > "$2"; fi
}
DIAG_CDB_STATE=$tmp/temp-state
diag_cdb_catalog_temp
[[ $CDB_TEMP_MB == 5 ]]
grep -Fq 'count(bytes)=count(*)' "$tmp/temp-query"
for temp_budget in 0 -1 bad; do
    if (diag_cdb_catalog_temp) > "$tmp/temp-console" 2>&1; then exit 1; fi
done
# Node client metadata must establish all prerequisites; no binary is run here.
client_ready=true
cdb_file() {
    [[ $1 == clients && $3 == host && $4 == node1 ]]
    printf '{"clients":{"sqlplus":true,"rman":true,"mkstore":true,"srvctl":true,"asmcmd":%s},"sbt_library_readable":true,"python":[3,8]}\n' "$client_ready" > "$2"
}
diag_cdb_node_clients node1 1
client_ready=false
if (diag_cdb_node_clients node1 1) > "$tmp/client-console" 2>&1; then exit 1; fi
# State uses shell quoting rather than evaluated query/client text and is private.
DIAG_CDB_STATE=$tmp/state
CDB_UNDO="literal ' and \$ shell text"
diag_cdb_save CDB_UNDO
unset CDB_UNDO
# shellcheck disable=SC1090
source "$DIAG_CDB_STATE"
[[ $CDB_UNDO == "literal ' and \$ shell text" ]]
printf 'Passed phased CDB collector continuation, dependency, state and health-query checks. No Oracle or SSH connections performed.\n'
