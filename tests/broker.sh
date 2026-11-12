#!/usr/bin/env bash
# Offline broker/standby fixtures only. Never invoke an installed Oracle client.
set -Eeuo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../dup_db.sh
source "$root/dup_db.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
checks=0
ok() { ((checks+=1)); }
reject() {
    if ("$@") > "$tmp/rejected" 2>&1; then printf 'Expected rejection: %s\n' "$*" >&2; exit 1; fi
    ok
}
no_match() {
    if grep -Eqi "$1" "$2"; then printf 'Unexpected match: %s in %s\n' "$1" "$2" >&2; exit 1; fi
}
ORACLE_HOME="$tmp/oracle" TARGET_SID=PRE1 TARGET_CDB=PRE DB_UNIQUE_NAME=PREM1
SOURCE_CDB=PROD SOURCE_UNIQUE=PRODM1 TARGET_PDB=APPTEST TARGET_DBID=42 DEBUG=0
mkdir -p "$ORACLE_HOME/bin"
export DG_TEST_RUN DG_TEST_CASE DG_TEST_INITIAL DG_TEST_CONFIG
source "$root/tests/fixtures/topology-19c.sh"
cat > "$ORACLE_HOME/bin/dgmgrl" <<'EOF'
#!/usr/bin/env bash
set -eu
if [[ $# == 2 ]]; then
    input=$(cat)
    [[ $input == $'SHOW CONFIGURATION VERBOSE;\nEXIT;' ]] || exit 99
    set -- "$@" 'SHOW CONFIGURATION VERBOSE;'
fi
[[ $ORACLE_SID == PRE1 && $# == 3 && $1 == -silent && $2 == / ]] || exit 99
printf '%s\n' "$3" >> "$DG_TEST_RUN/calls"
case $DG_TEST_CASE in
    broker-error) printf 'ORA-16525: broker unavailable %s\n' "${DG_TEST_SECRET:-}"; exit 0 ;;
    dgm-error) printf 'DGM-17016: failed to retrieve status\n'; exit 0 ;;
    tns-error) printf 'TNS-12541: no listener\n'; exit 0 ;;
    client-error) exit 2 ;;
    empty) exit 0 ;;
esac
case $3 in
    'SHOW CONFIGURATION VERBOSE;') cat "$DG_TEST_CONFIG" ;;
    "SHOW DATABASE 'PREST';"|"SHOW DATABASE 'PREST2';")
        db=${3#*\'}; db=${db%%\'*}
        state=$DG_TEST_INITIAL
        [[ ! -f $DG_TEST_RUN/stopped.$db ]] || state=APPLY-OFF
        [[ $DG_TEST_CASE != intended-on ]] || state=APPLY-ON
        printf 'Database - %s\n  Role: PHYSICAL STANDBY\n  Intended State: %s\n  Instance(s):\n    ST1\n    ST2\n\nDatabase Status:\nSUCCESS\n' "$db" "$state"
        ;;
    "SHOW INSTANCE VERBOSE 'ST1' ON DATABASE 'PREST';"|"SHOW INSTANCE VERBOSE 'ST1' ON DATABASE 'PREST2';")
        printf "Instance 'ST1'\n  HostName = 'standby1.example'\nInstance Status:\nSUCCESS\n" ;;
    "SHOW INSTANCE VERBOSE 'ST2' ON DATABASE 'PREST';"|"SHOW INSTANCE VERBOSE 'ST2' ON DATABASE 'PREST2';")
        printf "Instance 'ST2'\n  HostName = 'standby2.example'\nInstance Status:\nSUCCESS\n" ;;
    "EDIT DATABASE 'PREST' SET STATE='APPLY-OFF';"|"EDIT DATABASE 'PREST2' SET STATE='APPLY-OFF';")
        db=${3#*\'}; db=${db%%\'*}
        touch "$DG_TEST_RUN/stopped.$db"
        if [[ $DG_TEST_CASE == stop-error ]]; then printf 'ORA-16664: unable to receive result\n'; exit 0; fi
        printf 'Succeeded.\n' ;;
    *) printf 'Unexpected fixture command: %s\n' "$3" >&2; exit 98 ;;
esac
EOF
chmod +x "$ORACLE_HOME/bin/dgmgrl"

setup() {
    DG_TEST_CASE=$1 DG_TEST_INITIAL=${2:-APPLY-ON}
    RUN="$tmp/$1" LOG="$tmp/$1/run.log" PHASE=offline CUTOVER=untouched LOCK=
    DG_TEST_RUN=$RUN DG_TEST_CONFIG="$RUN/config" DG_HANDOFF=not-checked DG_TOPOLOGY=UNKNOWN DG_APPLY_ATTEMPTED=0
    mkdir -p "$RUN"; : > "$LOG"; : > "$RUN/calls"
    cat > "$DG_TEST_CONFIG" <<'EOF'
Configuration - pre_dg
  Protection Mode: MaxAvailability
  Members:
    PREM1 - Primary database
      PREST - (*) Physical standby database
  Properties:
    CommunicationTimeout = '180'
  Fast-Start Failover: DISABLED
Configuration Status:
SUCCESS
EOF
}

