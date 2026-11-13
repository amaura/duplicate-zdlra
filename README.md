# ZDLRA PDB refresh

`dup_db.sh` refreshes one preproduction PDB from Oracle 19c production backups in ZDLRA. It preserves the target CDB. It connects to the recovery catalog, a temporary local auxiliary, the target RAC instances, and the verified target's physical standbys for read-only checks. Broker member/apply commands connect locally to the verified target primary; the fixed read-only no-configuration probe also checks each verified primary RAC node; it never connects to production.

The script first duplicates the whole source CDB, including root and seed, into an isolated ASM namespace using dynamically discovered target disk groups. After recovery, encrypted block validation, removal of copied application services, and a plug compatibility check, it stops apply on the target's physical standbys through Oracle 19c Data Guard Broker, verifies actual apply stop and standby PDB closure, then stops relevant target services, drops the old target PDB when present and plugs the recovered PDB using **`MOVE`** with `CREATE_FILE_DEST` and `STANDBYS=NONE`. The recovered PDB's files move into target storage; remaining auxiliary database and working files stay available for diagnosis. Its temporary wallet copy is removed only when unused or after confirmed auxiliary shutdown.

The implementation is complete for offline review. **It has not been executed against ExaCC, ZDLRA, RAC, Data Guard, or Thales.** A test refresh on the intended topology is still required.

## Usage

```bash
./dup_db.sh --source-cdb PROD --target-cdb PRE \
  --source-pdb APP --target-pdb APPTEST \
  --aux-cdb RFRAUX --aux-base /u02/zdlra_refresh \
  --time "2024-10-01 10:20:05" --debug --purge-log 7 --do-duplicate
```

Dry run is the default. Add `--do-duplicate`, as above, to perform the actual duplication and target PDB replacement or initial creation. The former `--dry-run` option is no longer accepted.

The four source/target names and `--aux-cdb`, `--aux-base` are required, including for dry runs. `--aux-wallet-root` is optional: it specifies an existing parent directory for a fresh private wallet copy, never a wallet to reuse. CDB names mean `DB_NAME`, not `DB_UNIQUE_NAME`. Names are normalized to uppercase; the target environment file is located using that case. Simple letters, digits and underscores are accepted, starting with a letter (CDB/auxiliary: 8 characters; PDB: 30). Unknown/repeated options, missing values, invalid dates, unsafe paths/aliases, and nonpositive numeric values fail before Oracle access.

All timestamps are interpreted as fixed **UTC+02:00**, including winter dates. There is no DST conversion. Source catalog wall-clock timestamps must follow the same convention. `--time` is passed unchanged to RMAN `UNTIL TIME`; failure never causes a retry at an earlier point. Without `--time`, no `UNTIL` is generated: RMAN selects its recoverable endpoint from available backups/redo. Missing redo causes failure before cutover.

`--debug` displays redacted client output; it does not enable shell tracing. `--help` does not require Oracle.

## Dry run

```bash
./dup_db.sh --source-cdb PROD --target-cdb PRE \
  --source-pdb APP --target-pdb APPTEST \
  --aux-cdb RFRAUX --aux-base /u02/zdlra_refresh \
  --time "2024-10-01 10:20:05"
```

The default dry run checks the required local environment, Oracle clients and auxiliary configuration, validates the target CDB identity, discovers its `WALLET_ROOT` and ASM settings, reports whether the target PDB exists and its observed instance/open states, and authenticates to the ZDLRA recovery catalog using SEPS. It creates and verifies a real private copy of the target wallet tree except its top-level `tls` entry, then removes that unused copy. Copy failures fail the dry run. Both required RAC nodes are discovered from CDB metadata and checked independently. An absent target PDB is a successful initial-creation discovery; normal duplication can create it in the verified target CDB.

It resolves source DBID/incarnation, checks available SBT datafile and controlfile metadata, and reports RAC redo inventory and a candidate restore time range in fixed UTC+02:00. The lower bound is the latest of the earliest full/level-0 checkpoints for inventoried files; the exclusive upper bound is the earliest redo endpoint across inventoried threads. A supplied `--time` must lie strictly between these bounds. Missing inventory, connection failures and out-of-range times return nonzero.

These metadata bounds may contain gaps and do not prove complete file coverage, source PDB presence at that time, SBT media readability or continuous redo. Dry run connects to the catalog endpoint; it does not test an SBT restore. A normal auxiliary recovery remains the definitive recovery check. It skips broker, service, ASM capacity and plug compatibility checks.

Dry run creates private evidence logs and a temporary wallet working directory, and takes/releases the local target lock. It does not purge existing logs, create/start an auxiliary instance, restore data, change PDBs/services or change standby apply. The trusted target environment file is sourced as in normal mode and must have no side effects. Inspect `run.log`, `target-settings.out`, `auxiliary-wallet-path`, `auxiliary-wallet-status`, `target-rac.before`, `target-pdb-state`, `pdb-inventory.before`, `pdb.before`, `restore-range.out` and `redo-inventory.out` in the reported run directory. A successful dry run ends in phase `dry-run-complete`; it does not create a normal refresh completion marker.

## Read-only diagnostic collection

For manual testing in the offline deployment, keep `test_readonly.sh` beside `dup_db.sh` and run it as `oracle` on the designated target primary RAC node:

