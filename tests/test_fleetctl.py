"""Tests for templates/bin/ollie-fleetctl. Stdlib unittest only; every host
command (systemctl, docker, hermes) and /proc read is mocked so the suite
passes on any OS."""
import importlib.machinery
import importlib.util
import io
import json
import os
import pathlib
import shutil
import sys
import tempfile
import tarfile
import unittest
from unittest import mock
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

    def test_run_cmd_makes_local_bin_resolvable(self):
        # `hermes` lives in ~/.local/bin, which a non-interactive SSH shell does
        # NOT have on PATH. run_cmd must prepend it so `update hermes` (and any
        # other ~/.local/bin tool) resolves instead of failing "hermes: not found".
        import sys
        mod = load_fleetctl()
        local_bin = os.path.join(os.path.expanduser("~"), ".local", "bin")
        # Simulate the non-interactive SSH shell: ~/.local/bin absent from PATH.
        original = os.environ.get("PATH", "")
        os.environ["PATH"] = os.pathsep.join(
            p for p in original.split(os.pathsep) if p and p != local_bin)
        try:
            rc, out, err = mod.run_cmd(
                [sys.executable, "-c", "import os; print(os.environ.get('PATH', ''))"])
        finally:
            os.environ["PATH"] = original
        self.assertEqual(rc, 0, err)
        self.assertIn(local_bin, out.strip().split(os.pathsep))

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
        self.assertEqual(steps, ["git-pull-install-repo", "reinstall-fleetctl",
                                 "hermes-update", "reinstall-cortex-plugin",
                                 "repatch-cron-brain", "reinstall-souls",
                                 "reinstall-identity-sync", "heal-dashboard-units"])
        self.assertEqual(out[-1], {"event": "done", "component": "hermes"})
        self.assertEqual(seen[2], ["hermes", "update"])

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
        self.assertEqual(steps, ["reinstall-stack"])

    def test_update_hermes_pipes_yes_into_hermes_update(self):
        seen = []
        def fake_run(args, timeout=30, input_text=None):
            seen.append((tuple(args), input_text))
            return 0, "", ""
        self.mod.run_cmd = fake_run
        code, _ = run_main(self.mod, ["update", "hermes"])
        self.assertEqual(code, 0)
        inputs = dict(seen)
        self.assertEqual(inputs[("hermes", "update")], "y\ny\ny\ny\ny\n")
        self.assertIsNone(inputs[("git", "-C", self.mod.INSTALL_DIR, "pull", "--ff-only")])

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


class TestErrorContract(unittest.TestCase):
    """Every failure must surface as {"error": ...} on stdout, never a traceback."""

    def test_agents_list_missing_orch_key_emits_error_json(self):
        mod = load_fleetctl()
        mod.ORCH_ENV = "/nonexistent/.env"
        code, out = run_main(mod, ["agents", "list"])
        self.assertNotEqual(code, 0)
        self.assertEqual(len(out), 1)
        self.assertIn("ORCHESTRATOR_KEY", out[0]["error"])

    def test_restart_stack_systemctl_failure_emits_error_json(self):
        mod = load_fleetctl()
        mod.get_units = lambda: (_ for _ in ()).throw(RuntimeError("systemctl failed: no bus"))
        code, out = run_main(mod, ["restart", "stack"])
        self.assertNotEqual(code, 0)
        self.assertEqual(len(out), 1)
        self.assertIn("systemctl failed", out[0]["error"])


