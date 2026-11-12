#!/usr/bin/env bash
# Focused service checks: shell functions replace every Oracle client call.
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
    local expected=$1; shift
    if ("$@") > "$tmp/rejected" 2>&1; then
        printf 'Expected rejection: %s\n' "$*" >&2; exit 1
    fi
    grep -Fq "$expected" "$tmp/rejected"
    ok
}
setup() {
    RUN="$tmp/$1" TARGET_PDB=APPTEST TARGET_SID=PRE1 DB_UNIQUE_NAME=PREM1
    current_running=${2:-PRE2} sql_service=pre_app config_drift='' status_drift=''
    mkdir -p "$RUN"
    cp "$root/tests/fixtures/service-admin-19c.txt" "$RUN/config"
    # Unknown attributes must survive too, without adding parser/add arguments.
    printf 'Future attribute: retained verbatim\n' >> "$RUN/config"
    : > "$RUN/calls"
}
edit_config() {
    sed "$1" "$RUN/config" > "$RUN/edited"
    mv "$RUN/edited" "$RUN/config"
}
srv() {
    local out=$1; shift
    printf '%s\n' "$*" >> "$RUN/calls"
    case "$*" in
        'config service -db PREM1'|'config service -db PREM1 -service pre_app -verbose')
            cat "$RUN/config" > "$out"
            [[ -z $config_drift ]] || printf '%s\n' "$config_drift" >> "$out"
            ;;
        'status service -db PREM1 -service pre_app -force')
            if [[ -n $status_drift ]]; then printf '%s\n' "$status_drift" > "$out"
            elif [[ $current_running == - ]]; then printf 'Service pre_app is not running.\n' > "$out"
            else printf 'Service pre_app is running on instance(s) %s\n' "$current_running" > "$out"; fi
            ;;
        'modify service -db PREM1 -service pre_app -pdb APPTEST') : > "$out" ;;
        'enable service -db PREM1 -service pre_app')
            edit_config 's/^Service is disabled$/Service is enabled/'
            : > "$out"
            ;;
        'start service -db PREM1 -service pre_app -instance PRE1'|'start service -db PREM1 -service pre_app -instance PRE2')
            if [[ $current_running == - ]]; then current_running=${*: -1}
            else current_running+=",${*: -1}"; fi
            : > "$out"
            ;;
        *) printf 'Unexpected offline srvctl request: %s\n' "$*" >&2; exit 91 ;;
    esac
}
sql() {
    [[ $1 == PRE1 ]] || exit 92
    printf '%s\n' "$sql_service" > "$2"
    cat >/dev/null
}

# Realistic 19c administrator-managed output has both fields. PRE2 is the
# available instance: restoration must follow captured status, not preferences.
setup available-instance
snapshot_services
grep -Fxq 'Server pool: PREM1_pre_app' "$RUN/service.pre_app.before"
grep -Fxq 'Preferred instances: PRE1' "$RUN/service.pre_app.before"
grep -Fxq 'pre_app|enabled|PRE2' "$RUN/services.tsv"
cmp "$RUN/config" "$RUN/service.pre_app.before"; ok

for state in enabled-running enabled-stopped disabled-stopped multi-instance; do
    setup "$state"
    case $state in
        enabled-stopped) current_running=- ;;
        disabled-stopped) current_running=-; edit_config 's/^Service is enabled$/Service is disabled/' ;;
        multi-instance) current_running=PRE1,PRE2 ;;
    esac
    snapshot_services
    # Simulate the cutover's disabled/stopped state entirely in fixture files.
    edit_config 's/^Service is enabled$/Service is disabled/'
    current_running=-
    : > "$RUN/calls"
    restore_services
    cmp "$RUN/service.pre_app.before" "$RUN/service.pre_app.after"
    cmp "$RUN/service.pre_app.status.before" "$RUN/service.pre_app.status.after"
    {
        printf 'modify service -db PREM1 -service pre_app -pdb APPTEST\n'
        [[ $state == disabled-stopped ]] || printf 'enable service -db PREM1 -service pre_app\n'
        case $state in
            enabled-running) printf 'start service -db PREM1 -service pre_app -instance PRE2\n' ;;
            multi-instance) printf 'start service -db PREM1 -service pre_app -instance PRE1\nstart service -db PREM1 -service pre_app -instance PRE2\n' ;;
        esac
        printf 'config service -db PREM1 -service pre_app -verbose\nstatus service -db PREM1 -service pre_app -force\n'
    } > "$RUN/expected-calls"
    # Exact calls also prohibit resource add/remove or attribute reconstruction.
    cmp "$RUN/expected-calls" "$RUN/calls"; ok
done

setup global
edit_config 's/^Global: false$/Global: true/'
reject 'unsupported global/per-instance enablement' snapshot_services
for state in enabled disabled; do
    setup "per-instance-$state"
    edit_config "s/^Service is enabled$/Service is $state on instance(s) PRE1/"
    reject 'unsupported global/per-instance enablement' snapshot_services
done
setup missing-enable
edit_config '/^Service is enabled$/d'
reject 'Cannot determine enablement' snapshot_services
setup missing-preferred
edit_config '/^Preferred instances:/d'
reject 'Missing expected 19c administrator-managed service output' snapshot_services
setup missing-pdb
edit_config '/^Pluggable database name:/d'
reject 'Cannot identify PDB association' snapshot_services
setup wrong-pdb
edit_config 's/^Pluggable database name: APPTEST$/Pluggable database name: OTHERPDB/'
reject 'PDB service pre_app is not captured in srvctl' snapshot_services
# A resource belonging to another PDB is left alone if SQL does not associate it
# with the target PDB either.
sql_service=
snapshot_services
[[ ! -s $RUN/services.tsv ]]; ok
setup unmanaged
sql_service=unmanaged_app
reject 'PDB service unmanaged_app is not captured in srvctl' snapshot_services
setup disabled-running
edit_config 's/^Service is enabled$/Service is disabled/'
reject 'running but disabled' snapshot_services
setup bad-status
status_drift='Service pre_app status unknown'
reject 'Unrecognized 19c service status' snapshot_services
setup bad-instance
current_running='PRE1;bad'
reject 'Unrecognized running instances' snapshot_services

# Exact comparisons must still reject drift in a field we never interpret, or
# a running placement that differs even when the configuration is identical.
setup config-drift
snapshot_services
config_drift='Uncaptured change: true'
reject 'configuration was not preserved exactly' restore_services
setup placement-drift
snapshot_services
status_drift='Service pre_app is running on instance(s) PRE1'
reject 'running placement differs' restore_services

printf 'Passed %s focused offline service checks. No Oracle operations performed.\n' "$checks"
