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


SYSTEMCTL_OUT = (
    "hermes-gateway.service        loaded active running Hermes Gateway\n"
    "hermes-gateway-paige.service  loaded active running Hermes Gateway (paige)\n"
    "hermes-dashboard.service      loaded failed failed  Hermes Dashboard\n"
    "ollie-orchestrator.service    loaded active running Ollie Orchestrator\n"
)

COMPOSE_PS_OUT = (
    '{"Service":"cortex","State":"running","Status":"Up 3 days"}\n'
    '{"Service":"dashboard","State":"exited","Status":"Exited (1) 2 hours ago"}\n'
)


class TestHealth(unittest.TestCase):
    def setUp(self):
        self.mod = load_fleetctl()

    def test_get_units_parses_systemctl(self):
        self.mod.run_cmd = lambda *a, **k: (0, SYSTEMCTL_OUT, "")
        units = self.mod.get_units()
        self.assertEqual(units[0], {"unit": "hermes-gateway.service", "active": "active"})
        self.assertEqual(units[2], {"unit": "hermes-dashboard.service", "active": "failed"})
        self.assertEqual(len(units), 4)

    def test_get_containers_parses_compose_json_lines(self):
        self.mod.run_cmd = lambda *a, **k: (0, COMPOSE_PS_OUT, "")
        cs = self.mod.get_containers()
        self.assertEqual(cs, [
            {"name": "cortex", "state": "running", "status": "Up 3 days"},
            {"name": "dashboard", "state": "exited", "status": "Exited (1) 2 hours ago"},
        ])

    def test_get_units_raises_on_failure(self):
        self.mod.run_cmd = lambda *a, **k: (1, "", "boom")
        with self.assertRaises(RuntimeError):
            self.mod.get_units()

    def test_build_health_degrades_per_collector(self):
        self.mod.get_system = lambda: {"cpuPercent": 5, "ramUsedMb": 1, "ramTotalMb": 2,
                                       "diskUsedGb": 1.0, "diskTotalGb": 2.0}
        self.mod.get_units = lambda: (_ for _ in ()).throw(RuntimeError("systemctl gone"))
        self.mod.get_containers = lambda: []
        self.mod.get_versions = lambda: {"fleetctl": self.mod.VERSION, "hermes": "unknown"}
        self.mod.get_agents_summary = lambda: [{"id": "default"}]
        h = self.mod.build_health()
        self.assertEqual(h["system"]["cpuPercent"], 5)
        self.assertIsNone(h["units"])
        self.assertEqual(h["errors"], ["units: systemctl gone"])
        self.assertEqual(h["agents"], [{"id": "default"}])
        self.assertEqual(h["fleetctlVersion"], self.mod.VERSION)
        self.assertIn("collectedAt", h)

    def test_health_verb_emits_one_json_object(self):
        self.mod.get_system = lambda: None or {}
        self.mod.get_units = lambda: []
        self.mod.get_containers = lambda: []
        self.mod.get_versions = lambda: {"fleetctl": self.mod.VERSION}
        self.mod.get_agents_summary = lambda: []
        code, out = run_main(self.mod, ["health"])
        self.assertEqual(code, 0)
        self.assertEqual(len(out), 1)
        self.assertEqual(out[0]["errors"], [])

    def test_get_containers_parses_compose_array_format(self):
        array_out = ('[{"Service":"cortex","State":"running","Status":"Up 3 days"},'
                     '{"Service":"dashboard","State":"running","Status":"Up 3 days"}]')
        self.mod.run_cmd = lambda *a, **k: (0, array_out, "")
        cs = self.mod.get_containers()
        self.assertEqual([c["name"] for c in cs], ["cortex", "dashboard"])

    def test_get_containers_raises_on_failure(self):
        self.mod.run_cmd = lambda *a, **k: (1, "", "no docker")
        with self.assertRaises(RuntimeError):
            self.mod.get_containers()

    def test_get_containers_empty_output(self):
        self.mod.run_cmd = lambda *a, **k: (0, "", "")
        self.assertEqual(self.mod.get_containers(), [])