class TestBackup(unittest.TestCase):
    def setUp(self):
        self.mod = load_fleetctl()

    def test_collect_backup_paths(self):
        with tempfile.TemporaryDirectory() as d:
            hermes = os.path.join(d, ".hermes")
            os.makedirs(os.path.join(hermes, "profiles", "paige"))
            for rel in ("state.db", "config.yaml", "SOUL.md", "auth.json"):
                pathlib.Path(hermes, rel).write_text("x")
            pathlib.Path(hermes, "profiles", "paige", "state.db").write_text("x")
            pathlib.Path(hermes, "profiles", "paige", "SOUL.md").write_text("x")
            self.mod.HERMES_DIR = hermes
            self.mod.PROFILES_DIR = os.path.join(hermes, "profiles")
            paths = self.mod.collect_backup_paths()
        rels = sorted(os.path.relpath(p, hermes).replace(os.sep, "/") for p in paths)
        self.assertEqual(rels, ["SOUL.md", "auth.json", "config.yaml",
                                "profiles/paige/SOUL.md", "profiles/paige/state.db",
                                "state.db"])

    def test_collect_backup_paths_skips_missing(self):
        with tempfile.TemporaryDirectory() as d:
            self.mod.HERMES_DIR = d
            self.mod.PROFILES_DIR = os.path.join(d, "profiles")
            self.assertEqual(self.mod.collect_backup_paths(), [])


class TestHeartbeatDaemonHelpers(unittest.TestCase):
    def test_clamp_interval(self):
        mod = load_fleetctl()
        self.assertEqual(mod.clamp_interval(1), 5)
        self.assertEqual(mod.clamp_interval(30), 30)
        self.assertEqual(mod.clamp_interval(99999), 720)
        self.assertEqual(mod.clamp_interval("bad"), 30)  # falls back to default

    def test_health_beat_due(self):
        mod = load_fleetctl()
        # never beaten -> due
        self.assertTrue(mod.health_beat_due(1000, None, 5, False))
        # beat_now forces it
        self.assertTrue(mod.health_beat_due(1000, 999, 5, True))
        # within interval -> not due
        self.assertFalse(mod.health_beat_due(1000, 999, 5, False))
        # past interval -> due (5 min = 300s)
        self.assertTrue(mod.health_beat_due(1000 + 301, 1000, 5, False))

    def test_disabled_marker_roundtrip(self):
        mod = load_fleetctl()
        with tempfile.TemporaryDirectory() as d:
            mod.DISABLED_MARKER = os.path.join(d, "disabled")
            self.assertFalse(mod.is_disabled())
            mod.set_disabled()
            self.assertTrue(mod.is_disabled())
            mod.clear_disabled()
            self.assertFalse(mod.is_disabled())


class TestDaemonTick(unittest.TestCase):
    def _mod(self):
        return load_fleetctl()

    def test_active_due_posts_health(self):
        mod = self._mod()
        posted = {}
        mod.get_control = lambda url, token: {"state": "active", "intervalMinutes": 5, "beatNow": False, "controlPollSeconds": 60}
        mod.build_health = lambda: {"fleetctlVersion": mod.VERSION}
        mod.post_json = lambda url, token, payload, timeout=15: posted.setdefault("status", 200) or 200
        env = {"FLEET_URL": "https://f", "FLEET_TOKEN": "t"}
        new_last = mod.daemon_tick(env, last_beat_s=None, now_s=1000)
        self.assertEqual(new_last, 1000)
        self.assertEqual(posted["status"], 200)

    def test_paused_skips_health(self):
        mod = self._mod()
        mod.get_control = lambda url, token: {"state": "paused", "intervalMinutes": 5, "beatNow": False, "controlPollSeconds": 60}
        called = []
        mod.post_json = lambda *a, **k: called.append(1)
        env = {"FLEET_URL": "https://f", "FLEET_TOKEN": "t"}
        new_last = mod.daemon_tick(env, last_beat_s=500, now_s=10000)
        self.assertEqual(new_last, 500)       # unchanged
        self.assertEqual(called, [])          # no beat

    def test_disabled_sets_marker_and_signals(self):
        mod = self._mod()
        mod.get_control = lambda url, token: {"state": "disabled", "intervalMinutes": 5, "beatNow": False, "controlPollSeconds": 60}
        with tempfile.TemporaryDirectory() as d:
            mod.DISABLED_MARKER = os.path.join(d, "disabled")
            env = {"FLEET_URL": "https://f", "FLEET_TOKEN": "t"}
            result = mod.daemon_tick(env, last_beat_s=None, now_s=1000)
            self.assertEqual(result, "DISABLED")
            self.assertTrue(mod.is_disabled())

    def test_tick_no_control_keeps_last(self):
        mod = self._mod()
        mod.get_control = lambda url, token: None  # network blip
        env = {"FLEET_URL": "https://f", "FLEET_TOKEN": "t"}
        self.assertEqual(mod.daemon_tick(env, last_beat_s=42, now_s=1000), 42)


