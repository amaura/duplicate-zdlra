# Full CDB copy mode — implementation plan

Status: implementation added on this branch; interview decisions below are retained as the design record. Offline verification and deployment acceptance are described in README.md.
Branch:
`codex/full-cdb-copy-mode`, based on `main` at `08d5849`.
The existing PDB refresh implementation and its plan remain unchanged.

## Confirmed requirements

- Add a full-CDB copy mode to `dup_db.sh`; retain the existing PDB mode.
- Keep the target parameter file and target password file. Do not restore either
  file from production or replace either with a generated permanent file.
- A temporary restore PFILE derived from the target configuration is allowed.
  Keep the original parameter/password files unchanged and use the original
  parameter file for the final RAC restart.
- Duplicate the source controlfile and all source CDB datafiles, including root,
  seed, and application PDB datafiles, from ZDLRA backups.
- Rename the copied application PDB from `--source-pdb` to `--target-pdb` when
  those names differ, preserving the target-facing name and service associations.
  The name mapping must never restrict which CDB datafiles are copied.
- Keep copied Scheduler and legacy `DBMS_JOB` states unchanged. Job handling
  belongs to the external application refresh procedure. Temporary restore
  job suppression is allowed; final startup uses the original target settings.
- Redo logs and tempfiles may be recreated, as explicitly confirmed by the user.
- Accept a command-line directory containing the contents of the source
  `<WALLET_ROOT>/tde` directory. This is a TDE directory, not a complete wallet
  root, and must not require a source `tde_seps` directory.
- Require portable auto-login input: the supplied directory must contain a
  usable `cwallet.sso` providing unattended access to the required source CKMS
  keys on both target nodes. Password-only wallet input is outside this mode.
- The final copied CDB is allowed to use the source CipherTrust credentials.
- After stopping the target, the script will back up its existing TDE files and
  install the supplied source TDE contents at the existing `WALLET_ROOT/tde`
  location on both RAC nodes. Preserve all other wallet-root directories.
- The refreshed target may receive a new DBID. Existing physical standbys would
  require a separate full rebuild; preserving the old target DBID is not required.
- Existing target standbys must not block CDB mode. Warn that they must be
  recreated; a separate script handles their recreation. Do not manage or
  require successful access to those standbys in this mode.
- The target may remain down for the entire restore and recovery. Direct
  duplication into the stopped target is accepted; staging for a short outage
  is not required.
- After complete target shutdown, delete the old target datafiles, redo logs,
  and tempfiles before restoring the source copy. Do not retain those old
  database files through acceptance. Keep the agreed parameter/password files,
  protected controlfile copies, and old TDE backup.
- CDB mode uses `--work-dir PATH` and no `--aux-*` arguments. The existing PDB
  mode retains its auxiliary arguments and behavior.
- Keep catalog-only source access: no connection to the production database.
- Planning was completed before implementation. Deployment operations remain outside the implementation/offline-verification authorization.

## Findings from the existing implementation

- `build_duplicate()` already performs backup-based duplication of a whole CDB
  using a recovery catalog, local auxiliary authentication, configurable SBT
  channel parallelism, an optional recovery time, and `NOOPEN`.
- The current workflow then extracts one PDB from a separate auxiliary. Full-CDB
  mode must branch before those PDB-specific steps; it must not unplug, plug,
  drop an individual target PDB, or import keys from `HSM` after plugging.
- Existing wallet handling copies the target wallet root and later deletes its
  temporary copy. Neither policy fits a supplied source TDE directory that must
  remain usable by the refreshed target after completion.
- Service snapshots, saved-state handling, and several before/after checks are
  PDB-specific. Full-CDB mode needs whole-database inventories and invariants.
- Existing Data Guard handling stops apply for a PDB refresh. Replacing the
  entire database requires a different policy; stopping apply alone is
  insufficient.
- `test_readonly.sh` sources shared code from `dup_db.sh`. Its argument handling
  and evidence collection must eventually understand the new mode while keeping
  its existing read-only command guards.