class TestAgents(unittest.TestCase):
    def setUp(self):
        self.mod = load_fleetctl()
        self.calls = []

    def fake_orch(self, status, parsed, raw=""):
        def f(method, path, body=None, timeout=30):
            self.calls.append((method, path, body))
            return status, parsed, raw
        return f

    def test_agents_list(self):
        self.mod.orch_request = self.fake_orch(200, {"agents": [{"id": "default"}]})
        code, out = run_main(self.mod, ["agents", "list"])
        self.assertEqual(code, 0)
        self.assertEqual(out, [{"agents": [{"id": "default"}]}])
        self.assertEqual(self.calls, [("GET", "/v1/agents", None)])

    def test_agents_get_requires_id(self):
        code, out = run_main(self.mod, ["agents", "get"])
        self.assertNotEqual(code, 0)

    def test_agents_delete_treats_404_as_success(self):
        self.mod.orch_request = self.fake_orch(404, None)
        code, out = run_main(self.mod, ["agents", "delete", "paige"])
        self.assertEqual(code, 0)
        self.assertEqual(out, [{"deleted": "paige"}])
        self.assertEqual(self.calls, [("DELETE", "/v1/agents/paige", None)])

    def test_agents_update_passes_json_payload(self):
        self.mod.orch_request = self.fake_orch(200, {"id": "paige", "model": "m2"})
        code, out = run_main(self.mod, ["agents", "update", "paige", "--json", '{"model": "m2"}'])
        self.assertEqual(code, 0)
        self.assertEqual(self.calls, [("PATCH", "/v1/agents/paige", {"model": "m2"})])

    def test_agents_set_identity(self):
        self.mod.orch_request = self.fake_orch(200, {"ok": True})
        code, out = run_main(self.mod, ["agents", "set-identity", "default",
                                        "--json", '{"displayName": "Ollie", "soulContent": "# Soul"}'])
        self.assertEqual(code, 0)
        self.assertEqual(self.calls[0][1], "/v1/agents/default/identity")

    def test_agents_create_streams_and_succeeds_on_done(self):
        def fake_stream(method, path, body, timeout=600):
            self.calls.append((method, path, body))
            self.mod.event(event="progress", step="profile")
            self.mod.event(event="done", id="paige")
            return {"event": "done", "id": "paige"}
        self.mod.orch_stream = fake_stream
        code, out = run_main(self.mod, ["agents", "create", "--json", '{"name": "paige"}'])
        self.assertEqual(code, 0)
        self.assertEqual(out[-1]["event"], "done")

    def test_agents_create_fails_without_done(self):
        def fake_stream(method, path, body, timeout=600):
            self.mod.event(event="error", error="boom")
            return {"event": "error", "error": "boom"}
        self.mod.orch_stream = fake_stream
        code, out = run_main(self.mod, ["agents", "create", "--json", '{"name": "paige"}'])
        self.assertEqual(code, 1)

    def test_agents_error_status_fails(self):
        self.mod.orch_request = self.fake_orch(401, None, "unauthorized")
        code, out = run_main(self.mod, ["agents", "list"])
        self.assertEqual(code, 1)
        self.assertIn("error", out[0])

    def test_agents_create_http_error_emits_error_event(self):
        import urllib.error, urllib.request as _ur
        def fake_urlopen(*a, **k):
            raise urllib.error.HTTPError("http://localhost:9123/v1/agents", 400,
                                         "Bad Request", {}, io.BytesIO(b"duplicate name"))
        self.mod.orch_key = lambda: "k"
        real = _ur.urlopen
        _ur.urlopen = fake_urlopen
        try:
            code, out = run_main(self.mod, ["agents", "create", "--json", '{"name": "paige"}'])
        finally:
            _ur.urlopen = real
        self.assertEqual(code, 1)
        self.assertEqual(out[-1]["event"], "error")
        self.assertIn("HTTP 400", out[-1]["error"])
        self.assertIn("duplicate name", out[-1]["error"])

    def test_payload_empty_json_flag_is_invalid_not_stdin(self):
        code, out = run_main(self.mod, ["agents", "create", "--json", ""])
        self.assertEqual(code, 2)
        self.assertIn("invalid JSON payload", out[0]["error"])


if __name__ == "__main__":
    unittest.main()
