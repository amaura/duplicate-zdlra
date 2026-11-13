# ZDLRA PDB refresh implementation plan

Status: implemented in `dup_db.sh`, including the target Data Guard Broker apply-stop gate, with usage and recovery notes in `README.md` and focused offline checks in `tests/check.sh`, `tests/services.sh` and `tests/broker.sh`. No live database or broker operations have been performed; ExaCC/ZDLRA/RAC/Data Guard/Thales acceptance testing remains required. External keystores through PKCS#11 are supported for 19c on ExaCC; see the product-specific reference in the README.

## Goal and design approach

Implement `dup_db.sh` to refresh a preproduction PDB from production backups in ZDLRA while preserving the existing preproduction CDB.

Keep the implementation simple: one Bash script, focused functions, and a linear workflow using SQL*Plus, RMAN, `mkstore`, `srvctl`, and Oracle 19c DGMGRL only when broker topology requires it. Read the standard ExaCC target environment file unchanged. Pass auxiliary names, storage paths, optional catalog alias and capacity settings as command-line arguments.

Do not build a framework, a generic topology manager, an automatic rollback system, a checkpoint/resume engine, or a large test harness. Keep the CLI explicit and documented, including `--help`.

## Agreed requirements

- Oracle Database 19c and ZDLRA 23.
- Production and preproduction run on separate VMs, each with two-node **administrator-managed Oracle 19c RAC**; the target may have no standby or broker-managed physical standbys. This is an explicit deployment assumption; policy-managed topology support and generic topology detection are out of scope.
- The source CDB has one application PDB in addition to Oracle-maintained containers. The target CDB must exist; the requested target PDB is optional and unrelated target PDBs must be preserved.
- Production backups use ExaCC automatic backup tooling. Both environments use the same ZDLRA and VPC account described in `notes_zdlra.md`.
- Run as `oracle` on a designated target primary RAC node.
- No production database connection is possible. Use the ZDLRA recovery catalog for source and backup metadata, and connect only to the destination, temporary auxiliary, and the verified destination's physical standbys for read-only checks. Broker clients authenticate locally on the verified target primary.
- Preserve the destination CDB identity and configuration. Replace only the named target PDB when present, or create that name when absent. Never rebuild or restore over the destination CDB.
- A temporary auxiliary CDB is allowed.
- Create/plug the replacement PDB with `STANDBYS=NONE`. Standby refresh belongs to another script and is outside this implementation.
- For configured broker-managed physical standbys, stop apply through the target's Data Guard Broker only after auxiliary preparation, immediately before target service shutdown. Discover physical standby DB_UNIQUE_NAMEs, require the broker primary to match the target, verify apply is OFF across RAC, and leave it OFF for separate standby refresh. Never automatically change transport, protection mode or Fast-Start Failover.
- For a PRESENT target PDB, require the old target PDB independently closed on every standby RAC instance before DROP. For ABSENT, require zero matching PDB rows on every discovered standby while retaining identity, inventory and actual apply-stop checks. APPLY-OFF alone does not close a PDB. The operator establishes closure before the run; the script verifies DBID, PDB GUID, per-instance MOUNTED state and the complete broker-listed online instance inventory.
- Capture the preproduction PDB services before changes and restore their configuration and intended running state using `srvctl`.
- Treat all times as fixed UTC+02:00, without timezone conversion or daylight-saving adjustment.
- Copy the verified target `WALLET_ROOT` excluding its top-level `tls` entry to a fresh private auxiliary filesystem area in duplication, dry-run and diagnostic modes. Never overwrite an existing wallet or change the source. Use only independent regular-file copies; reject symlinks/special/unreadable files, verify bytes and preserve owner access. On TDE failure, retain the exact redacted Oracle/RMAN stack and advise checking historical key/HSM access; copying credentials does not establish that access. Thales KMS version is irrelevant to this script.

## CLI

```bash
./dup_db.sh \
  --source-cdb <SOURCE_DB_NAME> \
  --target-cdb <TARGET_DB_NAME> \
  --source-pdb <SOURCE_PDB> \
  --target-pdb <TARGET_PDB> \
  --aux-cdb <AUX_DB_NAME> \
  --aux-base <FILESYSTEM_WORK_PATH> \
  [--aux-wallet-root <WALLET_COPY_PARENT>] \
  [--zdlra-alias <ALIAS>] \
  [--aux-sga-mb <MIB>] [--aux-pga-mb <MIB>] \
  [--redo-reserve-mb <MIB>] \
  [--time "2024-10-01 10:20:05"] \
  [--do-duplicate] \
  [--debug] \
  [--purge-log <DAYS>]
```

