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
            "Active. You have persistent memory and a brain knowledge base.\n\n"
            "Use these tools proactively:\n"
            "- memory_save: Save important facts, preferences, or context the user shares. "
            "Call this whenever the user tells you something worth remembering (name, preferences, goals, etc.).\n"
            "- memory_search: Search past memories before answering questions about the user or their context.\n"
            "- brain_read: Read a section of the structured knowledge base (e.g. 'foundation', 'delivery').\n"
            "- brain_update: Update a knowledge base section with new or revised information.\n\n"
            "Always call memory_save immediately when the user shares personal information or explicitly asks you to remember something."
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
                "description": "Update a brain knowledge base section",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "key": {"type": "string"},
                        "content": {"type": "string"},
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
                return result.get("content", "") if isinstance(result, dict) else ""
            if name == "brain_update":
                self._client.put(f"/brain/files/{args['key']}", {"content": args["content"]})
                return "Updated."
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