## CLI

Use `--mode pdb|cdb`, defaulting to `pdb` for backward compatibility.
Use `--source-wallet-dir PATH` for a directory whose direct children are the
source TDE files, including required portable auto-login `cwallet.sso` and,
when present, `ewallet.p12`.
Require that directory in CDB mode and reject it in PDB mode rather than ignoring
it. Never treat its parent as the supplied wallet root.

Retain `--source-cdb`, `--target-cdb`, `--time`, `--zdlra-alias`,
`--restore-parallelism`, `--redo-reserve-mb`, logging options, and the default dry run.
Retain `--do-duplicate` as the explicit execution switch.

Duplicate directly into the stopped target SID, with datafiles in newly
allocated target-owned OMF locations. Require `--work-dir PATH` as the existing
filesystem parent for private per-run working files. There is no separately
named auxiliary CDB. Reject all `--aux-*` options in CDB mode, including auxiliary
memory and wallet-copy options. Derive temporary restore memory settings from
the target configuration instead. Reject `--work-dir` and `--source-wallet-dir`
in PDB mode; keep its existing required auxiliary arguments and defaults.

Retain the existing source/target PDB arguments to identify and rename the single
application PDB as approved by the user. They must never limit the set of
datafiles copied in CDB mode. Skip the rename when the names already match;
reject a missing source PDB or a conflicting destination name.

Planned CDB-mode dry-run example:

```bash
./dup_db.sh --mode cdb \
  --source-cdb PROD --target-cdb PRE \
  --source-pdb APP --target-pdb APPTEST \
  --work-dir /u02/zdlra_refresh \
  --source-wallet-dir /u02/source_tde \
  --restore-parallelism 8 \
  --time "2024-10-01 10:20:05"
```

`/u02/source_tde` contains the source TDE files directly. Add `--do-duplicate`
only to execute the restore, including deletion of old target datafiles, redo
logs, and tempfiles. Without it, do not install the active wallet, stop services
or instances, delete database files, or invoke RMAN. Keep the existing fixed
UTC+02:00 recovery-time interpretation and omit `--time` for the existing latest
recoverable-endpoint behavior.

## Planned architecture

### 1. Preserve target files and establish compatibility

Discover the target from its existing environment and database/Clusterware
metadata. Record the parameter-file location, whether it is an SPFILE or PFILE,
password-file location and registration, database resource, both RAC instances,
all Clusterware services, wallet root, ASM destinations, and target file lists.

Capture protected recovery copies and verification fingerprints for retained
parameter/password files using tools appropriate to filesystem or ASM storage.
Do not include secret-bearing contents in logs or diagnostic reports. The
original parameter/password files and their resource registrations must remain
unchanged; stop on unexpected drift.

Treat the retained configuration as a compatibility constraint. Check source
block size, supported format/RU, `COMPATIBLE`, file-count capacity, storage,
per-instance undo tablespace names, instance numbers, and redo threads. Some
checks require the restored controlfile or dictionary; execute them at the
earliest point where authoritative evidence exists, before unrestricted use.
Fail incompatible settings rather than silently editing the original file.

Establish an expected source datafile manifest for the recovery point and
verify that the duplicated database covers that complete set. Oracle documents
that ordinary `DUPLICATE` omits offline-clean/`OFFLINE NORMAL` files and can omit
some files affected by historical read-only transitions. Detect unsupported
omissions from authoritative catalog or restored-controlfile metadata at the
earliest available stage and fail rather than silently delivering a partial
CDB. Manual attachment of omitted files is outside the initial mode. Checks
that require a restored controlfile necessarily occur after the agreed old-file
deletion; report that limitation in the execution plan.

