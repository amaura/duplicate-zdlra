#!/usr/bin/env bash
# Offline topology discovery and freeze tests; no installed Oracle/SSH clients.
set -Eeuo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../dup_db.sh
source "$root/dup_db.sh"
# shellcheck source-path=.
# shellcheck source=tests/fixtures/topology-19c.sh
source "$root/tests/fixtures/topology-19c.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
checks=0
ok() { ((checks+=1)); }
reject() { if ("$@") > "$tmp/rejected" 2>&1; then cat "$tmp/rejected"; printf 'Expected rejection: %s\n' "$*" >&2; exit 1; fi; ok; }
export TOPOLOGY_CASE TOPOLOGY_CALLS
TOPOLOGY_CALLS=$tmp/calls
ORACLE_HOME=$tmp/oracle TARGET_SID=PRE1 TARGET_CDB=PRE DB_UNIQUE_NAME=PREM1 TARGET_DBID=42
SOURCE_CDB=PROD SOURCE_UNIQUE=PRODM1 TARGET_PDB=APPTEST DEBUG=0 DRY_RUN=0
mkdir -p "$ORACLE_HOME/bin" "$tmp/bin"
cat > "$ORACLE_HOME/bin/dgmgrl" <<'CLIENT'
#!/usr/bin/env bash
set -eu
interactive=0
if [[ $# == 2 ]]; then
    input=$(cat)
    [[ $input == $'SHOW CONFIGURATION VERBOSE;\nEXIT;' ]] || exit 99
    interactive=1
    set -- "$@" 'SHOW CONFIGURATION VERBOSE;'
fi
printf '%s|%s\n' "$ORACLE_SID" "$3" >> "$TOPOLOGY_CALLS"
[[ $3 == 'SHOW CONFIGURATION VERBOSE;' ]] || exit 99
if [[ $TOPOLOGY_CASE == unconfigured* && ( $TOPOLOGY_CASE != unconfigured-mixed || $ORACLE_SID == PRE1 ) ]]; then
    printf 'Error: ORA-16532: Data Guard broker configuration does not exist\n\nConfiguration details cannot be determined by DGMGRL\n'
    [[ $TOPOLOGY_CASE != unconfigured-timeout || $ORACLE_SID != PRE2 ]] || exit 124
    [[ $TOPOLOGY_CASE != unconfigured-extra-error || $ORACLE_SID != PRE2 ]] || printf 'TNS-12541: no listener\n'
    [[ $TOPOLOGY_CASE != unconfigured-same-line || $ORACLE_SID != PRE2 ]] || printf 'Error: ORA-16532: Data Guard broker configuration does not exist TNS-12541: no listener\n'
    ((interactive)) || exit 1
    exit 0
fi
printf 'Configuration - pre_dg\n  Members:\n    PREM1 - Primary database\n'
case $TOPOLOGY_CASE in
    broker-appliance) printf '    VAULT01 - Oracle Backup Appliance\n' ;;
    broker-far-only) printf '    FS01 - Far sync instance\n' ;;
    broker-appliance-physical) printf '    VAULT01 - Physical standby database\n' ;;
