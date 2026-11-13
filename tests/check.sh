#!/usr/bin/env bash
# Focused offline checks. No Oracle installation, credentials or connections.
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
    if ("$@") > "$tmp/rejected.out" 2>&1; then printf 'Expected rejection: %s\n' "$*" >&2; exit 1; fi
    ok
}
names=(--source-cdb PROD --target-cdb PRE --source-pdb APP --target-pdb APPTEST)
aux=(--aux-cdb duptest --aux-base /stage --aux-wallet-root /wallet)
base=("${names[@]}" "${aux[@]}")
parse_args "${base[@]}"
[[ $DUP_RESTORE_PARALLELISM == 1 ]]; ok
[[ $RETENTION == 7 && -z $RECOVERY_TIME && $DEBUG == 0 && $DRY_RUN == 1 ]]; ok
[[ $DUP_AUX_CDB == DUPTEST && $DUP_AUX_BASE == /stage && $DUP_AUX_WALLET_ROOT == /wallet && -z $DUP_ZDLRA_ALIAS ]]; ok
[[ $DUP_AUX_SGA_MB == 4096 && $DUP_AUX_PGA_MB == 1024 && $DUP_REDO_RESERVE_MB == 10240 ]]; ok
parse_args "${base[@]}" --zdlra-alias ra-host.example:1521/ra_service \
    --aux-sga-mb 8192 --aux-pga-mb 2048 --redo-reserve-mb 20480
[[ $DUP_ZDLRA_ALIAS == ra-host.example:1521/ra_service && $DUP_AUX_SGA_MB == 8192 && $DUP_AUX_PGA_MB == 2048 && $DUP_REDO_RESERVE_MB == 20480 ]]; ok
# Inherited/previous values cannot supply missing required arguments or optional defaults.
DUP_AUX_CDB=ENV_AUX DUP_AUX_BASE=/env/stage DUP_AUX_WALLET_ROOT=/env/wallet
DUP_ZDLRA_ALIAS=env_alias DUP_AUX_SGA_MB=1 DUP_AUX_PGA_MB=2 DUP_REDO_RESERVE_MB=3
reject parse_args "${names[@]}"
reject parse_args "${names[@]}" --aux-base /stage --aux-wallet-root /wallet
reject parse_args "${names[@]}" --aux-cdb DUPTEST --aux-wallet-root /wallet
parse_args "${names[@]}" --aux-cdb DUPTEST --aux-base /stage
[[ -z $DUP_AUX_WALLET_ROOT && -z $DUP_ZDLRA_ALIAS && $DUP_AUX_SGA_MB == 4096 ]]; ok
parse_args "${base[@]}"
[[ $DUP_AUX_CDB == DUPTEST && $DUP_AUX_BASE == /stage && $DUP_AUX_WALLET_ROOT == /wallet && -z $DUP_ZDLRA_ALIAS && $DUP_AUX_SGA_MB == 4096 && $DUP_AUX_PGA_MB == 1024 && $DUP_REDO_RESERVE_MB == 10240 ]]; ok
for value in PROD PRE 1AUX TOOLONG99 'AUX;id'; do
    reject parse_args "${names[@]}" --aux-cdb "$value" --aux-base /stage --aux-wallet-root /wallet
done
for value in relative/path '/stage/../other' '/stage/..' '/stage with spaces' "/stage'bad"; do
    reject parse_args "${names[@]}" --aux-cdb DUPTEST --aux-base "$value" --aux-wallet-root /wallet
    reject parse_args "${names[@]}" --aux-cdb DUPTEST --aux-base /stage --aux-wallet-root "$value"
done
for opt in --aux-cdb --aux-base --aux-wallet-root --zdlra-alias --aux-sga-mb --aux-pga-mb --redo-reserve-mb --restore-parallelism; do
    reject parse_args "${names[@]}" "$opt"
done
reject parse_args "${base[@]}" --aux-cdb OTHER
reject parse_args "${base[@]}" --aux-base /other
reject parse_args "${base[@]}" --aux-wallet-root /other
reject parse_args "${base[@]}" --zdlra-alias first --zdlra-alias second
for opt in --aux-sga-mb --aux-pga-mb --redo-reserve-mb --restore-parallelism; do
    for value in 0 -1 1.5 01 '1;id' 1000000000; do
        reject parse_args "${base[@]}" "$opt" "$value"
    done
    reject parse_args "${base[@]}" "$opt" 1024 "$opt" 2048
