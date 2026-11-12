#!/usr/bin/env bash
# shellcheck disable=SC2016
# Synthetic Oracle 19c topology metadata, for offline clients only.
topology_fixture() {
    local inst=$1 broker=$2 physical=${3:-} mode=${TOPOLOGY_FIXTURE_MODE:-healthy}
    local config='DG_CONFIG=(PREM1' id name value status=VALID target dest dbun type member
    local remote=0 appliance=0
    [[ -z $physical ]] || remote=1
    case $mode in appliance|appliance-parent|contradictory|appliance-status) appliance=1; remote=1 ;; esac
    [[ -z $physical ]] || config+=",$physical"
    ((appliance == 0)) || config+=',VAULT01'
    config+=')'
    printf 'IDENTITY|PRE|PREM1|42|PRIMARY|YES|%s\nCONTAINER|CDB$ROOT\n' "$inst"
    for name in dg_broker_start spfile log_archive_config fal_server fal_client log_archive_dest log_archive_duplex_dest; do
        value='<NULL>'
        case $name in
            dg_broker_start) value=$broker ;;
            spfile) [[ $mode == missing-spfile ]] || value=+DATA/PREM1/spfile.ora ;;
            log_archive_config) value=$config ;;
            fal_server)
                [[ $mode != fal-hint ]] || value=opaque_service
                [[ $mode != fal-literal ]] || value=UNSET
                [[ $mode != fal-marker ]] || value='<NULL>' ;;
        esac
        printf 'PARAM|%s|%s\n' "$name" "$value"
    done
    for ((id=1;id<=31;id++)); do
        value='<NULL>'
        if ((id==1)); then value='LOCATION=USE_DB_RECOVERY_FILE_DEST'
        elif ((id==2 && remote)); then
            if ((appliance)); then value='SERVICE=opaque_service DB_UNIQUE_NAME=VAULT01'
            else value="SERVICE=opaque_service DB_UNIQUE_NAME=${physical%%,*}"; fi
        fi
        [[ $mode != unknown-remote || $id != 2 ]] || value='SERVICE=opaque_service'
        printf 'PARAM|log_archive_dest_%s|%s\nPARAM|log_archive_dest_state_%s|ENABLE\n' "$id" "$value" "$id"
    done
    value=PRESENT; [[ $mode != missing-spfile ]] || value=ABSENT
    printf 'PRESENCE|spfile|%s\nPRESENCE|fal_client|ABSENT\n' "$value"
    value=ABSENT
    case $mode in fal-hint|fal-literal|fal-marker) value=PRESENT ;; esac
    printf 'PRESENCE|fal_server|%s\n' "$value"
    value=0
    case $mode in persistent-fal-literal|persistent-fal-marker) value=1 ;; esac
    printf 'PERSISTENT_FAL|%s\n' "$value"
    if [[ $mode != missing-spfile ]]; then
        printf 'SPFILE|*|dg_broker_start|1|%s\nSPFILE|*|log_archive_config|1|%s\n' "$broker" "$config"
        printf 'SPFILE|*|log_archive_dest_1|1|LOCATION=USE_DB_RECOVERY_FILE_DEST\n'
        if ((remote)); then
            dbun=${physical%%,*}; ((appliance == 0)) || dbun=VAULT01
            printf 'SPFILE|*|log_archive_dest_2|1|SERVICE=opaque_service DB_UNIQUE_NAME=%s\n' "$dbun"
        fi
        case $mode in
            dormant-defer|dormant-alternate|dormant-reset|dormant-disabled)
                printf 'SPFILE|*|log_archive_dest_9|1|SERVICE=unresolved DB_UNIQUE_NAME=HIDDEN\nSPFILE|*|log_archive_dest_state_9|1|%s\n' "${mode#dormant-}" ;;
            persistent-broker) printf 'SPFILE|PRE2|dg_broker_start|1|TRUE\n' ;;
            persistent-fal-literal) printf 'SPFILE|*|fal_server|1|UNSET\n' ;;
            persistent-fal-marker) printf 'SPFILE|*|fal_server|1|<NULL>\n' ;;
        esac
    fi
    for ((id=1;id<=31;id++)); do
        status=INACTIVE target=PRIMARY dest='<NULL>' dbun='<NULL>' type=UNKNOWN
        if ((id==1)); then status=VALID; dest=USE_DB_RECOVERY_FILE_DEST; dbun=PREM1; type=LOCAL
        elif ((id==2 && remote)); then
            status=DEFERRED target=STANDBY dest=opaque_service dbun=${physical%%,*} type=PHYSICAL
            if ((appliance)); then dbun=VAULT01; type='BACKUP APPLIANCE'; fi
            [[ $mode != contradictory ]] || type=PHYSICAL
            [[ $mode != appliance-status ]] || status=ALTERNATE
        fi
        if [[ $mode == unknown-remote && $id == 2 ]]; then target=STANDBY; dest=opaque_service; type=UNKNOWN; fi
        printf 'DEST|%s|%s|%s|%s|%s|%s\n' "$id" "$status" "$target" "$dest" "$dbun" "$type"
    done
    printf 'MEMBER|PREM1|PRIMARY DATABASE|<NULL>\n'
    if [[ -n $physical ]]; then
        local -a names
        IFS=',' read -r -a names <<< "$physical"
        for member in "${names[@]}"; do printf 'MEMBER|%s|PHYSICAL STANDBY|PREM1\n' "$member"; done
    fi
    if ((appliance)); then
        member=PREM1; [[ $mode != appliance-parent ]] || member=HIDDEN
        printf 'MEMBER|VAULT01|BACKUP APPLIANCE|%s\n' "$member"
    fi
    printf 'END|TOPOLOGY\n'
}
