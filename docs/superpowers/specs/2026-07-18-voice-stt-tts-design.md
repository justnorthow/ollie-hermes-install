# Ollie Voice v1 — Push-to-Talk STT + Spoken Replies (TTS)

**Date:** 2026-07-18
**Status:** Approved design, pre-implementation
**Repos touched:** ollie-hermes-orchestrator, ollie-hermes-frontend, ollie-hermes-install

## Problem

The Ollie web frontend has no microphone or audio playback capability. The
speech engines already work on the boxes — Edge TTS for synthesis and local
faster-whisper for transcription (round-trip verified live by Ollie) — but
there is no HTTP surface between the browser and them. Upstream
hermes-agent's API server reports `audio_api: false` / `realtime_voice:
false` as **hardcoded capability flags** (`gateway/platforms/api_server.py`
at pinned ref `abf9638f`): it has no audio endpoints at all, so there is no
upstream switch to flip. `transcribe_audio()` and `text_to_speech_tool()`
exist only inside the agent's tool environment, unreachable from the browser.

## Scope

**In:** push-to-talk recording in the browser, authenticated transcription
endpoint, transcript-to-composer (with an optional send-on-release
preference), spoken-replies toggle with auto-play, per-message replay,
per-agent admin-set voices.

**Out (v1):** continuous/interruptible conversation, sentence-streaming TTS,
barge-in, realtime voice APIs, server-side microphone access (PortAudio).
These can follow once the reliable push-to-talk path works.

## Decisions (John, 2026-07-18)

1. **STT flow:** transcript lands in the composer for review by default; a
   per-user **send-on-release** preference sends it immediately instead.
2. **TTS flow:** when the **spoken replies** toggle is on, the completed
   agent reply auto-plays; every agent message also gets a play/replay
   button regardless of the toggle.
3. **Voices:** per-agent voice, admin-set, with a sensible default —
   distinct voices per agent on a multi-agent box (Ollie ≠ Olivia).
4. **Architecture:** endpoints live in the **orchestrator** (not a sidecar
   container, not a shell-out into Hermes's venv, not an upstream fork).

## Architecture

```
Browser (MediaRecorder / <audio>)
   │  WebM/Opus upload            │  MP3 playback
   ▼                              ▼
nginx (frontend container) ── auth_request → X-Auth-User-Id
   │
   ▼
Orchestrator (FastAPI, native, user `ollie`)
   ├── POST /v1/audio/transcribe → faster-whisper (in-process, lazy)
   └── POST /v1/audio/speak      → edge-tts (outbound to Microsoft)
