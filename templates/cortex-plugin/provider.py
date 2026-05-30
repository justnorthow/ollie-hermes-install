import json
import logging
import threading
from .http_client import CortexHttpClient

_logger = logging.getLogger(__name__)

try:
    from agent.memory_provider import MemoryProvider
except ImportError:
    class MemoryProvider:  # type: ignore[no-redef]
        """Stub for running outside Hermes."""


class CortexProvider(MemoryProvider):
    _DEFAULT_API_URL = "http://localhost:9120"

    def __init__(self):
        self._client = None
        self._api_url = self._DEFAULT_API_URL
        self._session_id = ""

    @property
    def name(self) -> str:
        return "cortex"

    def is_available(self) -> bool:
        if self._client is not None:
            return self._client.is_reachable()
        api_url = self._api_url
        try:
            from hermes_cli.config import load_config
            cfg = load_config()
            api_url = cfg.get("memory", {}).get("cortex", {}).get("api_url", api_url)
        except Exception:
            pass
        return CortexHttpClient(api_url).is_reachable()

    def initialize(self, session_id: str, **kwargs) -> None:
        self._session_id = session_id
        api_url = self._api_url
        try:
            from hermes_cli.config import load_config
            cfg = load_config()
            api_url = cfg.get("memory", {}).get("cortex", {}).get("api_url", api_url)
        except Exception:
            pass
        self._api_url = api_url
        self._client = CortexHttpClient(self._api_url)

    def system_prompt_block(self) -> str:
        return (
            "# Cortex Memory\n"
            "Active. You have persistent memory and a brain knowledge base shared across ALL agents.\n\n"
            "Memory tools (per-thought facts about the user):\n"
            "- memory_save: Save important facts, preferences, or context the user shares.\n"
            "- memory_search: Search past memories before answering questions about the user.\n\n"
            "Brain tools (structured knowledge files, shared across agents):\n"
            "- brain_read: Read a brain file by section/file (e.g. 'foundation/company', 'logs/jnow-deliverability').\n"
            "- brain_update: Replace a brain file's entire contents. Use for full rewrites.\n"
            "- brain_append: Append a line or block to a brain file (creates the file if missing). "
            "Use this for longitudinal logs — daily run results, status changes, decisions made.\n\n"
            "Brain paths are always `<section>/<file>`. Sections include 'foundation', 'delivery', 'prospecting', "
            "'content', 'reference' (all pre-defined files), and 'logs' (free-form — you can create any file_id you want "
            "for operational logs). Examples: `logs/jnow-deliverability`, `logs/cron-runs`, `logs/incidents`.\n\n"
            "Brain files are the right place for anything you'll want to reference WEEKS later — "
            "trend lines, decision logs, deliverability history, incident timelines. "
            "Prefer brain_append to the 'logs/' section over writing to local files; brain is shared across all agents.\n\n"
            "Always call memory_save immediately when the user shares personal information or asks you to remember something."
        )

    def get_config_schema(self) -> list[dict]:
        return [
            {
                "key": "api_url",
                "label": "Cortex API URL",
                "type": "string",
                "default": "http://localhost:9120",
            }
        ]

    def save_config(self, config: dict) -> None:
        pass

    def get_tool_schemas(self) -> list[dict]:
        return [
            {
                "name": "memory_search",
                "description": "Search persistent memory for relevant thoughts",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "query": {"type": "string", "description": "Search query"},
                    },
                    "required": ["query"],
                },
            },
            {
                "name": "memory_save",
                "description": "Save a new thought to persistent memory",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "content": {"type": "string"},
                        "importance": {"type": "number", "description": "0.0–1.0", "default": 0.5},
                    },
                    "required": ["content"],
                },
            },
            {
                "name": "memory_pin",
                "description": "Pin a memory thought by ID",
                "parameters": {
                    "type": "object",
                    "properties": {"id": {"type": "string"}},
                    "required": ["id"],
                },
            },
            {
                "name": "memory_unpin",
                "description": "Unpin a memory thought by ID",
                "parameters": {
                    "type": "object",
                    "properties": {"id": {"type": "string"}},
                    "required": ["id"],
                },
            },
            {
                "name": "brain_read",
                "description": "Read a brain knowledge base section by key",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "key": {"type": "string", "description": "Section key (e.g. foundation, delivery)"}
                    },
                    "required": ["key"],
                },
            },
            {
                "name": "brain_update",
                "description": "Replace a brain knowledge base file's entire contents. For full rewrites only.",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "key": {"type": "string", "description": "File path (e.g. foundation/company, jnow-deliverability)"},
                        "content": {"type": "string"},
                    },
                    "required": ["key", "content"],
                },
            },
            {
                "name": "brain_append",
                "description": "Append a line or block to a brain file. Creates the file if it doesn't exist. Use for longitudinal logs — daily run results, decisions, status entries. Preferred over brain_update when you're adding to an existing record.",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "key": {"type": "string", "description": "File path (e.g. jnow-deliverability)"},
                        "content": {"type": "string", "description": "Text to append. A trailing newline is added if missing."},
                    },
                    "required": ["key", "content"],
                },
            },
        ]

    def handle_tool_call(self, name: str, args: dict) -> str:
        try:
            if name == "memory_search":
                results = self._client.get("/memory/thoughts", params={"search": args["query"]})
                return json.dumps(results)
            if name == "memory_save":
                result = self._client.post("/memory/thoughts", args)
                return json.dumps(result)
            if name == "memory_pin":
                self._client.patch(f"/memory/thoughts/{args['id']}/pin")
                return "Pinned."
            if name == "memory_unpin":
                self._client.patch(f"/memory/thoughts/{args['id']}/unpin")
                return "Unpinned."
            if name == "brain_read":
                result = self._client.get(f"/brain/files/{args['key']}")
                # Cortex returns {"body": "...", "exists": bool, ...}
                if isinstance(result, dict):
                    return result.get("body", "") or ""
                return ""
            if name == "brain_update":
                self._client.put(f"/brain/files/{args['key']}", {"content": args["content"]})
                return "Updated."
            if name == "brain_append":
                # Read existing content (tolerate missing files — append should create them).
                try:
                    existing = self._client.get(f"/brain/files/{args['key']}")
                    text = existing.get("body", "") if isinstance(existing, dict) else ""
                except Exception:
                    text = ""
                addition = args["content"]
                # Ensure a clean newline separator between existing content and the new block.
                if text and not text.endswith("\n"):
                    text += "\n"
                text += addition
                if not text.endswith("\n"):
                    text += "\n"
                self._client.put(f"/brain/files/{args['key']}", {"content": text})
                return "Appended."
            return f"Unknown tool: {name}"
        except Exception as e:
            return f"Cortex error: {e}"

    def sync_turn(self, user_content: str, assistant_content: str, *, session_id: str = "") -> None:
        sid = session_id or self._session_id
        def _run():
            try:
                self._client.post(
                    "/agent/sync-turn",
                    {
                        "session_id": sid,
                        "messages": [
                            {"role": "user", "content": user_content},
                            {"role": "assistant", "content": assistant_content},
                        ],
                    },
                )
            except Exception as e:
                _logger.warning("sync_turn failed: %s", e)
        threading.Thread(target=_run, daemon=True).start()