```bash
bash ./test_readonly.sh --source-cdb PROD --target-cdb PRE \
  --source-pdb APP --target-pdb APPTEST \
  --aux-cdb RFRAUX --aux-base /u02/zdlra_refresh \
  --time "2024-10-01 10:20:05" \
  --output ./readonly_report.txt
```

Replace the names, paths and recovery time with the deployment values. Omit `--time` to inspect the latest available backup range. Add `--zdlra-alias` when the SEPS wallet has multiple entries. No internet access or extra Python packages are needed. Bash 4+, the existing Oracle tools and Linux utilities, and GNU `timeout` (or `gtimeout`) are required. The default deadline is 60 seconds per client command; use `--timeout 120` for slower connections.

The collector checks the local environment/client versions, verified target primary identity and settings, creation/verification/cleanup of a private target wallet copy, auxiliary name occupancy, target RAC/PDB/saved states, per-node HSM status and SQL patches, dynamic ASM data/recovery destination discovery and combined auxiliary/target capacity, service configuration and running placement, target broker membership, each discovered standby's identity/RAC/apply-process count/old-PDB closure, SEPS catalog authentication, source identity/incarnation, SBT backup/redo/tempfile metadata, candidate recovery time range and estimated usable storage. Independent checks continue after a failure. Unsafe or unavailable discovery causes dependent connections to be skipped, with the reason recorded. An open standby PDB is reported as a failed prerequisite; the collector never closes it or stops apply.

All database statements are `SELECT` queries. Client wrappers reject mutating SQL, service and broker requests. RMAN is never invoked. The script sources the same trusted target environment file, which must have no side effects; installed SQL*Plus profiles must also be safe for diagnostic connections. It creates no refresh lock, starts no auxiliary, and changes no PDBs, services or Data Guard state. It writes the new report, private temporary evidence, and a private wallet copy outside the evidence directory. The wallet copy is verified and removed; only its path and lifecycle status enter the report. Other temporary evidence is included in the report and then removed. SSH requires existing trusted host keys and does not update them.

The report contains labelled `PASS`, `FAIL` and `SKIP` results, query text/output, client errors, script fingerprints, a summary, and a list of checks that remain untested. Catalog passwords remain in memory/stdin and are redacted from retained client output; environment-file output and wallet contents are not saved. The report is created with owner-only permissions. Without `--output`, its timestamped filename is printed at the end. Existing output files are refused. Exit status is `0` when collected checks pass, `1` for failed checks/invalid arguments, or `2` for collector setup failure; interrupted runs retain a partial report. Return that single report file for troubleshooting, including when the run reports failures.

For tempfile troubleshooting, compare `tempfiles.raw.txt` with `tempfiles.normalized.txt` in the report. Both scripts trim surrounding SQL*Plus formatting whitespace (spaces, tabs and CRLF), skip incidental blank rows, and require one positive decimal file ID per remaining row. Interior whitespace, zero IDs, extra columns, headings and client error text fail discovery; an empty/blank-only result also fails. Raw output is retained unchanged after credential redaction, and a rejected inventory has no normalized consumer artifact. The collector similarly retains `temp-size.raw.txt` and uses the validated `temp-size.normalized.txt` for capacity arithmetic. Size zero is valid; failed size queries skip dependent capacity checks, and insufficient ASM space still fails.

A successful report does **not** establish restore/cutover readiness. SBT media reads, complete backup coverage/redo continuity, actual recovery, historical HSM key access/key import, encrypted block validation, plug compatibility, service restoration and application validation still need later operational tests. This collector has been verified with offline fixtures only; it has not been run against the deployment. Run `bash tests/check.sh` locally to include its failure-continuation, redaction, read-only guard and report-writing fixtures in the offline checks.

## Required setup

The deployment must use **administrator-managed Oracle 19c RAC**; policy-managed topology support and generic topology detection are out of scope. Run as `oracle` on one **designated primary RAC node** with Bash 4+, matching Oracle 19c SQL*Plus/RMAN/mkstore/srvctl tools (DGMGRL is required when broker is enabled), and the usual Linux utilities. Both destination instances and every broker-listed standby instance must be online. Their homes/RUs, source database format and SQL patches must be compatible; this script does not perform upgrades or `datapatch`.

The script reads the standard ExaCC `/home/oracle/<TARGET_DB_NAME>.env` for `ORACLE_HOME`, local `ORACLE_SID`, and either `DB_UNIQUE_NAME` or `ORACLE_UNQNAME`. **Leave this file unchanged; pass all refresh-specific configuration as command-line arguments.** The script uses `ORACLE_UNQNAME` when `DB_UNIQUE_NAME` is unset or empty; an explicit `DB_UNIQUE_NAME` takes precedence. The trusted file must be quiet and must not enable tracing or print secrets. The same file must exist on the second node. Passwordless, host-key-verified `ssh oracle@<host_name from GV$INSTANCE>` is required for instance-local SQL*Plus operations. Saved PDB state is restored on each instance through those sessions.