class TestBrainBackup(unittest.TestCase):
    def setUp(self):
        self.mod = load_fleetctl()

    def test_backup_brain_refuses_tty(self):
        # When stdout is a terminal, refuse (the tarball would corrupt the TTY).
        class TTY(io.StringIO):
            def isatty(self):
                return True
        buf = TTY()
        code = 0
        try:
            with redirect_stdout(buf):
                self.mod.main(["backup-brain"])
        except SystemExit as e:
            code = e.code if isinstance(e.code, int) else 1
        self.assertEqual(code, 2)

    def test_backup_brain_snapshots_cortex_db_and_tars_cortex(self):
        # The live cortex.db lives in the cortex-data Docker volume, not under
        # ~/.hermes/cortex. backup-brain must snapshot it via the container and
        # include a `cortex/` entry in the archive.
        calls = []

        def fake_run(args, timeout=30, input_text=None):
            calls.append(args)
            if args[:3] == ["docker", "inspect", "-f"]:
                return (0, "justnorthow/ollie-hermes-cortex:latest\n", "")
            if args[:2] == ["docker", "cp"]:
                dest = args[3]
                if dest.endswith("cortex.db"):
                    open(dest, "w").close()                       # simulate db copy
                else:
                    os.makedirs(os.path.join(dest, "brain"), exist_ok=True)  # brain copy
            return (0, "", "")
        self.mod.run_cmd = fake_run
        tar_argv = {}

        def fake_call(argv, stdout=None):
            tar_argv["v"] = argv
            return 0
        code = 0
        with mock.patch.object(self.mod.subprocess, "call", fake_call):
            try:
                with redirect_stdout(io.StringIO()):
                    self.mod.main(["backup-brain"])
            except SystemExit as e:
                code = e.code if isinstance(e.code, int) else 1
        self.assertEqual(code, 0)
        self.assertTrue(any(a[:3] == ["docker", "exec", "cortex"]
                            and "sqlite3" in " ".join(a) for a in calls),
                        "expected an online sqlite snapshot of cortex.db")
        self.assertIn("cortex", tar_argv["v"])  # archive carries a cortex/ tree

    def test_restore_brain_writes_volume_and_restarts_cortex(self):
        calls = []

        def fake_run(args, timeout=30, input_text=None):
            calls.append(args)
            if args[:3] == ["docker", "inspect", "-f"]:
                return (0, "justnorthow/ollie-hermes-cortex:latest\n", "")
            return (0, "", "")
        self.mod.run_cmd = fake_run

        def fake_call(argv, stdin=None, stdout=None):
            if argv[:2] == ["tar", "xzf"]:
                staging = argv[4]
                os.makedirs(os.path.join(staging, "cortex"))
                open(os.path.join(staging, "cortex", "cortex.db"), "w").close()
            return 0
        archive = io.BytesIO()
        with tarfile.open(fileobj=archive, mode="w:gz") as tf:
            info = tarfile.TarInfo("cortex/cortex.db")
            data = b"db"
            info.size = len(data)
            tf.addfile(info, io.BytesIO(data))

        class FakeStdin:
            buffer = io.BytesIO(archive.getvalue())

        with mock.patch.object(self.mod.subprocess, "call", fake_call):
            with mock.patch.object(self.mod.sys, "stdin", FakeStdin()):
                code, out = run_main(self.mod, ["restore-brain"])
        self.assertEqual(code, 0)
        self.assertTrue(any(a[:2] == ["docker", "stop"] for a in calls), "should stop cortex")
        self.assertTrue(any(a[:2] == ["docker", "start"] for a in calls), "should restart cortex")
        # stop precedes start
        order = [a[1] for a in calls if a[:1] == ["docker"] and len(a) > 1 and a[1] in ("stop", "start")]
        self.assertEqual(order, ["stop", "start"])
        self.assertEqual(out[-1], {"restored": True, "cortexRestarted": True})