Before shutdown, capture and verify the complete old target datafile, tempfile,
and redo-member inventories. Freeze these exact paths for the later deletion
phase, separately from controlfiles, parameter/password files, wallet material,
archived logs, and backup files. Revalidate target identity and inventory before
shutdown so stale evidence cannot drive deletion. Associate the manifest with
the verified old target DBID and storage namespace; normalize/deduplicate paths
and aliases so the same file is not deleted twice.

CDB-mode capacity estimates must reflect deletion before restoration, rather
than the PDB-mode peak-coexistence formula. Estimate usable capacity after
reclaiming only the inventoried files actually stored in each destination ASM
group, accounting for ASM usable-space/mirroring semantics. Show the estimate
before deletion and recheck actual usable capacity afterward. Source copy size,
redo/tempfile recreation, recovery working space, and headroom still apply.
Fail estimates that cannot be established reliably before destroying old files;
do not count unrelated files or unverified potential reclaim.

### 2. Distinguish retained identity from replacement database contents

Preserve target `DB_NAME`, `DB_UNIQUE_NAME`, SIDs, Oracle home, parameter/password
files, and Clusterware resources. Ordinary RMAN `DUPLICATE` creates a new DBID;
the user has accepted this. Preserving the old target DBID is not required.

The source data dictionary replaces the target dictionary: users, grants,
PDB identity/names, jobs, links, application configuration, and stored service
metadata are source contents. Retaining the password file does not retain the
old database dictionary's users or credentials. Plan application reconciliation
and PDB naming explicitly rather than promising the old target metadata survives.

### 3. Warn about standby recreation and leave it to the separate script

Existing target physical standbys cannot continue unchanged after an independent
duplicate with a new DBID. They require a separate whole-database rebuild.

The user has chosen a warning-only policy for current standbys. CDB mode must
proceed whether existing standbys are present, unavailable, or awaiting rebuild.
Do not run the PDB-mode standby discovery/apply-stop prerequisites, connect to
standby hosts, wait for their state, or recreate them. Emit a clear warning in
the execution plan and completion/failure output that all target physical
standbys must be recreated by the separate script after the CDB replacement.

The retained target parameter file can contain Broker and redo-transport
settings. Temporary primary startup isolation is part of the agreed
restore procedure; it must not become an additional standby approval gate or
silently change the retained file. The final startup uses the retained target
configuration, so its Broker/transport settings may reactivate before final RAC
validation completes. Do not claim that the existing Data Guard configuration
is healthy or the old standbys are usable; remediation belongs to the separate
script. Do not add a standby reachability or rebuild prerequisite.

### 4. Stage and install the supplied source TDE files

Validate and independently copy the supplied directory into a private work area;
keep the supplied directory unchanged. Reject unsupported links, special files,
unreadable entries, unsafe paths, and incomplete or changing copies. Verify copied
bytes without exposing wallet contents.

Keep the target's original `WALLET_ROOT` value. The user approved script-managed
installation: after the target is fully stopped, preserve its old TDE directory
in a private recovery location and install the supplied contents at the active
`<target WALLET_ROOT>/tde` path on both RAC nodes, accounting for shared versus
node-local storage.

Preserve `server_seps`, TLS, and other unrelated target wallet-root directories.
Do not use a retained target `tde_seps` entry as if it were a source credential.
The user confirmed portable auto-login input as a requirement: `cwallet.sso`
must provide usable source HSM authentication on both target hosts without a
password prompt. Password-only input is unsupported. A source-host-bound local
auto-login wallet does not satisfy this requirement. Fail if the input does not
provide the required authentication instead of silently falling back to target
credentials or demanding an unrequested source wallet-root copy. Structural
copy validation alone cannot prove actual CKMS key access; the restore and
encrypted-data validation must establish that access.

Provider libraries, network access, domains, certificates, and historical key
availability remain prerequisites. The installed source TDE material becomes
the final target wallet and must never enter auxiliary-wallet cleanup.

### 5. Shut down, delete old database files, and duplicate into the target