On each target standby node, the same environment-file path must load that node's Oracle home without prompts or side effects. Passwordless, host-key-verified SSH to the broker's `HostName` is required. The supported setup uses `ORACLE_SID = INSTANCE_NAME`; the script overrides the SID explicitly and verifies it, including when sites reuse SID names. It discovers standby unique names, instance names and hosts from the target broker, rather than deriving standby names from the production source. No standby-specific arguments or database password are required.

The unique name must contain exactly one `M1` or `M2`. For example, target `PREM1` selects source unique name `PRODM1`. The script checks that identity in `RC_SITE`, resolves the DBID and the applicable current/ancestor incarnation, and refuses ambiguous results. Orphan incarnation selection is outside scope. Source and target must have different `DB_NAME` and DBID.

Pass the following refresh parameters when invoking the script (example paths must be replaced for the deployment):

| Argument | Required/default | Purpose |
| --- | --- | --- |
| `--aux-cdb RFRAUX` | Required | Dedicated, unused auxiliary `DB_NAME`/`DB_UNIQUE_NAME`/`ORACLE_SID`, up to 8 characters. |
| `--aux-base /u02/zdlra_refresh` | Required | Existing small filesystem work directory, writable by `oracle`; local or ACFS. Database files use discovered ASM groups. |
| `--aux-wallet-root /u02/wallet_copies` | Optional | Existing writable parent for a fresh private copy of target `WALLET_ROOT`. Defaults to the run's auxiliary work directory; dry run/collector default to `--aux-base`. Existing parent contents are preserved. |
| `--zdlra-alias ra-host.example:1521/ra_service` | Auto-select the sole SEPS credential | Exact catalog connect string to select when the SEPS wallet contains multiple credentials. |
| `--aux-sga-mb 4096` | 4.00 GiB | Auxiliary SGA size. |
| `--aux-pga-mb 1024` | 1.00 GiB | Auxiliary PGA target. |
| `--redo-reserve-mb 10240` | 10.00 GiB | Additional auxiliary redo space reserve. |

Paths must be absolute and contain only letters, digits, underscores, dots, slashes and hyphens, without parent traversal. Aliases accept the same characters plus colons. Capacity output uses GiB (1 GiB = 1024 MiB), rounded to two decimal places. The `--*-mb` options still accept MiB; calculations and Oracle settings retain MiB precision. Capacity values must be positive integers of at most nine digits. Legacy `DUP_*` settings in the calling environment or target `.env` do not supply or override these arguments/defaults.

Provision the auxiliary SID exclusively for this operation, outside Clusterware and any listener service. `STARTUP` deliberately omits `FORCE`, so an already running instance is never shut down. RMAN uses local OS authentication; no auxiliary password file or network connection is used. The auxiliary's dynamic registration points at an unused IPC address, remote registration is empty, and jobs/AQ time monitoring are disabled. Its SPFILE is not restored from production. Working files (PFILE, unplug XML, audit and diagnostics) are placed in a fresh directory under `--aux-base`. Auxiliary database files use ASM Oracle Managed Files in a unique per-run `DB_UNIQUE_NAME` namespace; their paths are verified before opening. The auxiliary SID/DB_NAME remains `--aux-cdb`.

The target must configure ASM `DB_CREATE_FILE_DEST` and `DB_RECOVERY_FILE_DEST`. The script discovers their disk-group roots dynamically, even when the configured paths contain target-specific subdirectories. No disk-group names or ASM destination arguments are hardcoded. Missing or non-ASM settings abort discovery. Auxiliary datafiles, tempfiles, control files and online redo use the data group; archived redo uses the recovery group. `--aux-base` needs only filesystem working space, not restored-database capacity.

Space checks estimate the catalogued full source CDB plus tempfiles and 25% headroom for both auxiliary and destination together in the data group, plus the auxiliary redo reserve. This conservative peak estimate also covers `MOVE` implementations that copy files before deleting the originals. When recovery uses a separate group, that group must also have the redo reserve available. When the groups coincide, the combined requirement is checked once. Increase that reserve for large recovery windows; these checks are estimates, not storage reservations. Existing target space is not counted as reclaimable before cutover.

ZDLRA access follows [notes_zdlra.md](notes_zdlra.md):

- SEPS auto-login wallet: `/var/opt/oracle/dbaas_acfs/<TARGET_DB_NAME>/wallet_root/server_seps`.
- The chosen wallet entry must identify the correct ZDLRA catalog and shared VPC user. If several entries exist, select the exact alias with `--zdlra-alias`.
- `mkstore -listCredential` and `-viewEntry` must work unattended. The password entry index is discovered; it is not assumed to be `2`.
- `$ORACLE_HOME/lib/libra.so` must be installed and usable. The script allocates an auxiliary SBT channel using `RA_WALLET`; it does not change persistent RMAN configuration.
- VPC privileges must expose the source's catalog views and all required backup pieces/redo. The preliminary inventory checks are followed by real auxiliary recovery, which proves the required backup/redo chain before the old PDB is touched.

## TDE and service scope

This implementation assumes the existing **united-mode HSM integration**, `WALLET_ROOT`, and HSM-containing `TDE_CONFIGURATION`. The auxiliary and both destination nodes need access to every required historical production key. The script discovers `wallet_root` from the verified target primary and copies its **directory tree except the top-level `tls` entry**, including `tde`, `tde_seps`, `server_seps` when present, hidden entries and other provider subdirectories. A separately provisioned auxiliary wallet is unnecessary. The source must contain readable, nonempty `tde/cwallet.sso` and `tde_seps/cwallet.sso`; every included file/directory must be readable/traversable. Vendor libraries, HSM connectivity and persistent provider configuration still require the established setup and are not changed by copying credentials.