done
parse_args "${base[@]}" --aux-sga-mb 999999999 --aux-pga-mb 999999999 --redo-reserve-mb 999999999
[[ $DUP_AUX_SGA_MB == 999999999 && $DUP_AUX_PGA_MB == 999999999 && $DUP_REDO_RESERVE_MB == 999999999 ]]; ok
for value in 'ra alias' 'ra;id' 'ra"alias' $'ra\nalias'; do
    reject parse_args "${base[@]}" --zdlra-alias "$value"
done
parse_args "${base[@]}" --time '2024-02-29 10:20:05' --debug --purge-log 14
[[ $RECOVERY_TIME == '2024-02-29 10:20:05' && $DEBUG == 1 && $RETENTION == 14 ]]; ok
reject parse_args
reject parse_args "${base[@]}" --time
reject parse_args "${base[@]}" --time '2023-02-29 10:20:05'
reject parse_args "${base[@]}" --time '2024-04-31 10:20:05'
reject parse_args "${base[@]}" --time '2024-01-01 24:00:00'
reject parse_args "${base[@]}" --time '0000-01-01 10:00:00'
reject parse_args "${base[@]}" --time 2024-10-01 10:20:05
reject parse_args "${base[@]}" --purge-log 0
reject parse_args "${base[@]}" --purge-log -1
reject parse_args "${base[@]}" --purge-log '7;id'
reject parse_args "${base[@]}" --debug --debug
reject parse_args "${base[@]}" --unknown
reject parse_args "${base[@]}" --dry-run
reject parse_args "${base[@]}" --do-duplicate --do-duplicate
reject parse_args --source-cdb PROD --target-cdb PRE --source-pdb APP --target-pdb 'APP;drop' "${aux[@]}"
reject parse_args --source-cdb PROD --target-cdb PROD --source-pdb APP --target-pdb APPTEST "${aux[@]}"
bash "$root/dup_db.sh" --help > "$tmp/help"; grep -q 'UTC+02:00' "$tmp/help"; ok
reject bash "$root/dup_db.sh"
grep -q '^Usage: dup_db.sh' "$tmp/rejected.out"
if grep -q 'ERROR:' "$tmp/rejected.out"; then exit 1; fi; ok

parse_args "${base[@]}"
RUN=$tmp AUX=/stage/run ORACLE_HOME=/opt/oracle WALLET=/seps RA_ALIAS=ra.example:1521/service
SOURCE_DBID=1234567890 DUP_AUX_CDB=DUPTEST
printf '1\n2\n4\n5\n6\n7\n' > "$tmp/expected-ids"
printf '  set newname for tempfile %s to new;\n' 1 2 4 5 6 7 > "$tmp/expected-newnames"
# Exercise the one shared normalization boundary with realistic SQL*Plus rows,
# including the final row without a newline. Both RMAN time modes consume it.
for format in incident unpadded spaces tabs crlf blanks eof mixed; do
    case $format in
        incident) cp "$root/tests/fixtures/tempfile-ids-padded.txt" "$RUN/tempfiles.raw.out" ;;
        unpadded) cp "$tmp/expected-ids" "$RUN/tempfiles.raw.out" ;;
        spaces) printf '   %s   \n' 1 2 4 5 6 7 > "$RUN/tempfiles.raw.out" ;;
        tabs) printf '\t%s\t \n' 1 2 4 5 6 7 > "$RUN/tempfiles.raw.out" ;;
        crlf) printf '  %s \t\r\n' 1 2 4 5 6 7 > "$RUN/tempfiles.raw.out" ;;
        blanks) printf '\n \t\r\n%s\n\n' 1 2 4 5 6 7 > "$RUN/tempfiles.raw.out" ;;
        eof) printf '1\n2\n4\n5\n6\n7' > "$RUN/tempfiles.raw.out" ;;
        mixed) printf '\r\n 1 \t\r\n\t2\r\n\n4 \n 5\t\n\t6 \r\n 7\t' > "$RUN/tempfiles.raw.out" ;;
    esac
    cp "$RUN/tempfiles.raw.out" "$tmp/raw-before"
    normalize_tempfile_ids "$RUN/tempfiles.raw.out" "$RUN/tempfiles.normalized.out"
    cmp "$tmp/raw-before" "$RUN/tempfiles.raw.out"
    cmp "$tmp/expected-ids" "$RUN/tempfiles.normalized.out"; ok
    RECOVERY_TIME=''
    build_duplicate > "$tmp/latest.rman"
    if grep -qi 'until\|from active\|nofilenamecheck\|connect target\|configure ' "$tmp/latest.rman"; then exit 1; fi
    grep 'set newname for tempfile' "$tmp/latest.rman" > "$tmp/actual-newnames"
    cmp "$tmp/expected-newnames" "$tmp/actual-newnames"
    [[ $(grep -c 'allocate auxiliary channel' "$tmp/latest.rman") == 1 ]]
    grep -q 'allocate auxiliary channel ra1 device type sbt_tape' "$tmp/latest.rman"
    grep -q 'dbid 1234567890' "$tmp/latest.rman"; ok
    RECOVERY_TIME='2024-10-01 10:20:05'
    build_duplicate > "$tmp/timed.rman"
    grep 'set newname for tempfile' "$tmp/timed.rman" > "$tmp/actual-newnames"
    cmp "$tmp/expected-newnames" "$tmp/actual-newnames"
    grep -Fq "until time \"to_date('2024-10-01 10:20:05','YYYY-MM-DD HH24:MI:SS')\"" "$tmp/timed.rman"; ok
