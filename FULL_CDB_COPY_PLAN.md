# Full CDB copy mode — design and interview draft

Status: plan only; implementation is not authorized yet. Branch:
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
- Keep catalog-only source access: no connection to the production database.
- For this branch's current task, write the plan and resolve design questions
  with the user before changing scripts, tests, or operational configuration.

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

## Proposed CLI — names and mode-specific arguments remain provisional

Use `--mode pdb|cdb`, defaulting to `pdb` for backward compatibility.
Use `--source-wallet-dir PATH` for a directory whose direct children are the
source TDE files, including required portable auto-login `cwallet.sso` and,
when present, `ewallet.p12`.
Require that directory in CDB mode and reject it in PDB mode rather than ignoring
it. Never treat its parent as the supplied wallet root.

Retain `--source-cdb`, `--target-cdb`, `--time`, `--zdlra-alias`,
`--restore-parallelism`, logging options, and the default dry run.
Retain `--do-duplicate` as the explicit execution switch.

Recommended first implementation duplicates directly into the stopped target
SID, with datafiles in fresh target-owned OMF locations. It therefore does not
need a separately named auxiliary CDB. Settle the naming of its filesystem work
directory and rejection of irrelevant `--aux-*` options during the interview.
Also settle whether the existing source/target PDB arguments remain required
solely to identify and rename the single application PDB; they must never limit
the set of datafiles copied in CDB mode.

## Recommended architecture — subject to the interview

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
settings. Temporary primary startup isolation remains part of the proposed
restore procedure; it must not become an additional standby approval gate or
silently change the retained file. The final startup uses the retained target
configuration. Do not claim that the existing Data Guard configuration is
healthy or the old standbys are usable; remediation belongs to the separate
script.

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

### 5. Shut down and duplicate into the target

Capture all target service/resource states, stop target services and both RAC
instances through Clusterware, and verify they cannot restart during the work.
The user accepts the full restore/recovery outage; direct duplication does not
need a short cutover or a separately staged database.

Start one controlled target instance in `NOMOUNT` using a temporary PFILE derived
from the target configuration, as approved by the user. Temporary overrides include
`CLUSTER_DATABASE=FALSE` and isolation of listeners, jobs, Broker, and redo
transport. The original parameter/password files stay unchanged, and final RAC
startup uses the original parameter file.

Use catalog-based `DUPLICATE DATABASE ... TO <TARGET_DB_NAME>` with an explicit
temporary `PFILE` and `NOOPEN`. Do not include `SPFILE`, `PASSWORD FILE`,
`FOR STANDBY`, or `FROM ACTIVE DATABASE`. Keep explicit SBT channel allocation
and recovery-time behavior. Do not automatically register or resynchronize the
new target identity into a backup service as part of the refresh.

Restore the source controlfile into the target's configured controlfile locations
only after recoverable copies of old controlfiles exist. Restore all source
datafiles to fresh target-owned OMF locations; do not overwrite old target
datafiles or follow source paths. Validate all resulting file mappings.

Interpret "only source controlfile and datafiles" as excluding the source
parameter/password files and source online redo files. Redo and tempfile
recreation is approved. A functioning duplicate still uses archived redo from
backups as necessary for recovery; it does not copy source online redo files.

Record the exact controlfile-replacement boundary. After that point, restarting
the old parameter file alone is not a rollback.

### 6. Validate and return to the retained target configuration

Before the first open, verify destination identity, file mappings, recovery
result, and any compatibility checks possible while mounted. Open `RESETLOGS`
under controlled isolation and restriction, then validate encrypted data using
the source credentials and all required historical keys.

Before normal listener registration or job execution, remove/reconcile copied
production services, apply the agreed job policy, settle the application PDB
name, and reconcile every retained target service with the resulting dictionary.
Do not run the old post-plug HSM key-import operation.

Shut down the controlled instance and restart through the retained target
parameter file and existing Clusterware resources. Validate both RAC instances,
source-key access, PDB states, services, file inventories, new DBID, and unchanged
parameter/password files. Restore agreed target service/resource states only
after those checks succeed. Record any required backup-registration or standby
rebuild handoff; do not claim those separate procedures are complete.

### 7. Failure handling and recovery evidence

Preserve old target datafiles, protected old controlfiles, and the old TDE wallet
through acceptance, subject to the user's retention decision and capacity checks.
Do not delete old files automatically or attempt an automatic rollback.