Each run creates `aux_wallet_<SID>_<random>/wallet_root` under its selected filesystem parent. The container and copied directories are owner-only (0700); copied files retain their owner execute bits, gain owner read/write access and lose group/other access. Files are copied independently and compared byte for byte; no source bytes or permissions are changed and no existing destination wallet is reused. The top-level `tls` entry is excluded from validation, copying and inventory verification, whether it is a directory or a symlink (including a broken link); it is never followed or copied. **All symlinks elsewhere inside the tree are rejected**, including internal, external and broken links; special files and unreadable entries also fail. The discovered root and parent may use directory aliases, which are resolved physically; copying into the target tree or report/evidence space is refused. Operators must provide a complete regular-file tree for the included entries when links are encountered. Keep the source stable during collection/copying.

The auxiliary PFILE references the new private root. Catalog authentication and `RA_WALLET` continue to use the established target `server_seps` credential location, even when its files are also present in the full-tree copy. Only paths and creation/lifecycle status are logged; wallet contents are excluded from reports. Normal duplication copies before auxiliary startup; dry run and `test_readonly.sh` also make and verify real copies, then remove them without starting an auxiliary. After a failure before startup, partial unused copies are removed. Once startup is attempted, failures retain the copy unless successful auxiliary shutdown is explicitly confirmed. Evidence includes its exact path and manual cleanup command; confirm the auxiliary SID is stopped before using that command. SIGKILL or a host crash can leave a private copy requiring manual cleanup.

The target additionally needs the established `IDENTIFIED BY EXTERNAL STORE` credentials in `WALLET_ROOT/tde_seps/cwallet.sso` for the PDB's HSM key import. The import uses the literal HSM provider token (`WITH SECRET "HSM" FROM 'HSM'`), not a stored password in the script. **Validate this import on the installed 19c RU and Thales integration before use.** Auto-login alone is not treated as proof that the post-plug import will work. This is a cutover-only check; target key import and target encrypted block validation occur after the old PDB has been dropped.

External keystores through PKCS#11 are supported for Oracle Database 19c on ExaCC, as documented in [Manage Keys Using an External Keystore](https://docs.oracle.com/en/engineered-systems/exadata-cloud-at-customer/ecccm/manage-and-store-master-encryption-keys-on-an-external-hsm.html). This product-specific guidance applies to this deployment. Configure the vendor PKCS#11 library and connectivity on each participating VM; Oracle notes that cloud automation does not precheck that connection. The CDB and its PDBs must use the same keystore solution, although PDB keys may differ. The script preserves that configuration and validates key access through database operations. The [Oracle HSM PDB key-import workflow](https://docs.oracle.com/database/121/ASOAG/using-transparent-data-encryption-with-other-oracle-features.htm) describes the import command used here.

On TDE failure, the redacted Oracle/RMAN stack, failed phase, and local instance are retained. Copying target credentials does not establish historical production key access. The diagnostic advises checking HSM/provider access through the established operator procedure, distinct from **ZDLRA SEPS** catalog authentication. Wallet status and RMAN logical block validation check tablespace encryption access; application tests are still required for encrypted columns and application behavior.

Administrator-managed RAC is a deployment assumption. Services must have uniform enablement and parseable 19c English output, including the expected `Preferred instances:` field. A nonempty `Server pool:` can appear alongside that field in valid administrator-managed output; it is preserved verbatim and is not a topology test or a reason for rejection. Unsupported global services, per-instance enablement, missing PDB association, unmanaged SQL services, disabled-but-running services, and unrecognized or inconsistent running/open states fail before cutover. The script preserves **the existing Clusterware resources**: full `srvctl config service -verbose` snapshots retain placement, roles, policy, edition, TAF/AC and other attributes without translating a subset into `add service` commands. Resources are disabled/stopped during cutover, reconciled with the target PDB, and restored to their captured enablement and running instances. Exact configuration/status comparisons detect any mismatch. Copied production application services are deleted in the unmanaged auxiliary before unplugging.

Use an application maintenance window and freeze external service/PDB changes for the run. The script checks for changes during preparation but cannot prevent an operator changing state concurrently. Application-specific jobs, credentials, database links, masking and external integrations require the application's normal refresh procedure; they are not rewritten here.

## Optional target PDB and initial state

The target CDB must already exist. The requested target PDB may be **PRESENT** on both verified RAC instances with one consistent GUID, or **ABSENT** after a successful empty inventory query and independent identity/HSM checks on both nodes. Partial presence, SQL errors, malformed rows, missing nodes or inconsistent GUIDs fail. The collector reports `target PDB absent; initial creation path`, lists the current PDB inventory, and continues service, standby, storage and catalog checks.

