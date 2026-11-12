# Fix 02: allow the requested target PDB to be absent

## Requested outcome

An existing target CDB is required; an existing target PDB is optional. If the requested PDB exists, refresh it with the current preservation behavior. If it is absent, recover the source and create the requested PDB in the verified target CDB. This supersedes statements in `PLAN.md` and `README.md` that normal duplication requires an existing target PDB.

Implement using offline fixtures. Deployment runs remain manual; do not execute live SQL, RMAN, service changes, or cutover during implementation.

## Evidence and current implementation

In `read_only_report.txt`, the target is a verified read-write primary, both RAC instances are online, and both node checks pass. The `pdb` query for `D0016E6D` in `C0001E1D` returns zero rows, causing failure and skipped service checks. These identifiers are examples only.

Review the complete path, not just the initial row-count condition:

- `dup_db.sh`: `main`, `preflight_broker`, `observe_standby`, `stop_target_apply`, `snapshot_services`, `restore_pdb_states`, cutover freeze checks, generated `drop-old.sql`, post-plug TDE checks, and final state comparisons.
- `test_readonly.sh`: `diag_pdb`, `diag_services`, standby-node checks, and the conditional scheduling of checks in `diag_main`.
- `tests/check.sh`, `tests/services.sh`, `tests/broker.sh`, `tests/readonly.sh`, and dry-run fixtures.

Many loops currently derive the target RAC node inventory from `pdb.before`. Empty PDB results would silently skip those loops unless this dependency is removed.

## Required behavior

1. Discover and verify target RAC instances independently through CDB/instance metadata. Use that inventory for node identity, HSM, SSH, post-plug validation, and initial creation defaults.
2. Represent successful discovery as explicit states such as PRESENT and ABSENT. ABSENT requires a successful query returning no matching PDB, with the required target RAC instances verified. SQL errors, missing instances, partial PDB visibility, inconsistent GUIDs, or malformed output remain failures.
3. For PRESENT, preserve existing open/restricted/saved states and Clusterware resources. Keep the existing preparation, old-PDB closure, applicable standby checks, drop, copy/plug, key import, and verification ordering.
4. For ABSENT, record that there is no old GUID, open-state snapshot, or saved-state snapshot to restore. Skip only operations specific to an old PDB: close, DROP, old-GUID comparison, and equality against a nonexistent old open/saved state. Do not generate or execute `drop-old.sql` for this path.
5. Recheck existence immediately before cutover and again before creation as appropriate. If the initially absent name appears during preparation, abort before changing it. If an existing PDB disappears or changes identity, abort rather than silently switching paths.
6. Use the existing recovered-PDB copy/plug workflow with `STANDBYS=NONE`, target OMF/ASM storage, target key import, and encrypted-data validation. Keep all source recovery and compatibility gates.
7. For a newly created target, use a documented initial policy: open READ WRITE, unrestricted, on both verified target RAC instances and save its state on both. Verify those actual states instead of comparing against empty pre-run files. Existing-PDB runs must retain their captured policy.
8. Capture relevant existing Clusterware resources even when the PDB is absent. Preserve supported stopped/disabled resources; treat a running service with no corresponding PDB as an inconsistency. Do not invent new application service names or reconstruct unrelated resources. Any service creation beyond normal PDB behavior needs an explicit documented requirement.
9. Use accurate phase/failure messages distinguishing initial creation from replacement. Preserve target CDB identity, root/seed files, backup configuration, and unrelated PDBs/services in both paths.

## Standby interaction

Coordinate with Fix 03. Absence of the target PDB must not suppress standby discovery or actual apply-stop verification when physical standbys exist. Old-PDB GUID/closure checks apply only when there is an old PDB to identify. Define and test the expected absent-PDB observations on discovered standbys; conflicting or inaccessible inventory must remain explicit and must not be converted into a fictitious matching GUID. Preserve the separate standby-refresh handoff and its control of apply resumption.

## Read-only reporting

The collector should report `target PDB absent; initial creation path` as a successful discovery result, list the actual current PDB inventory, and continue applicable service, storage, catalog, node, and standby observations. It must make no PDB, service, saved-state, or Data Guard changes. Update dry-run messages that currently say absence prevents a normal run.

## Acceptance tests

- PRESENT retains existing state and service-preservation behavior.
- ABSENT reaches generated plug/verification logic with fake clients, emits no old-PDB close or DROP, and uses both independently discovered RAC nodes for HSM and final checks.
- New-PDB open and saved states match the documented initial policy; no old-state comparison falsely fails or empty loop silently omits validation.
- Query failure, one unavailable node, partial presence, GUID mismatch, appearance/disappearance during preparation, and conflicting standby inventory block the unsafe path.
- Absent target plus no services, preserved stopped resources, and a contradictory running service are covered separately.
- Test absence with both no standby and managed physical standbys. Existing standby identity/apply gates still run where required.

Run Bash syntax checks, ShellCheck, and `bash tests/check.sh` using fake clients. Update CLI/help text where needed, `README.md`, and conflicting requirements in `PLAN.md`. Keep this change focused on optional PDB presence; wallet copying, no-standby classification, and numeric normalization belong to the other handoffs.