The four source/target arguments, `--aux-cdb` and `--aux-base` are mandatory in both dry-run and duplication modes. `--aux-wallet-root` optionally supplies an existing parent for a new per-run wallet copy, never a wallet to reuse. It defaults to the run's auxiliary working directory, or `--aux-base` in dry-run/diagnostic modes. Auxiliary SGA/PGA/redo reserve defaults are 4096/1024/10240 MiB; the sole SEPS credential is selected automatically unless `--zdlra-alias` is supplied. Dry run is the default; `--do-duplicate` enables actual duplication and replacement or initial creation. `--purge-log` defaults to seven days. `--time` must be quoted as shown.

## Implementation sequence

### 1. Confirm the Oracle workflow

- Verify the exact Oracle 19c commands and local release prerequisites against official documentation before coding the destructive steps.
- Use backup-based RMAN duplication with `CATALOG` and `AUXILIARY` connections, without a production `TARGET` connection.
- Recover the source PDB in an isolated temporary CDB, including the root and seed containers required by RMAN. Since the source contains one application PDB, prefer the simplest supported duplication scope rather than adding unnecessary selection logic.
- Unplug the recovered PDB and plug it into the existing target CDB under the requested target PDB name, using `STANDBYS=NONE`.
- Do not substitute active duplication or Data Pump. Direct RMAN backup-based PDB duplication into an existing CDB is not supported in 19c.
- Use distinct auxiliary names and file destinations. Document the auxiliary storage and HSM-access prerequisites; do not build automatic infrastructure provisioning.

### 2. Parse arguments and load the target environment

- Validate required arguments, conservative Oracle identifiers, timestamp format, and a positive integer log-retention value. Reject unknown options and missing values.
- Source the standard `/home/oracle/<TARGET_DB_NAME>.env` unchanged; fail if missing or unreadable. Refresh-specific settings come only from CLI arguments/defaults; inherited or legacy `DUP_*` assignments must not supply or override them.
- Check the required executables and Oracle environment. Confirm the connected database is the requested target CDB in the primary role.
- During preflight, collect complete read-only identity/root, runtime parameters, specified SPFILE settings, all 31 destinations regardless transport state, and Data Guard membership/parent roles on both verified RAC nodes. Classify NONE, MANAGED or UNKNOWN/unsupported. For enabled broker, parse its complete healthy inventory and verify the sole primary matches the target. Refuse production identities before standby access.
- Support no-standby proof through healthy primary-only broker membership without contradictory SQL evidence, or complete standalone runtime/SPFILE evidence with broker disabled on both nodes. Enabled/unconfigured broker additionally requires exact ORA-16532-only output from successful fixed SHOW/EXIT client probes on each verified RAC host. Disabled broker, missing DGMGRL, errors, timeouts and empty queries alone never establish absence. Keep remote backup appliance and physical standby roles distinct using role/type metadata, not names. Inspect dormant persistent SERVICE settings, all destination states (including RESET), FAL hints and membership parents. Unknown endpoints/parents, missing/truncated SPFILE evidence, unmanaged or unsupported replication remain UNKNOWN and block cutover; document metadata limits.
- Read the target `DB_UNIQUE_NAME` from the environment and cross-check it against the database. CLI CDB arguments represent `DB_NAME`.
- Naming interpretation from the agreed prompt: extract `M1` or `M2` from the target unique name and form the expected source unique name as `<SOURCE_DB_NAME><M1|M2>`, with no added separator.
- Validate that expected source identity in the catalog and resolve its DBID and relevant incarnation. Fail on a mismatch or unresolved ambiguity instead of silently trying another site.

### 3. Discover ZDLRA access and check prerequisites

