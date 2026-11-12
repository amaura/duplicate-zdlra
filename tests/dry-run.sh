#!/usr/bin/env bash
# Offline catalog fixtures; no Oracle clients or network access.
set -Eeuo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$root/dup_db.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
base=(--source-cdb PROD --target-cdb PRE --source-pdb APP --target-pdb APPTEST
    --aux-cdb DUPTEST --aux-base /stage --aux-wallet-root /wallet)
parse_args "${base[@]}"
[[ $DRY_RUN == 1 ]]
parse_args "${base[@]}" --do-duplicate
[[ $DRY_RUN == 0 ]]
# Each parse resets the mode; duplication must always be explicitly requested.
parse_args "${base[@]}"
[[ $DRY_RUN == 1 ]]
RUN=$tmp LOG=$tmp/run.log PHASE=test SOURCE_DBKEY=1 SOURCE_INC=2 point="to_date('2024-10-02','YYYY-MM-DD')"
printf '1|10|20|2024-10-02 00:00:00\n2|10|19|2024-10-01 23:00:00\n' > "$RUN/redo-inventory.out"
controlfiles=1
sql() {
    local query
    query=$(cat)
    [[ $1 == CATALOG && $query == select* && $query != *'alter '* && $query != *'restore '* ]]
    case $2 in
        */restore-range.out) printf '2024-10-01 00:00:00\n' > "$2" ;;
        */controlfile-count.out) printf '%s\n' "$controlfiles" > "$2" ;;
        *) exit 90 ;;
    esac
}
dry_run_range > /dev/null
grep -q 'to 2024-10-01 23:00:00' "$LOG"
RECOVERY_TIME='2024-10-01 12:00:00'
dry_run_range > /dev/null
RECOVERY_TIME='2024-10-01 23:00:00'
if (dry_run_range) > /dev/null 2>&1; then exit 1; fi
RECOVERY_TIME='2024-09-30 12:00:00'
if (dry_run_range) > /dev/null 2>&1; then exit 1; fi
RECOVERY_TIME='' controlfiles=0
if (dry_run_range) > /dev/null 2>&1; then exit 1; fi
# Verify the main flow exits dry run before any auxiliary startup or cutover.
awk '/^    if \(\( DRY_RUN \)\); then$/ {gate=NR}
     /^        dry_run_range$/ {check=NR}
     /^        return 0$/ {ret=NR}
     /^    phase auxiliary / {aux=NR}
     END {if (!(gate<check && check<ret && ret<aux)) exit 1}' "$root/dup_db.sh"
printf 'Passed offline dry-run argument, catalog range, failure and exit-boundary checks.\n'
