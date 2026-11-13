#!/usr/bin/env bash
# Disposable filesystem/fake-client checks only; no installed Oracle or SSH.
set -Eeuo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../dup_db.sh
source "$root/dup_db.sh"
tmp=$(mktemp -d)
tmp=$(cd "$tmp" && pwd -P)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/target/tde" "$tmp/target/tde_seps" "$tmp/target/provider/nested" \
    "$tmp/target/.hidden/empty" "$tmp/work" "$tmp/parent/tde" "$tmp/evidence" "$tmp/oracle/bin" "$tmp/bin"
printf 'wallet-only-secret\000\377\001\n' > "$tmp/target/tde/cwallet.sso"
cp "$tmp/target/tde/cwallet.sso" "$tmp/target/tde_seps/cwallet.sso"
cp "$tmp/target/tde/cwallet.sso" "$tmp/target/provider/nested/binary"
printf 'preexisting-wallet\n' > "$tmp/parent/tde/cwallet.sso"
chmod 444 "$tmp/target/tde/cwallet.sso"
chmod 750 "$tmp/target/provider"
export WALLET_FIXTURE_CALLS="$tmp/client-calls" WALLET_FIXTURE_SQL=success WALLET_FIXTURE_COPY=success
export WALLET_REAL_CP
WALLET_REAL_CP=$(command -v cp)
cat > "$tmp/bin/cp" <<'EOF'
#!/usr/bin/env bash
set -eu
case $WALLET_FIXTURE_COPY in
    fail) printf 'wallet-only-secret'; exit 1 ;;
    partial) "$WALLET_REAL_CP" "$@"; printf 'wallet-only-secret' >&2; exit 1 ;;
    corrupt) "$WALLET_REAL_CP" "$@"; printf 'corrupt' >> "$3" ;;
    hardlink) ln "$2" "$3" ;;
    symlink) ln -s "$2" "$3" ;;
    extra) "$WALLET_REAL_CP" "$@"; touch "${3%/*}/unexpected" ;;
    *) exec "$WALLET_REAL_CP" "$@" ;;
esac
EOF
cat > "$tmp/oracle/bin/sqlplus" <<'EOF'
#!/usr/bin/env bash
set -eu
[[ $# == 3 && $1 == -L && $2 == -s && $3 == /nolog && $ORACLE_SID == DUPTEST ]] || exit 90
query=$(cat)
if [[ $query == *'startup nomount'* ]]; then
    printf 'startup\n' >> "$WALLET_FIXTURE_CALLS"
    [[ $query != *FORCE* && $query != *force* ]] || exit 91
    if [[ $WALLET_FIXTURE_SQL == startup-fail ]]; then printf 'ORA-28365: wallet is not open\n'
    else printf 'ORACLE instance started.\n'; fi
elif [[ $query == *'shutdown immediate;'* ]]; then
    printf 'shutdown\n' >> "$WALLET_FIXTURE_CALLS"
    case $WALLET_FIXTURE_SQL in
        shutdown-fail) printf 'ORA-01089: immediate shutdown in progress\n' ;;
        shutdown-unknown) printf 'Disconnected\n' ;;
        shutdown-exit) exit 1 ;;
        *) printf 'Database closed.\nDatabase dismounted.\nORACLE instance shut down.\n' ;;
    esac