class TestSetDashboardAuth(unittest.TestCase):
    def setUp(self):
        self.mod = load_fleetctl()

    def test_writes_env_and_recreates_with_oauth_profile(self):
        calls = []
        self.mod.run_cmd = lambda a, timeout=30, input_text=None: (calls.append(a), (0, "", ""))[1]
        d = tempfile.mkdtemp()
        self.mod.STACK_DIR = d
        self.mod.COMPOSE_FILE = os.path.join(d, "docker-compose.yml")
        payload = {"enabled": True, "provider": "google", "client_id": "cid",
                   "client_secret": "shh", "cookie_secret": "ck",
                   "redirect_url": "https://b/oauth2/callback",
                   "allowed_emails": ["a@x.io"], "allowed_domains": "", "cookie_secure": True}
        old = self.mod.sys.stdin
        try:
            self.mod.sys.stdin = io.StringIO(json.dumps(payload))
            code, out = run_main(self.mod, ["set-dashboard-auth"])
        finally:
            self.mod.sys.stdin = old
        self.assertEqual(code, 0)
        # .env got the OAuth keys, mode 600
        env = open(os.path.join(d, ".env")).read()
        self.assertIn("OAUTH2_PROXY_CLIENT_ID=cid", env)
        self.assertIn("OAUTH2_PROXY_REDIRECT_URL=https://b/oauth2/callback", env)
        # POSIX-only: Windows ignores chmod mode bits. Fleet runs the verb on Linux.
        if os.name == "posix":
            self.assertEqual(oct(os.stat(os.path.join(d, ".env")).st_mode)[-3:], "600")
        # emails file
        self.assertIn("a@x.io", open(os.path.join(d, "oauth2-emails")).read())
        # recreate ran with the oauth profile
        self.assertTrue(any(a[:3] == ["docker", "compose", "-f"] and "--profile" in a and "oauth" in a
                            for a in calls))

    def test_disabled_clears_client_id_and_no_oauth_profile(self):
        calls = []
        self.mod.run_cmd = lambda a, timeout=30, input_text=None: (calls.append(a), (0, "", ""))[1]
        d = tempfile.mkdtemp()
        self.mod.STACK_DIR = d
        self.mod.COMPOSE_FILE = os.path.join(d, "docker-compose.yml")
        payload = {"enabled": False, "provider": "google", "client_id": "cid",
                   "client_secret": "shh", "cookie_secret": "ck",
                   "redirect_url": "https://b/oauth2/callback",
                   "allowed_emails": [], "allowed_domains": "", "cookie_secure": False}
        old = self.mod.sys.stdin
        try:
            self.mod.sys.stdin = io.StringIO(json.dumps(payload))
            code, out = run_main(self.mod, ["set-dashboard-auth"])
        finally:
            self.mod.sys.stdin = old
        self.assertEqual(code, 0)
        env = open(os.path.join(d, ".env")).read()
        # disabling clears CLIENT_ID so the dashboard tri-state falls back to off
        self.assertIn("OAUTH2_PROXY_CLIENT_ID=\n", env)
        # recreate runs without the oauth profile, and only the dashboard service
        recreate = [a for a in calls if a[:3] == ["docker", "compose", "-f"] and "up" in a]
        self.assertTrue(recreate)
        self.assertNotIn("--profile", recreate[0])
        self.assertIn("dashboard", recreate[0])
        self.assertNotIn("oauth2-proxy", recreate[0])
        self.assertEqual(out[0]["recreated"], ["dashboard"])

    def test_supabase_mode_writes_both_envs_and_recreates_without_oauth(self):
        calls = []
        self.mod.run_cmd = lambda a, timeout=30, input_text=None: (calls.append(a), (0, "", ""))[1]
        d = tempfile.mkdtemp()
        self.mod.STACK_DIR = d
        self.mod.COMPOSE_FILE = os.path.join(d, "docker-compose.yml")
        orch_env = os.path.join(d, "orch", ".env")
        self.mod.ORCH_ENV = orch_env
        # Seed a stale oauth client id to prove it gets cleared.
        with open(os.path.join(d, ".env"), "w") as f:
            f.write("OAUTH2_PROXY_CLIENT_ID=stale.apps.googleusercontent.com\n")
        payload = {"mode": "supabase", "enabled": True,
                   "supabase_url": "https://abc.supabase.co",
                   "anon_key": "sb_publishable_xyz",
                   "service_role_key": "sb_secret_123"}
        old = self.mod.sys.stdin
        try:
            self.mod.sys.stdin = io.StringIO(json.dumps(payload))
            code, out = run_main(self.mod, ["set-dashboard-auth"])
        finally:
            self.mod.sys.stdin = old
        self.assertEqual(code, 0)
        with open(os.path.join(d, ".env")) as f:
            stack_env = f.read()
        self.assertIn("SUPABASE_URL=https://abc.supabase.co", stack_env)
        self.assertIn("SUPABASE_ANON_KEY=sb_publishable_xyz", stack_env)
        # oauth gate cleared so the dashboard tri-state falls through to Supabase
        self.assertIn("OAUTH2_PROXY_CLIENT_ID=\n", stack_env)
        # orchestrator .env got URL + service-role key (mode 600)
        with open(orch_env) as f:
            orch = f.read()
        self.assertIn("SUPABASE_URL=https://abc.supabase.co", orch)
        self.assertIn("SUPABASE_SERVICE_ROLE_KEY=sb_secret_123", orch)
        if os.name == "posix":
            self.assertEqual(oct(os.stat(orch_env).st_mode)[-3:], "600")
        # recreate runs WITHOUT the oauth profile, force-recreating only the dashboard
        recreate = [a for a in calls if a[:3] == ["docker", "compose", "-f"] and "up" in a]
        self.assertTrue(recreate)
        self.assertNotIn("--profile", recreate[0])
        self.assertIn("dashboard", recreate[0])
        # the oauth2-proxy container is removed and the orchestrator restarted
        self.assertTrue(any(a[:3] == ["docker", "rm", "-f"] and "oauth2-proxy" in a for a in calls))
        self.assertTrue(any(a == ["systemctl", "--user", "restart", "ollie-orchestrator"] for a in calls))
        self.assertEqual(out[0], {"applied": True, "recreated": ["dashboard"], "orchestratorRestarted": True})

    def test_supabase_mode_writes_cookie_domain(self):
        calls = []
        self.mod.run_cmd = lambda a, timeout=30, input_text=None: (calls.append(a), (0, "", ""))[1]
        d = tempfile.mkdtemp()
        self.mod.STACK_DIR = d
        self.mod.COMPOSE_FILE = os.path.join(d, "docker-compose.yml")
        self.mod.ORCH_ENV = os.path.join(d, "orch", ".env")
        payload = {"mode": "supabase", "enabled": True,
                   "supabase_url": "https://abc.supabase.co",
                   "anon_key": "sb_publishable_xyz",
                   "service_role_key": "sb_secret_123",
                   "cookie_domain": ".jnow.io"}
        old = self.mod.sys.stdin
        try:
            self.mod.sys.stdin = io.StringIO(json.dumps(payload))
            code, out = run_main(self.mod, ["set-dashboard-auth"])
        finally:
            self.mod.sys.stdin = old
        self.assertEqual(code, 0)
        with open(os.path.join(d, ".env")) as f:
            stack_env = f.read()
        self.assertIn("SUPABASE_COOKIE_DOMAIN=.jnow.io", stack_env)

    def test_supabase_disabled_blanks_cookie_domain(self):
        calls = []
        self.mod.run_cmd = lambda a, timeout=30, input_text=None: (calls.append(a), (0, "", ""))[1]
        d = tempfile.mkdtemp()
        self.mod.STACK_DIR = d
        self.mod.COMPOSE_FILE = os.path.join(d, "docker-compose.yml")
        self.mod.ORCH_ENV = os.path.join(d, "orch", ".env")
        # Seed a stale cookie domain to prove disabling blanks it.
        with open(os.path.join(d, ".env"), "w") as f:
            f.write("SUPABASE_COOKIE_DOMAIN=.stale.io\n")
        payload = {"mode": "supabase", "enabled": False}
        old = self.mod.sys.stdin
        try:
            self.mod.sys.stdin = io.StringIO(json.dumps(payload))
            code, out = run_main(self.mod, ["set-dashboard-auth"])
        finally:
            self.mod.sys.stdin = old
        self.assertEqual(code, 0)
        with open(os.path.join(d, ".env")) as f:
            stack_env = f.read()
        self.assertIn("SUPABASE_COOKIE_DOMAIN=\n", stack_env)


