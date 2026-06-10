"""Tests for templates/bin/ollie-fleetctl. Stdlib unittest only; every host
command (systemctl, docker, hermes) and /proc read is mocked so the suite
passes on any OS."""
import importlib.machinery
import importlib.util
import io
import json
import os
import pathlib
import tempfile
import unittest
from contextlib import redirect_stdout

ROOT = pathlib.Path(__file__).resolve().parents[1]
FLEETCTL_PATH = ROOT / "templates" / "bin" / "ollie-fleetctl"


def load_fleetctl():
    """Load the extensionless script as a module (fresh copy per call)."""
    loader = importlib.machinery.SourceFileLoader("fleetctl", str(FLEETCTL_PATH))
    spec = importlib.util.spec_from_loader("fleetctl", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


def run_main(mod, argv):
    """Run mod.main(argv); return (exit_code, parsed-stdout-lines)."""
    buf = io.StringIO()
    code = 0
    try:
        with redirect_stdout(buf):
            mod.main(argv)
    except SystemExit as e:
        code = e.code if isinstance(e.code, int) else 1
    lines = [json.loads(l) for l in buf.getvalue().splitlines() if l.strip()]
    return code, lines


class TestScaffold(unittest.TestCase):
    def test_version_verb(self):
        mod = load_fleetctl()
        code, out = run_main(mod, ["version"])
        self.assertEqual(code, 0)
        self.assertEqual(out, [{"fleetctl": mod.VERSION}])

    def test_unknown_verb_exits_nonzero(self):
        mod = load_fleetctl()
        code, _ = run_main(mod, ["frobnicate"])
        self.assertNotEqual(code, 0)

    def test_read_env_file(self):
        mod = load_fleetctl()
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, ".env")
            with open(p, "w") as f:
                f.write("# comment\nFLEET_URL=https://fleet.example.com\nFLEET_TOKEN='abc123'\nBAD LINE\n")
            env = mod.read_env_file(p)
        self.assertEqual(env, {"FLEET_URL": "https://fleet.example.com", "FLEET_TOKEN": "abc123"})

    def test_read_env_file_missing_returns_empty(self):
        mod = load_fleetctl()
        self.assertEqual(mod.read_env_file("/nonexistent/.env"), {})

    def test_run_cmd_missing_binary(self):
        mod = load_fleetctl()
        rc, out, err = mod.run_cmd(["definitely-not-a-real-binary-xyz"])
        self.assertEqual(rc, 127)
        self.assertIn("not found", err)

    def test_fail_emits_error_json_and_exit_code(self):
        mod = load_fleetctl()
        buf = io.StringIO()
        with self.assertRaises(SystemExit) as ctx:
            with redirect_stdout(buf):
                mod.fail("boom", 2)
        self.assertEqual(ctx.exception.code, 2)
        self.assertEqual(json.loads(buf.getvalue()), {"error": "boom"})

    def test_read_env_file_skips_empty_key(self):
        mod = load_fleetctl()
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, ".env")
            with open(p, "w") as f:
                f.write("=NOKEY\nGOOD=1\n")
            self.assertEqual(mod.read_env_file(p), {"GOOD": "1"})


if __name__ == "__main__":
    unittest.main()