else exit 92
fi
EOF
chmod +x "$tmp/bin/cp" "$tmp/oracle/bin/sqlplus"
export PATH="$tmp/bin:$PATH"
checks=0
ok() { ((checks+=1)); }
reject() {
    if ("$@") > "$tmp/rejected" 2>&1; then printf 'Expected wallet rejection: %s\n' "$*" >&2; exit 1; fi
    ok
}
reset_wallet() {
    parse_args --source-cdb PROD --target-cdb PRE --source-pdb APP --target-pdb APPTEST \
        --aux-cdb DUPTEST --aux-base "$tmp/work" "$@"
    RUN=$tmp/evidence/$((checks+1)); mkdir "$RUN"
    LOG=$RUN/run.log PHASE=wallet CUTOVER=untouched LOCK='' DG_HANDOFF=no-standby
    TARGET_WALLET=$tmp/target ORACLE_HOME=$tmp/oracle TARGET_SID=PRE1
    AUX='' AUX_WALLET_DIR='' AUX_WALLET_ROOT='' AUX_WALLET_STATUS=not-created AUXILIARY_STATE=not-started
    WALLET_FIXTURE_COPY=success WALLET_FIXTURE_SQL=success
    : > "$WALLET_FIXTURE_CALLS"
}
snapshot_source() {
    python3 - "$tmp/target" <<'PY'
import hashlib, os, stat, sys
for parent, dirs, files in os.walk(sys.argv[1]):
    for name in sorted(dirs + files):
        path = os.path.join(parent, name)
        info = os.stat(path)
        digest = hashlib.sha256(open(path, 'rb').read()).hexdigest() if stat.S_ISREG(info.st_mode) else '-'
        print(os.path.relpath(path, sys.argv[1]), oct(stat.S_IMODE(info.st_mode)), info.st_uid, info.st_gid, digest)
PY
}
snapshot_source > "$tmp/source-before"

# Normal mode needs no auxiliary wallet. Copy included subdirectories/binary files;
# retain source bytes/modes while granting only the copy's owner access.
reset_wallet --do-duplicate
[[ $DRY_RUN == 0 && -z $DUP_AUX_WALLET_ROOT ]]; ok
AUX=$tmp/work/run; mkdir "$AUX"
create_aux_wallet > "$tmp/create-console"
[[ $AUX_WALLET_DIR == "$AUX/aux_wallet_DUPTEST_"* && -d $AUX_WALLET_ROOT/.hidden/empty ]]; ok
cmp "$TARGET_WALLET/provider/nested/binary" "$AUX_WALLET_ROOT/provider/nested/binary"
[[ ! $TARGET_WALLET/tde/cwallet.sso -ef $AUX_WALLET_ROOT/tde/cwallet.sso ]]; ok
python3 - "$AUX_WALLET_DIR" <<'PY'
import os, stat, sys
for parent, dirs, files in os.walk(sys.argv[1]):
    for path in [parent] + [os.path.join(parent, name) for name in files]:
        mode = stat.S_IMODE(os.stat(path).st_mode)
        assert mode & 0o077 == 0, path
        assert mode & 0o600 == 0o600, path
        if os.path.isdir(path): assert mode == 0o700, path
PY
ok
AUX_UNIQUE=DUPTEST_RUN COMPATIBLE=19.0.0 BLOCK_SIZE=8192 AUX_DATA_DEST=+DATA_X AUX_RECO_DEST=+RECO_Y
TDE_CONFIGURATION=KEYSTORE_CONFIGURATION=HSM
build_aux_pfile > "$AUX/init.ora"
grep -Fxq "*.wallet_root='$AUX_WALLET_ROOT'" "$AUX/init.ora"; ok
# Catalog SEPS stays at the established TARGET credential location.
WALLET=$tmp/established/server_seps RA_ALIAS=ra.example:1521/catalog SOURCE_DBID=77
printf '1\n' > "$RUN/tempfiles.normalized.out"
build_duplicate > "$RUN/duplicate.rman"
grep -Fq "location=file:$WALLET credential_alias=$RA_ALIAS" "$RUN/duplicate.rman"; ok
printf 'modified-copy' >> "$AUX_WALLET_ROOT/tde/cwallet.sso"
snapshot_source > "$tmp/source-after"
cmp "$tmp/source-before" "$tmp/source-after"; ok
first=$AUX_WALLET_DIR
cleanup_aux_wallet > /dev/null
[[ ! -e $first && $AUX_WALLET_STATUS == removed ]]; ok

# Default dry run also performs a real copy, then removes it without starting
# any instance. An optional parent may contain an old wallet; it is untouched.
reset_wallet --aux-wallet-root "$tmp/parent"
[[ $DRY_RUN == 1 ]]; ok
create_aux_wallet > /dev/null
second=$AUX_WALLET_DIR
[[ $second != "$first" && $second == "$tmp/parent/aux_wallet_DUPTEST_"* ]]; ok
reject create_aux_wallet
cleanup_aux_wallet > /dev/null
grep -Fxq 'preexisting-wallet' "$tmp/parent/tde/cwallet.sso"; ok
reset_wallet
create_aux_wallet > /dev/null
third=$AUX_WALLET_DIR
[[ $third != "$second" && $third == "$tmp/work/aux_wallet_DUPTEST_"* ]]; ok
cleanup_aux_wallet > /dev/null