- Follow `notes_zdlra.md` for the target SEPS wallet location, ZDLRA connection alias, VPC username/password discovery, `libra.so`, and `RA_WALLET` settings.
- Discover the credential index associated with the selected alias; do not hardcode `password2`.
- Keep catalog authentication and SBT restore configuration explicit. Prefer per-run auxiliary channel allocation over changes to persistent RMAN configuration.
- Discover target settings, including `wallet_root`, independently of target PDB presence after primary identity verification, using the same helper in refresh and collector. Validate the source tree excluding its top-level `tls` entry, required `tde/cwallet.sso` and `tde_seps/cwallet.sso`, and an accessible copy parent outside source/evidence space. Resolve aliases and never write permission probe files into the source. A pre-provisioned auxiliary wallet is not required. Keep catalog SEPS at its established target credential location and preserve persistent HSM/provider configuration.
- Check catalog access, backup/redo availability, combined auxiliary/target ASM capacity in dynamically discovered DB_CREATE_FILE_DEST and DB_RECOVERY_FILE_DEST disk groups, filesystem working space, and auxiliary key-access prerequisites before changing the existing PDB.
- Normalize tempfile ID rows through one shared helper before consumption: trim surrounding SQL*Plus whitespace including CRLF, skip incidental blanks, require positive decimal IDs, and reject empty or malformed inventories without publishing a partial result. Retain separate raw/normalized artifacts for IDs and the collector's size scalar; use only the validated scalar for later capacity arithmetic, allowing size zero. Other numeric row-list queries concatenate their fields explicitly, and standalone numeric scalars already pass through `one_line`; no broader parser change is needed.
- With `--time`, use the requested recovery time and fail if it cannot be reached. Without it, use RMAN's latest consistent recoverable point from available ZDLRA backups and redo. Account for all required RAC redo threads and record the recovery point actually reached.
- Use catalog metadata and, where necessary, restored auxiliary metadata for source details. Never request a production connection, log switch, or new backup.

### 4. Capture services and recover the auxiliary

- Discover the two target RAC instances independently using CDB instance metadata; verify each node identity/19c/HSM through local/SSH SQL even if the target PDB is absent. Classify a successful complete PDB inventory as PRESENT (one consistent GUID on both nodes) or ABSENT (zero rows). Reject partial, malformed, duplicate, inaccessible or inconsistent inventories.
- For PRESENT, save the existing RAC open/restricted/saved states and service configuration/status. For ABSENT, record no old GUID/state snapshot, keep raw observations, and set explicit expected READ WRITE/unrestricted/open-saved state on both verified nodes. Capture stopped enabled/disabled associated Clusterware resources; reject any running resource without its PDB. Do not create application service names.
- Preserve existing Clusterware service resources and their complete `srvctl config service -verbose` and status snapshots, including placement, roles, policies, edition, TAF/AC and unknown attributes. Do not rebuild resources from parsed attributes. Administrator-managed 19c output can contain both a nonempty `Server pool:` and `Preferred instances:`; retain both verbatim and do not reject a pool name or infer topology from it. Keep PDB-association and expected-output checks, and reject unsupported global services, per-instance enablement, unmanaged SQL services, disabled-but-running services and unrecognized states before cutover.
- Use `srvctl` with the target `DB_UNIQUE_NAME`, not its `DB_NAME`.
- Save original standby broker intended states and actual per-instance recovery-process counts. Discover nodes via broker instance/HostName metadata; use read-only local OS-authenticated SQL through SSH and the existing target-named environment file on each standby node. Require every configured instance online and the old PDB GUID/MOUNTED state verified. Document operator closure using local `ALTER PLUGGABLE DATABASE ... CLOSE IMMEDIATE` only on open standby instances; keep the maintenance window frozen against reopening/restarts.
- Recover the temporary CDB from ZDLRA, with isolated files and without advertising copied production application services.
- Before auxiliary startup, make and byte-verify the target wallet tree excluding its top-level `tls` entry in a fresh 0700 container; use the actual copy in the PFILE. Copy failure blocks startup and cutover. Wallets, PFILE, XML, audit and diagnostics use filesystem working space; database files retain the isolated dynamically discovered ASM destinations. Dry run and `test_readonly.sh` also copy/verify, then remove their unused copy; database/client command guards remain in force.
- Check the recovered PDB, encrypted-data access, file placement, and supported plug compatibility before removing the old target PDB wherever possible.
- Prepare the unplugged PDB and its metadata for the transfer. Keep any remaining cutover-only checks explicit.

### 5. Replace or create the target PDB and restore services

