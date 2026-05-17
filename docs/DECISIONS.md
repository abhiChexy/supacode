# Decision Log

One entry per non-trivial design choice in the orchestrator fork. Append, don't rewrite history.

---

## 2026-05-17: HTTP + WebSocket bridge between Swift app and Python sidecar

**Context:** The orchestrator agent runs as a Python `claude-agent-sdk` process. Supacode needs to (a) send lifecycle commands to it, (b) receive streamed assistant tokens, and (c) field tool-call callbacks from it that mutate Supacode state.

**Options considered:**
- A. `XPC` between Swift app and a Swift-wrapped Python interpreter.
- B. Unix domain socket with a hand-rolled length-prefixed framing.
- C. Local HTTP + WebSocket on `127.0.0.1` random ports.

**Decision:** C.

**Why:** Debuggability — every message is curl-able. Language-agnostic — Python sidecar can be replaced or augmented without touching Swift transport code. Existing `Network.framework` HTTP support means no third-party Swift networking dep (per spec §9: "No SwiftNIO, no Vapor"). Defense-in-depth bearer token at startup is trivial to add and addresses the same-machine-different-user attack surface.

**Reversal cost:** Medium — the wire format is `JSON over HTTP/WS`, both sides have small transport modules, but reducer call sites would not change.

---

## 2026-05-17: Python sidecar for `claude-agent-sdk`, not a Swift re-implementation

**Context:** `claude-agent-sdk` is currently most mature in Python. Building a Swift-native agent loop would re-implement session management, tool dispatch, streaming, resume, etc.

**Options considered:**
- A. Embed the Python SDK via a sidecar process.
- B. Embed `pyembed` / vendored CPython in-process.
- C. Write a Swift agent loop on top of the Anthropic SDK.

**Decision:** A.

**Why:** SDK maturity and feature parity (resume, tool decorators, streaming) is highest in Python today. Process isolation means a crashing agent loop doesn't crash the app. A vendored CPython is overkill for personal-fork-on-Apple-Silicon — we assume `mise` provides Python 3.12+ for dev (spec §9). Bundling decision deferred to Phase 5.

**Reversal cost:** Medium — the bridge contract is small (~8 endpoints + WS events). Swapping to a Swift agent later would require re-implementing the contract on the same wire format.

---

## 2026-05-17: One sidecar process for all conversations

**Context:** The user may have several conversations active simultaneously. Each conversation has its own `ClaudeSDKClient` session.

**Options considered:**
- A. One Python process per conversation.
- B. One Python process per app instance, with multiple `ClaudeSDKClient` sessions keyed by `conversation_id`.

**Decision:** B.

**Why:** Process count stays bounded regardless of conversation count. Session management lives in one place; cross-conversation operations (list, restart, health) are trivial. Each `ClaudeSDKClient` runs in its own asyncio task, so an agent loop blocking on a tool call doesn't starve another conversation's loop. Cost: a sidecar crash takes down every conversation simultaneously — acceptable for personal use, mitigated by app-level auto-restart with backoff (Phase 4).

**Reversal cost:** Low — the `POST /sessions` endpoint already keys by `conversation_id`; switching to per-conversation processes is a routing change on the Swift side only.

---

## 2026-05-17: Strip telemetry (PostHog + Sentry) to no-op clients

**Context:** Personal fork, single user, single machine. No value in shipping analytics or crash reports anywhere.

**Options considered:**
- A. Remove `AnalyticsClient` / `AppTelemetry` / `AppCrashReporting` entirely and delete call sites.
- B. Keep the type interfaces and call sites, replace `liveValue` with no-ops; remove SPM deps on PostHog and Sentry.
- C. Replace SPM deps with no-op stub modules of the same module name.

**Decision:** B.

**Why:** Minimizes the diff against upstream — every call site stays the same, every dep injection point stays the same. Easier to `git merge upstream/main` because nothing structural moved. Removing the SPM deps eliminates the actual network surface and binary bloat. Tests on `AppTelemetry.Configuration` / `AppCrashReporting.Configuration` stay green because the value types are preserved. Reversing to live telemetry is one commit.

**Reversal cost:** Low.
