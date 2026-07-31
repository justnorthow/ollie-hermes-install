"""Agent-to-agent consult tools, hosted inside the Cortex memory provider.

Why here: Hermes has no generic tool-plugin category. get_tool_schemas /
handle_tool_call / initialize(session_id) is the MemoryProvider contract, and
Cortex is the only surface that both loads and receives the session id. MCP
cannot carry that session id at all, so it cannot carry provenance.

This module owns everything dispatch-specific. provider.py delegates and holds
no dispatch logic, so the two concerns stay separable if a real tool category
ever lands upstream.
"""
import json
import logging
import os
import urllib.error
import urllib.parse
import urllib.request

_logger = logging.getLogger(__name__)

#: Only what this build implements. `local` and `linear` are real modes in the
#: orchestrator's vocabulary, reserved for later slices — advertising tools for
#: them would offer a surface where every call refuses server-side.
_IMPLEMENTED_MODES = frozenset({"direct"})

#: The plugin's own refusal vocabulary, deliberately DISJOINT from the
#: orchestrator's REASON_* set. When a consult fails, whoever reads the tool
#: result should be able to tell whether the plugin could not reach the
#: orchestrator or the orchestrator declined the consult.
REASON_AUTH = "orchestrator_auth_failed"
REASON_UNREACHABLE = "orchestrator_unreachable"
REASON_TIMEOUT = "orchestrator_timeout"
REASON_ERROR = "dispatch_error"
#: Distinct from the server's REASON_NOT_ENABLED ("not_enabled"), which this
#: plugin used to send verbatim. DISPATCH_MODE is set in two places -- the
#: profile env and the orchestrator env -- so the reason and detail both name
#: the profile side specifically, letting the two cases be told apart.
REASON_OFF_LOCALLY = "dispatch_off_locally"
#: A non-401/403 HTTP status (e.g. a 404 from a build without /v1/dispatch/*
#: wired up, or a 500) is a response FROM the orchestrator, not evidence it
#: could not be reached. Keeping this collapsed into REASON_UNREACHABLE (as
#: the ported reference implementation used to) hid a rotated key, a wrong
#: ORCHESTRATOR_URL, a slow consult, and a dead service behind one string.
REASON_ORCHESTRATOR_ERROR = "orchestrator_error"

#: Checked by provider.handle_tool_call to decide what to delegate. Kept as a
#: constant so the routing test can assert it does not overlap memory's names.
TOOL_NAMES = frozenset({"list_teammates", "ask_teammate"})

_PROMPT_BLOCK = (
    "# Teammates\n"
    "You can consult other agents on this box and get an answer in this turn.\n\n"
    "- list_teammates: see who is available and who can be consulted inline.\n"
    "- ask_teammate: ask one teammate a question. Use it for questions, not "
    "for giving out work.\n\n"
    "Two rules, without exception:\n"
    "- Never invent a teammate's answer. If the tool returns ok=false, say "
    "plainly that you could not reach them and why. An invented answer is "
    "worse than no answer, because it is attributed to someone else.\n"
    "- Never say you assigned, handed off, or delegated anything. You can ask "
    "a question and get an answer; there is no work queue. Saying otherwise "
    "would let someone stop tracking work nobody picked up.\n"
)


def refusal(reason: str, detail: str = "") -> dict:
    """A structured refusal. Never carries an answer — the whole point is that
    a model cannot mistake a failure for a teammate's opinion."""
    return {"ok": False, "answer": None, "reason": reason, "detail": detail}