esac
printf '  Properties:\nConfiguration Status:\nSUCCESS\n'
CLIENT
cat > "$tmp/bin/ssh" <<'CLIENT'
#!/usr/bin/env bash
set -eu
[[ $* == *oracle@node2.example* && $* == *dgmgrl* ]] || exit 98
printf 'SSH-PRE2\n' >> "$TOPOLOGY_CALLS"
ORACLE_SID=PRE2 exec "$TOPOLOGY_ORACLE_HOME/bin/dgmgrl" -silent /
CLIENT
chmod +x "$ORACLE_HOME/bin/dgmgrl" "$tmp/bin/ssh"
export TOPOLOGY_ORACLE_HOME=$ORACLE_HOME
PATH=$tmp/bin:$PATH
sql() {
    local sid=$1 out=$2 query broker=FALSE physical='' mode=healthy
    query=$(cat)
    if [[ $query == *'END|TOPOLOGY'* ]]; then
        case $TOPOLOGY_CASE in
            standalone|new-appliance|appliance|appliance-status|appliance-parent|contradictory|missing-spfile|unknown-remote|fal-hint|fal-literal|fal-marker|persistent-fal-literal|persistent-fal-marker|persistent-broker|dormant-*) mode=$TOPOLOGY_CASE ;;
            disabled-physical|new-physical) physical=PREST ;;
            inconsistent) [[ $sid == PRE1 ]] || broker=TRUE ;;
            query-failure) printf 'ORA-00942: synthetic inventory failure\n' > "$out"; return 1 ;;
            unconfigured*|broker-*) broker=TRUE ;;
            cross-role) physical=PREST; [[ $sid == PRE1 ]] || mode=appliance ;;
        esac
        [[ $mode != standalone && $mode != new-appliance ]] || mode=healthy
        [[ $TOPOLOGY_CASE != new-appliance ]] || mode=appliance
        [[ $TOPOLOGY_CASE != broker-appliance-physical ]] || mode=appliance
        TOPOLOGY_FIXTURE_MODE=$mode topology_fixture "$sid" "$broker" "$physical" > "$out"
        if [[ $TOPOLOGY_CASE == malformed ]]; then printf 'unexpected text\n' >> "$out"; fi
    elif [[ $query == *"select instance_name||"* ]]; then
        printf 'PRE1|node1.example|OPEN|19.0.0.0.0\nPRE2|node2.example|OPEN|19.0.0.0.0\n' > "$out"
    else printf 'Unexpected fixture SQL\n' >&2; exit 97
    fi
}
setup() {
    TOPOLOGY_CASE=$1 RUN=$tmp/$1 PHASE=offline CUTOVER=untouched LOCK='' DG_HANDOFF=not-checked DG_TOPOLOGY=UNKNOWN DG_APPLY_ATTEMPTED=0
    mkdir -p "$RUN"; LOG=$RUN/run.log; : > "$LOG"; : > "$TOPOLOGY_CALLS"
}
# Accept both observed primary-root encodings, retaining strict remote checks.
setup primary-parent
for parent in '<NULL>' NONE; do
    topology_fixture PRE1 FALSE > "$RUN/input"
    sed "s/MEMBER|PREM1|PRIMARY DATABASE|<NULL>/MEMBER|PREM1|PRIMARY DATABASE|$parent/" "$RUN/input" > "$RUN/metadata"
    parse_topology_node "$RUN/metadata" PRE1 FALSE
    ok
done
for parent in PREM1 HIDDEN; do
    sed "s/MEMBER|PREM1|PRIMARY DATABASE|<NULL>/MEMBER|PREM1|PRIMARY DATABASE|$parent/" "$RUN/input" > "$RUN/metadata"
    reject parse_topology_node "$RUN/metadata" PRE1 FALSE
