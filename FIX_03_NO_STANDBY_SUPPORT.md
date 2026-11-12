# Fix 03: support target databases with no standby

## Requested outcome

The scripts must work with a target CDB that has no configured standby, including a standalone target where Data Guard Broker is disabled or unconfigured. Keep the existing protection for targets that do have physical standbys. This supersedes the blanket requirement in `PLAN.md` and `README.md` that every supported target have an enabled broker configuration.

Implement and validate offline. The operator executes deployment diagnostics manually; do not enable broker, change redo transport, configure Data Guard, or run a live refresh while implementing this fix.

## Evidence and current implementation

`read_only_report.txt` shows a successful target primary/RAC identity check but the aggregate broker-enable query returns `DISABLED`. Discovery aborts before broker membership is inspected, so the report cannot determine whether a standby exists or identify which instance has broker disabled.

Current code already accepts an enabled, healthy, primary-only broker configuration as no standby. That does not cover a standalone target with no broker configuration.

Review:

- `dup_db.sh`: `discover_standbys`, `preflight_broker`, `stop_target_apply`, predrop discovery, `finish`, `DG_HANDOFF`, mandatory client checks, and completion messages.
- `test_readonly.sh`: `diag_clients`, `diag_broker_inventory`, standby check scheduling, and summary wording.
- `tests/broker.sh`, `tests/readonly.sh`, main-flow placement assertions, and documented topology assumptions.

## Required behavior

1. Classify the verified target explicitly: no configured standby, broker-managed physical standbys, or unresolved/unsupported configuration. Save the observations supporting that result.
2. Support both no-standby cases: an enabled healthy broker configuration containing only the verified primary, and a verified standalone target with disabled/unconfigured broker and no configured standby relationships.
3. Do not equate `DG_BROKER_START=FALSE`, a missing executable, a DGMGRL error, empty output, or a failed SQL query with no standby. Collect per-instance parameter values rather than only an aggregate ENABLED/DISABLED result.
4. Design the standalone discovery using documented read-only runtime and persistent configuration evidence across all required target RAC instances. Inspect relevant redo destination configuration, destination states, and Data Guard membership hints; include deferred/disabled/alternate destinations so stopped transport is not mistaken for absence. Verify the chosen Oracle 19c metadata and its limits before implementing classification.
5. Distinguish physical standbys from Recovery Appliance/ZDLRA or other remote endpoints where supported evidence permits. A remote destination alone does not identify a physical standby. Avoid hardcoded hostnames, site names, or assumptions based solely on an endpoint's spelling.
6. If metadata cannot resolve the topology, report UNKNOWN and block normal cutover. A narrowly scoped explicit operator declaration such as `--standby-mode none` may be used if necessary; document its meaning and validate available corroborating configuration. It must not suppress failed identity/discovery queries or contradict positively identified physical standbys. Do not add a generic skip-errors switch.
7. For no standby, skip standby SSH, old-standby-PDB GUID checks, and all broker EDIT/apply commands. Preserve CDB/RAC, storage, service, recovery, TDE, and PDB creation/replacement validation. Do not require a working DGMGRL client solely for a positively established standalone path.
8. For configured broker-managed physical standbys, retain complete membership parsing, verified primary identity, standby instance coverage, applicable old-PDB closure checks, actual apply-stop verification, and the existing no-automatic-resume policy. Configured unmanaged standbys remain an explicit unsupported state unless separately implemented; they cannot take the no-standby branch.
9. Revalidate the topology before service changes and immediately before the target's destructive/create step. A target classified as standalone must abort if a standby relationship appears during auxiliary preparation. Preserve equivalent membership freeze checks on the managed path.
10. Record a truthful no-standby handoff without claiming broker verification occurred when the decision came from standalone metadata. Success/failure messages for standalone targets must not instruct the operator to resume stopped apply or perform a standby refresh that was never involved.

## Read-only reporting

For an established no-standby target, mark topology discovery successful and identify standby-only checks as not applicable. For failed discovery, retain FAIL/UNKNOWN and the reason. Keep all operations read-only and preserve raw observations in the single report. Never attempt to enable broker automatically to make a test pass.

## Acceptance tests

- Healthy broker primary-only configuration continues, preserving existing coverage.
- Disabled/unconfigured broker plus valid standalone evidence continues without standby SSH or broker EDIT; no unnecessary DGMGRL prerequisite blocks it.
- Broker disabled with evidence of a physical standby, inconsistent per-node settings, contradictory metadata, inaccessible inventory, and configured unmanaged replication remain blocked or explicitly unsupported.
- Discovery errors never become successful no-standby results. Distinguish appliance endpoints from physical standbys or report unresolved classification.
- Existing running/stopped/multiple-standby fixtures retain their identity, closure, apply-stop, partial-failure, and handoff guarantees.
- A newly appearing standby relationship aborts before cutover. Cover no standby with both an existing and absent target PDB.

Run Bash syntax checks, ShellCheck, and `bash tests/check.sh` with fake clients. Update `README.md`, `PLAN.md`, help/argument handling if changed, and tests that currently expect every disabled broker to fail regardless of topology. Coordinate old-PDB handling with Fix 02 and preserve the read-only collector's command guards.
