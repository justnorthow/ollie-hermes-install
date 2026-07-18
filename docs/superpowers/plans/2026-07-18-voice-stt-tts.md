# Ollie Voice v1 (Push-to-Talk STT + Spoken Replies TTS) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire the Ollie web frontend to the box's speech engines — browser push-to-talk recording transcribed via a new orchestrator `/v1/audio/transcribe` endpoint (faster-whisper), and spoken agent replies via `/v1/audio/speak` (edge-tts) with per-agent admin-set voices.

**Architecture:** Two new authenticated FastAPI endpoints in the orchestrator (`src/api/audio.py`) using the same nginx-auth_request + `require_bearer` pattern as `src/api/prefs.py`. The frontend adds a recorder hook, a speech lib (markdown stripping + shared audio playback), voice controls in the Chat composer, and a `voice` per-user prefs key. `voice` becomes a per-agent AGENTS_JSON field editable in the agent settings form. Spec: `docs/superpowers/specs/2026-07-18-voice-stt-tts-design.md` (this repo).

**Tech Stack:** FastAPI + faster-whisper (CPU int8, lazy singleton) + edge-tts (orchestrator, Python); React + MediaRecorder + vitest (frontend); bash test harness (install repo).

## Global Constraints

- Endpoints require the trusted `X-Auth-User-Id` header (401 without it) AND router-level `Depends(require_bearer)` — copy the `prefs.py` pattern exactly.
- Transcribe cap: reject > 15 MB with 413; empty body with 400. Speak cap: reject empty text 400, > 5,000 chars 413.
- Voice resolution order: agent's `voice` from AGENTS_JSON → env `TTS_DEFAULT_VOICE` → hardcoded `en-US-AndrewMultilingualNeural`. Unknown agentId falls back, never errors.
- Whisper model from env `WHISPER_MODEL` (default `base`), `device="cpu"`, `compute_type="int8"`, lazily loaded on first request; transcription single-flighted behind an `asyncio.Semaphore(1)` and run in `asyncio.to_thread`.
- Only the newest completed reply ever auto-plays; empty transcript never auto-sends.
- All whisper/edge-tts calls MUST be mocked in tests — no model downloads, no network.
- **Documented deviations from the spec** (both follow existing codebase patterns; approved intent unchanged): (1) `/transcribe` takes a raw request body (`Content-Type: audio/webm`) like the existing avatar upload, NOT multipart — avoids a new `python-multipart` dep; (2) the two client methods go on the existing `OrchestratorClient`, not a separate `AudioClient.ts` file — the frontend has exactly one orchestrator client and Chat already holds it.
- Commit messages: repo convention `feat:`/`fix:`/`test:` prefixes, each commit ends with the `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>` trailer.
- Run commands from each repo's root: orchestrator `D:\workspaces\jnow\ollie-hermes-orchestrator` (`python -m pytest`), frontend `D:\workspaces\jnow\ollie-hermes-frontend` (`npx vitest run`), install `D:\workspaces\jnow\ollie-hermes-install` (bash test scripts).

---

### Task 1: AGENTS_JSON `voice` field (orchestrator)

**Files:**
- Modify: `D:\workspaces\jnow\ollie-hermes-orchestrator\src\agents_json.py`
- Test: `D:\workspaces\jnow\ollie-hermes-orchestrator\tests\test_agents_json.py`

**Interfaces:**
- Consumes: nothing new.
- Produces: `AgentEntry.voice: Optional[str] = None` (last dataclass field); `_entry_to_json` emits `"voice"` when set; `_json_to_entry` reads `d.get("voice")`. Later tasks construct `AgentEntry(..., voice=...)` by keyword.

- [ ] **Step 1: Write the failing tests** — append to `tests/test_agents_json.py`:

```python
def test_voice_round_trips(tmp_path):
    env = tmp_path / ".env"
    env.write_text("AGENTS_JSON=[]\n")
    write_agent(env, AgentEntry(
        id="default", name="Ollie", gateway_port=8642, dashboard_port=9119,
        color="#888888", voice="en-GB-RyanNeural",
    ))
    entries = read_agents(env)
    assert entries[0].voice == "en-GB-RyanNeural"
    # serialized compactly under the "voice" key
    assert '"voice":"en-GB-RyanNeural"' in env.read_text()


def test_voice_absent_is_none_and_not_serialized(tmp_path):
    env = tmp_path / ".env"
    env.write_text("AGENTS_JSON=[]\n")
    write_agent(env, AgentEntry(
        id="default", name="Ollie", gateway_port=8642, dashboard_port=9119,
        color="#888888",
    ))
    assert read_agents(env)[0].voice is None
    assert '"voice"' not in env.read_text()
```