Capture all target service/resource states, stop target services and both RAC
instances through Clusterware, and verify they cannot restart during the work.
Hold target application service resources disabled through restoration and the
final database restart, recording their original enablement and placement for
later restoration. Do not let automatic service startup expose an unvalidated
copy when the database resource starts.
The user accepts the full restore/recovery outage; direct duplication does not
need a short cutover or a separately staged database.

Before any database-file deletion, finish the protected parameter/password,
controlfile, and old-TDE backups; stage and verify the supplied wallet; and
complete the available catalog, compatibility, and capacity checks. Verify both
RAC instances are stopped and cannot be automatically restarted.

Delete every old target datafile, tempfile, and redo-log member from the frozen,
verified inventory before starting the source duplication. Include all old CDB
containers and all inventoried online and standby redo-log members belonging to
this target. Use supported ASM/filesystem operations against explicit individual
paths; do not use directory-wide removal,
wildcards, or `DROP DATABASE`, which could remove retained files. Exclude the
retained parameter/password files, controlfiles, wallets, archived logs, and
backup files. Verify deletion results and record each outcome. Do not begin
RMAN duplication if deletion is partial or its result is unknown.

This first successful old-database-file deletion is the destructive boundary;
record it explicitly. Partial deletion already makes the old database unusable.
Parameter/password retention and small controlfile/wallet backups do not provide
a rollback after that boundary.

Start one controlled target instance in `NOMOUNT` using a temporary PFILE derived
from the target configuration, as approved by the user. Temporary overrides include
`CLUSTER_DATABASE=FALSE` and isolation of listeners, jobs, Broker, and redo
transport. The original parameter/password files stay unchanged, and final RAC
startup uses the original parameter file.

In that temporary PFILE and the RMAN command, establish target-owned OMF naming
for all new datafiles, online redo, and tempfiles before creation. Remove or
override conflicting source/old-target filename-conversion settings only in the
temporary copy. Keep the retained `CONTROL_FILES` locations and original
permanent parameter file unchanged.

Use catalog-based `DUPLICATE DATABASE ... TO <TARGET_DB_NAME>` with an explicit
temporary `PFILE` and `NOOPEN`. Do not include `SPFILE`, `PASSWORD FILE`,
`FOR STANDBY`, or `FROM ACTIVE DATABASE`. Keep explicit SBT channel allocation
and recovery-time behavior. Do not automatically register or resynchronize the
new target identity into a backup service as part of the refresh.

Restore the source controlfile into the target's configured controlfile locations
only after recoverable copies of old controlfiles exist. Restore all source
datafiles to newly allocated target-owned OMF locations after old target
datafiles, redo logs, and tempfiles have been deleted. Do not follow source paths
or require the old file paths to be reused. Validate all resulting file mappings.

Interpret "only source controlfile and datafiles" as excluding the source
parameter/password files and source online redo files. Redo and tempfile
recreation is approved. A functioning duplicate still uses archived redo from
backups as necessary for recovery; it does not copy source online redo files.

Record controlfile replacement as a later transition, distinct from the earlier
old-file deletion boundary. Restarting the old parameter file alone cannot
recover the old target database after deletion.

### 6. Validate and return to the retained target configuration

Before the first open, verify destination identity, file mappings, recovery
result, complete expected source datafile coverage, and any compatibility checks
possible while mounted. Verify planned redo/tempfile destinations at this stage;
`NOOPEN` can defer tempfile creation until `OPEN RESETLOGS`, so do not require
every recreated file to exist while mounted. Open `RESETLOGS`
under controlled isolation and restriction, then validate encrypted data using
the source credentials and all required historical keys. Verify the actual new
datafile, redo, and tempfile inventories after opening.

Before normal listener registration or job execution, remove/reconcile copied
production services, rename the copied application PDB to `--target-pdb` when
necessary, and reconcile every retained target service
with the resulting dictionary. Validate the resulting PDB name and target-facing
service associations before restoring normal access.
Do not run the old post-plug HSM key-import operation.

