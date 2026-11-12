# Fix 04: accept padded numeric output from SQL*Plus

## Requested outcome

Fix numeric tempfile parsing in both the read-only collector and the refresh script. Valid Oracle tempfile IDs must not be rejected because SQL*Plus pads numeric columns with whitespace. Keep rejection of malformed data and client errors.

This is an offline code/test fix. Do not connect to Oracle or rerun the report against a live deployment during implementation.

## Reproducer and root cause

In `read_only_report.txt`, section `tempfiles`, `rc_tempfile` successfully returns these rows, each with leading spaces:

```text
         1
         2
         4
         5
         6
         7
```

`test_readonly.sh` function `diag_tempfiles` validates each raw line with `^[0-9]+$`. All six rows therefore fail even though the IDs are valid. The resulting false failure skips ASM capacity checks.

The normal refresh path has the same problem: `dup_db.sh` selects numeric `file#` values into `tempfiles.out`, and `build_duplicate` rejects padded rows before generating `set newname for tempfile ... to new;`. Fixing only the collector would leave the actual refresh broken.

Existing offline SQL fixtures generally emit unpadded IDs such as `3`, so they did not reproduce the deployment output. Scalar numeric queries already handled by `one_line` have separate whitespace handling; do not regress that behavior.

## Required behavior

1. Choose one small, consistent normalization boundary for tempfile ID rows and use it in both paths. A shared helper that trims surrounding whitespace and validates each ID is preferable to unrelated ad hoc fixes. Explicit character formatting in both SELECT queries is also acceptable if every consumer is covered and realistic padded fixtures still pass through validation.
2. Trim only leading/trailing formatting whitespace, including tabs and a trailing carriage return where applicable. Do not delete interior whitespace: `1 2` must never become ID `12`.
3. Validate one positive decimal integer per nonblank row. Handle incidental blank lines consistently; an entirely empty/blank inventory remains a failure. Reject signs, decimal values, zero file IDs, extra columns/tokens, SQL*Plus headings, and Oracle/client error text. Do not evaluate returned text as shell code or unchecked shell arithmetic.
4. Retain the original SQL result as diagnostic evidence. If normalization rewrites a consumer file, save the raw output separately and identify the normalized artifact clearly.
5. Generate correct RMAN commands for every returned ID, without padding or omitted rows. Preserve the existing tempfile remapping, source identity/incarnation, ASM isolation, and requested recovery-time behavior.
6. Let successful tempfile discovery continue to the size query and capacity checks. Numeric size zero is a different case from invalid tempfile ID zero; preserve each field's intended validation rules.
7. Audit other numeric row-list consumers for the same raw-line assumption, but keep changes limited to demonstrated formatting issues. Continue treating ORA/SP2/TNS errors and failed or timed-out clients as failures before consuming their output.

## Likely touchpoints

- `dup_db.sh`: numeric helpers near `one_line`, catalog tempfile queries in `main`, and `build_duplicate`.
- `test_readonly.sh`: `diag_tempfiles`, its tempfile size result, and dependent capacity scheduling.
- `tests/check.sh`: generated RMAN assertions.
- `tests/readonly.sh`: fake SQL*Plus output and report/capacity assertions.
- `tests/asm.sh` or dry-run fixtures if shared numeric handling affects them.

## Acceptance tests

Use the six incident rows as a small synthetic formatting fixture, without copying unrelated topology or credentials from the report.

- Padded rows normalize to exactly `1, 2, 4, 5, 6, 7`; unpadded rows still work.
- Tabs, surrounding spaces, trailing whitespace, CRLF, and incidental blank lines behave as documented.
- Empty/blank-only results, `0`, `-1`, `+1`, `1.0`, `1 2`, `1|2`, alphabetic text, headings, and ORA/SP2/TNS errors fail cleanly.
- `build_duplicate` emits one exact `set newname for tempfile <id> to new;` for every valid ID in both explicit-time and omitted-time cases.
- The collector marks tempfile discovery successful and attempts the expected ASM capacity queries when other required metadata is available. Do not merely remove the validation or force a PASS result.
- A failed size query or insufficient ASM space still fails its applicable check. Preserve credential redaction and zero live Oracle/SSH activity in fixtures.

Run Bash syntax checks, `shellcheck -x dup_db.sh test_readonly.sh tests/*.sh`, and `bash tests/check.sh`. Preserve raw evidence and update relevant troubleshooting notes. This change should be possible before the other three fixes; their tests should then use realistic numeric output.

## Integration

The original report also has genuine wallet, PDB-presence, and broker/topology issues. Fixing this parser must not hide those results. After integrating all four handoffs, add a combined fixture for a missing target PDB, established no-standby topology, automatic wallet-copy planning, and padded tempfile metadata, with the collector remaining read-only.