done
# Multiple channels use identical SBT credentials in both recovery-time modes.
parse_args "${base[@]}" --restore-parallelism 4
[[ $DUP_RESTORE_PARALLELISM == 4 ]]; ok
for recovery_time in '' '2024-10-01 10:20:05'; do
    RECOVERY_TIME=$recovery_time
    build_duplicate > "$tmp/parallel.rman"
    [[ $(grep -c 'allocate auxiliary channel' "$tmp/parallel.rman") == 4 ]]
    for channel in 1 2 3 4; do
        grep -Fxq "  allocate auxiliary channel ra$channel device type sbt_tape" "$tmp/parallel.rman"
    done
    [[ $(grep -Fc "SBT_LIBRARY=$ORACLE_HOME/lib/libra.so, ENV=(RA_WALLET='location=file:$WALLET credential_alias=$RA_ALIAS')" "$tmp/parallel.rman") == 4 ]]
    if grep -qi 'configure ' "$tmp/parallel.rman"; then exit 1; fi
    grep 'set newname for tempfile' "$tmp/parallel.rman" > "$tmp/actual-newnames"
    cmp "$tmp/expected-newnames" "$tmp/actual-newnames"
    if [[ -n $recovery_time ]]; then
        grep -Fq "until time" "$tmp/parallel.rman"
    elif grep -qi 'until' "$tmp/parallel.rman"; then exit 1; fi
    ok
done
parse_args "${base[@]}"
[[ $DUP_RESTORE_PARALLELISM == 1 ]]; ok
# Reject malformed complete inventories, never publish a valid prefix, and
# invalidate an earlier normalized result if a subsequent query is unusable.
for value in '' $' \t\r\n\t ' 0 00 -1 +1 1.0 '1 2' $'1\t2' '1|2' '1 2 3' abc 'FILE#' '----------' \
    'ORA-00942: fixture' 'SP2-0734: fixture' 'TNS-12541: fixture' 'SQL> select file#' $'1\n2\nbad' $'1\r2' "1;touch $tmp/executed"; do
    printf '%s' "$value" > "$RUN/tempfiles.raw.out"
    cp "$RUN/tempfiles.raw.out" "$tmp/raw-before"
    printf '1\n' > "$RUN/tempfiles.normalized.out"
    reject normalize_tempfile_ids "$RUN/tempfiles.raw.out" "$RUN/tempfiles.normalized.out"
    [[ ! -e $RUN/tempfiles.normalized.out && ! -e $tmp/executed ]]
    cmp "$tmp/raw-before" "$RUN/tempfiles.raw.out"; ok
