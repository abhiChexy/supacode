"""Per-conversation orchestrator session."""

from __future__ import annotations

import asyncio
from typing import Any, AsyncIterator

from .bridge import SupacodeBridge
from .tools import build_tools

DEFAULT_SYSTEM_PROMPT = """\
You are the **orchestrator** for a Supacode user's multi-repo coding session.

Your job is to COORDINATE — break work down, spawn workspaces, message
into them, summarize progress back. You DO NOT read code, write code, or
run shell commands directly. Use the tools.

Rules:
1. Confirm scope before fanning out. Propose a workspace plan ("I'll spin
   up workspaces in X and Y") and wait for the user before calling
   `create_workspace`.
2. Use `peek_workspace` lazily — only when about to summarize or asked.
3. Surface waiting-for-input states immediately. Don't make the user ask.
4. Be brief. The user talks to many things. Short, scannable messages.
"""


class OrchestratorSession:
    """Wraps one `ClaudeSDKClient` plus the bridge that its tools call back through."""

    def __init__(
        self,
        conversation_id: str,
        supacode_port: int,
        shared_token: str,
        system_prompt: str | None = None,
        resume_session_id: str | None = None,
    ) -> None:
        self.conversation_id = conversation_id
        self._supacode_port = supacode_port
        self._shared_token = shared_token
        self._system_prompt = system_prompt or DEFAULT_SYSTEM_PROMPT
        self._resume_session_id = resume_session_id
        self._bridge: SupacodeBridge | None = None
        self._client: Any = None
        self._lock = asyncio.Lock()

    async def start(self) -> str | None:
        """Build the SDK client. Returns the session_id once available."""
        self._bridge = SupacodeBridge(self._supacode_port, self._shared_token)
        await self._bridge.__aenter__()
        try:
            from claude_agent_sdk import ClaudeSDKClient  # type: ignore[import-not-found]
        except ImportError:
            # SDK not installed yet — sessions are inert until it is.
            return None
        tools = build_tools(self._bridge)
        kwargs: dict[str, Any] = {"system_prompt": self._system_prompt, "tools": tools}
        if self._resume_session_id:
            kwargs["resume_session_id"] = self._resume_session_id
        self._client = ClaudeSDKClient(**kwargs)
        await self._client.connect()
        return getattr(self._client, "session_id", None)

    async def send_user_message(self, content: str) -> AsyncIterator[dict[str, Any]]:
        """Send a user message; yields normalized event dicts for the WS layer."""
        if self._client is None:
            yield {"type": "error", "message": "SDK not initialized"}
            return
        async with self._lock:
            async for event in self._client.send_user_message(content):  # type: ignore[union-attr]
                yield _normalize_event(event, self.conversation_id)

    async def close(self) -> None:
        if self._client is not None:
            try:
                await self._client.disconnect()
            except Exception:
                pass
            self._client = None
        if self._bridge is not None:
            await self._bridge.__aexit__()
            self._bridge = None


def _normalize_event(raw: Any, conversation_id: str) -> dict[str, Any]:
    """Shape SDK events into the wire format Supacode consumes."""
    base = {"conversation_id": conversation_id}
    if isinstance(raw, dict):
        return {**raw, **base}
    # Best-effort fallback for non-dict SDK event types.
    return {**base, "type": "raw", "value": repr(raw)}
