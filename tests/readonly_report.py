#!/usr/bin/env python3
"""Offline report privacy checks; no Oracle tools or connections."""
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("readonly_report", ROOT / "lib/readonly_report.py")
REPORT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(REPORT)


class ReportTests(unittest.TestCase):
    def test_structured_identities_and_status(self):
        raw = """ZDLRA read-only diagnostics v1
Source: RETAIL/APP (catalog only)
Target: REPORT/OPEN
=== primary-2: Primary node REPORT2 ===
[PASS] primary-2
--- identity.before ---
REPORT|REPORTM1|81827162|PRIMARY|YES|READ WRITE
--- node.REPORT2.config ---
IDENTITY|REPORT|REPORTM1|81827162|PRIMARY|REPORT2
SETTING|db_block_size|8192
SETTING|db_files|2048
SETTING|undo_tablespace|DATA
SETTING|wallet_root|/private/deployment/wallet
SETTING|service_names|READ,OPEN
SETTING|log_archive_dest_2|SERVICE=supersecret HOST=10.20.30.40 PASSWORD=numeric123
VERSION|19.21.0.0.0
PATCH|35261302|APPLY|SUCCESS
--- target-rac.before ---
REPORT1|private-host1.internal|OPEN|19.21.0.0.0
REPORT2|private-host2.internal|OPEN|19.21.0.0.0
--- source.out ---
727281|91827382
--- incarnation.out ---
28177|81277812001|2025-10-12 10:15:00
--- services.tsv ---
pre_app|enabled|REPORT1,REPORT2|OTHERPDB
SUMMARY: total=4 PASS=4 FAIL=0 SKIP=0
"""
        result = REPORT.Renderer(["RETAIL", "APP", "REPORT", "OPEN"]).render(raw)
        for name in ("RETAIL", "REPORTM1", "REPORT1", "REPORT2", "private-host", "private/deployment", "OTHERPDB", "pre_app", "supersecret", "numeric123", "10.20.30.40", "81827162", "91827382", "727281", "28177"):
            self.assertNotIn(name, result)
        self.assertIn("SETTING|db_block_size|8192", result)
        self.assertIn("SETTING|db_files|2048", result)
        self.assertIn("VERSION|19.21.0.0.0", result)
        self.assertIn("PATCH|35261302|APPLY|SUCCESS", result)
        self.assertIn("81277812001|2025-10-12 10:15:00", result)
        self.assertIn("SUMMARY: total=4 PASS=4 FAIL=0 SKIP=0", result)
        identity = re.search(r"IDENTITY\|([^|]+)\|([^|]+)\|([^|]+)\|PRIMARY\|([^\n]+)", result)
        self.assertIsNotNone(identity)
        self.assertRegex(identity[3], r"\[ID_[0-9]+\]")
        # The node identity and configured/running service use one pseudonym.
        self.assertGreaterEqual(result.count(identity[4]), 3)

    def test_raw_artifacts_and_client_error_text_are_omitted(self):
        raw = """[FAIL] cdb-configuration
--- command.sql ---
select customersecret from secret_table;
--- duplicate.rman ---
connect catalog secretuser/secretpassword@secrethost;
--- client.log ---
leak any raw content including 8675309
=== catalog: Catalog metadata ===
[FAIL] catalog (exit 1)
--- console.txt ---
ORA-28365: Wallet directory /customer/private; supersecret 898989
ERROR: Missing or unsupported Oracle 19c clients; remaining checks will still be attempted.
SP2-0734: unknown command beginning "customer"
SUMMARY: total=2 PASS=0 FAIL=2 SKIP=0
"""
        result = REPORT.Renderer().render(raw)
        for value in ("customersecret", "secret_table", "secretuser", "secretpassword", "secrethost", "8675309", "supersecret", "898989", "/customer/private", '"customer"'):
            self.assertNotIn(value, result)
        self.assertIn("ORA-28365", result)
        self.assertIn("SP2-0734", result)
        self.assertIn("[FAIL] catalog (exit 1)", result)
        self.assertIn("Missing or unsupported Oracle 19c clients", result)
        self.assertIn("SUMMARY: total=2 PASS=0 FAIL=2 SKIP=0", result)

    def test_json_metadata_preserves_capacity_but_no_identifiers_or_hashes(self):
        fingerprint = "a" * 64
        raw = "--- retained.SECRET.PARAM.before.json ---\n" + json.dumps({"source": "+SECRET/PRIVATE/spfile.123", "sha256": fingerprint, "size": 12345}) + "\n--- capacity.SECRET.before.json ---\n" + json.dumps({"usable_mb": 67890, "type": "NORMAL"}) + "\n--- source-tde.inventory.json ---\n" + json.dumps({"customer_wallet.sso": {"size": 81, "sha256": fingerprint}}) + "\n"
        result = REPORT.Renderer(["SECRET"]).render(raw)
        for value in ("SECRET", "+SECRET/PRIVATE/spfile.123", "customer_wallet.sso", fingerprint):
            self.assertNotIn(value, result)
        self.assertIn('"size": 12345', result)
        self.assertIn('"usable_mb": 67890', result)
        self.assertIn('"type": "NORMAL"', result)
        self.assertEqual(result.count("[FINGERPRINT_001]"), 2)

    def test_unrecognized_json_does_not_fall_back_to_raw(self):
        result = REPORT.Renderer().render('--- source.json ---\n{secret: bad json with customer}\n')
        self.assertIn("[unrecognized metadata omitted]", result)
        self.assertNotIn("customer", result)

    def test_client_availability_keeps_tool_labels(self):
        raw = '--- clients.2.json ---\n' + json.dumps({
            'clients': {'sqlplus': True, 'rman': False, 'asmcmd': True},
            'sbt_library_readable': True, 'python': [3, 8]}) + '\n'
        result = REPORT.Renderer().render(raw)
        self.assertIn('"rman": false', result)
        self.assertIn('"sqlplus": true', result)
        self.assertIn('"sbt_library_readable": true', result)
        self.assertIn('"python": [3, 8]', result)

    def test_path_masks_preserve_case_sensitive_differences(self):
        renderer = REPORT.Renderer()
        first = renderer.opaque('/wallet/TARGET', 'PATH')
        second = renderer.opaque('/wallet/target', 'PATH')
        self.assertNotEqual(first, second)
        self.assertEqual(first, renderer.opaque('/wallet/TARGET', 'PATH'))

    def test_cdb_check_results_remain_identifiable(self):
        raw = ('[FAIL] cdb-online-redo (exit 1)\n'
               '[PASS] cdb-clients-2\n[PASS] cdb-asm-1\n'
               '[SKIP] cdb-capacity: Source redo budget unavailable.\n')
        result = REPORT.Renderer().render(raw)
        for line in raw.splitlines():
            self.assertIn(line, result)

    def test_health_metadata_and_names_colliding_with_diagnostic_words(self):
        raw = """--- target-rac.before ---
DATA|WALLET|OPEN|19.0.0.0.0
--- pdb.txt ---
DATA|WALLET|READ WRITE|NO|0123456789ABCDEF0123456789ABCDEF
--- health.1.out ---
IDENTITY|CATALOG|DATABASE|8817271|PRIMARY|YES|READ WRITE|DATA|OPEN|19.21.0.0.0
PDB|3|READ WRITE|NO
CHARSET|NLS_CHARACTERSET|ZHS16GBK
CHARSET|NLS_NCHAR_CHARACTERSET|AL16UTF16
COMPONENT|XDB|19.0.0.0.0|VALID
--- identity.json ---
{"dbid": 8817271, "db_key": 8888888, "bytes": 8817271}
"""
        result = REPORT.Renderer().render(raw)
        self.assertNotIn("DATA|WALLET", result)
        self.assertNotIn("|DATA|", result)
        self.assertNotIn('"dbid": 8817271', result)
        self.assertNotIn('"db_key": 8888888', result)
        self.assertIn('"bytes": 8817271', result)
        self.assertIn("|PRIMARY|YES|READ WRITE|[NAME_", result)
        self.assertIn("PDB|3|READ WRITE|NO", result)
        self.assertIn("CHARSET|NLS_CHARACTERSET|ZHS16GBK", result)
        self.assertIn("CHARSET|NLS_NCHAR_CHARACTERSET|AL16UTF16", result)
        self.assertIn("COMPONENT|XDB|19.0.0.0.0|VALID", result)

    def test_cli_publishes_private_output_and_no_map(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source, output, seeds = root / "raw", root / "report", root / "seeds"
            source.write_text("Source: CUSTOMER/APP (catalog only)\nSUMMARY: total=0 PASS=0 FAIL=0 SKIP=0\n")
            seeds.write_bytes(b"CUSTOMER\0APP\0")
            subprocess.run([sys.executable, str(ROOT / "lib/readonly_report.py"), "--input", str(source), "--output", str(output), "--seed-file", str(seeds)], check=True)
            self.assertNotIn("CUSTOMER", output.read_text())
            self.assertEqual(output.stat().st_mode & 0o777, 0o600)
            self.assertEqual({p.name for p in root.iterdir()}, {"raw", "report", "seeds"})
            original = output.read_text()
            failure = subprocess.run([sys.executable, str(ROOT / "lib/readonly_report.py"), "--input", str(root / "missing"), "--output", str(output)], capture_output=True)
            self.assertEqual(failure.returncode, 2)
            self.assertEqual(output.read_text(), original)


if __name__ == "__main__":
    unittest.main()