done
reject normalize_tempfile_ids "$RUN/tempfiles.raw.out" "$RUN/tempfiles.raw.out"
reject normalize_tempfile_ids "$tmp/missing-ids" "$RUN/tempfiles.normalized.out"
reject build_duplicate
# IDs are checked as decimal text, without arithmetic conversion/size limits.
printf '999999999999999999999999999999999999999\n' > "$RUN/tempfiles.raw.out"
normalize_tempfile_ids "$RUN/tempfiles.raw.out" "$RUN/tempfiles.normalized.out"
cmp "$RUN/tempfiles.raw.out" "$RUN/tempfiles.normalized.out"; ok
TARGET_DEST=+DATA
build_plug > "$tmp/plug.sql"
grep -Fq "create pluggable database APPTEST using '/stage/run/pdb.xml' move create_file_dest='+DATA' standbys=none;" "$tmp/plug.sql"
grep -Fq 'identified by external store;' "$tmp/plug.sql"
if grep -Eqi 'drop database|create database|nocopy|identified by "' "$tmp/plug.sql"; then exit 1; fi; ok

# Passwords containing shell glob/replacement characters must be literal matches.
# shellcheck disable=SC2016
VPC_PASSWORD='a*b[1]&/$secret\value'
printf 'ORA-01017: %s\n' "$VPC_PASSWORD" | redact > "$tmp/redacted"
grep -Fq 'ORA-01017: [REDACTED]' "$tmp/redacted"
if grep -Fq "$VPC_PASSWORD" "$tmp/redacted"; then exit 1; fi; ok