For PRESENT, the original per-instance open/restricted/saved policy and complete Clusterware service resources are preserved. For ABSENT, there is no old GUID or old-state snapshot to restore: no old-PDB close or DROP is generated or executed. The same auxiliary recovery, compatibility, OMF/ASM `MOVE`, `STANDBYS=NONE`, key import and encrypted-data checks apply. The initial policy is **READ WRITE, unrestricted, on both verified target RAC instances, with OPEN/unrestricted state saved on both**. `pdb.expected` and `saved.expected` hold this policy; final queries must match it. Relevant stopped enabled/disabled Clusterware resources are preserved and restored without inventing application service names. A running service associated with an absent PDB is an inconsistency and aborts.

Presence and GUID are frozen during preparation, checked before service changes and again immediately before DROP/create; continued absence is checked just before CREATE. A name that appears, or an old PDB that disappears/changes GUID, aborts instead of switching paths. RAC instance inventory is checked independently at cutover. Keep external PDB/service changes frozen throughout the run.

PDB absence does not bypass configured standby discovery or actual apply-stop verification. An absent primary PDB requires zero same-name PDB rows on **every** discovered standby instance; a stale row, conflicting identity or inaccessible inventory fails. There is no fictitious matching old GUID. Broker/apply evidence records `ABSENT` with no old open mode, and the separate standby-refresh procedure still owns apply resumption.

## Broker apply gate and standby PDB prerequisite

Topology discovery records **NONE**, **MANAGED**, or **UNKNOWN/unsupported**. Both verified target RAC instances must agree on their broker setting, resolved membership roles/parents, and evidence availability. No-standby support has three evidence paths:

- A complete healthy enabled broker configuration with its sole primary matching the verified target and no physical standby. SQL membership, transport and persistent settings must not identify an omitted physical standby, unsupported replication or contradictory endpoint role.
- Broker disabled on both instances, with complete standalone runtime/SPFILE metadata and no configured standby relationship or FAL hint. This path does not require or invoke DGMGRL.
- Broker enabled but unconfigured, with the same standalone metadata and the exact documented ORA-16532 no-configuration response from a successfully completed fixed read-only SHOW/EXIT probe on **each verified RAC host**. Other broker/client/SSH errors, timeouts or extra error text remain UNKNOWN.

Discovery queries each node identity/root, all relevant `V$SYSTEM_PARAMETER` values, specified `V$SPPARAMETER` entries (including SID/ordinal), all 31 `V$ARCHIVE_DEST` destinations joined to `V$ARCHIVE_DEST_STATUS`, and `V$DATAGUARD_CONFIG` membership/parent roles. Explicit SQL nullness flags establish runtime SPFILE/FAL presence, and a separate count identifies non-NULL specified persistent FAL values; display sentinels do not decide absence. Runtime and persistent `LOG_ARCHIVE_CONFIG`, FAL hints, destinations and destination states are inspected even when transport is deferred, disabled, alternate or reset. A remote `TARGET=STANDBY` does not prove a physical standby: explicit database role/type evidence distinguishes backup appliances. Persistent SERVICE settings require a resolved DB_UNIQUE_NAME, or an identical effective runtime definition positively typed BACKUP APPLIANCE. Endpoint spelling is never used.

These views describe configured relationships; they cannot discover a completely deconfigured remote database. Archive destination status is runtime-only and disappears on shutdown. A missing SPFILE, truncated/ambiguous persistent value, unknown SID, unresolved endpoint/member/parent, cyclic/unsupported parent chain, configured unmanaged standby or other unsupported replication blocks standalone cutover as UNKNOWN. No generic override or automatic broker/transport configuration is provided. Healthy broker-only proof remains available when standalone SPFILE proof is unavailable, subject to all observable contradiction checks.

For MANAGED targets, the complete healthy enabled broker configuration must identify exactly one primary matching the verified target. Physical members are selected by DB_UNIQUE_NAME; far sync and backup-appliance roles remain distinct in the frozen inventory and are not apply targets. Far sync without complete physical standby membership, logical/snapshot standbys, disabled/unhealthy members and incomplete discovery abort. The existing standby identity, instance coverage, applicable PDB closure and actual apply-stop gates remain mandatory.

The topology/configuration snapshot is revalidated before service changes, before DROP and again before CREATE. A newly configured standby or other relationship aborts. Only transient destination status is excluded from the freeze comparison. Raw per-node metadata, resolved roles and classification are retained as `dg.<stage>.<instance>.metadata`, `dg.<stage>.resolved`, `dg.<stage>.mode` and `dg.<stage>.topology`. Collector reports identify standby-only checks as NOT APPLICABLE for established NONE; errors remain FAIL/UNKNOWN. No-standby completion/failure messages do not request an unrelated standby refresh or apply resumption.

**APPLY-OFF does not close an open standby PDB.** For a PRESENT target PDB, before invoking the script, the operator must establish closure independently on every configured target standby RAC instance. Use local OS-authenticated SQL*Plus in `CDB$ROOT` on each verified standby node. Check `V$DATABASE` first: `DB_NAME` and DBID must match the target primary, `DB_UNIQUE_NAME` must match its discovered standby, and the role must be `PHYSICAL STANDBY`. Obtain the old PDB's GUID from the target primary and compare it with the standby inventory:

```sql
-- Read-only identity check; use only the target primary/its verified standbys.
select name, db_unique_name, dbid, database_role from v$database;
select i.instance_name, p.name, rawtohex(p.guid) pdb_guid, p.open_mode
from gv$pdbs p join gv$instance i on i.inst_id=p.inst_id
where p.name='APPTEST' order by i.instance_name;

-- On EACH verified standby instance where this PDB is open, in CDB$ROOT:
alter pluggable database APPTEST close immediate;
```