class TestEnvSafety(unittest.TestCase):
    def setUp(self):
        self.mod = load_fleetctl()

    def test_write_env_key_rejects_multiline_values(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, ".env")
            with open(path, "w", encoding="utf-8") as f:
                f.write("SAFE=1\n")
            with self.assertRaises(ValueError):
                self.mod.write_env_key(path, "SAFE", "ok\nEVIL=1")
            self.assertEqual(open(path, encoding="utf-8").read(), "SAFE=1\n")

    def test_set_hermes_ui_url_rejects_newline_in_url(self):
        with tempfile.TemporaryDirectory() as d:
            self.mod.STACK_DIR = d
            self.mod.COMPOSE_FILE = os.path.join(d, "docker-compose.yml")
            self.mod.run_cmd = lambda *a, **k: (0, "", "")
            with mock.patch.object(self.mod.sys, "stdin",
                                   io.StringIO('{"url":"https://ok.example\\nEVIL=1"}')):
                code, out = run_main(self.mod, ["set-hermes-ui-url"])
            self.assertNotEqual(code, 0)

    def test_write_env_key_rejects_invalid_key_name(self):
        with tempfile.TemporaryDirectory() as d:
            with self.assertRaises(ValueError):
                self.mod.write_env_key(os.path.join(d, ".env"), "BAD\nKEY", "value")