# Small SQL fixture: assert local target access vs explicit SSH standby access,
# then return per-instance observations. Production endpoints are never used.
sql() {
    local sid=$1 out=$2 host=${3:-} remote=${4:-0} query db count=0 mode=MOUNTED id=42
    query=$(cat)
    if [[ $query == *'END|TOPOLOGY'* ]]; then
        local physical broker=TRUE
        physical=$(sed -nE 's/^[[:space:]]*([A-Za-z0-9_]+) - (\(\*\) )?Physical standby database$/\1/p' "$DG_TEST_CONFIG" | paste -sd, -)
        [[ $DG_TEST_CASE != broker-disabled ]] || broker=FALSE
        topology_fixture "$sid" "$broker" "$physical" > "$out"
        return
    fi
    if [[ $sid == "$TARGET_SID" && -z $host ]]; then
        case $query in
            *"select instance_name||"*)
                printf 'PRE1|node1.example|OPEN|19.0.0.0.0\nPRE2|node2.example|OPEN|19.0.0.0.0\n' > "$out" ;;
            *gv\$parameter*)
                if [[ $DG_TEST_CASE == broker-disabled ]]; then printf 'DISABLED\n' > "$out"
                else printf 'ENABLED\n' > "$out"; fi ;;
            *rawtohex*)
                if [[ $DG_TEST_CASE == target-pdb-change && $out == *.precutover ]]; then
                    printf 'FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF\n' > "$out"
                else printf '0123456789ABCDEF0123456789ABCDEF\n' > "$out"; fi ;;
            *) return 97 ;;
        esac
        return
    fi
    [[ $remote == 1 && ( $sid == ST1 || $sid == ST2 ) && $host == standby?.example ]] || return 96
    [[ $query == *"v\$dataguard_process"* && $query == *"lower(role) like '%recovery%'"* && $query == *"gv\$instance"* && $query == *'rawtohex(guid)'* ]] || return 95
    db=PREST; [[ $out != *dg.PREST2.* ]] || db=PREST2
    [[ $DG_TEST_INITIAL != APPLY-ON || -f $RUN/stopped.$db ]] || count=1
    if [[ $DG_TEST_CASE == failed-verify && $out == *'.after.ST2.'* ]]; then count=2; fi
    if [[ $DG_TEST_CASE == pdb-open && $sid == ST2 ]]; then mode='READ ONLY'; fi
    if [[ $DG_TEST_CASE == predrop-open && $out == *'.predrop.ST2.'* ]]; then mode='READ ONLY'; fi
    [[ $DG_TEST_CASE != identity-error ]] || id=999
    {
        printf "IDENTITY|PRE|%s|%s|PHYSICAL STANDBY|YES|%s\nCONTAINER|CDB\$ROOT\nBROKER|TRUE\n" "$db" "$id" "$sid"
        printf 'RAC|ST1|standby1.example\n'
        [[ $DG_TEST_CASE == missing-instance ]] || printf 'RAC|ST2|standby2.example\n'
        printf 'APPLY|%s\nPDB|0123456789ABCDEF0123456789ABCDEF|%s\n' "$count" "$mode"
    } > "$out"
}

# A successful, complete, enabled primary-only configuration establishes absence.
setup no-standby
sed '/PREST -/d' "$DG_TEST_CONFIG" > "$tmp/config"; mv "$tmp/config" "$DG_TEST_CONFIG"
preflight_broker
stop_target_apply
[[ $DG_HANDOFF == no-standby && ! -s $RUN/dg.preflight.standbys ]]
no_match 'EDIT|SHOW DATABASE' "$RUN/calls"
grep -q 'No physical standby configured' "$LOG"; ok

setup running
preflight_broker
no_match EDIT "$RUN/calls"; ok
(trap finish EXIT; stop_target_apply)
grep -q 'Data Guard handoff: APPLY-OFF verified' "$LOG"
grep -Fxq "EDIT DATABASE 'PREST' SET STATE='APPLY-OFF';" "$RUN/calls"
grep -Fq 'preflight|PREST|APPLY-ON|ST2|1|' "$RUN/dg-states.tsv"
grep -Fq 'after|PREST|APPLY-OFF|ST2|0|' "$RUN/dg-states.tsv"
observe_standby PREST predrop 1
grep -Fq 'predrop|PREST|APPLY-OFF|ST1|0|' "$RUN/dg-states.tsv"; ok