Replace `APPTEST` with the requested target PDB. Skip the close command for an instance already reporting `MOUNTED`. Confirm the final inventory shows the matching old PDB GUID and `MOUNTED` on **every** broker-listed standby instance. A mounted standby CDB also satisfies closure when those PDB rows are present. Freeze standby opens, instance restarts, role changes and external apply management throughout the maintenance window; saved-state reopening on restart would invalidate this prerequisite. The script does not close standby PDBs or change their saved state. For PRESENT, missing PDB rows, inaccessible/offline instances, a GUID mismatch or an open PDB abort the run, including during preflight. For ABSENT, the independent node/identity/apply checks still run and any same-name standby PDB row is a conflict; no standby close is requested.

After auxiliary preparation and target freeze checks succeed, immediately before stopping target services, the script rediscovers broker membership and verifies it and the old target PDB GUID are unchanged. It captures the states before cutover, issues `EDIT DATABASE '<standby_db_unique_name>' SET STATE='APPLY-OFF';` for each physical standby, including an already stopped one, and rereads its broker intended state. Read-only SQL on **each** configured RAC instance checks identity, the complete online instance inventory, old-PDB closure and `V$DATAGUARD_PROCESS` recovery-process counts. The count includes `MRP0` and recovery roles (including multi-instance recovery workers); waiting/idle recovery processes still prevent acceptance. Every instance must report zero and the broker must report `APPLY-OFF`. A zero DGMGRL exit status alone is insufficient. Membership, apply and closure checks repeat immediately before `DROP`; any failure prevents the drop. No redo transport, protection mode or Fast-Start Failover setting is automatically changed; a broker refusal requires operator investigation.

## Logs and failure recovery

Each run has a private directory under `/home/oracle/duplicate_logs/dup_<source>_to_<target>_<timestamp>_*`. It contains the redacted log, identity/configuration and RAC-state snapshots, RMAN commands, `drop-old.sql` for PRESENT only, `plug.sql`, recovery evidence, and `auxiliary-path`. Broker evidence includes `dg.preflight.*` and `dg.precutover.*` membership, `dg.<standby>.*` broker/SQL observations and stop output, and `dg.<standby>.result`. `dg-states.tsv` is pipe-delimited: stage, DB_UNIQUE_NAME, broker intended state, instance, recovery-process count, old-PDB GUID, open mode. `preflight` records original states, `before` records states immediately before stopping apply, and `after`/`predrop` record resulting states. Rows with `-` contain broker-only observations; `UNKNOWN` in a result file means verification did not complete, not that apply is running. Catalog passwords remain in memory and stdin pipes, never process arguments or retained command files. Double quotes/line breaks in the catalog password and unusual alias syntax are rejected rather than interpolated unsafely.

Normal duplication retains the original tempfile ID query in `tempfiles.raw.out`; `tempfiles.normalized.out` supplies the exact IDs for `duplicate.rman` tempfile remapping. A numeric parsing failure blocks auxiliary startup. `temp-size.out` retains the refresh size query; its validated, trimmed scalar is used immediately for capacity. Source identity, incarnation, redo inventory and requested recovery-time predicates remain enforced.

`--purge-log` defaults to seven days. Only `run.log` from runs marked `complete` and older than the retention interval is removed. Incomplete logs, snapshots, generated recovery commands and auxiliary files are retained for manual management.

The per-target directory lock is **local to the designated execution node**. It is not a distributed RAC lock. Do not start this script on another node. Trappable errors/signals release the lock; after a crash or `SIGKILL`, inspect `owner`, Oracle sessions and auxiliary processes before removing a stale lock. An incomplete run must be investigated before rerunning.

There is **no automatic rollback**. For replacement, a usable backup or other agreed recovery copy of the old target PDB must exist before starting. `DROP ... INCLUDING DATAFILES` removes it permanently from this CDB; the script creates no backup of it.

| Failure stage | Manual recovery |
| --- | --- |
| Before service stop/drop/create | For PRESENT, the old target PDB remains; for ABSENT, there is no old PDB to restore. Correct the failed prerequisite or auxiliary problem. Retain evidence; shut down only the confirmed auxiliary SID before a new run. |
| Apply stop attempted, before service stop/drop/create | For PRESENT, the old target PDB remains; for ABSENT, the target name remains absent unless changed externally. Inspect each standby's original/resulting apply states: some may be OFF and others unchanged or UNKNOWN. Leave stopped apply OFF for the separate standby-refresh/recovery procedure; no automatic restart occurs. |
| Services stopped, old PDB still exists | Restore its per-instance open/saved state from `pdb.before` and `saved.before`. Re-enable only services originally enabled in `services.tsv`, and restart only captured running instances using `srvctl -db <DB_UNIQUE_NAME>`. |
| `drop-issued` or `old-pdb-removed` | First query the target to establish whether the drop completed. Keep application services stopped. Either finish the prepared replacement using the reviewed `plug.sql` and retained XML/datafiles, or restore the old PDB from an independent usable backup. Never rerun the whole script blindly. |
| `create-issued`, or new PDB exists and validation/services fail | First query whether CREATE completed; keep any new PDB restricted or closed until TDE/plug violations are corrected. Review `plug.out`, `verify-pdb.out`, service snapshots and any generated `state.<instance>.sql`. `MOVE` may have relocated recovered PDB files, so establish their actual locations before retrying or cleaning up; the retained XML records pre-MOVE paths. Continue the remaining steps manually; do not repeat `CREATE` against an existing PDB. |