class TestRestoreSafety(unittest.TestCase):
    def setUp(self):
        self.mod = load_fleetctl()

    def _tar_with_member(self, name):
        path = tempfile.NamedTemporaryFile(delete=False, suffix=".tgz")
        path.close()
        try:
            with tarfile.open(path.name, "w:gz") as tf:
                info = tarfile.TarInfo(name)
                data = b"x"
                info.size = len(data)
                tf.addfile(info, io.BytesIO(data))
            return path.name
        except Exception:
            os.unlink(path.name)
            raise

    def test_restore_rejects_parent_traversal_members(self):
        archive = self._tar_with_member("../escape")
        try:
            with self.assertRaises(ValueError):
                self.mod.validate_restore_archive(archive)
        finally:
            os.unlink(archive)

    def test_restore_rejects_symlink_members(self):
        path = tempfile.NamedTemporaryFile(delete=False, suffix=".tgz")
        path.close()
        try:
            with tarfile.open(path.name, "w:gz") as tf:
                link = tarfile.TarInfo("profiles/default/escape")
                link.type = tarfile.SYMTYPE
                link.linkname = "/etc/passwd"
                tf.addfile(link)
            with self.assertRaises(ValueError):
                self.mod.validate_restore_archive(path.name)
        finally:
            os.unlink(path.name)

    def test_restore_accepts_expected_relative_members(self):
        archive = self._tar_with_member("cortex/cortex.db")
        try:
            self.mod.validate_restore_archive(archive)
        finally:
            os.unlink(archive)

    def test_restore_accepts_expected_directory_members(self):
        path = tempfile.NamedTemporaryFile(delete=False, suffix=".tgz")
        path.close()
        try:
            with tarfile.open(path.name, "w:gz") as tf:
                directory = tarfile.TarInfo("cortex/")
                directory.type = tarfile.DIRTYPE
                tf.addfile(directory)
            self.mod.validate_restore_archive(path.name)
        finally:
            os.unlink(path.name)