- After auxiliary recovery, encryption validation, unplug/compatibility preparation and target freeze checks, rediscover topology and require frozen configuration, endpoint identities and full broker roles/membership unchanged. Revalidate before services, DROP and CREATE; standalone targets must abort on new relationships. No-standby paths skip standby SSH/apply commands and carry truthful standalone/broker evidence without an apply-resumption or standby-refresh handoff. Capture states immediately before stopping apply.
- For every physical standby issue `EDIT DATABASE '<standby_db_unique_name>' SET STATE='APPLY-OFF';`, including already stopped standbys. Check client status/output and independently verify broker intended APPLY-OFF plus zero `V$DATAGUARD_PROCESS` recovery processes on every configured standby RAC instance. Count waiting recovery and multi-instance workers too. A failed command or verification aborts before target service stop/drop; record UNKNOWN when a resulting state cannot be established.
- Recheck the independent RAC inventory and frozen PDB presence/GUID before service changes and immediately before DROP/create. Abort on appearance, disappearance or identity change rather than switching paths.
- Stop affected preproduction services. For PRESENT only, close and DROP the old PDB; do not generate or execute old close/DROP artifacts for ABSENT. Recheck zero matching rows immediately before CREATE in both paths.
- Immediately before DROP, recheck all standby identities, actual apply stop, instance coverage and matching old-PDB GUID/MOUNTED state. Keep standby closure separate from apply-stop verification; the script does not close standby PDBs itself.
- Replace or initially create only that PDB, using the requested target PDB name and `MOVE CREATE_FILE_DEST` with `STANDBYS=NONE` at the supported create/plug step. The recovered PDB files move into target storage; retain only the remaining auxiliary files and treat the unplug XML as a record of pre-MOVE paths when recovering from a failure.
- Preserve the target CDB's DBID, unique name, root, seed, and existing backup configuration.
- Open the replacement on the intended RAC instances and restore its required saved state.
- Restore captured open/restricted/saved states for PRESENT, or READ WRITE/unrestricted and OPEN/unrestricted saved state on both independently verified RAC nodes for ABSENT. Query and compare actual final states to the explicit expected policy, and validate HSM on both nodes independent of old PDB rows.
- Reconcile the preserved Clusterware resources with the target PDB using `srvctl modify service -pdb`, restore captured enablement, and start only the captured running instances (including available instances after failover). Require exact configuration/status snapshot matches. Prevent copied production application services from being advertised.
- Report the primary-side result and explicit handoff to the separate standby-refresh script on success or failure. Leave stopped apply OFF; do not restore original APPLY-ON automatically. Handoff includes original/resulting broker/SQL evidence, UNKNOWN/partial outcomes and the separate procedure's ownership of safe resumption. Do not claim the standby PDB has been refreshed or that `STANDBYS=NONE` guarantees standby health.

### 6. Add essential operational handling

- Write timestamped, source/target-specific logs under `/home/oracle/duplicate_logs`; purge only this script's expired logs, preserving active logs and recovery information needed by incomplete runs.
- Retain `dg-states.tsv`, per-standby result files, preflight/precutover member inventories, broker stop output and before/after/predrop SQL observations in the run directory. Record original broker intent and actual recovery-process counts as well as resulting state; a failed client may have partially stopped apply.
- Keep debug output useful but redacted. Do not expose passwords in shell traces, process arguments, or retained files.
- Use SQL*Plus error-exit directives and reliable RMAN/shell exit handling. Log the failed phase and return a nonzero status.
- Use a simple per-target lock. Document execution on the designated node; do not add a distributed-lock subsystem or claim a local lock protects other RAC nodes.
- On interruption/failure, release the lock. Remove only this run's wallet container while unused or after confirmed successful auxiliary shutdown; retain it for running/unknown auxiliary state, with its exact path and manual instructions. Source wallets and preexisting parent contents are never deleted. Record only wallet path and creation/lifecycle status outside the copy; never package its contents as evidence. Retain useful auxiliary files and service snapshots for diagnosis when needed. Never delete files adopted by the refreshed PDB.
- Supply short manual recovery instructions for failures before and after the old PDB is removed. Be explicit that automatic rollback is not provided and that recovery of the old PDB needs an existing usable backup or other agreed recovery copy.

## Verification and completion criteria

Keep verification focused:

1. Run `bash -n` on `dup_db.sh`, `test_readonly.sh` and the test scripts, ShellCheck, and `bash tests/check.sh` (which also runs optional-PDB main-flow, service, broker, dry-run, ASM, wallet and diagnostic collector fixtures). Only syntax/lint/offline tests are authorized for this implementation; execute no live database or broker changes. `test_readonly.sh` is the manual deployment evidence collector; its report includes failed/skipped checks and excludes database/service/broker mutations. Its temporary wallet copy is verified and removed outside evidence packaging, as requested for both diagnostic modes.
   Include the shared shell fixture helpers in syntax/lint checks. Check the six padded tempfile IDs, the whitespace/error/empty/mixed-inventory matrix, exact RMAN commands in both time modes, raw evidence retention, normalized CRLF size consumption, size zero, failed/timed-out size queries and insufficient ASM capacity. Extend the existing absent-target/standalone main and collector fixtures to verify wallet planning/copy/cleanup together with padded numeric metadata, with the collector remaining read-only.