On success, the auxiliary is shut down and that run's private wallet copy is removed after SQL*Plus confirms `ORACLE instance shut down.` Its other filesystem working files and remaining ASM files are retained; the recovered PDB's files have moved to the target through `MOVE CREATE_FILE_DEST`. The run log records both locations; `auxiliary-asm` records the auxiliary namespace and disk-group roots, `aux-files.out` records pre-MOVE paths, and `auxiliary-wallet-path`/`auxiliary-wallet-status` record wallet lifecycle. The retained unplug XML also references pre-MOVE paths and must not be replayed blindly. Failed or unconfirmed shutdown retains the wallet and reports manual cleanup instructions. Before manual cleanup of database files, inspect the target's current `V$DATAFILE` and `V$TEMPFILE` inventory and exclude every file it uses. Remove only remaining files verified to belong to that completed auxiliary run; never use wildcard cleanup spanning multiple runs or remove the target wallet or copy parent.

Recovery evidence includes the mounted auxiliary checkpoint SCN, per-file header SCNs/times, last-applied-redo information when Oracle exposes it, and the new RESETLOGS SCN. RESETLOGS wall-clock time is **not** reported as the source recovery timestamp. RMAN's successful `UNTIL TIME` completion is required for an explicit request; no approximate SCN-to-time conversion is invented.

## Standby handoff and validation

`STANDBYS=NONE` excludes the new PDB from standby recovery. It does not certify standby health, provision standby files, or refresh the standby PDB. **Leave target standby apply OFF for the separate standby-refresh procedure on success and after any stop attempt that fails.** The exit handler reports the handoff on success/failure when physical standbys are involved, or reports no-standby evidence accurately as broker membership or standalone metadata. If failure happens before a stop attempt, the script has not changed apply; if a command or verification failed, inspect every standby rather than assuming its state.

Hand over the run directory (especially `dg-states.tsv`, per-standby result files, original/resulting broker/SQL observations), new PDB identity/file inventory, recovery point and requested PDB name. The separate procedure owns the decision to restore/rebuild the standby PDB, safe apply resumption and Data Guard validation. Never blindly restore `APPLY-ON` from the original snapshot after a drop or failed cutover. This repository does not implement that procedure.

Offline checks:

```bash
bash -n dup_db.sh
bash -n test_readonly.sh
bash -n tests/check.sh
bash -n tests/pdb.sh
bash -n tests/broker.sh
bash -n tests/topology.sh
bash -n tests/services.sh
bash -n tests/dry-run.sh
bash -n tests/readonly.sh
bash -n tests/asm.sh
bash -n tests/wallet.sh
bash -n tests/fixtures/topology-19c.sh
shellcheck -x dup_db.sh test_readonly.sh tests/*.sh tests/fixtures/*.sh
bash tests/check.sh
```

Argument checks include required auxiliary arguments, optional wallet-copy parents, capacity defaults/overrides, unsafe paths/aliases, and isolation from inherited or legacy `.env` refresh settings. Dry-run checks cover catalog ranges, failure cases and the exit before auxiliary startup/cutover. `tests/wallet.sh` checks binary copies with top-level TLS exclusion, unchanged source bytes/modes, PFILE/catalog paths, repeated-run isolation, aliases/unsafe paths, symlinks/special/unreadable files, partial/incorrect copies and successful/failed/unknown auxiliary shutdown. Collector fixtures verify actual copy/cleanup without database changes or wallet contents in reports.

`tests/pdb.sh` exercises the real main flow through fake clients for initial creation, replacement, no/managed standby, stopped enabled/disabled resources, contradictory running services, unavailable nodes, query errors and appearance/disappearance/GUID changes (including after old-PDB closure). It verifies both-node HSM/final checks, the initial saved/open policy and absence of old-PDB close/DROP artifacts. Collector fixtures separately cover absent target discovery, current inventory, continued checks, standby conflicts and partial/erroring PDB inventories.

The synthetic six-row tempfile fixture contains padded IDs `1, 2, 4, 5, 6, 7`. Focused checks cover spaces/tabs/CRLF, trailing whitespace, incidental blanks, EOF without a newline, malformed/empty/mixed inventories, raw retention and the complete exact RMAN tempfile command set in both time modes. Collector checks prove discovery continues through CRLF size output to both ASM queries, accept zero size, and reject size/client failures, timeouts and insufficient space. Combined initial-creation/standalone fixtures verify automatic wallet planning, copy and cleanup alongside padded tempfile metadata; the collector keeps its read-only guards and credential redaction.