class TestDockerComposeTemplate(unittest.TestCase):
    """The dashboard service must pass SUPABASE_URL/SUPABASE_ANON_KEY through from
    the stack .env so Fleet's Supabase apply has somewhere to write them."""

    def test_dashboard_has_supabase_passthrough(self):
        compose = (ROOT / "templates" / "docker-compose.yml").read_text(encoding="utf-8")
        self.assertIn("- SUPABASE_URL=${SUPABASE_URL:-}", compose)
        self.assertIn("- SUPABASE_ANON_KEY=${SUPABASE_ANON_KEY:-}", compose)

    def test_images_are_not_mutable_latest_defaults(self):
        compose = (ROOT / "templates" / "docker-compose.yml").read_text(encoding="utf-8")
        installer = (ROOT / "scripts" / "06-install-stack.sh").read_text(encoding="utf-8")
        self.assertNotIn("ollie-hermes-cortex:latest", compose)
        self.assertNotIn("ollie-hermes-frontend:latest", compose)
        self.assertIn("CORTEX_IMAGE=", installer)
        self.assertIn("FRONTEND_IMAGE=", installer)


class TestInstallScriptContracts(unittest.TestCase):
    def _text(self, rel):
        return (ROOT / rel).read_text(encoding="utf-8")

    def test_fleet_heartbeat_service_user_is_templated(self):
        service = self._text("templates/systemd/ollie-fleet-heartbeat.service")
        install = self._text("scripts/10-install-fleetctl.sh")
        self.assertIn("User=__OLLIE_SERVICE_USER__", service)
        self.assertNotIn("User=ollie", service)
        self.assertIn("SERVICE_USER=\"$(id -un)\"", install)
        self.assertIn("__OLLIE_SERVICE_USER__", install)

    def test_profile_inheritance_does_not_require_pyyaml(self):
        install = self._text("scripts/03-install-profile.sh")
        self.assertNotIn("import yaml", install)
        self.assertIn("def read_model_key", install)

    def test_hermes_installer_uses_pinned_ref_by_default(self):
        install = self._text("scripts/02-install-hermes.sh")
        self.assertIn("HERMES_INSTALL_REF", install)
        self.assertNotIn("raw.githubusercontent.com/NousResearch/hermes-agent/main", install)


class TestDashboardBindsLoopback(unittest.TestCase):
    REPO = pathlib.Path(__file__).resolve().parents[1]

    def _text(self, rel):
        return (self.REPO / rel).read_text(encoding="utf-8")

    def test_dashboard_execstart_uses_loopback_everywhere(self):
        sources = [
            "scripts/02-install-hermes.sh",
            "scripts/03-install-profile.sh",
            "templates/bin/ollie-fleetctl",
        ]
        for rel in sources:
            text = self._text(rel)
            # The dashboard ExecStart must not publicly bind or use --insecure.
            self.assertNotIn("dashboard --host 0.0.0.0", text, rel)
            self.assertNotIn("--insecure", text, rel)
            self.assertIn("dashboard --host 127.0.0.1", text, rel)