```

The orchestrator already fronts every cross-cutting authenticated API for
the frontend and runs as the same user as Hermes, so the whisper model cache
(`~/.cache`) is shared — no duplicate model download.

## Backend — ollie-hermes-orchestrator

New router `src/api/audio.py`, registered in `src/api/main.py`. Auth is
identical to `src/api/prefs.py`: router-level `Depends(require_bearer)` plus
the trusted `X-Auth-User-Id` header set by nginx's cryptographic
`auth_request` (unforgeable by the browser). Requests without a signed-in
user are rejected 401.

### POST /v1/audio/transcribe

- **Request:** `multipart/form-data` with an `audio` file part — WebM/Opus
  as produced by the browser's MediaRecorder. Other containers PyAV can
  decode are accepted incidentally; the contract is WebM/Opus.
- **Caps:** reject > 15 MB (~2 min of Opus) with 413; reject empty/absent
  file with 400.
- **Engine:** `faster-whisper`, model name from env `WHISPER_MODEL`
  (default `base`), `compute_type="int8"`, CPU. The model is **lazily
  loaded on first request** into a process-wide singleton so idle
  orchestrator memory stays flat, and decoding uses faster-whisper's
  bundled PyAV — no ffmpeg binary dependency.
- **Concurrency:** a single-flight `asyncio` semaphore (size 1) around
  transcription; concurrent requests queue rather than stacking CPU work.
  Transcription runs in `asyncio.to_thread` so the event loop never blocks.
- **Response:** `{"text": "<transcript>"}` (segments joined, stripped).
  Unintelligible / silent audio returns `{"text": ""}` — the frontend
  treats empty text as "nothing heard", not an error.
- **Errors:** decode failure → 400 with a short detail; engine failure →
  502.

### POST /v1/audio/speak

- **Request:** JSON `{"text": str, "agentId": str}`.
- **Caps:** reject empty text 400; reject > 5,000 chars 413.
- **Voice resolution:** the agent's `voice` field from AGENTS_JSON if set,
  else env `TTS_DEFAULT_VOICE`, else the hardcoded default
  `en-US-AndrewMultilingualNeural`. An unknown `agentId` falls back to the
  default voice (it does not error — TTS should degrade, not gate).
- **Engine:** `edge-tts` (async, outbound HTTPS to Microsoft — the boxes
  have outbound internet).
- **Response:** `audio/mpeg` bytes.
- **Errors:** edge-tts failure/timeout → 502; the frontend degrades
  silently to text.

### Per-agent voice

- `AgentEntry` (`src/agents_json.py`) gains `voice: Optional[str] = None`,
  serialized into AGENTS_JSON and served on `/v1/agents` (camelCase
  `voice`), exactly like `subtitle`.
- Admin-editable through the existing agent-management update endpoint
  (same seam and RBAC as `subtitle`/`avatar_url` — account_admin gate).
  Value is a raw Edge TTS voice short-name string; v1 does not validate it
  against the live catalog (a bad value degrades to the default voice at
  synth time via the error path).
- **Install-repo landmine:** `scripts/lib/merge-agents-json.py` must
  preserve `voice` across re-runs of `06-install-stack.sh` — same class of
  bug as the historical `scope`-drop incident. A regression test covers it.

### Dependencies & config

- New orchestrator deps: `faster-whisper`, `edge-tts` (~100 MB of wheels
  incl. CTranslate2). Added to the orchestrator's dependency manifest and
  installed by the existing orchestrator install path
  (`05-install-orchestrator.sh` / `update orchestrator`).
- New env (all optional, sensible defaults): `WHISPER_MODEL`,
  `TTS_DEFAULT_VOICE`. Documented in the install repo; no new required
  provisioning inputs.
- Rate limiting via the existing `src/rate_limit.py` machinery — generous
  limits (these are interactive endpoints), primarily an abuse backstop.

## Frontend — ollie-hermes-frontend

### Recording (STT)

- New hook `src/hooks/useVoiceRecorder.ts`: wraps `getUserMedia` +
  `MediaRecorder` (`audio/webm;codecs=opus`), exposes
  `idle | recording | transcribing` state, elapsed seconds, `start()`,
  `stop()` (returns the blob), `cancel()`.
- **Mic button** beside Send in the shared Chat composer
  (`src/pages/shared/Chat.tsx`). Tap to start, tap to stop — toggle, not
  hold (reliable on desktop and mobile). While recording: pulsing red
  state + elapsed timer + a cancel (✕ / Esc) that discards without
  transcribing.
- On stop → upload to `/v1/audio/transcribe` with a "Transcribing…"
  composer state. Result handling per the **send-on-release** preference:
  - off (default): transcript is inserted into the composer (appended to
    any existing draft text) for edit-then-send;
  - on: sent immediately as a normal chat message. Empty transcript never
    auto-sends.

### Playback (TTS)

- **Spoken-replies toggle** rendered near the composer; state persisted
  per-user in `user_prefs` under a `voice` key:
  `{"spokenReplies": bool, "sendOnRelease": bool}` via the existing
  `/v1/prefs/mine` (`getMyPrefs`/`saveMyPrefs`). The send-on-release
  setting lives in the same object (surfaced as a small secondary control
  in the same voice settings cluster).
- When a run completes and the toggle is on: strip markdown to plain text
  (code blocks summarized as "code omitted", links reduced to their text),
  POST to `/v1/audio/speak`, play the returned MP3. **Only the newest
  completed reply auto-plays** — never history on page load, which also
  keeps playback inside a user-gesture chain for browser autoplay policies.
- **Per-message speaker icon** on every agent message (independent of the
  toggle): play/replay that message. One shared `<audio>` element —
  starting any playback stops the previous one. Playing state shown on the
  active message's icon (click again to stop).
- New adapter `src/adapters/orchestrator/AudioClient.ts` for the two
  endpoints, following the existing OrchestratorClient patterns
  (constructor base URL, `fetch` with credentials, error-on-non-OK).

### Error handling

- Mic permission denied / no device → toast with a permission hint; button
  returns to idle.
- Transcription failure or timeout → toast, recording discarded, composer
  draft untouched.
- `/speak` failure with the toggle on → silent degrade to text; the
  per-message icon shows a transient error state. No automatic retries
  anywhere that could double-send a message.
- MediaRecorder unsupported (ancient browser) → mic button hidden.

## Testing

- **Orchestrator (pytest, TDD):** auth required on both endpoints; size and
  text caps; voice resolution order (agent → env → hardcoded); unknown
  agentId falls back; semaphore single-flight behavior; endpoints with
  whisper/edge-tts mocked (no model download in CI); AGENTS_JSON `voice`
  round-trip.
- **Install repo:** merge-agents-json regression test — `voice` survives a
  merge.
- **Frontend (vitest, TDD):** useVoiceRecorder state machine (mocked
  MediaRecorder); composer mic states incl. cancel; transcript-to-composer
  vs send-on-release; prefs round-trip; auto-play gating (newest reply
  only, toggle off = no synth call); per-message replay; markdown
  stripping; shared-audio exclusivity.
- **Live verify (sandbox):** real in-browser mic round-trip — record →
  transcript in composer → send; spoken reply auto-plays; per-message
  replay; per-agent voice difference after setting one.

## Rollout

Standard deploy train, sandbox first:

1. Land orchestrator + frontend + install changes (TDD, per-repo reviews).
2. Rebuild + push the frontend image; bump the `FRONTEND_IMAGE` digest pin
   in `06-install-stack.sh`.
3. Sandbox box: `update orchestrator` (installs new deps), targeted
   `docker compose up -d dashboard` swap for the frontend.
4. Live mic round-trip verification on sandbox (above).
5. jnow prod; GetBilled box on John's call.
6. Bump Fleet `INSTALL_REPO_REF` + redeploy fleet-prod so fresh provisions
   carry the feature.

Deploy notes: first transcription on a box downloads the whisper model if
not already cached (one-time latency, logged); `/speak` requires outbound
HTTPS (present on all boxes; a box without it degrades to text-only).

## Risks

- **Whisper CPU latency** on small VPS instances — mitigated by the `base`
  int8 model and short push-to-talk clips; model size is env-tunable per
  box.
- **edge-tts is an unofficial Microsoft surface** — it can break upstream;
  the UI degrades to text silently, and the engine sits behind our own
  endpoint so a provider swap later (e.g. another TTS engine) is contained
  to the orchestrator.
- **Orchestrator memory** grows by the loaded whisper model (~150 MB for
  `base`) after first STT use — acceptable on current boxes; lazy load
  keeps non-voice deployments flat.