2. Cover PRESENT/ABSENT with complete fake-client main flows, initial open/saved state, both-node HSM checks, no old close/DROP for ABSENT, stopped resource preservation, contradictory running services, query/node/partial/GUID failures, changing presence/identity, and absent versus conflicting standby inventory. Collector absence must pass discovery, list actual PDB inventory and continue applicable checks. Check both explicit-time and omitted-time paths, environment/identity failures, redaction, and preservation of service settings. `tests/services.sh` accepts a realistic administrator-managed 19c fixture containing both `Server pool:` and `Preferred instances:`; it checks complete snapshots, enabled/running, enabled/stopped and disabled/stopped restoration, placement on available/multiple instances, unsupported global/per-instance enablement, PDB association, unmanaged SQL services, unrecognized states, and configuration/placement drift. Broker fixtures cover no standby, running/stopped/multiple standbys, standalone disabled/unconfigured broker, contradictory metadata, dormant destinations, unknown endpoints, topology drift, unreachable/erroring broker, wrong primary/production members, discovery/member changes, missing RAC instances, open standby PDBs and failed actual stop verification despite a successful client. Verify handoff/evidence on success and partial failure, and the gate's placement before services/drop. Use small focused checks rather than a general mocking framework.
3. In the intended Oracle test environment, verify the ZDLRA restore, requested recovery point, TDE access, PDB transfer, RAC open state, and `srvctl` service restoration. Validate the installed 19c RU's English `config service -verbose`/`status service -force` output and whole-service enablement reporting, confirm `modify service -pdb` retains every resource attribute, and verify exact configuration/status comparisons for stopped, disabled and relocated services on the assumed administrator-managed deployment.
4. Confirm the destination CDB identity is unchanged and the refreshed PDB was created with `STANDBYS=NONE`.
5. Report exactly which checks ran and which require access to the actual ExaCC/ZDLRA environment. A generic standalone Oracle test database cannot validate this topology.
6. In later environment acceptance tests, validate installed 19c DGMGRL output/authentication, standby SSH and DBID/GUID checks in mounted/read-only modes, single-/multi-instance RAC apply stop, already stopped apply and multiple/no standby configurations. Inject broker/FSFO-policy refusal, partial stop, interruption and failed verification; prove service stop/drop is blocked as appropriate, open standby PDBs are rejected, and apply remains OFF until the separate refresh procedure safely resumes it. Do not change transport/protection/FSFO automatically or involve production.

Deliver `dup_db.sh` plus concise usage, prerequisites, auxiliary configuration, failure-recovery notes, and standby handoff instructions. Do not implement the separate standby-refresh script as part of this work.

## References

- [Oracle 19c: Duplicating databases and PDB restrictions](https://docs.oracle.com/en/database/oracle/oracle-database/19/bradv/rman-duplicating-databases.html)
- [Oracle 19c: RMAN DUPLICATE reference](https://docs.oracle.com/en/database/oracle/oracle-database/19/rcmrf/DUPLICATE.html)
- [Oracle 19c: CREATE PLUGGABLE DATABASE and STANDBYS](https://docs.oracle.com/en/database/oracle/oracle-database/19/sqlrf/CREATE-PLUGGABLE-DATABASE.html)
- [Oracle 19c: Data Guard Broker states and RAC apply](https://docs.oracle.com/en/database/oracle/oracle-database/19/dgbkr/managing-oracle-data-guard-broker-configuration-members.html)
- [Oracle 19c: DGMGRL commands](https://docs.oracle.com/en/database/oracle/oracle-database/19/dgbkr/oracle-data-guard-broker-commands.html)
- [Oracle 19c: V$DATAGUARD_PROCESS](https://docs.oracle.com/en/database/oracle/oracle-database/19/refrn/V-DATAGUARD_PROCESS.html)
- Local configuration: [notes_zdlra.md](notes_zdlra.md)

## Recommended implementation model

As of 2026-11-02, use **GPT-6 Astra with Extra High (`xhigh`) reasoning** for the implementation and review. This is a recommendation based on the interacting RMAN, RAC, catalog, TDE, and service requirements; it does not imply the script should be more elaborate.

Official OpenAI documentation positions Astra for demanding reasoning and coding, and Extra High for complex work with exact requirements. **GPT-6.1 Sol with Extra High** is a reasonable lower-cost alternative.

- [OpenAI model selection](https://developers.openai.com/api/docs/guides/model-selection)
- [GPT-6 Astra model documentation](https://developers.openai.com/api/docs/models/gpt-6-astra)