# Fake clients deliberately echo stdin, to exercise even worst-case error output.
# Their argv is checked separately; no Oracle binary is invoked.
ORACLE_HOME="$tmp/oracle" LOG="$tmp/log" DEBUG=0 TARGET_SID=PRE1 PHASE=offline
mkdir -p "$ORACLE_HOME/bin"
cat > "$ORACLE_HOME/bin/sqlplus" <<'EOF'
#!/usr/bin/env bash
[[ $# == 3 && $1 == -L && $2 == -s && $3 == /nolog ]] || exit 99
cat
printf 'ORA-28365: wallet is not open\n'
exit 0
EOF
cat > "$ORACLE_HOME/bin/rman" <<'EOF'
#!/usr/bin/env bash
[[ $# == 0 ]] || exit 99
cat
printf 'RMAN-00569: ERROR MESSAGE STACK FOLLOWS\n'
exit 0
EOF
chmod +x "$ORACLE_HOME/bin/sqlplus" "$ORACLE_HOME/bin/rman"
VPC_USER=VPC
reject sql CATALOG "$tmp/sql-error" <<< 'select 1 from dual;'
grep -Fq 'ORA-28365: wallet is not open' "$tmp/sql-error"
if grep -Fq "$VPC_PASSWORD" "$tmp/sql-error"; then exit 1; fi
if grep -Fq "$VPC_PASSWORD" "$LOG"; then exit 1; fi; ok
# A standby can reuse the primary SID. Forced remote verification must still
# take SSH; this fake captures the request without opening any connection.
mkdir -p "$tmp/fake-bin"
export OFFLINE_SSH_MARKER="$tmp/ssh-used"
cat > "$tmp/fake-bin/ssh" <<'EOF'
#!/usr/bin/env bash
[[ $* == *oracle@standby.example* && $* == *"ORACLE_SID='PRE1'"* ]] || exit 99
touch "$OFFLINE_SSH_MARKER"
cat >/dev/null
printf 'ORA-28365: offline forced SSH fixture\n'
EOF
chmod +x "$tmp/fake-bin/ssh"
PATH="$tmp/fake-bin:$PATH" reject sql "$TARGET_SID" "$tmp/remote-error" standby.example 1 <<< 'select 1 from dual;'
[[ -f $OFFLINE_SSH_MARKER ]]; ok
reject rman DUPTEST duplicate "$tmp/timed.rman" "$tmp/rman-error"
grep -Fq 'RMAN-00569' "$tmp/rman-error"
if grep -Fq "$VPC_PASSWORD" "$tmp/rman-error"; then exit 1; fi; ok
unset VPC_PASSWORD

open_sql 'READ WRITE' NO > "$tmp/state"
grep -Fxq 'alter pluggable database APPTEST open READ WRITE;' "$tmp/state"; ok
open_sql 'OPEN READ ONLY' YES > "$tmp/state"
grep -Fxq 'alter pluggable database APPTEST open READ ONLY restricted;' "$tmp/state"; ok
[[ -z $(open_sql MOUNTED NO) ]]; ok
reject open_sql MIGRATE NO
reject open_sql 'READ WRITE' UNKNOWN
printf '1\n2\n' > "$tmp/ambiguous"
reject one_line "$tmp/ambiguous"
printf '\r\n\t  0 \t\r\n\n' > "$tmp/scalar"
one_line "$tmp/scalar"
[[ $RESULT == 0 ]]; ok
printf '\t  12345 \t\r\n' > "$tmp/scalar"
one_line "$tmp/scalar"
[[ $RESULT == 12345 ]]; ok
reject safe_path '/tmp/a/../b'
reject safe_path "/tmp/a'bad"
reject load_environment "$tmp/no-such-target.env"
(
    unset DB_UNIQUE_NAME
    printf 'ORACLE_UNQNAME=PREM1\n' > "$tmp/target.env"
    load_environment "$tmp/target.env"
    [[ $DB_UNIQUE_NAME == PREM1 ]]
    DB_UNIQUE_NAME=''
    load_environment "$tmp/target.env"
    [[ $DB_UNIQUE_NAME == PREM1 ]]
    DB_UNIQUE_NAME=EXPLICIT
    load_environment "$tmp/target.env"
    [[ $DB_UNIQUE_NAME == EXPLICIT ]]
); ok
DB_UNIQUE_NAME=''
printf 'DB_UNIQUE_NAME=PREM1\n' > "$tmp/target.env"
load_environment "$tmp/target.env"
[[ $DB_UNIQUE_NAME == PREM1 ]]; ok
# A legacy refresh block in the standard environment must not replace CLI settings.
(
    parse_args "${base[@]}" --zdlra-alias cli.example:1521/service \
        --aux-sga-mb 8192 --aux-pga-mb 2048 --redo-reserve-mb 20480 --restore-parallelism 4
    cat > "$tmp/legacy.env" <<'EOF'
ORACLE_HOME=/legacy/oracle
ORACLE_SID=PRE1
DB_UNIQUE_NAME=PREM1
export DUP_AUX_CDB=LEGACY
export DUP_AUX_BASE=/legacy/stage
export DUP_AUX_WALLET_ROOT=/legacy/wallet
export DUP_ZDLRA_ALIAS=legacy_alias
export DUP_AUX_SGA_MB=1
export DUP_AUX_PGA_MB=2
export DUP_REDO_RESERVE_MB=3
export DUP_RESTORE_PARALLELISM=9
EOF
    load_environment "$tmp/legacy.env"
    [[ $DUP_RESTORE_PARALLELISM == 4 ]]
    [[ $ORACLE_HOME == /legacy/oracle && $ORACLE_SID == PRE1 && $DB_UNIQUE_NAME == PREM1 ]]
    [[ $DUP_AUX_CDB == DUPTEST && $DUP_AUX_BASE == /stage && $DUP_AUX_WALLET_ROOT == /wallet ]]
    [[ $DUP_ZDLRA_ALIAS == cli.example:1521/service && $DUP_AUX_SGA_MB == 8192 && $DUP_AUX_PGA_MB == 2048 && $DUP_REDO_RESERVE_MB == 20480 ]]
); ok
# shellcheck disable=SC2016
printf 'PRE|PREM1|42|PRIMARY|YES|READ WRITE\nCONTAINER|CDB$ROOT\n' > "$tmp/identity"
validate_target_identity "$tmp/identity"
[[ $TARGET_DBID == 42 ]]; ok
sed 's/PRIMARY/PHYSICAL STANDBY/' "$tmp/identity" > "$tmp/identity.bad"
reject validate_target_identity "$tmp/identity.bad"
sed 's/PREM1/OTHERM1/' "$tmp/identity" > "$tmp/identity.bad"
reject validate_target_identity "$tmp/identity.bad"
# shellcheck disable=SC2016
sed 's/CDB\$ROOT/APPTEST/' "$tmp/identity" > "$tmp/identity.bad"
reject validate_target_identity "$tmp/identity.bad"

printf 'Passed %s focused offline checks. No database operations performed.\n' "$checks"
bash "$root/tests/pdb.sh"
bash "$root/tests/services.sh"
bash "$root/tests/broker.sh"
bash "$root/tests/topology.sh"
bash "$root/tests/dry-run.sh"
bash "$root/tests/asm.sh"
bash "$root/tests/wallet.sh"
bash "$root/tests/readonly.sh"