Preserve all copied application and Oracle-maintained job definitions/states;
do not disable Scheduler jobs or mark legacy `DBMS_JOB` jobs broken. Temporary
job suppression applies only during the controlled restore startup. The final
restart restores the original target parameter settings, so copied jobs can run
according to those settings. External application refresh procedures own any
required job changes; this script does not wait for or manage that work.

Shut down the controlled instance and restart through the retained target
parameter file and existing Clusterware resources while application service
resources remain held disabled. Validate both RAC instances, source-key access,
PDB states, file inventories, new DBID, service definitions, and unchanged
parameter/password files. After database-readiness checks succeed, restore the
captured target service/resource enablement and running placement, then validate
actual service state and the final configuration. Record any required
backup-registration or standby
rebuild handoff; do not claim those separate procedures are complete.

### 7. Failure handling and recovery evidence

The user requires pre-copy deletion of old target datafiles, redo logs, and
tempfiles. Retain only the protected configuration/controlfile evidence and old
TDE backup, plus any newly restored files needed to diagnose a failed copy.
Do not imply that these small backups preserve the deleted database. Recovery
of the former target after deletion requires an independent usable database
backup or other external recovery source; automatic rollback is not provided.

Retain precise state: stopped/running resources, active wallet, active controlfile
locations, old/new DBIDs, recovery endpoint, old/new file inventories, per-file
deletion results, and the last verified phase. Distinguish failures before any
deletion, during partial deletion, during restore, and after opening the copy.
Do not resume Clusterware application services or standby transport against an
incompletely restored database during the controlled restore. Application
service release requires the final readiness checks described above. Final
startup with the original parameter file may reactivate its Broker/transport
settings; existing standby health remains outside this mode.

## Implementation sequence

1. Add mode-aware parsing and validation without changing existing PDB defaults.
2. Split reusable discovery/catalog/storage helpers from PDB-specific execution.
3. Add retained-file snapshots, whole-CDB inventories, and final verification.
4. Add supplied-TDE-directory validation, installation, and permanent lifecycle.
5. Implement the agreed Data Guard policy, complete RAC shutdown/isolation,
   exact old-file deletion, direct duplication, restricted first open, and final
   target restart.
6. Add CDB-specific service/PDB reconciliation and recovery instructions,
   preserving copied job states and documenting the external job handoff.
7. Extend dry run and the read-only collector with CDB-mode prerequisites and
   clearly label checks that need an actual restore. Neither may install the
   active wallet, stop the database, or run RMAN.
8. Add meaningful offline command/flow fixtures and documentation for both modes.

## Verification planned for implementation

- Verify generated RMAN excludes source SPFILE/password copying and all PDB
  unplug/plug operations; covers every source datafile, redo recovery, new online
  redo/tempfile destinations, requested time, and channel parallelism.
- Verify expected/restored source datafile coverage, explicit failure for
  offline-clean or other unsupported omissions, OMF conversion conflicts, and
  planned pre-open versus actual post-open redo/tempfile inventories.
- Exercise retained parameter/password files and registrations before/after;
  both-node shutdown/restart; restart prevention; unexpected drift; unsupported
  topology; and mode-specific argument rejection.
- Verify that existing, unreachable, or unrebuilt standbys do not block CDB mode;
  no standby connections or apply commands occur; and the recreation warning
  appears. Preserve the existing PDB-mode standby policy and tests.
- Exercise source TDE input copying, unchanged input, incomplete/unsafe files,
  stale target external-store credentials, per-node installation, failure after
  partial installation, and no deletion of final target TDE material.
- Exercise old-file deletion only after full RAC shutdown and required backups;
  exact path protection; deletion of all target datafiles/redo/tempfiles before
  duplication; partial/unknown deletion blocking restore; actual post-delete
  capacity checks; and no automatic rollback or deletion of new restored files.