(Match the file's existing imports — it already imports `AgentEntry`, `read_agents`, `write_agent`.)

- [ ] **Step 2: Run to verify failure**

Run: `python -m pytest tests/test_agents_json.py -v -k voice`
Expected: FAIL — `TypeError: ... unexpected keyword argument 'voice'`

- [ ] **Step 3: Implement** — in `src/agents_json.py`:

Add as the LAST field of `AgentEntry` (after `manager_visible`):

```python
    voice: Optional[str] = None
```

In `_entry_to_json`, after the `avatar_url` block (before `d["scope"] = e.scope`):

```python
    if e.voice:
        d["voice"] = e.voice
```

In `_json_to_entry`, add to the constructor call:

```python
        voice=d.get("voice"),
```

- [ ] **Step 4: Run full file** — `python -m pytest tests/test_agents_json.py -v` → all PASS.

- [ ] **Step 5: Commit**

```bash
git add src/agents_json.py tests/test_agents_json.py
git commit -m "feat: add per-agent voice field to AGENTS_JSON entries"
```

---

### Task 2: `voice` through models/lifecycle/agents API + scope-drop bugfix (orchestrator)

**Files:**
- Modify: `D:\workspaces\jnow\ollie-hermes-orchestrator\src\models.py` (UpdateAgent ~line 58, Agent ~line 69)
- Modify: `D:\workspaces\jnow\ollie-hermes-orchestrator\src\lifecycle.py` (UpdateRequest ~line 224, update_agent ~line 318)
- Modify: `D:\workspaces\jnow\ollie-hermes-orchestrator\src\api\agents.py` (`_entry_to_agent` ~line 29)
- Test: `D:\workspaces\jnow\ollie-hermes-orchestrator\tests\test_lifecycle_update.py`, `tests\test_api_agents.py`

**Interfaces:**
- Consumes: `AgentEntry.voice` from Task 1.
- Produces: `UpdateAgent.voice: Optional[str]` (pydantic, max_length=128); `UpdateRequest.voice: Optional[str] = None`; `Agent.voice: Optional[str] = None` served on `GET /v1/agents` and `PATCH /v1/agents/{id}`. `""` clears the voice (same tri-state as subtitle).

**Bugfix folded in (same constructor we must touch):** `update_agent`'s `new_entry = AgentEntry(...)` omits `scope` and `manager_visible`, so ANY agent PATCH silently resets `scope` to `"company"` and `manager_visible` to `False` — for Ollie (`scope:"user"`) that fail-closes members out of their own assistant on the next RBAC check. Preserve both from `entry`.

- [ ] **Step 1: Write the failing tests** — append to `tests/test_lifecycle_update.py` (mirror the file's existing fixtures/idioms — it uses the `fake_env` conftest fixture and calls `update_agent` via `asyncio`/`pytest.mark.asyncio` like its neighbors; copy the pattern of the existing subtitle test):

```python
@pytest.mark.asyncio
async def test_update_sets_and_clears_voice(fake_env):
    env_path = fake_env["stack"] / ".env"
    write_agent(env_path, AgentEntry(
        id="marketing-agent", name="Olivia", gateway_port=8643,
        dashboard_port=9121, color="#888888",
    ))
    r = await update_agent("marketing-agent", UpdateRequest(voice="en-US-EmmaNeural", restart=False))
    assert r["ok"]
    assert read_agents(env_path)[0].voice == "en-US-EmmaNeural"
    r = await update_agent("marketing-agent", UpdateRequest(voice="", restart=False))
    assert r["ok"]
    assert read_agents(env_path)[0].voice is None


@pytest.mark.asyncio
async def test_update_preserves_scope_and_manager_visible(fake_env):
    env_path = fake_env["stack"] / ".env"
    write_agent(env_path, AgentEntry(
        id="default", name="Ollie", gateway_port=8642, dashboard_port=9119,
        color="#888888", scope="user", manager_visible=True, voice="en-GB-RyanNeural",
    ))
    r = await update_agent("default", UpdateRequest(displayName="Ollie2", restart=False))
    assert r["ok"]
    e = read_agents(env_path)[0]
    assert e.scope == "user"
    assert e.manager_visible is True
    assert e.voice == "en-GB-RyanNeural"   # untouched update preserves voice too
```

And to `tests/test_api_agents.py` (mirror its existing list test that asserts on `subtitle`):

```python
def test_list_agents_includes_voice(...existing fixture...):
    # seed an entry with voice="en-GB-RyanNeural" the way neighboring tests seed subtitle,
    # then: assert body["agents"][0]["voice"] == "en-GB-RyanNeural"
    # and for an entry without voice: assert body["agents"][0]["voice"] is None
```

(The implementer copies the file's existing seeding fixture verbatim — same as the subtitle assertions there.)

- [ ] **Step 2: Run to verify failure**

Run: `python -m pytest tests/test_lifecycle_update.py tests/test_api_agents.py -v -k "voice or preserves_scope"`
Expected: FAIL — `unexpected keyword argument 'voice'` / scope assertion fails with `'company'`.

- [ ] **Step 3: Implement**

`src/models.py` — `UpdateAgent` gains (after `avatar_url`):

```python
    voice: Optional[str] = Field(default=None, max_length=128)
```

`Agent` gains (after `scope`):

```python
    voice: Optional[str] = None
```

`src/lifecycle.py` — `UpdateRequest` gains (after `avatar_url`, before `restart`):

```python
    voice: Optional[str] = None
```

In `update_agent`, after the `new_avatar_url` block add the same tri-state:

```python
        if req.voice is not None:
            new_voice = req.voice.strip() or None   # "" clears
        else:
            new_voice = entry.voice                  # untouched
```

and fix the `new_entry` constructor to preserve RBAC fields and carry voice:

```python
        new_entry = AgentEntry(
            id=entry.id,
            name=req.displayName if req.displayName is not None else entry.name,
            gateway_port=entry.gateway_port,
            dashboard_port=entry.dashboard_port,
            color=req.color if req.color is not None else entry.color,
            model=req.model if req.model is not None else entry.model,
            subtitle=new_subtitle,
            avatar_url=new_avatar_url,
            # scope/manager_visible were silently reset to defaults by every
            # PATCH before (fail-closing members out of scope:"user" agents).
            scope=entry.scope,
            manager_visible=entry.manager_visible,
            voice=new_voice,
        )
```

`src/api/agents.py` — `_entry_to_agent`'s `Agent(...)` call adds:

```python
        voice=e.voice,
```

- [ ] **Step 4: Run** — `python -m pytest tests/ -v -x` (full suite) → all PASS.

- [ ] **Step 5: Commit**

```bash
git add src/models.py src/lifecycle.py src/api/agents.py tests/test_lifecycle_update.py tests/test_api_agents.py
git commit -m "feat: per-agent TTS voice on update/list; fix PATCH dropping scope/manager_visible"
```

---

### Task 3: `POST /v1/audio/speak` (orchestrator)

**Files:**
- Create: `D:\workspaces\jnow\ollie-hermes-orchestrator\src\api\audio.py`
- Modify: `D:\workspaces\jnow\ollie-hermes-orchestrator\src\api\main.py` (import + include_router, ~lines 19/46)
- Modify: `D:\workspaces\jnow\ollie-hermes-orchestrator\requirements.txt`
- Test: `D:\workspaces\jnow\ollie-hermes-orchestrator\tests\test_audio_api.py`

**Interfaces:**
- Consumes: `read_agents` + `AgentEntry.voice` (Task 1); `require_bearer` from `src.auth`; `TokenBucket` from `src.rate_limit`; `request.app.state.config.hermes_stack_dir`.
- Produces: `POST /v1/audio/speak` `{text: str, agentId: str}` → `audio/mpeg` bytes. Module test seams: `audio._synthesize(text, voice) -> bytes` (async), `audio._resolve_voice(agent_id, cfg) -> str`, module constants `_MAX_SPEAK_CHARS = 5000`, `_FALLBACK_VOICE = "en-US-AndrewMultilingualNeural"`.

- [ ] **Step 1: Write the failing tests** — create `tests/test_audio_api.py` (mirrors `tests/test_prefs_api.py` idioms):

```python
"""Browser-facing STT/TTS endpoints (Ollie Voice v1). Engines mocked."""
import types

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from src.agents_json import AgentEntry, write_agent
from src.api import audio as audio_mod
from src.api.audio import router as audio_router
from src.auth import require_bearer


@pytest.fixture
def ctx(tmp_path, monkeypatch):
    stack = tmp_path / "hermes-stack"
    stack.mkdir()
    (stack / ".env").write_text("AGENTS_JSON=[]\n")
    write_agent(stack / ".env", AgentEntry(
        id="marketing-agent", name="Olivia", gateway_port=8643,
        dashboard_port=9121, color="#888888", voice="en-US-EmmaNeural",
    ))
    app = FastAPI()
    app.state.config = types.SimpleNamespace(hermes_stack_dir=stack)
    app.include_router(audio_router)
    app.dependency_overrides[require_bearer] = lambda: None
    # fresh rate bucket per test so 429s can't leak between tests
    monkeypatch.setattr(audio_mod, "_bucket", audio_mod.TokenBucket(rate_per_min=1000))
    return TestClient(app), monkeypatch


AUTH = {"X-Auth-User-Id": "u1"}


def _mock_synth(monkeypatch, out=b"MP3BYTES"):
    calls = []
    async def fake(text, voice):
        calls.append((text, voice))
        return out
    monkeypatch.setattr(audio_mod, "_synthesize", fake)
    return calls


def test_speak_requires_signed_in_user(ctx):
    c, _ = ctx
    r = c.post("/v1/audio/speak", json={"text": "hi", "agentId": "marketing-agent"})
    assert r.status_code == 401


def test_speak_returns_mpeg_with_agent_voice(ctx):
    c, monkeypatch = ctx
    calls = _mock_synth(monkeypatch)
    r = c.post("/v1/audio/speak", json={"text": "hello there", "agentId": "marketing-agent"}, headers=AUTH)
    assert r.status_code == 200
    assert r.headers["content-type"].startswith("audio/mpeg")
    assert r.content == b"MP3BYTES"
    assert calls == [("hello there", "en-US-EmmaNeural")]


def test_speak_unknown_agent_falls_back_to_env_then_default(ctx):
    c, monkeypatch = ctx
    calls = _mock_synth(monkeypatch)
    monkeypatch.setenv("TTS_DEFAULT_VOICE", "en-AU-WilliamNeural")
    assert c.post("/v1/audio/speak", json={"text": "x", "agentId": "nope"}, headers=AUTH).status_code == 200
    monkeypatch.delenv("TTS_DEFAULT_VOICE")
    assert c.post("/v1/audio/speak", json={"text": "y", "agentId": "nope"}, headers=AUTH).status_code == 200
    assert calls[0][1] == "en-AU-WilliamNeural"
    assert calls[1][1] == audio_mod._FALLBACK_VOICE


def test_speak_caps(ctx):
    c, monkeypatch = ctx
    _mock_synth(monkeypatch)
    assert c.post("/v1/audio/speak", json={"text": "  ", "agentId": "a"}, headers=AUTH).status_code == 400
    assert c.post("/v1/audio/speak", json={"text": "x" * 5001, "agentId": "a"}, headers=AUTH).status_code == 413


def test_speak_engine_failure_is_502(ctx):
    c, monkeypatch = ctx
    async def boom(text, voice):
        raise RuntimeError("edge down")
    monkeypatch.setattr(audio_mod, "_synthesize", boom)
    r = c.post("/v1/audio/speak", json={"text": "hi", "agentId": "marketing-agent"}, headers=AUTH)
    assert r.status_code == 502


def test_speak_rate_limited_is_429(ctx):
    c, monkeypatch = ctx
    _mock_synth(monkeypatch)
    monkeypatch.setattr(audio_mod, "_bucket", audio_mod.TokenBucket(rate_per_min=1))
    assert c.post("/v1/audio/speak", json={"text": "a", "agentId": "x"}, headers=AUTH).status_code == 200
    assert c.post("/v1/audio/speak", json={"text": "b", "agentId": "x"}, headers=AUTH).status_code == 429
```

- [ ] **Step 2: Run to verify failure**

Run: `python -m pytest tests/test_audio_api.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'src.api.audio'`

- [ ] **Step 3: Implement** — create `src/api/audio.py`:

```python
"""Browser-facing STT/TTS endpoints (Ollie Voice v1).

Upstream hermes-agent's API server has no audio surface (its capability
flags hardcode audio_api=false), so the orchestrator provides the HTTP
plumbing between the browser and the box's speech engines: faster-whisper
for transcription, edge-tts for synthesis. Auth mirrors src/api/prefs.py:
router-level bearer plus the trusted X-Auth-User-Id header set by nginx's
cryptographic auth_request (unforgeable by the browser).
"""
import asyncio
import io
import logging
import os

from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.responses import Response
from pydantic import BaseModel

from src.agents_json import read_agents
from src.auth import require_bearer
from src.rate_limit import TokenBucket

_logger = logging.getLogger(__name__)

router = APIRouter(prefix="/v1/audio", tags=["audio"], dependencies=[Depends(require_bearer)])

_MAX_AUDIO_BYTES = 15 * 1024 * 1024
_MAX_SPEAK_CHARS = 5000
_FALLBACK_VOICE = "en-US-AndrewMultilingualNeural"

# Interactive endpoints; the bucket is an abuse backstop, not a quota.
_bucket = TokenBucket(rate_per_min=30)


def _trusted_user_id(request: Request) -> str:
    user_id = request.headers.get("X-Auth-User-Id", "").strip()
    if not user_id:
        raise HTTPException(status_code=401, detail="not signed in")
    return user_id


def _rate_check(user_id: str) -> None:
    if not _bucket.take(user_id):
        raise HTTPException(status_code=429, detail="rate limited")


class SpeakRequest(BaseModel):
    text: str
    agentId: str = ""


def _resolve_voice(agent_id: str, cfg) -> str:
    """Agent voice -> TTS_DEFAULT_VOICE -> hardcoded default. Never raises:
    TTS should degrade to a default voice, not gate on config problems."""
    try:
        for e in read_agents(cfg.hermes_stack_dir / ".env"):
            if e.id == agent_id:
                if e.voice:
                    return e.voice
                break
    except Exception:
        _logger.warning("voice resolution failed for %s", agent_id, exc_info=True)
    return os.environ.get("TTS_DEFAULT_VOICE", "").strip() or _FALLBACK_VOICE


async def _synthesize(text: str, voice: str) -> bytes:
    import edge_tts

    buf = bytearray()
    async for chunk in edge_tts.Communicate(text, voice).stream():
        if chunk["type"] == "audio":
            buf.extend(chunk["data"])
    return bytes(buf)


@router.post("/speak")
async def speak(body: SpeakRequest, request: Request) -> Response:
    _rate_check(_trusted_user_id(request))
    text = body.text.strip()
    if not text:
        raise HTTPException(status_code=400, detail="empty text")
    if len(text) > _MAX_SPEAK_CHARS:
        raise HTTPException(status_code=413, detail="text too long")
    voice = _resolve_voice(body.agentId, request.app.state.config)
    try:
        audio = await asyncio.wait_for(_synthesize(text, voice), timeout=60.0)
    except Exception as exc:
        _logger.warning("tts synthesis failed (voice=%s): %s", voice, exc, exc_info=True)
        raise HTTPException(status_code=502, detail="synthesis failed")
    if not audio:
        raise HTTPException(status_code=502, detail="synthesis returned no audio")
    return Response(content=audio, media_type="audio/mpeg")
```

`src/api/main.py`: add `from src.api.audio import router as audio_router` with the other router imports, and `app.include_router(audio_router)` with the other includes.

`requirements.txt`: append

```
edge-tts>=7.0.0
```

Then `pip install -r requirements.txt` in the repo venv so the import works at runtime (tests never call it).

- [ ] **Step 4: Run** — `python -m pytest tests/test_audio_api.py -v` → all PASS; then full suite `python -m pytest tests/ -x -q`.

- [ ] **Step 5: Commit**

```bash
git add src/api/audio.py src/api/main.py requirements.txt tests/test_audio_api.py
git commit -m "feat: POST /v1/audio/speak — edge-tts synthesis with per-agent voice"
```

---

### Task 4: `POST /v1/audio/transcribe` (orchestrator)

**Files:**
- Modify: `D:\workspaces\jnow\ollie-hermes-orchestrator\src\api\audio.py`
- Modify: `D:\workspaces\jnow\ollie-hermes-orchestrator\requirements.txt`
- Test: `D:\workspaces\jnow\ollie-hermes-orchestrator\tests\test_audio_api.py`

**Interfaces:**
- Consumes: Task 3's module (`_trusted_user_id`, `_rate_check`, `_MAX_AUDIO_BYTES`).
- Produces: `POST /v1/audio/transcribe` — raw body (`Content-Type: audio/webm`) → `{"text": str}`. Test seams: `audio._get_model()` (lazy singleton loader), `audio._transcribe_with(model, data: bytes) -> str`, `audio._transcribe_gate` (`asyncio.Semaphore(1)`).

- [ ] **Step 1: Write the failing tests** — append to `tests/test_audio_api.py`:

```python
class _FakeSeg:
    def __init__(self, text):
        self.text = text


class _FakeModel:
    def __init__(self, segs=("hello", "world")):
        self.calls = 0
        self._segs = segs

    def transcribe(self, f):
        self.calls += 1
        return [_FakeSeg(f" {s} ") for s in self._segs], {"language": "en"}


def test_transcribe_requires_signed_in_user(ctx):
    c, _ = ctx
    assert c.post("/v1/audio/transcribe", content=b"xx").status_code == 401


def test_transcribe_joins_segments(ctx):
    c, monkeypatch = ctx
    model = _FakeModel()
    monkeypatch.setattr(audio_mod, "_get_model", lambda: model)
    r = c.post("/v1/audio/transcribe", content=b"FAKEWEBM", headers=AUTH)
    assert r.status_code == 200
    assert r.json() == {"text": "hello world"}
    assert model.calls == 1


def test_transcribe_caps(ctx):
    c, monkeypatch = ctx
    monkeypatch.setattr(audio_mod, "_get_model", lambda: _FakeModel())
    assert c.post("/v1/audio/transcribe", content=b"", headers=AUTH).status_code == 400
    big = b"x" * (audio_mod._MAX_AUDIO_BYTES + 1)
    assert c.post("/v1/audio/transcribe", content=big, headers=AUTH).status_code == 413


def test_transcribe_decode_failure_is_400(ctx):
    c, monkeypatch = ctx
    class _Broken:
        def transcribe(self, f):
            raise ValueError("not audio")
    monkeypatch.setattr(audio_mod, "_get_model", lambda: _Broken())
    r = c.post("/v1/audio/transcribe", content=b"not-audio", headers=AUTH)
    assert r.status_code == 400


def test_transcribe_model_load_failure_is_502(ctx):
    c, monkeypatch = ctx
    def boom():
        raise RuntimeError("no ctranslate2")
    monkeypatch.setattr(audio_mod, "_get_model", boom)
    assert c.post("/v1/audio/transcribe", content=b"xx", headers=AUTH).status_code == 502


def test_transcribe_silence_returns_empty_text(ctx):
    c, monkeypatch = ctx
    monkeypatch.setattr(audio_mod, "_get_model", lambda: _FakeModel(segs=()))
    r = c.post("/v1/audio/transcribe", content=b"quiet", headers=AUTH)
    assert r.status_code == 200
    assert r.json() == {"text": ""}
```

- [ ] **Step 2: Run to verify failure**

Run: `python -m pytest tests/test_audio_api.py -v -k transcribe`
Expected: FAIL — 404 (route missing) / `AttributeError: _get_model`.

- [ ] **Step 3: Implement** — append to `src/api/audio.py`:

```python
_whisper_model = None
# Single-flight: transcription is CPU-bound; queue concurrent requests
# instead of stacking whisper runs on a small VPS.
_transcribe_gate = asyncio.Semaphore(1)


def _get_model():
    """Lazy process-wide singleton so idle orchestrator memory stays flat and
    startup never blocks on a model download. First call on a box downloads
    the model to the user cache (shared with Hermes — same service user)."""
    global _whisper_model
    if _whisper_model is None:
        from faster_whisper import WhisperModel

        name = os.environ.get("WHISPER_MODEL", "").strip() or "base"
        _logger.info("loading whisper model %r (first transcription request)", name)
        _whisper_model = WhisperModel(name, device="cpu", compute_type="int8")
    return _whisper_model


def _transcribe_with(model, data: bytes) -> str:
    # faster-whisper decodes WebM/Opus via its bundled PyAV — no ffmpeg binary.
    segments, _info = model.transcribe(io.BytesIO(data))
    return " ".join(s.text.strip() for s in segments).strip()


@router.post("/transcribe")
async def transcribe(request: Request) -> dict:
    _rate_check(_trusted_user_id(request))
    body = await request.body()
    if not body:
        raise HTTPException(status_code=400, detail="empty body")
    if len(body) > _MAX_AUDIO_BYTES:
        raise HTTPException(status_code=413, detail="audio too large")
    async with _transcribe_gate:
        try:
            model = await asyncio.to_thread(_get_model)
        except Exception:
            _logger.exception("whisper model load failed")
            raise HTTPException(status_code=502, detail="transcription engine unavailable")
        try:
            text = await asyncio.to_thread(_transcribe_with, model, body)
        except Exception as exc:
            _logger.warning("transcription failed: %s", exc, exc_info=True)
            raise HTTPException(status_code=400, detail="could not decode audio")
    return {"text": text}
```

`requirements.txt`: append

```
faster-whisper>=1.1.0
```

and `pip install -r requirements.txt` in the venv.

- [ ] **Step 4: Run** — `python -m pytest tests/test_audio_api.py -v` then full `python -m pytest tests/ -x -q` → PASS.

- [ ] **Step 5: Commit**

```bash
git add src/api/audio.py requirements.txt tests/test_audio_api.py
git commit -m "feat: POST /v1/audio/transcribe — lazy faster-whisper, single-flight, raw-body upload"
```

---

### Task 5: install repo — merge preserves `voice`, env docs

**Files:**
- Modify: `D:\workspaces\jnow\ollie-hermes-install\scripts\lib\merge-agents-json.py`
- Test: `D:\workspaces\jnow\ollie-hermes-install\tests\test-merge-agents.sh`
- Modify: `D:\workspaces\jnow\ollie-hermes-install\README.md` (env-var docs section — add `WHISPER_MODEL`, `TTS_DEFAULT_VOICE` under the orchestrator env notes, one line each)

**Interfaces:**
- Consumes: AGENTS_JSON `voice` key written by the orchestrator (Tasks 1–2).
- Produces: a re-run of `06-install-stack.sh` preserves `voice` (same class as the historical scope-drop bug).

- [ ] **Step 1: Write the failing test** — in `tests/test-merge-agents.sh`, add before the invocation block at the bottom:

```bash
test_preserves_voice() {
  local existing='[{"id":"default","name":"Ollie","voice":"en-GB-RyanNeural"}]'
  local out; out="$(EXISTING_AGENTS="$existing" DETECTED="$DETECTED" "$PY" "$MERGE")"
  assert_eq "default keeps voice" "$(printf '%s' "$out" | field default voice)" "en-GB-RyanNeural"
}
```

and add `test_preserves_voice` to the invocation list before `finish`.

- [ ] **Step 2: Run to verify failure**

Run: `bash tests/test-merge-agents.sh`
Expected: FAIL — "default keeps voice" gets `None`.

- [ ] **Step 3: Implement** — in `scripts/lib/merge-agents-json.py`, after the `avatar_url` preserve block:

```python
    # Per-agent TTS voice (set via orchestrator/UI) — preserve so a re-run of
    # 06 never wipes it (same class as the scope-drop bug).
    if p.get("voice"):
        entry["voice"] = p["voice"]
```

- [ ] **Step 4: Run** — `bash tests/test-merge-agents.sh` → all PASS.

- [ ] **Step 5: README** — add to the orchestrator environment documentation:

```markdown
- `WHISPER_MODEL` — faster-whisper model for `/v1/audio/transcribe` (default `base`; downloaded to the service user's cache on first use).
- `TTS_DEFAULT_VOICE` — Edge TTS voice used when an agent has no `voice` set (default `en-US-AndrewMultilingualNeural`).
```

- [ ] **Step 6: Commit**

```bash
git add scripts/lib/merge-agents-json.py tests/test-merge-agents.sh README.md
git commit -m "feat: preserve per-agent voice across stack re-runs; document voice env vars"
```

---

### Task 6: frontend types + orchestrator client methods

**Files:**
- Modify: `D:\workspaces\jnow\ollie-hermes-frontend\src\adapters\orchestrator\OrchestratorTypes.ts` (Agent, UpdateAgentRequest)
- Modify: `D:\workspaces\jnow\ollie-hermes-frontend\src\adapters\orchestrator\OrchestratorClient.ts`
- Test: `D:\workspaces\jnow\ollie-hermes-frontend\src\adapters\orchestrator\__tests__\OrchestratorClient.test.ts`

**Interfaces:**
- Consumes: orchestrator endpoints from Tasks 3–4.
- Produces: `Agent.voice?: string`, `UpdateAgentRequest.voice?: string`; `OrchestratorClient.transcribeAudio(blob: Blob): Promise<string>` and `OrchestratorClient.synthesizeSpeech(text: string, agentId: string): Promise<Blob>`.

- [ ] **Step 1: Write the failing tests** — append to the existing `OrchestratorClient.test.ts` (mirror its fetch-mocking idiom):

```ts
describe('audio endpoints', () => {
  it('transcribeAudio POSTs the blob raw and returns text', async () => {
    const fetchMock = vi.fn().mockResolvedValue({
      ok: true, json: async () => ({ text: 'hello world' }),
    });
    vi.stubGlobal('fetch', fetchMock);
    const c = new OrchestratorClient('/orchestrator-proxy');
    const blob = new Blob([new Uint8Array([1, 2, 3])], { type: 'audio/webm' });
    await expect(c.transcribeAudio(blob)).resolves.toBe('hello world');
    const [url, init] = fetchMock.mock.calls[0];
    expect(url).toBe('/orchestrator-proxy/v1/audio/transcribe');
    expect(init.method).toBe('POST');
    expect(init.headers['Content-Type']).toBe('audio/webm');
    expect(init.body).toBe(blob);
  });

  it('transcribeAudio throws on non-OK', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue({ ok: false, status: 413 }));
    const c = new OrchestratorClient('/orchestrator-proxy');
    await expect(c.transcribeAudio(new Blob())).rejects.toThrow('413');
  });

  it('synthesizeSpeech POSTs JSON and returns the audio blob', async () => {
    const audioBlob = new Blob([new Uint8Array([9])], { type: 'audio/mpeg' });
    const fetchMock = vi.fn().mockResolvedValue({ ok: true, blob: async () => audioBlob });
    vi.stubGlobal('fetch', fetchMock);
    const c = new OrchestratorClient('/orchestrator-proxy');
    await expect(c.synthesizeSpeech('hi there', 'default')).resolves.toBe(audioBlob);
    const [url, init] = fetchMock.mock.calls[0];
    expect(url).toBe('/orchestrator-proxy/v1/audio/speak');
    expect(JSON.parse(init.body)).toEqual({ text: 'hi there', agentId: 'default' });
  });

  it('synthesizeSpeech throws on non-OK', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue({ ok: false, status: 502 }));
    const c = new OrchestratorClient('/orchestrator-proxy');
    await expect(c.synthesizeSpeech('x', 'default')).rejects.toThrow('502');
  });
});
```

- [ ] **Step 2: Run to verify failure**

Run: `npx vitest run src/adapters/orchestrator/__tests__/OrchestratorClient.test.ts`
Expected: FAIL — `transcribeAudio is not a function`.

- [ ] **Step 3: Implement**

`OrchestratorTypes.ts`: `Agent` gains (after `scope`): `` /** Edge TTS voice short-name for spoken replies (admin-set). */ voice?: string; `` and `UpdateAgentRequest` gains `voice?: string;`.

`OrchestratorClient.ts` — add near `getMyPrefs`:

```ts
  /** Push-to-talk STT: raw recorded blob in, transcript out. */
  async transcribeAudio(blob: Blob): Promise<string> {
    const r = await fetch(this.url('/v1/audio/transcribe'), {
      method: 'POST',
      headers: { 'Content-Type': blob.type || 'audio/webm' },
      body: blob,
    });
    if (!r.ok) throw new Error(`orchestrator ${r.status}: POST /v1/audio/transcribe`);
    return ((await r.json()).text ?? '') as string;
  }

  /** Spoken replies TTS: text in, playable audio/mpeg blob out. */
  async synthesizeSpeech(text: string, agentId: string): Promise<Blob> {
    const r = await fetch(this.url('/v1/audio/speak'), {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ text, agentId }),
    });
    if (!r.ok) throw new Error(`orchestrator ${r.status}: POST /v1/audio/speak`);
    return r.blob();
  }
```

- [ ] **Step 4: Run** — same command → PASS. Then `npx tsc --noEmit` (or `npm run build`'s tsc step) for type check.

- [ ] **Step 5: Commit**

```bash
git add src/adapters/orchestrator/OrchestratorTypes.ts src/adapters/orchestrator/OrchestratorClient.ts src/adapters/orchestrator/__tests__/OrchestratorClient.test.ts
git commit -m "feat: orchestrator client audio methods + per-agent voice types"
```

---

### Task 7: speech lib — markdown stripping + shared playback (frontend)

**Files:**
- Create: `D:\workspaces\jnow\ollie-hermes-frontend\src\lib\speech.ts`
- Test: `D:\workspaces\jnow\ollie-hermes-frontend\src\lib\speech.test.ts`

**Interfaces:**
- Consumes: nothing app-specific.
- Produces: `stripMarkdownForSpeech(md: string): string`; playback singleton: `playBlob(blob: Blob, key: string): void`, `stopPlayback(): void`, `getPlayingKey(): string | null`, `usePlayingKey(): string | null` (React hook via `useSyncExternalStore`, mirrors `src/lib/viewMode.ts` pattern), `__resetSpeechForTests(): void`.

- [ ] **Step 1: Write the failing tests** — create `src/lib/speech.test.ts`:

```ts
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { stripMarkdownForSpeech, playBlob, stopPlayback, getPlayingKey, __resetSpeechForTests } from './speech';

describe('stripMarkdownForSpeech', () => {
  it('replaces code fences and strips inline markdown', () => {
    const md = '# Hi\n\nUse `ls` here:\n```bash\nls -la\n```\nSee [docs](https://x.y) for **more**.';
    const out = stripMarkdownForSpeech(md);
    expect(out).not.toContain('ls -la');
    expect(out).toContain('code omitted');
    expect(out).toContain('ls here');
    expect(out).toContain('See docs for more.');
    expect(out).not.toContain('#');
    expect(out).not.toContain('**');
    expect(out).not.toContain('https://x.y');
  });

  it('collapses whitespace and trims', () => {
    expect(stripMarkdownForSpeech('  a\n\n\n- b\n- c  ')).toBe('a b c');
  });

  it('returns empty string for markdown-only content', () => {
    expect(stripMarkdownForSpeech('```\ncode\n```')).toBe('code omitted.');
  });
});

describe('playback singleton', () => {
  class FakeAudio {
    static instances: FakeAudio[] = [];
    onended: (() => void) | null = null;
    onerror: (() => void) | null = null;
    paused = false;
    constructor(public src: string) { FakeAudio.instances.push(this); }
    play() { return Promise.resolve(); }
    pause() { this.paused = true; }
  }

  beforeEach(() => {
    FakeAudio.instances = [];
    vi.stubGlobal('Audio', FakeAudio as unknown as typeof Audio);
    vi.stubGlobal('URL', {
      createObjectURL: vi.fn(() => 'blob:fake'),
      revokeObjectURL: vi.fn(),
    });
    __resetSpeechForTests();
  });
  afterEach(() => vi.unstubAllGlobals());

  it('tracks the playing key and clears it on ended', () => {
    playBlob(new Blob(), 'msg-1');
    expect(getPlayingKey()).toBe('msg-1');
    FakeAudio.instances[0].onended?.();
    expect(getPlayingKey()).toBeNull();
  });

  it('starting a new playback stops the previous one', () => {
    playBlob(new Blob(), 'msg-1');
    playBlob(new Blob(), 'msg-2');
    expect(FakeAudio.instances[0].paused).toBe(true);
    expect(getPlayingKey()).toBe('msg-2');
  });

  it('stopPlayback pauses and clears', () => {
    playBlob(new Blob(), 'msg-1');
    stopPlayback();
    expect(getPlayingKey()).toBeNull();
    expect(FakeAudio.instances[0].paused).toBe(true);
  });
});
```

- [ ] **Step 2: Run to verify failure**

Run: `npx vitest run src/lib/speech.test.ts`
Expected: FAIL — module not found.

- [ ] **Step 3: Implement** — create `src/lib/speech.ts`:

```ts
import { useSyncExternalStore } from 'react';

/**
 * Speech helpers for Ollie Voice v1.
 *
 * stripMarkdownForSpeech: agent replies are markdown; TTS should read prose,
 * not syntax. Code blocks collapse to "code omitted" (reading code aloud is
 * noise), links read their text, formatting marks are dropped.
 *
 * Playback singleton: ONE shared audio element app-wide — starting any
 * playback stops the previous one, and consumers subscribe to the playing
 * key to render per-message play/stop state (useSyncExternalStore pattern,
 * mirrors src/lib/viewMode.ts).
 */

export function stripMarkdownForSpeech(md: string): string {
  return md
    .replace(/```[\s\S]*?```/g, ' code omitted. ')
    .replace(/`([^`]+)`/g, '$1')
    .replace(/!\[[^\]]*\]\([^)]*\)/g, '')
    .replace(/\[([^\]]+)\]\([^)]*\)/g, '$1')
    .replace(/^#{1,6}\s+/gm, '')
    .replace(/(\*\*|__|~~)/g, '')
    .replace(/(^|\s)[*_](\S[^*_]*\S|\S)[*_](?=\s|$|[.,!?])/gm, '$1$2')
    .replace(/^\s*>\s?/gm, '')
    .replace(/^\s*[-*+]\s+/gm, '')
    .replace(/^\s*\|.*\|\s*$/gm, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

let audio: { pause(): void; onended: (() => void) | null; onerror: (() => void) | null } | null = null;
let objectUrl: string | null = null;
let playingKey: string | null = null;
const listeners = new Set<() => void>();

function notify(): void { for (const l of listeners) l(); }

function cleanup(): void {
  if (objectUrl) { URL.revokeObjectURL(objectUrl); objectUrl = null; }
  audio = null;
  playingKey = null;
  notify();
}

export function stopPlayback(): void {
  if (audio) audio.pause();
  cleanup();
}

export function playBlob(blob: Blob, key: string): void {
  stopPlayback();
  objectUrl = URL.createObjectURL(blob);
  const el = new Audio(objectUrl);
  audio = el;
  playingKey = key;
  el.onended = () => { if (playingKey === key) cleanup(); };
  el.onerror = () => { if (playingKey === key) cleanup(); };
  void el.play().catch(() => { if (playingKey === key) cleanup(); });
  notify();
}

export function getPlayingKey(): string | null { return playingKey; }

export function subscribePlayback(listener: () => void): () => void {
  listeners.add(listener);
  return () => { listeners.delete(listener); };
}

/** React hook: re-renders when the playing key changes. */
export function usePlayingKey(): string | null {
  return useSyncExternalStore(subscribePlayback, getPlayingKey, () => null);
}

/** Test-only. */
export function __resetSpeechForTests(): void {
  audio = null;
  objectUrl = null;
  playingKey = null;
  listeners.clear();
}
```

- [ ] **Step 4: Run** — `npx vitest run src/lib/speech.test.ts` → PASS. (If the italic-stripping regex fights a test case, simplify the test input, not the contract: bold/backtick/link/heading/fence stripping are the load-bearing behaviors.)

- [ ] **Step 5: Commit**

```bash
git add src/lib/speech.ts src/lib/speech.test.ts
git commit -m "feat: speech lib — markdown-to-speech stripping + shared playback singleton"
```

---

### Task 8: useVoiceRecorder hook (frontend)

**Files:**
- Create: `D:\workspaces\jnow\ollie-hermes-frontend\src\hooks\useVoiceRecorder.ts`
- Test: `D:\workspaces\jnow\ollie-hermes-frontend\src\hooks\__tests__\useVoiceRecorder.test.ts`

**Interfaces:**
- Consumes: browser `navigator.mediaDevices.getUserMedia` + `MediaRecorder`.
- Produces:

```ts
export type RecorderState = 'idle' | 'recording';
export interface VoiceRecorder {
  supported: boolean;          // false -> hide the mic button entirely
  state: RecorderState;
  elapsed: number;             // seconds while recording
  start(): Promise<void>;      // throws Error('mic-denied') on permission refusal
  stop(): Promise<Blob | null>; // resolves the recorded blob (null if not recording)
  cancel(): void;              // discard without resolving a blob
}
export function useVoiceRecorder(): VoiceRecorder;
```

- [ ] **Step 1: Write the failing tests** — create `src/hooks/__tests__/useVoiceRecorder.test.ts` using `@testing-library/react`'s `renderHook`/`act` (already available — mirror `src/hooks/useSetupCheck.test.ts` imports):

```ts
import { renderHook, act } from '@testing-library/react';
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { useVoiceRecorder } from '../useVoiceRecorder';

class FakeMediaRecorder {
  static instances: FakeMediaRecorder[] = [];
  static isTypeSupported = vi.fn(() => true);
  ondataavailable: ((e: { data: Blob }) => void) | null = null;
  onstop: (() => void) | null = null;
  state = 'inactive';
  constructor(public stream: unknown, public opts?: unknown) {
    FakeMediaRecorder.instances.push(this);
  }
  start() { this.state = 'recording'; }
  stop() {
    this.state = 'inactive';
    this.ondataavailable?.({ data: new Blob([new Uint8Array([1])], { type: 'audio/webm' }) });
    this.onstop?.();
  }
}

const fakeTrack = { stop: vi.fn() };
const fakeStream = { getTracks: () => [fakeTrack] };

beforeEach(() => {
  FakeMediaRecorder.instances = [];
  fakeTrack.stop.mockClear();
  vi.stubGlobal('MediaRecorder', FakeMediaRecorder as unknown as typeof MediaRecorder);
  Object.defineProperty(navigator, 'mediaDevices', {
    configurable: true,
    value: { getUserMedia: vi.fn().mockResolvedValue(fakeStream) },
  });
});
afterEach(() => vi.unstubAllGlobals());

describe('useVoiceRecorder', () => {
  it('start -> recording, stop -> blob + tracks released', async () => {
    const { result } = renderHook(() => useVoiceRecorder());
    expect(result.current.supported).toBe(true);
    await act(async () => { await result.current.start(); });
    expect(result.current.state).toBe('recording');
    let blob: Blob | null = null;
    await act(async () => { blob = await result.current.stop(); });
    expect(blob).not.toBeNull();
    expect(result.current.state).toBe('idle');
    expect(fakeTrack.stop).toHaveBeenCalled();
  });

  it('cancel discards and releases tracks', async () => {
    const { result } = renderHook(() => useVoiceRecorder());
    await act(async () => { await result.current.start(); });
    act(() => result.current.cancel());
    expect(result.current.state).toBe('idle');
    expect(fakeTrack.stop).toHaveBeenCalled();
  });

  it('permission denial throws mic-denied and stays idle', async () => {
    (navigator.mediaDevices.getUserMedia as ReturnType<typeof vi.fn>)
      .mockRejectedValue(new DOMException('denied', 'NotAllowedError'));
    const { result } = renderHook(() => useVoiceRecorder());
    await expect(act(async () => { await result.current.start(); })).rejects.toThrow('mic-denied');
    expect(result.current.state).toBe('idle');
  });

  it('unsupported browser reports supported=false', () => {
    vi.unstubAllGlobals(); // remove MediaRecorder
    // @ts-expect-error simulate missing API
    delete (globalThis as Record<string, unknown>).MediaRecorder;
    const { result } = renderHook(() => useVoiceRecorder());
    expect(result.current.supported).toBe(false);
  });
});
```

- [ ] **Step 2: Run to verify failure**

Run: `npx vitest run src/hooks/__tests__/useVoiceRecorder.test.ts`
Expected: FAIL — module not found.

- [ ] **Step 3: Implement** — create `src/hooks/useVoiceRecorder.ts`:

```ts
import { useCallback, useEffect, useRef, useState } from 'react';

export type RecorderState = 'idle' | 'recording';

export interface VoiceRecorder {
  supported: boolean;
  state: RecorderState;
  elapsed: number;
  start(): Promise<void>;
  stop(): Promise<Blob | null>;
  cancel(): void;
}

/** Push-to-talk recorder around MediaRecorder (WebM/Opus). Tap to start,
 *  tap to stop; cancel discards. Tracks are always released so the browser
 *  mic indicator never sticks on. */
export function useVoiceRecorder(): VoiceRecorder {
  const supported = typeof MediaRecorder !== 'undefined'
    && typeof navigator !== 'undefined' && !!navigator.mediaDevices?.getUserMedia;
  const [state, setState] = useState<RecorderState>('idle');
  const [elapsed, setElapsed] = useState(0);
  const recorderRef = useRef<MediaRecorder | null>(null);
  const streamRef = useRef<MediaStream | null>(null);
  const chunksRef = useRef<Blob[]>([]);
  const timerRef = useRef<ReturnType<typeof setInterval> | null>(null);
  const discardRef = useRef(false);

  const releaseTracks = useCallback(() => {
    streamRef.current?.getTracks().forEach(t => t.stop());
    streamRef.current = null;
    if (timerRef.current) { clearInterval(timerRef.current); timerRef.current = null; }
  }, []);

  const start = useCallback(async () => {
    if (!supported || recorderRef.current) return;
    let stream: MediaStream;
    try {
      stream = await navigator.mediaDevices.getUserMedia({ audio: true });
    } catch {
      throw new Error('mic-denied');
    }
    streamRef.current = stream;
    const mime = 'audio/webm;codecs=opus';
    const rec = new MediaRecorder(stream,
      MediaRecorder.isTypeSupported?.(mime) ? { mimeType: mime } : undefined);
    chunksRef.current = [];
    discardRef.current = false;
    rec.ondataavailable = e => { if (e.data.size > 0) chunksRef.current.push(e.data); };
    recorderRef.current = rec;
    rec.start();
    setElapsed(0);
    timerRef.current = setInterval(() => setElapsed(s => s + 1), 1000);
    setState('recording');
  }, [supported]);

  const stop = useCallback((): Promise<Blob | null> => {
    const rec = recorderRef.current;
    if (!rec) return Promise.resolve(null);
    return new Promise(resolve => {
      rec.onstop = () => {
        const blob = discardRef.current || chunksRef.current.length === 0
          ? null
          : new Blob(chunksRef.current, { type: 'audio/webm' });
        chunksRef.current = [];
        recorderRef.current = null;
        releaseTracks();
        setState('idle');
        resolve(blob);
      };
      rec.stop();
    });
  }, [releaseTracks]);

  const cancel = useCallback(() => {
    const rec = recorderRef.current;
    if (!rec) return;
    discardRef.current = true;
    rec.onstop = null;
    try { rec.stop(); } catch { /* already inactive */ }
    chunksRef.current = [];
    recorderRef.current = null;
    releaseTracks();
    setState('idle');
  }, [releaseTracks]);

  // Unmount safety: never leave the mic captured.
  useEffect(() => () => {
    discardRef.current = true;
    try { recorderRef.current?.stop(); } catch { /* noop */ }
    recorderRef.current = null;
    releaseTracks();
  }, [releaseTracks]);

  return { supported, state, elapsed, start, stop, cancel };
}
```

- [ ] **Step 4: Run** — `npx vitest run src/hooks/__tests__/useVoiceRecorder.test.ts` → PASS.

- [ ] **Step 5: Commit**

```bash
git add src/hooks/useVoiceRecorder.ts src/hooks/__tests__/useVoiceRecorder.test.ts
git commit -m "feat: useVoiceRecorder push-to-talk MediaRecorder hook"
```

---

### Task 9: ChatStreamContext — expose the completed reply (frontend)

**Files:**
- Modify: `D:\workspaces\jnow\ollie-hermes-frontend\src\contexts\ChatStreamContext.tsx`
- Test: `D:\workspaces\jnow\ollie-hermes-frontend\src\contexts\__tests__\ChatStreamContext.test.tsx` (append to existing)

**Interfaces:**
- Consumes: existing stream event flow (`chunk` accumulates text at `ChatStreamContext.tsx:196`, `done` finalizes at `:212`).
- Produces: on `ChatStreamContextValue`:

```ts
/** The most recently completed assistant turn — auto-play consumers watch
 *  this. `turn` increments per completion so an identical reply re-fires. */
lastCompletedReply: { agentId: string; content: string; turn: number } | null;
```

- [ ] **Step 1: Write the failing test** — append to the existing ChatStreamContext test file, following its established provider/mock-backend harness (it already simulates `chunk` + `done` events for other assertions — copy that setup):

```tsx
it('publishes lastCompletedReply on done, with accumulated content and incrementing turn', async () => {
  // Using the file's existing mock backend that replays events:
  //   chunk("Hello ") -> chunk("world") -> done(threadId)
  // After the stream completes:
  expect(result.current.lastCompletedReply).toEqual(
    expect.objectContaining({ agentId: 'default', content: 'Hello world', turn: 1 }),
  );
  // A second send that completes bumps turn to 2 even with identical content.
});

it('does not publish lastCompletedReply when the stream errors before content', async () => {
  // Replay: error("boom") with no chunks -> lastCompletedReply stays null.
});
```

(The implementer expands these skeletons with the file's actual harness — the assertions above are the contract.)

- [ ] **Step 2: Run to verify failure**

Run: `npx vitest run src/contexts/__tests__/ChatStreamContext.test.tsx`
Expected: FAIL — `lastCompletedReply` is `undefined`.

- [ ] **Step 3: Implement** — in `ChatStreamContext.tsx`:

1. Interface: add the `lastCompletedReply` field (doc comment above) to `ChatStreamContextValue`.
2. State (with the other `useState` calls):

```ts
const [lastCompletedReply, setLastCompletedReply] =
  useState<{ agentId: string; content: string; turn: number } | null>(null);
const turnCounterRef = useRef(0);
const turnContentRef = useRef('');
```

3. In `send()`, where the turn begins (next to `let receivedContent = false;` at line 192): `turnContentRef.current = '';`
4. In the `chunk` branch (line 196, where `receivedContent = true`): `turnContentRef.current += event.text;`
5. In the `done` branch (line 212), after `setSessionListRevision(r => r + 1);`:

```ts
if (receivedContent && turnAgentId) {
  setLastCompletedReply({
    agentId: turnAgentId,
    content: turnContentRef.current,
    turn: ++turnCounterRef.current,
  });
}
```

6. Add `lastCompletedReply` to the provider value object.

- [ ] **Step 4: Run** — `npx vitest run src/contexts/__tests__/ChatStreamContext.test.tsx` → PASS; then the full suite `npx vitest run` to catch consumers of the context value shape.

- [ ] **Step 5: Commit**

```bash
git add src/contexts/ChatStreamContext.tsx src/contexts/__tests__/ChatStreamContext.test.tsx
git commit -m "feat: expose lastCompletedReply from the chat stream for spoken replies"
```

---

### Task 10: voice controls + Chat wiring + prefs (frontend)

**Files:**
- Modify: `D:\workspaces\jnow\ollie-hermes-frontend\src\lib\prefs.ts` (Prefs interface)
- Create: `D:\workspaces\jnow\ollie-hermes-frontend\src\components\VoiceControls.tsx`
- Modify: `D:\workspaces\jnow\ollie-hermes-frontend\src\pages\shared\Chat.tsx`
- Test: `D:\workspaces\jnow\ollie-hermes-frontend\src\components\__tests__\VoiceControls.test.tsx`, plus assertions in `src\pages\shared\__tests__\Chat.test.tsx`

**Interfaces:**
- Consumes: `useVoiceRecorder` (Task 8), `stripMarkdownForSpeech`/`playBlob`/`stopPlayback`/`usePlayingKey` (Task 7), `orchestrator.transcribeAudio`/`synthesizeSpeech` (Task 6), `lastCompletedReply` (Task 9), `usePref`/`setPref` (existing `src/lib/prefs.ts`).
- Produces:

```ts
// prefs.ts
export interface VoicePrefs { spokenReplies?: boolean; sendOnRelease?: boolean }
// Prefs gains: voice?: VoicePrefs;

// VoiceControls.tsx
export function MicButton(props: {
  orchestrator: OrchestratorClient | null;
  disabled?: boolean;
  onTranscript: (text: string) => void;
  onError: (message: string) => void;
}): JSX.Element | null;          // null when recorder unsupported or no orchestrator

export function SpokenRepliesToggle(): JSX.Element;   // reads/writes prefs.voice

export function SpeakerButton(props: {
  orchestrator: OrchestratorClient | null;
  text: string;
  agentId: string;
  playKey: string;
}): JSX.Element | null;
```

- [ ] **Step 1: Prefs type** — in `src/lib/prefs.ts` add above `Prefs`:

```ts
export interface VoicePrefs { spokenReplies?: boolean; sendOnRelease?: boolean }
```

and to `Prefs`:

```ts
  voice?: VoicePrefs;
```

(Type-only change; existing prefs tests must stay green.)

- [ ] **Step 2: Write the failing component tests** — create `src/components/__tests__/VoiceControls.test.tsx` (React Testing Library, mirror neighboring component tests for render/user-event idioms):

```tsx
import { render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { describe, it, expect, vi, beforeEach } from 'vitest';
import { MicButton, SpokenRepliesToggle, SpeakerButton } from '../VoiceControls';
import { __resetPrefsForTests, getPrefs } from '../../lib/prefs';
import { __resetSpeechForTests } from '../../lib/speech';

// Mock the recorder hook: the state machine has its own tests (Task 8).
const recorder = {
  supported: true, state: 'idle' as const, elapsed: 0,
  start: vi.fn().mockResolvedValue(undefined),
  stop: vi.fn().mockResolvedValue(new Blob([new Uint8Array([1])], { type: 'audio/webm' })),
  cancel: vi.fn(),
};
vi.mock('../../hooks/useVoiceRecorder', () => ({ useVoiceRecorder: () => recorder }));

const orchestrator = {
  transcribeAudio: vi.fn().mockResolvedValue('hello world'),
  synthesizeSpeech: vi.fn().mockResolvedValue(new Blob([new Uint8Array([9])], { type: 'audio/mpeg' })),
} as unknown as import('../../adapters/orchestrator/OrchestratorClient').OrchestratorClient;

beforeEach(() => {
  vi.clearAllMocks();
  recorder.state = 'idle';
  __resetPrefsForTests({});
  __resetSpeechForTests();
  vi.stubGlobal('Audio', class { onended = null; onerror = null; play() { return Promise.resolve(); } pause() {} } as unknown as typeof Audio);
  vi.stubGlobal('URL', { createObjectURL: vi.fn(() => 'blob:f'), revokeObjectURL: vi.fn() });
});

describe('MicButton', () => {
  it('starts recording on click when idle', async () => {
    render(<MicButton orchestrator={orchestrator} onTranscript={vi.fn()} onError={vi.fn()} />);
    await userEvent.click(screen.getByRole('button', { name: /record voice message/i }));
    expect(recorder.start).toHaveBeenCalled();
  });

  it('stops + transcribes on click while recording, delivering the transcript', async () => {
    recorder.state = 'recording';
    const onTranscript = vi.fn();
    render(<MicButton orchestrator={orchestrator} onTranscript={onTranscript} onError={vi.fn()} />);
    await userEvent.click(screen.getByRole('button', { name: /stop recording/i }));
    await waitFor(() => expect(onTranscript).toHaveBeenCalledWith('hello world'));
  });

  it('reports mic denial via onError', async () => {
    recorder.start.mockRejectedValueOnce(new Error('mic-denied'));
    const onError = vi.fn();
    render(<MicButton orchestrator={orchestrator} onTranscript={vi.fn()} onError={onError} />);
    await userEvent.click(screen.getByRole('button', { name: /record voice message/i }));
    await waitFor(() => expect(onError).toHaveBeenCalledWith(expect.stringMatching(/microphone/i)));
  });

  it('reports transcription failure via onError and delivers nothing', async () => {
    recorder.state = 'recording';
    (orchestrator.transcribeAudio as ReturnType<typeof vi.fn>).mockRejectedValueOnce(new Error('502'));
    const onTranscript = vi.fn(); const onError = vi.fn();
    render(<MicButton orchestrator={orchestrator} onTranscript={onTranscript} onError={onError} />);
    await userEvent.click(screen.getByRole('button', { name: /stop recording/i }));
    await waitFor(() => expect(onError).toHaveBeenCalled());
    expect(onTranscript).not.toHaveBeenCalled();
  });

  it('renders nothing without an orchestrator', () => {
    const { container } = render(<MicButton orchestrator={null} onTranscript={vi.fn()} onError={vi.fn()} />);
    expect(container.firstChild).toBeNull();
  });
});

describe('SpokenRepliesToggle', () => {
  it('toggles prefs.voice.spokenReplies', async () => {
    render(<SpokenRepliesToggle />);
    await userEvent.click(screen.getByRole('button', { name: /spoken replies/i }));
    expect(getPrefs().voice?.spokenReplies).toBe(true);
    await userEvent.click(screen.getByRole('button', { name: /spoken replies/i }));
    expect(getPrefs().voice?.spokenReplies).toBe(false);
  });
});

describe('SpeakerButton', () => {
  it('synthesizes stripped text and plays it', async () => {
    render(<SpeakerButton orchestrator={orchestrator} text={'**Hi** there'} agentId="default" playKey="m1" />);
    await userEvent.click(screen.getByRole('button', { name: /play message audio/i }));
    await waitFor(() =>
      expect(orchestrator.synthesizeSpeech).toHaveBeenCalledWith('Hi there', 'default'));
  });

  it('does not call speak for empty stripped text', async () => {
    render(<SpeakerButton orchestrator={orchestrator} text={''} agentId="default" playKey="m1" />);
    expect(screen.queryByRole('button', { name: /play message audio/i })).toBeNull();
  });
});
```

- [ ] **Step 3: Run to verify failure** — `npx vitest run src/components/__tests__/VoiceControls.test.tsx` → FAIL (module not found).

- [ ] **Step 4: Implement** — create `src/components/VoiceControls.tsx`:

```tsx
import { useState } from 'react';
import { Mic, Square, Volume2, X } from 'lucide-react';
import type { OrchestratorClient } from '../adapters/orchestrator/OrchestratorClient';
import { useVoiceRecorder } from '../hooks/useVoiceRecorder';
import { stripMarkdownForSpeech, playBlob, stopPlayback, usePlayingKey } from '../lib/speech';
import { usePref, setPref } from '../lib/prefs';

export function MicButton({ orchestrator, disabled, onTranscript, onError }: {
  orchestrator: OrchestratorClient | null;
  disabled?: boolean;
  onTranscript: (text: string) => void;
  onError: (message: string) => void;
}) {
  const rec = useVoiceRecorder();
  const [transcribing, setTranscribing] = useState(false);
  if (!orchestrator || !rec.supported) return null;

  const handleClick = async () => {
    if (rec.state === 'idle') {
      try {
        await rec.start();
      } catch {
        onError('Microphone access denied — allow the mic for this site and try again.');
      }
      return;
    }
    const blob = await rec.stop();
    if (!blob) return;
    setTranscribing(true);
    try {
      const text = (await orchestrator.transcribeAudio(blob)).trim();
      if (text) onTranscript(text);
    } catch {
      onError('Transcription failed — try again.');
    } finally {
      setTranscribing(false);
    }
  };

  const recording = rec.state === 'recording';
  return (
    <div className="flex items-end gap-1 shrink-0">
      {recording && (
        <button type="button" onClick={rec.cancel} aria-label="Cancel recording"
          className="p-2.5 rounded-xl text-slate-400 hover:text-slate-200 hover:bg-slate-800 transition-colors">
          <X size={16} />
        </button>
      )}
      <button
        type="button"
        onClick={handleClick}
        disabled={disabled || transcribing}
        aria-label={recording ? 'Stop recording' : 'Record voice message'}
        title={recording ? 'Stop recording' : 'Record voice message'}
        className={`p-2.5 rounded-xl transition-colors disabled:opacity-40 disabled:cursor-not-allowed ${
          recording
            ? 'text-red-400 bg-red-900/40 animate-pulse'
            : 'text-slate-400 hover:text-slate-200 hover:bg-slate-800'
        }`}
      >
        {recording ? <Square size={16} /> : <Mic size={16} />}
      </button>
      {recording && (
        <span className="text-xs text-red-400 tabular-nums self-center">{rec.elapsed}s</span>
      )}
      {transcribing && (
        <span className="text-xs text-slate-400 italic self-center">Transcribing…</span>
      )}
    </div>
  );
}

export function SpokenRepliesToggle() {
  const voice = usePref('voice');
  const on = voice?.spokenReplies === true;
  return (
    <button
      type="button"
      onClick={() => setPref('voice', { ...voice, spokenReplies: !on })}
      aria-label="Spoken replies"
      aria-pressed={on}
      title={on ? 'Spoken replies on' : 'Spoken replies off'}
      className={`text-xs transition-colors ${on ? 'text-cyan-400' : 'text-slate-500 hover:text-slate-300'}`}
    >
      <span className="inline-flex items-center gap-1"><Volume2 size={12} /> Spoken replies</span>
    </button>
  );
}

export function SpeakerButton({ orchestrator, text, agentId, playKey }: {
  orchestrator: OrchestratorClient | null;
  text: string;
  agentId: string;
  playKey: string;
}) {
  const playingKey = usePlayingKey();
  const [failed, setFailed] = useState(false);
  const spoken = stripMarkdownForSpeech(text);
  if (!orchestrator || !spoken) return null;
  const playing = playingKey === playKey;

  const handleClick = async () => {
    if (playing) { stopPlayback(); return; }
    setFailed(false);
    try {
      const blob = await orchestrator.synthesizeSpeech(spoken, agentId);
      playBlob(blob, playKey);
    } catch {
      setFailed(true);
    }
  };

  return (
    <button
      type="button"
      onClick={handleClick}
      aria-label={playing ? 'Stop message audio' : 'Play message audio'}
      title={failed ? 'Audio failed — click to retry' : (playing ? 'Stop' : 'Play aloud')}
      className={`p-1 rounded transition-colors ${
        playing ? 'text-cyan-400' : failed ? 'text-red-400' : 'text-slate-500 hover:text-slate-300'
      }`}
    >
      {playing ? <Square size={12} /> : <Volume2 size={12} />}
    </button>
  );
}
```

- [ ] **Step 5: Wire into Chat** — in `src/pages/shared/Chat.tsx`:

1. Imports:

```ts
import { MicButton, SpokenRepliesToggle, SpeakerButton } from '../../components/VoiceControls';
import { stripMarkdownForSpeech, playBlob } from '../../lib/speech';
import { usePref } from '../../lib/prefs';
```

2. In the `Chat` component: pull `lastCompletedReply` from `useChatStream()` (extend the existing destructuring); add local state `const [voiceError, setVoiceError] = useState<string | null>(null);` and `const voicePrefs = usePref('voice');`.
3. Voice-error banner: render next to the existing `error` banner (same classes), with auto-clear:

```tsx
{voiceError && (
  <div className="mx-6 mt-3 px-4 py-2 bg-red-900/40 border border-red-700 rounded text-red-300 text-sm">
    {voiceError}
  </div>
)}
```

and an effect: `useEffect(() => { if (!voiceError) return; const t = setTimeout(() => setVoiceError(null), 6000); return () => clearTimeout(t); }, [voiceError]);`

4. Transcript handling (composer insert vs send-on-release):

```ts
const handleTranscript = useCallback((text: string) => {
  if (voicePrefs?.sendOnRelease) {
    if (!isStreaming) void send(text);
    return;
  }
  setInput(prev => (prev.trim() ? `${prev.replace(/\s+$/, '')} ${text}` : text));
  textareaRef.current?.focus();
}, [voicePrefs?.sendOnRelease, isStreaming, send]);
```

5. Composer row: add `<MicButton orchestrator={orchestrator} disabled={isStreaming} onTranscript={handleTranscript} onError={setVoiceError} />` immediately after the attach-image (Paperclip) button.
6. Toggle placement (spec: "near the composer"): inside the composer container (`<div className="px-6 py-4 border-t border-slate-800">`), FIRST child — a small controls row above the input row:

```tsx
<div className="flex items-center gap-4 mb-2">
  <SpokenRepliesToggle />
  {/* send-on-release control below */}
</div>
```

Add a small secondary control beside the toggle for send-on-release, same visual style:

```tsx
<button type="button" aria-pressed={voicePrefs?.sendOnRelease === true}
  onClick={() => setPref('voice', { ...voicePrefs, sendOnRelease: !(voicePrefs?.sendOnRelease === true) })}
  className={`text-xs transition-colors ${voicePrefs?.sendOnRelease ? 'text-cyan-400' : 'text-slate-500 hover:text-slate-300'}`}>
  Send on release
</button>
```

(import `setPref` in Chat for this).
7. Per-message speaker: in the message map, inside the assistant bubble column (after the `msg.content` div, before `ThinkingStepsCollapsible`):

```tsx
{!isUser && msg.content && (
  <SpeakerButton orchestrator={orchestrator} text={msg.content}
    agentId={msg.agentId ?? effectiveAgentId ?? ''} playKey={key} />
)}
```

8. Auto-play effect (newest completed reply only, toggle on):

```ts
useEffect(() => {
  if (!lastCompletedReply || !orchestrator) return;
  if (voicePrefs?.spokenReplies !== true) return;
  const spoken = stripMarkdownForSpeech(lastCompletedReply.content);
  if (!spoken) return;
  let stale = false;
  orchestrator.synthesizeSpeech(spoken, lastCompletedReply.agentId)
    .then(blob => { if (!stale) playBlob(blob, `auto-${lastCompletedReply.turn}`); })
    .catch(() => { /* silent degrade to text per spec */ });
  return () => { stale = true; };
  // deliberately keyed ONLY on the completed turn — pref/orchestrator changes
  // must not replay an old reply.
  // eslint-disable-next-line react-hooks/exhaustive-deps
}, [lastCompletedReply]);
```

- [ ] **Step 6: Chat tests** — add to `src/pages/shared/__tests__/Chat.test.tsx`, following its existing render harness (it already mocks the stream context and orchestrator):

```tsx
it('renders the mic button in the composer when orchestrator is available', ...);
it('auto-plays the newest completed reply when spokenReplies is on', ...);
   // seed prefs {voice:{spokenReplies:true}}, publish lastCompletedReply,
   // assert synthesizeSpeech called once with stripped content + agentId
it('does not synthesize when spokenReplies is off', ...);
it('send-on-release sends the transcript instead of inserting it', ...);
```

(Contract assertions as shown; implementer reuses the file's harness.)

- [ ] **Step 7: Run** — `npx vitest run src/components/__tests__/VoiceControls.test.tsx src/pages/shared/__tests__/Chat.test.tsx`, then the full `npx vitest run` → all PASS.

- [ ] **Step 8: Commit**

```bash
git add src/lib/prefs.ts src/components/VoiceControls.tsx src/components/__tests__/VoiceControls.test.tsx src/pages/shared/Chat.tsx src/pages/shared/__tests__/Chat.test.tsx
git commit -m "feat: push-to-talk mic, spoken-replies toggle, per-message playback in Chat"
```

---

### Task 11: per-agent voice field in agent settings (frontend)

**Files:**
- Modify: `D:\workspaces\jnow\ollie-hermes-frontend\src\components\agents\AgentSettingsForm.tsx`
- Test: `D:\workspaces\jnow\ollie-hermes-frontend\src\components\agents\__tests__\AgentSettingsForm.test.tsx` (append; if the file doesn't exist, follow the pattern of the neighboring modal tests in that `__tests__` dir)

**Interfaces:**
- Consumes: `UpdateAgentRequest.voice` (Task 6); orchestrator `PATCH /v1/agents/{id}` voice support (Task 2).
- Produces: admins can set/clear an agent's Edge TTS voice from the Edit Agent modal.

- [ ] **Step 1: Write the failing test**:

```tsx
it('submits a changed voice via updateAgent', async () => {
  // render AgentSettingsForm with agent={ ...base, voice: undefined } and a
  // mocked orchestrator; type "en-GB-RyanNeural" into the "Voice" field
  // (label text /voice/i), click Save, assert:
  expect(orchestrator.updateAgent).toHaveBeenCalledWith(agent.id,
    expect.objectContaining({ voice: 'en-GB-RyanNeural' }));
});

it('does not include voice when unchanged', async () => {
  // change only displayName; assert the updateAgent body has no `voice` key.
});
```

- [ ] **Step 2: Run to verify failure** — `npx vitest run src/components/agents/__tests__/` → FAIL (no Voice field).

- [ ] **Step 3: Implement** — in `AgentSettingsForm.tsx`, mirror the `subtitle` pattern exactly:

State (next to `subtitle`):

```ts
const [voice, setVoice] = useState(agent.voice ?? '');
```

Changed-detection (next to the subtitle line):

```ts
if ((agent.voice ?? '') !== voice) changed.voice = voice;
```

Field (in the `identity` tab, after the Subtitle field):

```tsx
<Field label="Voice">
  <input type="text" value={voice} onChange={e => setVoice(e.target.value)}
    maxLength={128} placeholder="Edge TTS voice, e.g. en-US-EmmaNeural (blank = default)"
    className="w-full bg-slate-900 border border-slate-700 rounded px-3 py-1.5 text-sm text-white"
  />
  <p className="text-xs text-slate-500 mt-1">
    Used for spoken replies. Any Edge TTS short name; leave blank for the instance default.
  </p>
</Field>
```

- [ ] **Step 4: Run** — `npx vitest run src/components/agents/__tests__/` then full `npx vitest run` and `npx tsc --noEmit` → PASS.

- [ ] **Step 5: Commit**

```bash
git add src/components/agents/AgentSettingsForm.tsx src/components/agents/__tests__/
git commit -m "feat: admin-set per-agent TTS voice in agent settings"
```

---

## Post-implementation (not tasks — the deploy train, per spec §Rollout)

1. Rebuild + push the frontend image; bump `FRONTEND_IMAGE` pin in `ollie-hermes-install/scripts/06-install-stack.sh`.
2. Sandbox box: `update orchestrator` (installs `faster-whisper` + `edge-tts` into the orchestrator venv via its `install.sh` `pip install -r requirements.txt`), then targeted `docker compose up -d dashboard` swap.
3. **Live verify on sandbox (browser, real mic):** record → transcript in composer → send; toggle spoken replies → reply auto-plays; per-message replay; set a distinct voice on one agent and hear the difference; first transcription logs the one-time model download.
4. jnow prod; GetBilled on John's call. Fleet `INSTALL_REPO_REF` bump + fleet-prod redeploy last.
