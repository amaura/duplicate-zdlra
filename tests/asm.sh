#!/usr/bin/env bash
# Offline ASM discovery, combined capacity and namespace isolation checks.
set -Eeuo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$root/dup_db.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
log() { :; }
reject() { if ("$@") >/dev/null 2>&1; then printf 'Expected rejection: %s\n' "$*" >&2; exit 1; fi; }
discover_aux_storage +DATA_X/TARGET +RECOVERY_Y/old_alias
[[ $AUX_DATA_DEST == +DATA_X && $AUX_RECO_DEST == +RECOVERY_Y ]]
for value in UNSET '' /filesystem '+DATA;bad' '+DATA/../TARGET'; do
    reject discover_aux_storage "$value" +RECO
    reject discover_aux_storage +DATA "$value"
done
AUX_UNIQUE=DUPTEST_20261112120000_ABC123
printf '+data_x/%s/DATAFILE/system.123.456\n+RECOVERY_Y/%s/CONTROLFILE/current.234.567\n' "$AUX_UNIQUE" "$AUX_UNIQUE" > "$tmp/files"
validate_aux_files "$tmp/files"
for file in '+DATA_X/TARGET/DATAFILE/system.1.2' '+DATA_X/DUPTEST_OLD/DATAFILE/system.1.2' '/stage/data.dbf' '+OTHER/DUPTEST/file'; do
    printf '%s\n' "$file" > "$tmp/files"
    reject validate_aux_files "$tmp/files"
done
: > "$tmp/files"
reject validate_aux_files "$tmp/files"
# Inspect the actual generated PFILE without starting an Oracle instance.
AUX=/work/run DUP_AUX_CDB=DUPTEST COMPATIBLE=19.0.0 BLOCK_SIZE=8192
DUP_AUX_SGA_MB=4096 DUP_AUX_PGA_MB=1024 AUX_WALLET_ROOT=/work/run/aux_wallet_fixture/wallet_root
TDE_CONFIGURATION=KEYSTORE_CONFIGURATION=HSM
build_aux_pfile > "$tmp/init.ora"
grep -Fxq "*.db_unique_name='$AUX_UNIQUE'" "$tmp/init.ora"
grep -Fxq "*.control_files='+DATA_X'" "$tmp/init.ora"
grep -Fxq "*.db_create_file_dest='+DATA_X'" "$tmp/init.ora"
grep -Fxq "*.db_create_online_log_dest_1='+DATA_X'" "$tmp/init.ora"
grep -Fxq "*.log_archive_dest_1='LOCATION=+RECOVERY_Y'" "$tmp/init.ora"
grep -Fxq "*.diagnostic_dest='/work/run/diag'" "$tmp/init.ora"
grep -Fxq "*.wallet_root='$AUX_WALLET_ROOT'" "$tmp/init.ora"
space_check() { printf '%s|%s\n' "$1" "$2" >> "$tmp/space"; }
DUP_REDO_RESERVE_MB=100
check_refresh_space 1000
printf '+DATA_X|2100\n+RECOVERY_Y|100\n' > "$tmp/expected"
cmp "$tmp/space" "$tmp/expected"
: > "$tmp/space"
discover_aux_storage +shared/target +SHARED/recovery
check_refresh_space 1000
printf '+SHARED|2100\n' > "$tmp/expected"
cmp "$tmp/space" "$tmp/expected"
printf 'Passed offline ASM discovery, capacity and namespace isolation checks.\n'
