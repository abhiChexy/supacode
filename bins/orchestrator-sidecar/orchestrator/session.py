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
            #   round-trip over our pipe — every answer reads as a dismissal.
            # - Bash / Edit / Write / NotebookEdit: orchestrator shouldn't
            #   write code or run commands — it spawns workspaces that do.
            # - Task: prevents the orchestrator from dispatching subagents
            #   that further slow down the turn.
            # - Skill: pulls in the user's personal superpowers config and
            #   bloats context dramatically.
            disallowed_tools=[
                "AskUserQuestion",
                "Bash",
                "Edit",
                "Write",
                "NotebookEdit",
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
        # session_id is populated after first turn — leave None for now.
        return self._resume_session_id

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
        )
    except ImportError:
        return [{**base, "type": "raw", "value": repr(raw)}]

    if isinstance(raw, AssistantMessage):
        for block in raw.content:
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
                out.append({
                    **base,
                    "type": "tool_result",
                    "tool_use_id": block.tool_use_id,
                    "result": str(block.content) if block.content else "",
                })
    elif isinstance(raw, ResultMessage):
        out.append({
            **base,
            "type": "turn_complete",
            "session_id": getattr(raw, "session_id", None),
        })
    elif isinstance(raw, SystemMessage):
        # init / progress / etc. — capture session_id if available
        sid = getattr(raw, "session_id", None) or (
            raw.data.get("session_id") if isinstance(getattr(raw, "data", None), dict) else None
        )
        if sid:
            out.append({**base, "type": "turn_complete", "session_id": sid})
    return out
