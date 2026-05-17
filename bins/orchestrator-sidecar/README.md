# orchestrator-sidecar

Python sidecar that hosts `claude-agent-sdk` sessions for the Supacode orchestrator fork. One process per running app instance; one in-process session per conversation.

## Run (local dev)

```bash
cd bins/orchestrator-sidecar
uv sync
uv run python -m orchestrator --supacode-port 50000
```

On startup it prints `SIDECAR_PORT=<port>` to stdout. The parent Swift process reads that line to learn where the sidecar is bound.

## Wire protocol

See `../../docs/ARCHITECTURE_TOUR.md` and `ORCHESTRATOR_SPEC.md` §6.3 / §6.4.

Sidecar HTTP (called by Supacode):
- `POST /sessions` — create/resume a session.
- `POST /sessions/{conversation_id}/messages` — send a user message.
- `DELETE /sessions/{conversation_id}` — kill a session.
- `GET /healthz`
- `GET /stream` — WebSocket for streamed assistant deltas and tool events.

Supacode HTTP (called by sidecar tools): `POST /commands/<verb>` — see `tools.py`.

## Auth

Defense-in-depth bearer token shared between Supacode and the sidecar at launch via `--shared-token`. Required because the loopback ports are technically reachable by other processes on the same machine running as the same user.