# No path spelling, source/destination alias or evidence parent can put a copy
# into the source tree or report packaging. Checks do not write probe files.
ln -s "$tmp/target" "$tmp/target-alias"
ln -s "$tmp/target/provider" "$tmp/subtree-alias"
for parent in "$tmp/target" "$tmp/target/tde" "$tmp/target-alias" "$tmp/subtree-alias" / /./ // "$tmp/missing"; do
    reset_wallet --aux-wallet-root "$tmp/parent"
    DUP_AUX_WALLET_ROOT=$parent
    reject create_aux_wallet
done
reset_wallet
DUP_AUX_WALLET_ROOT=$RUN
reject create_aux_wallet
DUP_AUX_WALLET_ROOT=''
DUP_AUX_BASE=$tmp/target-alias
reject create_aux_wallet
# Ignore only top-level TLS, including external/broken links and directory
# contents that would otherwise fail validation. Never copy the TLS entry.
for tls in internal external broken directory; do
    reset_wallet
    case $tls in
        internal) ln -s tde "$TARGET_WALLET/tls" ;;
        external) ln -s "$tmp/parent" "$TARGET_WALLET/tls" ;;
        broken) ln -s missing "$TARGET_WALLET/tls" ;;
        directory)
            mkdir "$TARGET_WALLET/tls"
            ln -s missing "$TARGET_WALLET/tls/link"
            mkfifo "$TARGET_WALLET/tls/pipe" ;;
    esac
    create_aux_wallet > /dev/null
    [[ ! -e $AUX_WALLET_ROOT/tls && ! -L $AUX_WALLET_ROOT/tls ]]; ok
    cmp "$TARGET_WALLET/tde/cwallet.sso" "$AUX_WALLET_ROOT/tde/cwallet.sso"
    cleanup_aux_wallet > /dev/null
    rm -rf "$TARGET_WALLET/tls"
done
# A nested entry named tls remains subject to strict validation, as do TDE
# directories and required credential files.
for location in tde tde_seps provider; do
    reset_wallet
    ln -s missing "$TARGET_WALLET/$location/tls"
    reject create_aux_wallet
    grep -q 'symlink' "$tmp/rejected"
    rm "$TARGET_WALLET/$location/tls"
done
for required in tde tde_seps; do
    reset_wallet
    mv "$TARGET_WALLET/$required" "$tmp/hidden-directory"
    ln -s "$tmp/hidden-directory" "$TARGET_WALLET/$required"
    reject create_aux_wallet
    grep -q 'symlink' "$tmp/rejected"
    rm "$TARGET_WALLET/$required"
    mv "$tmp/hidden-directory" "$TARGET_WALLET/$required"
done
for link in internal external broken; do
    reset_wallet
    case $link in
        internal) ln -s tde/cwallet.sso "$TARGET_WALLET/link" ;;
        external) ln -s "$tmp/parent/tde/cwallet.sso" "$TARGET_WALLET/link" ;;
        broken) ln -s missing "$TARGET_WALLET/link" ;;
    esac
    reject create_aux_wallet
    grep -q 'symlink' "$tmp/rejected"
    rm "$TARGET_WALLET/link"
done
reset_wallet
mkfifo "$TARGET_WALLET/pipe"
reject create_aux_wallet
rm "$TARGET_WALLET/pipe"
for required in tde/cwallet.sso tde_seps/cwallet.sso; do
    mv "$TARGET_WALLET/$required" "$tmp/hidden-wallet"
    reset_wallet
    reject create_aux_wallet
    mv "$tmp/hidden-wallet" "$TARGET_WALLET/$required"
