"""aiohttp server: HTTP for lifecycle, WebSocket for streamed events."""

from __future__ import annotations

import json
import sys
from typing import Any

from aiohttp import WSMsgType, web

from .session import OrchestratorSession


_SESSIONS: dict[str, OrchestratorSession] = {}
_WS_CLIENTS: set[web.WebSocketResponse] = set()


def _check_auth(request: web.Request) -> bool:
    expected = request.app["shared_token"]
    if not expected:
        return True
    header = request.headers.get("Authorization", "")
    return header == f"Bearer {expected}"


async def _broadcast(event: dict[str, Any]) -> None:
    payload = json.dumps(event)
    dead: list[web.WebSocketResponse] = []
    for ws in _WS_CLIENTS:
        try:
            await ws.send_str(payload)
        except ConnectionResetError:
            dead.append(ws)
    for ws in dead:
        _WS_CLIENTS.discard(ws)


async def healthz(_request: web.Request) -> web.Response:
    return web.Response(text="ok")


async def create_session(request: web.Request) -> web.Response:
    if not _check_auth(request):
        return web.Response(status=401)
    body = await request.json()
    cid = body["conversation_id"]
    if cid in _SESSIONS:
        return web.json_response({"session_id": getattr(_SESSIONS[cid], "session_id", None)})
    session = OrchestratorSession(
        conversation_id=cid,
        supacode_port=request.app["supacode_port"],
        shared_token=request.app["shared_token"],
        system_prompt=body.get("system_prompt"),
        resume_session_id=body.get("resume_session_id"),
    )
    session_id = await session.start()
    _SESSIONS[cid] = session
    # Broadcast initial server info so the UI's composer pills populate
    # before the first turn fires.
    info = session.initial_server_info()
    if info:
        await _broadcast({
            "conversation_id": cid,
            "type": "session_info",
            "model": info.get("model"),
            "permission_mode": info.get("permission_mode"),
            "cwd": info.get("cwd"),
        })
    return web.json_response({"session_id": session_id})


async def set_model(request: web.Request) -> web.Response:
    if not _check_auth(request):
        return web.Response(status=401)
    cid = request.match_info["conversation_id"]
    session = _SESSIONS.get(cid)
    if session is None:
        return web.Response(status=404)
    body = await request.json()
    model = body.get("model")
    await session.set_model(model)
    await _broadcast({
        "conversation_id": cid,
        "type": "session_info",
        "model": model,
    })
    return web.Response(status=204)


async def send_message(request: web.Request) -> web.Response:
    if not _check_auth(request):
        return web.Response(status=401)
    cid = request.match_info["conversation_id"]
    session = _SESSIONS.get(cid)
    if session is None:
        return web.Response(status=404, text=f"unknown conversation {cid}")
    body = await request.json()
    content = body.get("content", "")

    async def pump() -> None:
        async for event in session.send_user_message(content):
            await _broadcast(event)
        await _broadcast({"type": "turn_complete", "conversation_id": cid})

    request.app["loop_tasks"].add(request.app.loop.create_task(pump()))
    return web.Response(status=202)


async def interrupt_session(request: web.Request) -> web.Response:
    if not _check_auth(request):
        return web.Response(status=401)
    cid = request.match_info["conversation_id"]
    session = _SESSIONS.get(cid)
    if session is None:
        return web.Response(status=404)
    try:
        await session.interrupt()
    except Exception as exc:
        return web.Response(status=500, text=str(exc))
    return web.Response(status=204)


async def session_inspect(request: web.Request) -> web.Response:
    if not _check_auth(request):
        return web.Response(status=401)
    cid = request.match_info["conversation_id"]
    session = _SESSIONS.get(cid)
    if session is None:
        return web.Response(status=404)
    mcp = await session.get_mcp_status()
    ctx = await session.get_context_usage()
    agents = await session.list_agents()
    return web.json_response({
        "mcp_servers": mcp,
        "context_usage": ctx,
        "agents": agents,
    })


async def delete_session(request: web.Request) -> web.Response:
    if not _check_auth(request):
        return web.Response(status=401)
    cid = request.match_info["conversation_id"]
    session = _SESSIONS.pop(cid, None)
    if session is not None:
        await session.close()
    return web.Response(status=204)


async def stream(request: web.Request) -> web.WebSocketResponse:
    if not _check_auth(request):
        return web.Response(status=401)  # type: ignore[return-value]
    ws = web.WebSocketResponse(heartbeat=20)
    await ws.prepare(request)
    _WS_CLIENTS.add(ws)
    try:
        async for msg in ws:
            if msg.type == WSMsgType.ERROR:
                break
    finally:
        _WS_CLIENTS.discard(ws)
    return ws


async def run_server(*, supacode_port: int, bind_port: int, shared_token: str, port_file: str = "") -> None:
    app = web.Application()
    app["supacode_port"] = supacode_port
    app["shared_token"] = shared_token
    app["loop_tasks"] = set()
    app.add_routes([
        web.get("/healthz", healthz),
        web.post("/sessions", create_session),
        web.post("/sessions/{conversation_id}/messages", send_message),
        web.post("/sessions/{conversation_id}/interrupt", interrupt_session),
        web.post("/sessions/{conversation_id}/model", set_model),
        web.get("/sessions/{conversation_id}/inspect", session_inspect),
        web.delete("/sessions/{conversation_id}", delete_session),
        web.get("/stream", stream),
    ])

    runner = web.AppRunner(app)
    await runner.setup()
    site = web.TCPSite(runner, host="127.0.0.1", port=bind_port)
    await site.start()

    # Publish the bound port to the parent process. We use a file when given
    # one because stdout from a LaunchServices-spawned grandchild can be
    # swallowed; the file is the reliable channel.
    actual_port = site._server.sockets[0].getsockname()[1]  # type: ignore[union-attr]
    print(f"SIDECAR_PORT={actual_port}", flush=True)
    sys.stdout.flush()
    if port_file:
        try:
            with open(port_file, "w") as f:
                f.write(f"{actual_port}\n")
        except OSError as exc:
            print(f"[server] could not write port_file: {exc}", flush=True)

    # Block forever until cancelled.
    import asyncio
    await asyncio.Event().wait()