done
sed '/^MEMBER|/d' "$RUN/input" > "$RUN/metadata"
parse_topology_node "$RUN/metadata" PRE1 FALSE; ok
# Empty membership must never make a configured remote endpoint acceptable.
topology_fixture PRE1 FALSE PREST > "$RUN/remote-input"
sed '/^MEMBER|/d' "$RUN/remote-input" > "$RUN/metadata"
reject parse_topology_node "$RUN/metadata" PRE1 FALSE
# A partial inventory lacking the primary remains contradictory.
sed '/^MEMBER|PREM1|/d' "$RUN/remote-input" > "$RUN/metadata"
reject parse_topology_node "$RUN/metadata" PRE1 FALSE
# Literal NONE is accepted only on unused local destinations.
sed 's/INACTIVE|PRIMARY|<NULL>|<NULL>|UNKNOWN/INACTIVE|PRIMARY|<NULL>|NONE|LOCAL/g' "$RUN/input" | sed '/^MEMBER|/d' > "$RUN/metadata"
parse_topology_node "$RUN/metadata" PRE1 FALSE; ok
sed 's/DEST|2|INACTIVE|PRIMARY|<NULL>|NONE|LOCAL/DEST|2|INACTIVE|STANDBY|<NULL>|NONE|LOCAL/' "$RUN/metadata" > "$RUN/remote-none"
reject parse_topology_node "$RUN/remote-none" PRE1 FALSE
sed 's/DEST|2|INACTIVE|PRIMARY|<NULL>|NONE|LOCAL/DEST|2|ERROR|PRIMARY|<NULL>|NONE|LOCAL/' "$RUN/metadata" > "$RUN/error-none"
reject parse_topology_node "$RUN/error-none" PRE1 FALSE
topology_fixture PRE1 FALSE PREST > "$RUN/input"
sed 's/MEMBER|PREST|PHYSICAL STANDBY|PREM1/MEMBER|PREST|PHYSICAL STANDBY|NONE/' "$RUN/input" > "$RUN/metadata"
reject parse_topology_node "$RUN/metadata" PRE1 FALSE
setup standalone
# A missing client does not block positively corroborated FALSE-broker topology.
mv "$ORACLE_HOME/bin/dgmgrl" "$tmp/dgmgrl"
preflight_broker
stop_target_apply
[[ $DG_TOPOLOGY == NONE && $DG_TOPOLOGY_EVIDENCE == STANDALONE_DISABLED && $DG_HANDOFF == no-standby && ! -s $TOPOLOGY_CALLS ]]; ok
(trap finish EXIT; false) >/dev/null 2>&1 || :
grep -q 'evidence=STANDALONE_DISABLED' "$LOG"
if grep -Eq 'Leave any stopped apply|separate standby-refresh procedure' "$LOG"; then exit 1; fi; ok
mv "$tmp/dgmgrl" "$ORACLE_HOME/bin/dgmgrl"
TOPOLOGY_CASE=unconfigured
if broker "$tmp/single-command-result" 'SHOW CONFIGURATION VERBOSE;'; then exit 1; fi
grep -q ORA-16532 "$tmp/single-command-result"; ok
for scenario in appliance unconfigured broker-appliance; do
    setup "$scenario"
    preflight_broker
    stop_target_apply
    [[ $DG_TOPOLOGY == NONE && ! -s $RUN/dg.preflight.standbys ]]; ok
    if [[ $scenario == unconfigured ]]; then
        [[ $DG_TOPOLOGY_EVIDENCE == STANDALONE_UNCONFIGURED ]]
        grep -Fxq SSH-PRE2 "$TOPOLOGY_CALLS"
        grep -Fxq 'PRE2|SHOW CONFIGURATION VERBOSE;' "$TOPOLOGY_CALLS"; ok
    fi
done
for scenario in disabled-physical inconsistent query-failure missing-spfile unknown-remote fal-hint fal-literal fal-marker persistent-fal-literal persistent-fal-marker persistent-broker dormant-defer dormant-alternate dormant-reset dormant-disabled appliance-parent contradictory malformed cross-role unconfigured-mixed unconfigured-timeout unconfigured-extra-error unconfigured-same-line broker-far-only broker-appliance-physical; do
    setup "$scenario"
    reject preflight_broker
    grep -q '^UNKNOWN|' "$RUN/dg.preflight.mode"
done
# Status-only changes are observations rather than a membership/config change.
setup appliance
preflight_broker
TOPOLOGY_CASE='appliance-status'
stop_target_apply
[[ $DG_HANDOFF == no-standby ]]; ok
# Newly configured relationships must abort before any caller change marker.
for relationship in new-physical new-appliance; do
    setup standalone
    preflight_broker
    TOPOLOGY_CASE=$relationship
    reject stop_target_apply
    if grep -q EDIT "$TOPOLOGY_CALLS"; then exit 1; fi
done
# Both destructive and create boundaries revalidate the frozen topology.
awk '/^    stop_target_apply$/ {stop=NR}
     /^    CUTOVER=services-stopped/ {services=NR}
     /^    discover_standbys predrop$/ {predrop=NR}
     /^    CUTOVER=drop-issued/ {drop=NR}
     /^    discover_standbys precreate$/ {precreate=NR}
     /^    CUTOVER=create-issued/ {create=NR}
     END {if (!(stop<services && predrop<drop && drop<precreate && precreate<create)) exit 1}' "$root/dup_db.sh"; ok
printf 'Passed %s offline topology classification/freeze checks. No Oracle/SSH operations performed.\n' "$checks"