done
reset_wallet
chmod 000 "$TARGET_WALLET/provider/nested/binary"
if [[ ! -r $TARGET_WALLET/provider/nested/binary ]]; then reject create_aux_wallet; fi
chmod 644 "$TARGET_WALLET/provider/nested/binary"
reset_wallet
# shellcheck disable=SC2016
reject bash -c 'source "$1"; TARGET_WALLET="$2" DUP_AUX_BASE="$3" DUP_AUX_WALLET_ROOT="" RUN="$4" AUX=""; find() { command find "$@"; return 1; }; check_aux_wallet' \
    bash "$root/dup_db.sh" "$tmp/target" "$tmp/work" "$RUN"

# Copy errors, incomplete copies, zero-exit corruption and link-producing copies
# all abort the real startup sequence. finish removes partial unused copies.
for failure in fail partial corrupt hardlink symlink extra; do
    reset_wallet --do-duplicate
    WALLET_FIXTURE_COPY=$failure
    set +e
    (
        set -Eeuo pipefail
        trap finish EXIT
        create_aux_wallet
        start_auxiliary
        touch "$tmp/target-changed"
    ) > "$RUN/console.txt" 2>&1
    rc=$?
    set -e
    [[ $rc != 0 && ! -s $WALLET_FIXTURE_CALLS && ! -e $tmp/target-changed ]]; ok
    grep -q 'removed|auxiliary=not-started' "$RUN/auxiliary-wallet-status"; ok
    copied=$(cat "$RUN/auxiliary-wallet-path")
    [[ ! -e ${copied%/wallet_root} ]]; ok
done

# Successful shutdown is positively confirmed before removal. Failed startup,
# running instances and unconfirmed/failed shutdowns retain the wallet and path.
reset_wallet --do-duplicate
AUX=$tmp/work/run
create_aux_wallet > /dev/null
build_aux_pfile > "$AUX/init.ora"
start_auxiliary > /dev/null
[[ $AUXILIARY_STATE == running ]]; ok
cleanup_aux_wallet > /dev/null
[[ -d $AUX_WALLET_ROOT && $AUX_WALLET_STATUS == retained ]]; ok
shutdown_auxiliary > /dev/null
[[ $AUXILIARY_STATE == stopped && $AUX_WALLET_STATUS == removed && ! -e $AUX_WALLET_DIR ]]; ok
for failure in startup-fail shutdown-fail shutdown-unknown shutdown-exit; do
    reset_wallet --do-duplicate
    AUX=$tmp/work/run
    WALLET_FIXTURE_SQL=$failure
    set +e
    (
        set -Eeuo pipefail
        trap finish EXIT
        create_aux_wallet
        build_aux_pfile > "$AUX/init.ora"
        start_auxiliary
        shutdown_auxiliary
    ) > "$RUN/console.txt" 2>&1
    rc=$?
    set -e
    [[ $rc != 0 ]]; ok
    copied=$(cat "$RUN/auxiliary-wallet-path")
    [[ -d $copied ]]; ok
    grep -q 'retained|auxiliary=unknown' "$RUN/auxiliary-wallet-status"
    grep -Fq "Confirm auxiliary SID DUPTEST is shut down before manual cleanup: rm -rf -- '${copied%/wallet_root}'" "$RUN/console.txt"; ok
    rm -rf -- "${copied%/wallet_root}"
done
snapshot_source > "$tmp/source-final"
cmp "$tmp/source-before" "$tmp/source-final"; ok
if grep -RFq 'wallet-only-secret' "$tmp/evidence" "$tmp/create-console" "$tmp/rejected"; then exit 1; fi
ok
# Actual workflow ordering: verified target settings precede copies; all copies
# precede startup/cutover; dry run returns after copy cleanup and before startup.
awk '/^    discover_target_settings / {discovery=NR}
     /^        create_aux_wallet$/ {drycopy=NR}
     /^        cleanup_aux_wallet$/ {dryclean=NR}
     /^        return 0$/ {dryreturn=NR}
     /^    create_aux_wallet$/ {copy=NR}
     /^    start_auxiliary$/ {startup=NR}
     /^    stop_target_apply$/ {cutover=NR}
     END {if (!(discovery<drycopy && drycopy<dryclean && dryclean<dryreturn && dryreturn<copy && copy<startup && startup<cutover)) exit 1}' "$root/dup_db.sh"
ok
printf 'Passed %s offline wallet copy, isolation, failure and lifecycle checks.\n' "$checks"