The focused checks cover CLI/calendar validation, missing environment and identity failures, both RMAN time paths, generated plug SQL, literal credential redaction, SQL*Plus/RMAN errors even with a zero client exit status, and full service snapshot preservation/rejection. `tests/check.sh` runs `tests/services.sh`, whose realistic 19c administrator-managed fixture includes both a nonempty `Server pool:` and `Preferred instances:`. Service checks cover enabled/running, enabled/stopped and disabled/stopped restoration, captured placement on available/multiple instances, global/per-instance enablement rejection, PDB association, unmanaged SQL services, unrecognized states, and exact configuration/status drift rejection. `tests/check.sh` also runs `tests/topology.sh` for standalone/appliance/unconfigured metadata, dormant destinations, inconsistencies, failed clients and topology drift, and `tests/broker.sh`, which covers positively verified no standby, running/already stopped apply, multiple standbys, disabled/unavailable/erroring brokers, wrong primary/production members, changed membership, missing RAC instances, open standby PDBs, a successful command with failed second-instance stop verification, broker intended-state mismatch, partial stop failure, and success/failure handoff. Fake clients and SQL fixtures perform **no database or broker operations** and do not validate Oracle execution.

Service acceptance on the installed 19c RU must confirm the English `srvctl config service -verbose` and `srvctl status service -force` formats, whole-service versus per-instance enablement reporting, and preservation of every attribute by `modify service -pdb`. Verify exact before/after comparisons for enabled/running, enabled/stopped, disabled/stopped and relocated services, including output with both pool and preferred-instance fields. Offline fixtures do not validate installed `srvctl` behavior.

Before operational use, exercise an explicit-time and latest-point refresh on representative ExaCC/ZDLRA test systems. Verify SBT restore and RAC redo coverage, actual recovery SCNs, Thales key import and encrypted reads on both nodes, compatibility, file isolation, stopped/disabled/running service cases, per-instance saved state, unchanged CDB DBID/root/seed/backup configuration, and the separate standby handoff. Exercise interruption before and after drop with a disposable target PDB and a verified recovery copy.

Broker acceptance on the installed 19c RU must confirm English member/instance/hostname output, local OS authentication and SSH access to every standby node, DBID/GUID checks in mounted and read-only modes, and zero recovery processes across RAC with both single-instance and multi-instance apply. Exercise already stopped apply, multiple standbys, a valid no-standby configuration, broker disabled/unreachable, a refusal caused by existing protection/FSFO policy, partial stop/interruption and failed verification. Demonstrate that an open PDB on any standby blocks preflight/drop, that operator-established closure survives the window, and that services/drop never follow a failed stop gate. No acceptance test should change production; use disposable target systems. Verify apply remains OFF until the separate standby-refresh procedure completes.

Oracle references: [backup-based duplication](https://docs.oracle.com/en/database/oracle/oracle-database/19/bradv/rman-duplicating-databases.html), [DUPLICATE syntax and restrictions](https://docs.oracle.com/en/database/oracle/oracle-database/19/rcmrf/DUPLICATE.html), [OMF file placement](https://docs.oracle.com/en/database/oracle/oracle-database/19/bradv/rman-duplicating-databases-advanced.html), [CREATE PLUGGABLE DATABASE / STANDBYS](https://docs.oracle.com/en/database/oracle/oracle-database/19/sqlrf/CREATE-PLUGGABLE-DATABASE.html), [SRVCTL](https://docs.oracle.com/en/database/oracle/oracle-database/19/racad/server-control-utility-reference.html), [PDB services and saved state](https://docs.oracle.com/en/database/oracle/oracle-database/19/multi/administering-pdbs-with-sql-plus.html).

Broker references: [Oracle 19c broker states and RAC apply](https://docs.oracle.com/en/database/oracle/oracle-database/19/dgbkr/managing-oracle-data-guard-broker-configuration-members.html), [DGMGRL command reference](https://docs.oracle.com/en/database/oracle/oracle-database/19/dgbkr/oracle-data-guard-broker-commands.html), [V$DATAGUARD_PROCESS](https://docs.oracle.com/en/database/oracle/oracle-database/19/refrn/V-DATAGUARD_PROCESS.html).


Topology references: [runtime parameters](https://docs.oracle.com/en/database/oracle/oracle-database/19/refrn/V-SYSTEM_PARAMETER.html), [persistent parameters and SPFILE limits](https://docs.oracle.com/en/database/oracle/oracle-database/19/refrn/V-SPPARAMETER.html), [archive destinations](https://docs.oracle.com/en/database/oracle/oracle-database/19/refrn/V-ARCHIVE_DEST.html), [runtime destination types and limits](https://docs.oracle.com/en/database/oracle/oracle-database/19/refrn/V-ARCHIVE_DEST_STATUS.html), [membership roles and parents](https://docs.oracle.com/en/database/oracle/oracle-database/19/refrn/V-DATAGUARD_CONFIG.html), [archive configuration](https://docs.oracle.com/en/database/oracle/oracle-database/19/refrn/LOG_ARCHIVE_CONFIG.html), [destination states](https://docs.oracle.com/en/database/oracle/oracle-database/19/refrn/LOG_ARCHIVE_DEST_STATE_n.html), [ORA-16532](https://docs.oracle.com/en/error-help/db/ora-16532/). Operational acceptance must verify installed 19c fixed SHOW/EXIT probe output and both configured and unconfigured broker cases; implementation fixtures use no live Oracle or SSH connections.
