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


class TestRestartLogs(unittest.TestCase):
    def setUp(self):
        self.mod = load_fleetctl()

    def test_resolve_target_mappings(self):
        m = self.mod
        self.assertEqual(m.resolve_target("gateway"), (["hermes-gateway.service"], []))
        self.assertEqual(m.resolve_target("gateway-paige"), (["hermes-gateway-paige.service"], []))
        self.assertEqual(m.resolve_target("dashboard-karl"), (["hermes-dashboard-karl.service"], []))
        self.assertEqual(m.resolve_target("orchestrator"), (["ollie-orchestrator.service"], []))
        self.assertEqual(m.resolve_target("cortex"), ([], ["cortex"]))
        self.assertEqual(m.resolve_target("frontend"), ([], ["dashboard"]))

    def test_resolve_target_stack_uses_live_units(self):
        self.mod.get_units = lambda: [
            {"unit": "hermes-gateway.service", "active": "active"},
            {"unit": "hermes-dashboard.service", "active": "active"},
            {"unit": "ollie-orchestrator.service", "active": "active"},
        ]
        units, services = self.mod.resolve_target("stack")
        self.assertEqual(units, ["hermes-gateway.service", "hermes-dashboard.service",
                                 "ollie-orchestrator.service"])
        self.assertEqual(services, ["cortex", "dashboard"])

    def test_resolve_target_unknown_raises(self):
        with self.assertRaises(ValueError):
            self.mod.resolve_target("mainframe")

    def test_restart_reports_per_target_results(self):
        seen = []
        def fake_run(args, timeout=30, input_text=None):
            seen.append(args)
            return 0, "", ""
        self.mod.run_cmd = fake_run
        code, out = run_main(self.mod, ["restart", "gateway-paige"])
        self.assertEqual(code, 0)
        self.assertEqual(out[0]["restarted"][0],
                         {"target": "hermes-gateway-paige.service", "ok": True, "error": None})
        self.assertIn(["systemctl", "--user", "restart", "hermes-gateway-paige.service"], seen)

    def test_restart_failure_exits_nonzero(self):
        self.mod.run_cmd = lambda *a, **k: (1, "", "unit not found")
        code, out = run_main(self.mod, ["restart", "gateway"])
        self.assertEqual(code, 1)
        self.assertFalse(out[0]["restarted"][0]["ok"])

    def test_logs_systemd_service(self):
        self.mod.run_cmd = lambda args, timeout=30, input_text=None: (0, "line1\nline2\n", "")
        code, out = run_main(self.mod, ["logs", "gateway-paige", "-n", "50"])
        self.assertEqual(code, 0)
        self.assertEqual(out[0], {"service": "gateway-paige", "lines": ["line1", "line2"]})

    def test_logs_docker_service(self):
        captured = []
        def fake_run(args, timeout=30, input_text=None):
            captured.append(args)
            return 0, "cortex log line\n", ""
        self.mod.run_cmd = fake_run
        code, out = run_main(self.mod, ["logs", "cortex"])
        self.assertEqual(code, 0)
        self.assertIn("logs", captured[0])
        self.assertEqual(out[0]["lines"], ["cortex log line"])

    def test_logs_rejects_stack_target(self):
        code, out = run_main(self.mod, ["logs", "stack"])
        self.assertEqual(code, 2)
        self.assertIn("not a valid logs target", out[0]["error"])


class TestUpdateHeartbeat(unittest.TestCase):
    def setUp(self):
        self.mod = load_fleetctl()

    def test_update_hermes_runs_runbook_in_order(self):
        seen = []
        self.mod.run_cmd = lambda args, timeout=30, input_text=None: (seen.append(args), (0, "", ""))[1]
        code, out = run_main(self.mod, ["update", "hermes"])
        self.assertEqual(code, 0)
        steps = [e["step"] for e in out if e.get("event") == "progress"]
        self.assertEqual(steps, ["git-pull-install-repo", "hermes-update",
                                 "reinstall-cortex-plugin", "repatch-cron-brain",
                                 "reinstall-souls"])
        self.assertEqual(out[-1], {"event": "done", "component": "hermes"})
        self.assertEqual(seen[1], ["hermes", "update"])

    def test_update_stops_and_errors_on_failed_step(self):
        calls = {"n": 0}
        def fake_run(args, timeout=30, input_text=None):
            calls["n"] += 1
            return (1, "", "pull refused") if calls["n"] == 1 else (0, "", "")
        self.mod.run_cmd = fake_run
        code, out = run_main(self.mod, ["update", "hermes"])
        self.assertEqual(code, 1)
        self.assertEqual(out[-1]["event"], "error")
        self.assertEqual(out[-1]["step"], "git-pull-install-repo")
        self.assertEqual(calls["n"], 1)  # stopped at first failure

    def test_update_stack_steps(self):
        self.mod.run_cmd = lambda *a, **k: (0, "", "")
        code, out = run_main(self.mod, ["update", "stack"])
        steps = [e["step"] for e in out if e.get("event") == "progress"]
        self.assertEqual(steps, ["compose-pull", "compose-up"])

    def test_heartbeat_skips_when_not_enrolled(self):
        self.mod.FLEET_ENV = "/nonexistent/.env"
        code, out = run_main(self.mod, ["heartbeat"])
        self.assertEqual(code, 0)
        self.assertIn("skipped", out[0])

    def test_heartbeat_posts_health_with_bearer(self):
        with tempfile.TemporaryDirectory() as d:
            envp = os.path.join(d, ".env")
            with open(envp, "w") as f:
                f.write("FLEET_URL=https://fleet.example.com\nFLEET_TOKEN=tok123\n")
            self.mod.FLEET_ENV = envp
            self.mod.build_health = lambda: {"fleetctlVersion": self.mod.VERSION, "errors": []}
            captured = {}
            def fake_post(url, token, payload, timeout=15):
                captured.update(url=url, token=token, payload=payload)
                return 200
            self.mod.post_json = fake_post
            code, out = run_main(self.mod, ["heartbeat"])
        self.assertEqual(code, 0)
        self.assertEqual(captured["url"], "https://fleet.example.com/heartbeat")
        self.assertEqual(captured["token"], "tok123")
        self.assertIn("health", captured["payload"])
        self.assertEqual(out[0], {"posted": True, "status": 200})


if __name__ == "__main__":
    unittest.main()
