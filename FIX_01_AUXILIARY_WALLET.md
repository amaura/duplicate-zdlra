# Fix 01: create a temporary copy of the target wallet root

## Requested outcome

The user requires the duplication script to make a temporary copy of the target CDB's entire `WALLET_ROOT` directory for the auxiliary. A separately provisioned auxiliary wallet must no longer be mandatory. This requirement supersedes the older prohibitions on automatic wallet copying in `PLAN.md` and `README.md` for this specific target-to-auxiliary copy.

Implement the change in the scripts and their offline tests. The operator runs deployment checks manually; do not connect to live databases or execute a real duplication during implementation.

## Evidence and current implementation

`read_only_report.txt`, section `auxiliary`, fails because `/acfs01/app_acfs/dup/wallet/tde/cwallet.sso` is missing or unreadable. The target's discovered wallet root is `/var/opt/oracle/dbaas_acfs/C0001E1D/wallet_root`; the HSM wallet is reported OPEN on both target RAC instances. These are incident examples, not paths to hardcode.

Inspect these locations by function name; line numbers can change:

- `dup_db.sh`: `parse_args`, initial prerequisites in `main`, target settings discovery, `build_aux_pfile`, auxiliary creation/startup, `finish`, successful auxiliary shutdown.
- `test_readonly.sh`: `diag_parse_args`, `diag_auxiliary`, `diag_settings`, and diagnostic ordering.
- `tests/check.sh`, `tests/readonly.sh`, `tests/asm.sh`, CLI examples and wallet instructions in `README.md` and `PLAN.md`.

Currently `--aux-wallet-root` is mandatory, its `tde/cwallet.sso` must already exist, and `build_aux_pfile` uses that supplied path directly. The initial prerequisite runs before target `WALLET_ROOT` discovery; reorder this dependency.

## Required behavior

1. Discover and validate the source directory from the verified target primary's `wallet_root` parameter. Keep the standard target environment file unchanged. Do not infer the path from the CDB name or connect to production.
2. In `--do-duplicate` mode, create a unique private directory for this run and copy the complete target wallet-root tree into it before auxiliary startup. Preserve the required relative layout, including `tde`, `tde_seps`, and any other source subdirectories. The auxiliary PFILE must reference the actual new copy.
3. Use a real independent copy. Do not point the auxiliary at the target directory, hard-link files back to it, overwrite an existing wallet, or leave writable links that resolve into the original tree. Inspect symlinks and define a safe policy for external or broken links; fail clearly if an independent usable copy cannot be made.
4. Keep the copy outside report/evidence packaging, in a private auxiliary working area. Protect its directory from other users, preserve required owner access, and never print wallet contents or credentials. Record only its path, creation status, and lifecycle status in evidence.
5. Remove the pre-provisioned-wallet requirement. Recommended compatibility approach: make `--aux-wallet-root` optional and treat an explicitly supplied value as a parent for a fresh per-run copy. Otherwise use the run's auxiliary filesystem work directory. Document the final argument meaning and never reuse pre-existing contents as the new copy.
6. Keep catalog SEPS authentication using its established target credential location. Copying the tree must not silently redirect the recovery-catalog connection or change persistent HSM/provider configuration.
7. Fail on incomplete copies or missing required source files before auxiliary startup and before target cutover. Preserve Oracle/RMAN errors: copying credentials does not establish access to every historical production key.
8. Define cleanup around auxiliary lifetime. After confirmed successful auxiliary shutdown, remove only the copy created by this run. On failures where the auxiliary is running or its state is unknown, retain the private copy with an explicit path and manual cleanup instructions. Never remove a wallet still needed by an auxiliary or delete the target source tree.

## Read-only modes

`test_readonly.sh` and the default dry run must not create a wallet copy. They should check the discovered source wallet and the planned copy destination's accessibility without writing test files, and report that copying is deferred to duplication mode. They must stop failing solely because the old auxiliary-wallet path has no `tde/cwallet.sso`. Adjust ordering so source discovery precedes these checks.

## Acceptance tests

- No pre-existing auxiliary wallet: a normal-mode fixture creates an independent copy and generates a PFILE pointing to it.
- Both source and copy contain nested directories and representative binary files; source bytes and permissions remain unchanged, and modifying the copy cannot modify the source.
- Repeated runs use different directories. Existing directories, source/destination aliases, symlinks back into the source, unreadable files, partial-copy errors, and unsafe paths are handled without overwriting source data.
- Dry-run and read-only fixtures create no copied wallet or auxiliary directories.
- A copy failure prevents auxiliary startup and target changes. Successful shutdown permits copy cleanup; failed/unknown auxiliary shutdown preserves it with a clear status.
- Reports and console output contain no wallet contents, including on failure.

Run Bash syntax checks, `shellcheck -x dup_db.sh test_readonly.sh tests/*.sh`, and `bash tests/check.sh`. Use disposable local files and fake clients only. Update help, tests, `README.md`, and conflicting requirements in `PLAN.md`.

## Integration

Coordinate shared target-settings discovery with Fix 02. Preserve the current dynamically discovered ASM storage behavior: wallet copies, the PFILE, XML, audit, and diagnostics use filesystem working space; database datafiles, tempfiles, control files, and redo remain in their isolated ASM namespaces. Apply the other three handoffs' requirements when editing shared functions.