Retain precise state: stopped/running resources, active wallet, active controlfile
locations, old/new DBIDs, recovery endpoint, old/new file inventories, and the
last verified phase. Provide manual recovery instructions for failure before
and after controlfile replacement. Do not resume Clusterware services or
standby transport against an incompletely validated database.

## Implementation work after the interview

1. Add mode-aware parsing and validation without changing existing PDB defaults.
2. Split reusable discovery/catalog/storage helpers from PDB-specific execution.
3. Add retained-file snapshots, whole-CDB inventories, and final verification.
4. Add supplied-TDE-directory validation, installation, and permanent lifecycle.
5. Implement the agreed Data Guard policy, complete RAC shutdown/isolation,
   direct duplication, restricted first open, and final target restart.
6. Add CDB-specific service/PDB/job reconciliation and recovery instructions.
7. Extend dry run and the read-only collector with CDB-mode prerequisites and
   clearly label checks that need an actual restore. Neither may install the
   active wallet, stop the database, or run RMAN.
8. Add meaningful offline command/flow fixtures and documentation for both modes.

## Verification planned for implementation

- Verify generated RMAN excludes source SPFILE/password copying and all PDB
  unplug/plug operations; covers every source datafile, redo recovery, new online
  redo/tempfile destinations, requested time, and channel parallelism.
- Exercise retained parameter/password files and registrations before/after;
  both-node shutdown/restart; restart prevention; unexpected drift; unsupported
  topology; and mode-specific argument rejection.
- Verify that existing, unreachable, or unrebuilt standbys do not block CDB mode;
  no standby connections or apply commands occur; and the recreation warning
  appears. Preserve the existing PDB-mode standby policy and tests.
- Exercise source TDE input copying, unchanged input, incomplete/unsafe files,
  stale target external-store credentials, per-node installation, failure after
  partial installation, and no deletion of final target TDE material.
- Exercise failure boundaries, unchanged old datafiles, controlfile/wallet recovery
  copies, suppressed source services/jobs, final PDB naming, and restoration of
  all agreed target service states.
- Run shell syntax checks, ShellCheck, and relevant existing/new offline fixtures.
  For this plan-only task no implementation tests or live Oracle commands run.
- Require later ExaCC/ZDLRA/RAC/CipherTrust acceptance testing. Offline fixtures
  cannot establish real key access, SBT recovery, or successful RAC reopening.

## Interview decision queue

Ask one dependent decision at a time, give a recommendation, and record answers
here before treating proposals above as accepted.

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
8. Should the copied PDB be renamed to the existing/requested target PDB name?
   **Recommend yes** to preserve target-facing service associations; do not
   exclude any CDB datafiles based on that name mapping.
9. May copied production jobs be disabled in the copied dictionary until the
   application refresh procedure completes? **Recommend yes** before removing
   temporary startup isolation.
10. May old target files/controlfiles/wallet remain until manual acceptance?
    **Recommend yes**, with conservative capacity checks and manual cleanup.
11. Which mode-specific working-directory arguments should remain?
    **Recommend one explicit work directory**, without an artificial auxiliary
    database name for direct CDB mode.

Decisions recorded: a new DBID, recreation of redo logs/tempfiles, full target
restore/recovery downtime, a temporary restore PFILE, script-managed TDE backup
and installation on both RAC nodes, portable auto-login wallet input, and a
warning-only policy for current standbys are approved. Original parameter/password
files remain unchanged; final
RAC startup uses the original parameter file. Standby recreation is handled by
another script. Source credentials on the final copied CDB were already approved
in the preceding discussion.
Other recommendations remain provisional.

## References

- [Oracle 19c DUPLICATE: backup-based modes, new DBID, file handling, and clauses](https://docs.oracle.com/en/database/oracle/oracle-database/19/rcmrf/DUPLICATE.html)
- [Oracle 19c duplication guide: recovery, auxiliary parameters, RAC, and naming](https://docs.oracle.com/en/database/oracle/oracle-database/19/bradv/rman-duplicating-databases.html)
- [Oracle 19c DBNEWID: consequences of renaming a staged database](https://docs.oracle.com/en/database/oracle/oracle-database/19/sutil/oracle-dbnewid-utility.html)
- Existing repository context: `PLAN.md`, `README.md`, `dup_db.sh`, and
  `test_readonly.sh`. Their current behavior is evidence, not a replacement for
  the requirements confirmed for this new mode.
