"""Per-conversation orchestrator session."""

from __future__ import annotations

import asyncio
import traceback
from typing import Any, AsyncIterator

from .bridge import SupacodeBridge

DEFAULT_SYSTEM_PROMPT = """\
You are the **orchestrator** for a Supacode user's multi-repo coding session.

You coordinate — break work down, propose plans, hand work off to child
workspaces, summarize progress. You don't write code yourself.

**Default to proposing a concrete plan, not asking questions.** Treat the
user the same way they'd treat you in Claude Code: make reasonable
assumptions, surface them in your plan, and let them push back. They will
correct you if you're wrong — that's cheaper than a 5-question intake.

Only ask a clarifying question if:
- You genuinely cannot proceed without it (e.g., two equally plausible
  interpretations that lead to different code locations).
- It's a one-line yes/no.

Otherwise: state your assumptions in a single short paragraph, propose the
workspace plan, and stop. Maximum 1 clarifying question per turn, and only
if proposing without it would waste real work.

Style:
- Brief and scannable. The user is juggling multiple agents.
- The user's repos live under `~`. Common ones include chexyCore,
  chexyEngine, chexyHermes. Pick the most likely repo, name it, move on.
- Plain prose. No interactive tools.
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
        self.session_id: str | None = None

    async def start(self) -> str | None:
        """Build the SDK client. Returns the session_id once available."""
        self._bridge = SupacodeBridge(self._supacode_port, self._shared_token)
        await self._bridge.__aenter__()
        try:
            from claude_agent_sdk import ClaudeAgentOptions, ClaudeSDKClient  # type: ignore[import-not-found]
        except ImportError as exc:
            print(f"[session] claude-agent-sdk not installed: {exc}", flush=True)
            return None
        import os
        options = ClaudeAgentOptions(
            system_prompt=self._system_prompt,
            resume=self._resume_session_id,
            permission_mode="acceptEdits",
            cwd=os.path.expanduser("~"),
            # Ignore the user's personal ~/.claude config — its skills /
            # hooks / superpowers are tuned for their dev workflow and turn
            # the orchestrator into a heavy-context dev agent. We want a
            # lightweight coordinator persona.
            setting_sources=None,
            # Disabled tools:
            # - AskUserQuestion: interactive Claude Code tool that doesn't
            #   round-trip cleanly over our pipe.
            # - Task: would spawn subagents whose chat rows the user
            #   can't talk back to. Compounds latency too.
            # - Skill: pulls in the user's personal ~/.claude superpowers
            #   config and bloats context dramatically.
            # Bash / Write / Edit are LEFT ENABLED — the orchestrator
            # genuinely needs shell to invoke spawn-worktree, git, etc.
            # until create_workspace is wired through TCA.
            disallowed_tools=[
                "AskUserQuestion",
                "Task",
                "Skill",
            ],
            # Stream partial assistant blocks so the UI's "Thinking…"
            # turns into actual text quickly instead of after a long pause.
            include_partial_messages=True,
        )
        try:
            self._client = ClaudeSDKClient(options=options)
            await self._client.connect()
        except Exception as exc:
            print(f"[session] connect failed: {exc}", flush=True)
            traceback.print_exc()
            self._client = None
            return None
        # Probe for the model catalog so the UI's composer pills don't
        # sit on placeholder values until the first turn lands a
        # SystemMessage.init with the real active model. get_server_info
        # returns the catalog (default / sonnet / haiku) plus account info
        # but NOT the currently-active model — that only surfaces during
        # the first turn.
        try:
            info = await self._client.get_server_info()
            if info:
                models = info.get("models") or []
                default_model = models[0] if models else None
                # Synthesize a label like "Opus 4.7 (default)" from the
                # default catalog entry's description ("Opus 4.7 with 1M
                # context · Most capable…"). Falls back to displayName.
                label = None
                if default_model:
                    desc = default_model.get("description", "")
                    label = desc.split(" with ")[0].split(" ·")[0].strip() or default_model.get("displayName")
                self._initial_server_info = {
                    "model": label,
                    "cwd": os.path.expanduser("~"),
                    "permission_mode": "acceptEdits",
                    "available_models": [
                        {"value": m.get("value"), "label": m.get("displayName")}
                        for m in models
                    ],
                }
        except Exception as exc:
            print(f"[session] get_server_info failed: {exc}", flush=True)
        return self._resume_session_id

    def initial_server_info(self) -> dict[str, Any] | None:
        return getattr(self, "_initial_server_info", None)

    async def set_model(self, model: str | None) -> None:
        if self._client is None:
            return
        try:
            self._client.set_model(model)
        except Exception as exc:
            print(f"[session] set_model failed: {exc}", flush=True)

    async def send_user_message(self, content: str) -> AsyncIterator[dict[str, Any]]:
        """Send a user message; yields normalized event dicts."""
        if self._client is None:
            yield {"type": "error", "message": "SDK not initialized — install claude-agent-sdk"}
            return
        async with self._lock:
            try:
                await self._client.query(content)
                async for message in self._client.receive_response():
                    for event in _normalize_message(message, self.conversation_id):
                        if event.get("type") == "turn_complete":
                            sid = event.get("session_id")
                            if sid:
                                self.session_id = sid
                        yield event
            except Exception as exc:
                print(f"[session] send failed: {exc}", flush=True)
                traceback.print_exc()
                yield {"type": "error", "message": str(exc)}

    async def get_mcp_status(self) -> list[dict[str, Any]]:
        if self._client is None:
            return []
        try:
            status = await self._client.get_mcp_status()
            return status if isinstance(status, list) else []
        except Exception as exc:
            print(f"[session] get_mcp_status failed: {exc}", flush=True)
            return []

    async def get_context_usage(self) -> dict[str, Any]:
        if self._client is None:
            return {}
        try:
            usage = await self._client.get_context_usage()
            if hasattr(usage, "__dict__"):
                return dict(usage.__dict__)
            if isinstance(usage, dict):
                return usage
            return {"raw": repr(usage)}
        except Exception as exc:
            print(f"[session] get_context_usage failed: {exc}", flush=True)
            return {}

    async def list_agents(self) -> list[str]:
        if self._client is None:
            return []
        try:
            info = await self._client.get_server_info()
            agents = info.get("agents") if info else None
            if isinstance(agents, list):
                return [str(a) for a in agents]
            return []
        except Exception as exc:
            print(f"[session] list_agents failed: {exc}", flush=True)
            return []

    async def interrupt(self) -> None:
        if self._client is None:
            return
        try:
            await self._client.interrupt()
        except Exception as exc:
            print(f"[session] interrupt failed: {exc}", flush=True)

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


def _normalize_message(raw: Any, conversation_id: str) -> list[dict[str, Any]]:
    """Convert one SDK message into zero-or-more Supacode wire events."""
    out: list[dict[str, Any]] = []
    base = {"conversation_id": conversation_id}

    try:
        from claude_agent_sdk import (  # type: ignore[import-not-found]
            AssistantMessage,
            ResultMessage,
            SystemMessage,
            TextBlock,
            ToolResultBlock,
            ToolUseBlock,
            UserMessage,
        )
    except ImportError:
        return [{**base, "type": "raw", "value": repr(raw)}]

    def _emit_block(block: Any) -> None:
        if isinstance(block, TextBlock):
            out.append({**base, "type": "assistant_delta", "text": block.text})
        elif isinstance(block, ToolUseBlock):
            out.append({
                **base,
                "type": "tool_use",
                "tool": block.name,
                "id": block.id,
                "input": block.input,
            })
        elif isinstance(block, ToolResultBlock):
            # Tool result content may be a string, a list of blocks, or other
            # structured data — coerce to a readable string.
            content = block.content
            if isinstance(content, list):
                parts: list[str] = []
                for c in content:
                    text = getattr(c, "text", None)
                    parts.append(text if isinstance(text, str) else str(c))
                content_str = "\n".join(parts)
            else:
                content_str = str(content) if content is not None else ""
            out.append({
                **base,
                "type": "tool_result",
                "tool_use_id": block.tool_use_id,
                "result": content_str,
            })

    if isinstance(raw, AssistantMessage):
        for block in raw.content:
            _emit_block(block)
    elif isinstance(raw, UserMessage):
        # Tool results from the SDK come back wrapped in a UserMessage with
        # ToolResultBlock content. Pass them through so the UI can resolve
        # pending tool_use rows.
        content = getattr(raw, "content", None)
        if isinstance(content, list):
            for block in content:
                _emit_block(block)
    elif isinstance(raw, ResultMessage):
        usage = getattr(raw, "usage", {}) or {}
        cost = getattr(raw, "total_cost_usd", None)
        out.append({
            **base,
            "type": "usage",
            "input_tokens": usage.get("input_tokens", 0),
            "output_tokens": usage.get("output_tokens", 0),
            "cache_read_input_tokens": usage.get("cache_read_input_tokens", 0),
            "cache_creation_input_tokens": usage.get("cache_creation_input_tokens", 0),
            "cost_usd": cost,
        })
        out.append({
            **base,
            "type": "turn_complete",
            "session_id": getattr(raw, "session_id", None),
        })
    elif isinstance(raw, SystemMessage):
        data = getattr(raw, "data", None)
        if isinstance(data, dict) and data.get("subtype") == "init":
            out.append({
                **base,
                "type": "session_info",
                "model": data.get("model"),
                "permission_mode": data.get("permissionMode"),
                "cwd": data.get("cwd"),
                "session_id": data.get("session_id"),
            })
        sid = getattr(raw, "session_id", None) or (
            data.get("session_id") if isinstance(data, dict) else None
        )
        if sid:
            out.append({**base, "type": "turn_complete", "session_id": sid})
    return out