- Exercise failure boundaries, controlfile/wallet recovery copies,
  source-service isolation, temporary job suppression, unchanged copied
  Scheduler/legacy job states, final PDB naming, and restoration of all agreed
  target service states. Verify that automatic services stay disabled through
  final RAC startup and actual running-state checks occur after restoration.
- Run shell syntax checks, ShellCheck, and relevant existing/new offline fixtures.
  Implementation runs offline tests only; live Oracle acceptance remains separate.
- Require later ExaCC/ZDLRA/RAC/CipherTrust acceptance testing. Offline fixtures
  cannot establish real key access, SBT recovery, or successful RAC reopening.

## Recorded interview decisions

All interview decisions below are resolved. Implementation follows these choices; no design question is pending.

1. **Resolved:** the refreshed target may receive a new DBID, using ordinary
   independent RMAN duplication; any old target standbys need rebuilding.
2. **Resolved:** do not block on current standbys or manage them. Warn that they
   must be recreated; another script handles recreation.
3. **Resolved:** full target downtime during restore/recovery is acceptable.
   Duplicate directly into the stopped target rather than staging another CDB.
4. **Resolved:** a temporary restore PFILE derived from the target configuration
   is allowed. Preserve the original parameter/password files unchanged and use
   the original parameter file for the final RAC restart.
5. **Resolved:** the script backs up the old TDE files after target shutdown and
   installs the supplied source TDE contents at the existing `WALLET_ROOT/tde`
   location on both RAC nodes. Preserve other wallet-root directories.
6. **Resolved:** require portable auto-login `cwallet.sso` input that provides
   unattended access to required source CKMS keys on both target nodes.
   Password-only wallet input is unsupported.
7. **Resolved:** the user approved recreation of redo logs and tempfiles.
   Recovery still consumes the backed-up archived redo required by RMAN.
8. **Resolved:** rename the copied application PDB to `--target-pdb` when it
   differs from `--source-pdb`, preserving target-facing service associations.
   Copy all CDB datafiles regardless of that name mapping.
9. **Resolved:** preserve copied Scheduler and legacy `DBMS_JOB` states. Handle
   jobs externally; do not persistently disable them. Temporary restore startup
   suppression ends when the original target configuration is used again.
10. **Resolved:** delete old target datafiles, redo logs, and tempfiles before
    copying the source database. Preserve the original parameter/password files,
    controlfile copies, and agreed old-TDE backup. No retained-datafile rollback.
11. **Resolved:** CDB mode requires `--work-dir PATH` and omits all `--aux-*`
    arguments. PDB mode retains its existing auxiliary arguments.

Decisions recorded: a new DBID, recreation of redo logs/tempfiles, full target
restore/recovery downtime, a temporary restore PFILE, script-managed TDE backup
and installation on both RAC nodes, portable auto-login wallet input, application
PDB renaming to the target name, unchanged copied job states with external job
handling, pre-copy deletion of old target datafiles/redo/tempfiles, `--work-dir`
for CDB mode without auxiliary arguments, and a warning-only policy for current
standbys are approved. Original parameter/password files remain unchanged; final
RAC startup uses the original parameter file. Standby recreation is handled by
another script. Source credentials on the final copied CDB were already approved
in the preceding discussion. No further interview decision is pending.

## References

- [Oracle 19c DUPLICATE: backup-based modes, new DBID, file handling, and clauses](https://docs.oracle.com/en/database/oracle/oracle-database/19/rcmrf/DUPLICATE.html)
- [Oracle 19c duplication guide: recovery, auxiliary parameters, RAC, and naming](https://docs.oracle.com/en/database/oracle/oracle-database/19/bradv/rman-duplicating-databases.html)
- [Oracle 19c DBNEWID: consequences of renaming a staged database](https://docs.oracle.com/en/database/oracle/oracle-database/19/sutil/oracle-dbnewid-utility.html)
- Existing repository context: `PLAN.md`, `README.md`, `dup_db.sh`, and
  `test_readonly.sh`. Their current behavior is evidence, not a replacement for
  the requirements confirmed for this new mode.