class DispatchTools:
    """Per-session dispatch state. One per initialize() call."""

    def __init__(self, session_id: str):
        self._session_id = session_id or ""

    @property
    def mode(self) -> str:
        raw = os.environ.get("DISPATCH_MODE", "off").strip()
        return raw if raw in _IMPLEMENTED_MODES else "off"

    @property
    def enabled(self) -> bool:
        return self.mode != "off"

    @property
    def agent_id(self) -> str:
        # Deliberately not defaulted. The orchestrator fails closed on an
        # unmatched (agent_id, session_id) pair, so "" produces a clean
        # refusal; a guessed default could match a real agent and resolve
        # someone else's human.
        return os.environ.get("DISPATCH_AGENT_ID", "").strip()

    def payload(self, to_agent: str, question: str) -> dict:
        """The consult body. Carries no identity claim of its own — the
        orchestrator derives the human from (from_agent, session_id)."""
        return {
            "from_agent": self.agent_id,
            "session_id": self._session_id,
            "to_agent": to_agent,
            "question": question,
            "chain": [],
        }

    #: The server's worst case is 60s: owner lookup (10) + tier lookup (10) +
    #: gateway (30) + audit write (10). Giving up before it finishes makes the
    #: orchestrator record a granted consult that never reached the caller.
    _TIMEOUT = 75.0

    @property
    def _base(self) -> str:
        return os.environ.get(
            "ORCHESTRATOR_URL", "http://127.0.0.1:9123").strip().rstrip("/")

    @property
    def _key(self) -> str:
        return os.environ.get("ORCHESTRATOR_KEY", "").strip()

    def _request(self, req) -> dict:
        """Send and parse. Returns a refusal dict on any failure; never raises.

        The detail strings are deliberately written by hand rather than from
        str(exc): urllib renders the full URL, which would put the box's
        internal topology in front of a language model.
        """
        try:
            with urllib.request.urlopen(req, timeout=self._TIMEOUT) as resp:
                data = json.loads(resp.read())
                if not isinstance(data, dict):
                    return refusal(REASON_ERROR,
                                   "the orchestrator sent an unreadable reply")
                return data
        except urllib.error.HTTPError as e:
            if e.code in (401, 403):
                return refusal(REASON_AUTH,
                               "the orchestrator rejected this agent's key")
            return refusal(REASON_ORCHESTRATOR_ERROR,
                           f"the orchestrator returned HTTP {e.code}")
        except TimeoutError:
            return refusal(REASON_TIMEOUT, "the orchestrator did not answer in time")
        except urllib.error.URLError:
            return refusal(REASON_UNREACHABLE, "the orchestrator could not be reached")
        except Exception:  # noqa: BLE001 — a malformed reply must not raise
            _logger.warning("dispatch request failed", exc_info=True)
            return refusal(REASON_ERROR, "the orchestrator sent an unreadable reply")

    def post(self, path: str, body: dict) -> dict:
        req = urllib.request.Request(
            f"{self._base}{path}",
            data=json.dumps(body).encode("utf-8"),
            headers={"Authorization": f"Bearer {self._key}",
                     "Content-Type": "application/json"},
            method="POST",
        )
        return self._request(req)

    def get(self, path: str, params: dict | None = None) -> dict:
        url = f"{self._base}{path}"
        if params:
            url += "?" + urllib.parse.urlencode(params)
        req = urllib.request.Request(
            url, headers={"Authorization": f"Bearer {self._key}"}, method="GET")
        return self._request(req)

    def tool_schemas(self) -> list[dict]:
        """Cortex's convention is "parameters", not "input_schema"."""
        if not self.enabled:
            return []
        return [
            {
                "name": "list_teammates",
                "description": (
                    "List the other agents on this box and whether each can be "
                    "consulted inline."
                ),
                "parameters": {"type": "object", "properties": {}},
            },
            {
                "name": "ask_teammate",
                "description": (
                    "Ask one teammate agent a question and get their answer in "
                    "this turn. Use for questions, not for giving work."
                ),
                "parameters": {
                    "type": "object",
                    "properties": {
                        "to_agent": {
                            "type": "string",
                            "description": "The teammate's agent id, from list_teammates.",
                        },
                        "question": {
                            "type": "string",
                            "description": "The question, self-contained.",
                        },
                    },
                    "required": ["to_agent", "question"],
                },
            },
        ]

    def prompt_block(self) -> str:
        return _PROMPT_BLOCK if self.enabled else ""

    def handle(self, name: str, args: dict) -> str:
        """Route one dispatch tool call. Always returns a JSON string.

        Mode is checked FIRST, before any argument reading or request, so an
        unadvertised-but-called tool cannot produce a live request.
        """
        try:
            if not self.enabled:
                return json.dumps(refusal(
                    REASON_OFF_LOCALLY,
                    "dispatch is off on this profile (DISPATCH_MODE is not "
                    "set to a supported mode on this agent's profile)"))

            if name == "list_teammates":
                data = self.get("/v1/dispatch/teammates",
                                {"agent": self.agent_id, "session_id": self._session_id})
                if isinstance(data, dict) and "ok" not in data:
                    if "teammates" in data:
                        # Defensive, and unreachable against a current
                        # orchestrator: as of 2026-07-30 it stamps `ok` on the
                        # success shape too, so this only fires against an
                        # older build. Kept so the model sees one shape for
                        # both outcomes either way. Never overwrite an `ok` the
                        # server did send — that would turn a refusal into an
                        # apparent success, the worst bug possible in this file.
                        data = {"ok": True, **data}
                    else:
                        # A dict that is neither a server refusal (has `ok`)
                        # nor a recognizable success (has `teammates`) is a
                        # shape-skewed reply from something other than the
                        # orchestrator. Stamping it True would convert an
                        # unreadable reply into an apparent success.
                        data = refusal(REASON_ERROR,
                                       "the orchestrator sent an unreadable reply")
                return json.dumps(data)

            if name == "ask_teammate":
                to_agent = str(args.get("to_agent") or "").strip()
                question = str(args.get("question") or "").strip()
                if not to_agent or not question:
                    return json.dumps(refusal(
                        REASON_ERROR,
                        "ask_teammate needs both to_agent and question"))
                data = self.post("/v1/dispatch/consult", self.payload(to_agent, question))
                if not (isinstance(data, dict) and "ok" in data):
                    # A real consult response, success or refusal, always
                    # carries `ok`. Anything else is a shape-skewed reply that
                    # must not reach the model as an unlabeled dict.
                    data = refusal(REASON_ERROR,
                                   "the orchestrator sent an unreadable reply")
                return json.dumps(data)

            return json.dumps(refusal(REASON_ERROR, f"unknown dispatch tool: {name}"))
        except Exception:  # noqa: BLE001 — nothing here may reach the model as a raise
            _logger.warning("dispatch tool call failed", exc_info=True)
            return json.dumps(refusal(REASON_ERROR, "the dispatch tool failed"))