setup stopped APPLY-OFF
preflight_broker
stop_target_apply
grep -Fq 'preflight|PREST|APPLY-OFF|ST1|0|' "$RUN/dg-states.tsv"
grep -q 'verified no recovery processes' "$RUN/dg.PREST.result"; ok

setup multiple
sed '/PREST -/a\
      PREST2 - Physical standby database
' "$DG_TEST_CONFIG" > "$tmp/config"; mv "$tmp/config" "$DG_TEST_CONFIG"
preflight_broker
stop_target_apply
[[ $(grep -c '^EDIT DATABASE' "$RUN/calls") == 2 ]]
grep -q 'verified no recovery processes' "$RUN/dg.PREST2.result"; ok

for failure in broker-error dgm-error tns-error client-error empty; do
    setup "$failure"
    sed '/PREST -/d' "$DG_TEST_CONFIG" > "$tmp/config"; mv "$tmp/config" "$DG_TEST_CONFIG"
    reject preflight_broker
    no_match EDIT "$RUN/calls"
done
setup broker-error
VPC_PASSWORD='offline*broker&secret'
export DG_TEST_SECRET="$VPC_PASSWORD"
reject preflight_broker
grep -Fq '[REDACTED]' "$RUN/dg.preflight.configuration"
if grep -Fq "$VPC_PASSWORD" "$LOG"; then exit 1; fi
unset VPC_PASSWORD DG_TEST_SECRET
ok
setup config-disabled
sed 's/^SUCCESS$/DISABLED/' "$DG_TEST_CONFIG" > "$tmp/config"; mv "$tmp/config" "$DG_TEST_CONFIG"
reject preflight_broker
setup discovery-failure
sed '/Members:/d' "$DG_TEST_CONFIG" > "$tmp/config"; mv "$tmp/config" "$DG_TEST_CONFIG"
reject preflight_broker
setup member-disabled
sed 's/Physical standby database/Physical standby database (disabled)/' "$DG_TEST_CONFIG" > "$tmp/config"; mv "$tmp/config" "$DG_TEST_CONFIG"
reject preflight_broker
setup wrong-primary
sed 's/PREM1 -/OTHERM1 -/' "$DG_TEST_CONFIG" > "$tmp/config"; mv "$tmp/config" "$DG_TEST_CONFIG"
reject preflight_broker
no_match 'SHOW DATABASE|EDIT' "$RUN/calls"
setup production-member
sed 's/PREST -/PRODM1 -/' "$DG_TEST_CONFIG" > "$tmp/config"; mv "$tmp/config" "$DG_TEST_CONFIG"
reject preflight_broker
no_match 'SHOW DATABASE|EDIT' "$RUN/calls"
for failure in identity-error missing-instance pdb-open; do
    setup "$failure"
    reject preflight_broker
    no_match EDIT "$RUN/calls"
done

# The caller's destructive marker must remain absent when the stop gate fails.
cutover_probe() { trap finish EXIT; stop_target_apply; touch "$RUN/destructive"; }
for failure in failed-verify intended-on stop-error; do
    setup "$failure"
    # intended-on is needed only after the stop request, not during preflight.
    preflight_broker
    reject cutover_probe
    [[ ! -f $RUN/destructive ]]
    grep -q 'Data Guard handoff: stop attempted' "$LOG"
    grep -q 'Apply is never restarted automatically' "$LOG"
    grep -q '^after|' "$RUN/dg-states.tsv"
done
setup membership-change
preflight_broker
sed '/PREST -/d' "$DG_TEST_CONFIG" > "$tmp/config"; mv "$tmp/config" "$DG_TEST_CONFIG"
reject cutover_probe
no_match EDIT "$RUN/calls"
[[ ! -f $RUN/destructive ]]
setup target-pdb-change
preflight_broker
reject cutover_probe
no_match EDIT "$RUN/calls"
[[ ! -f $RUN/destructive ]]

setup predrop-open
preflight_broker
stop_target_apply
reject observe_standby PREST predrop 1
grep -q 'APPLY-OFF does not close it' "$RUN/run.log"

# Check the real main-flow placement as well as exercising the gate itself.
awk '/^    phase auxiliary / {aux=NR}
     /^    stop_target_apply$/ {stop=NR}
     /^    CUTOVER=services-stopped/ {services=NR}
     /^    discover_standbys predrop$/ {membership=NR}
     /observe_standby "\$standby" predrop 1/ {verify=NR}
     /^    CUTOVER=drop-issued/ {drop=NR}
     END {if (!(aux<stop && stop<services && services<membership && membership<verify && verify<drop)) exit 1}' "$root/dup_db.sh"; ok
no_match '^EDIT .*TRANSPORT|^EDIT CONFIGURATION|^DISABLE |APPLY-ON.*;' "$RUN/calls"; ok
printf 'Passed %s focused offline broker checks. No database or broker operations performed.\n' "$checks"