class TestSetHermesUiUrl(unittest.TestCase):
    def setUp(self):
        self.mod = load_fleetctl()
        self.tmp = tempfile.mkdtemp()
        self.mod.STACK_DIR = self.tmp
        self.mod.COMPOSE_FILE = os.path.join(self.tmp, "docker-compose.yml")
        self.calls = []
        self.mod.run_cmd = lambda argv, timeout=None, input_text=None: (
            self.calls.append(argv) or (0, "", ""))

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def _env(self):
        return self.mod.read_env_file(os.path.join(self.tmp, ".env"))

    def _run(self, argv, stdin_str):
        old = self.mod.sys.stdin
        try:
            self.mod.sys.stdin = io.StringIO(stdin_str)
            code, out = run_main(self.mod, argv)
        finally:
            self.mod.sys.stdin = old
        return code, out

    def test_writes_url_and_recreates_dashboard(self):
        code, out = self._run(["set-hermes-ui-url"],
                              '{"url": "https://ollie-hermes.jnow.io"}')
        self.assertEqual(code, 0)
        self.assertEqual(self._env().get("HERMES_UI_URL"), "https://ollie-hermes.jnow.io")
        self.assertIn(["docker", "compose", "-f", self.mod.COMPOSE_FILE,
                       "up", "-d", "--force-recreate", "dashboard"], self.calls)
        self.assertEqual(out[0].get("applied"), True)
        self.assertEqual(out[0].get("recreated"), ["dashboard"])

    def test_empty_url_clears_key(self):
        self._run(["set-hermes-ui-url"], '{"url": "https://x.jnow.io"}')
        self._run(["set-hermes-ui-url"], '{"url": ""}')
        self.assertEqual(self._env().get("HERMES_UI_URL"), "")

    def test_non_http_url_fails(self):
        code, out = self._run(["set-hermes-ui-url"], '{"url": "javascript:alert(1)"}')
        self.assertNotEqual(code, 0)


class TestSetVertical(unittest.TestCase):
    def _run(self, mod, payload):
        with mock.patch.object(sys, "stdin", io.StringIO(json.dumps(payload))):
            return run_main(mod, ["set-vertical"])

    def test_writes_env_and_recreates_dashboard(self):
        mod = load_fleetctl()
        with tempfile.TemporaryDirectory() as d:
            mod.STACK_DIR = d
            with open(os.path.join(d, ".env"), "w") as f:
                f.write("HERMES_GATEWAY_KEY=k\n")
            with mock.patch.object(mod, "run_cmd") as rc:
                code, out = self._run(mod, {"vertical": "real-estate"})
            self.assertEqual(code, 0)
            self.assertEqual(out[-1], {"applied": True, "recreated": ["dashboard"]})
            env = mod.read_env_file(os.path.join(d, ".env"))
            self.assertEqual(env["VERTICAL"], "real-estate")
            # dashboard force-recreated so generate-config.sh re-emits config.js
            argv = rc.call_args[0][0]
            self.assertIn("--force-recreate", argv)
            self.assertIn("dashboard", argv)

    def test_empty_clears_the_vertical(self):
        mod = load_fleetctl()
        with tempfile.TemporaryDirectory() as d:
            mod.STACK_DIR = d
            with open(os.path.join(d, ".env"), "w") as f:
                f.write("VERTICAL=real-estate\n")
            with mock.patch.object(mod, "run_cmd"):
                code, out = self._run(mod, {"vertical": ""})
            self.assertEqual(code, 0)
            env = mod.read_env_file(os.path.join(d, ".env"))
            self.assertEqual(env.get("VERTICAL", ""), "")

    def test_rejects_invalid_slug(self):
        mod = load_fleetctl()
        with tempfile.TemporaryDirectory() as d:
            mod.STACK_DIR = d
            with mock.patch.object(mod, "run_cmd") as rc:
                code, _ = self._run(mod, {"vertical": "Bad Slug!"})
            self.assertNotEqual(code, 0)
            rc.assert_not_called()


if __name__ == "__main__":
    unittest.main()
