"""Child SDK session per workspace.

Each spawned workspace gets its own ClaudeSDKClient running with
cwd=worktree path. Its events stream into the same WebSocket as the
parent orchestrator session, tagged with a workspace_id so the UI can
render them inline under a 'Workspace X' header.
"""

from __future__ import annotations

import asyncio
import traceback
from typing import Any, AsyncIterator

CHILD_SYSTEM_PROMPT = """\
You are a child workspace agent spawned by the Supacode orchestrator.

Your cwd is a fresh git worktree on a single feature branch. The user
gave the orchestrator a task; the orchestrator delegated this slice to
you. Do the work. Be brief. Use Edit / Write / Bash freely — permissions
are pre-approved. When the task is done, summarize what changed in one
short paragraph and stop.
"""


class WorkspaceSession:
    def __init__(
        self,
        parent_conversation_id: str,
        workspace_id: str,
        cwd: str,
    ) -> None:
        self.parent_conversation_id = parent_conversation_id
        self.workspace_id = workspace_id
        self.cwd = cwd
        self._client: Any = None
        self._lock = asyncio.Lock()

    async def start(self) -> None:
        try:
            from claude_agent_sdk import ClaudeAgentOptions, ClaudeSDKClient
        except ImportError as exc:
            print(f"[workspace {self.workspace_id}] SDK missing: {exc}", flush=True)
            return
        options = ClaudeAgentOptions(
            system_prompt=CHILD_SYSTEM_PROMPT,
            permission_mode="bypassPermissions",
            cwd=self.cwd,
            setting_sources=["user"],
            disallowed_tools=["AskUserQuestion", "Task", "Skill"],
            include_partial_messages=True,
        )
        try:
            self._client = ClaudeSDKClient(options=options)
            await self._client.connect()
        except Exception as exc:
            print(f"[workspace {self.workspace_id}] connect failed: {exc}", flush=True)
            traceback.print_exc()
            self._client = None

    async def send_message(self, content: str) -> AsyncIterator[dict[str, Any]]:
        if self._client is None:
            yield {"type": "error", "message": "child SDK not initialized"}
            return
        # Reuse the parent's event-normalizer so output shape matches.
        from .session import _normalize_message
        async with self._lock:
            try:
                await self._client.query(content)
                async for message in self._client.receive_response():
                    for event in _normalize_message(message, self.parent_conversation_id):
                        # Stamp workspace_id on every event so the UI knows
                        # it's child output, not parent.
                        event["workspace_id"] = self.workspace_id
                        yield event
            except Exception as exc:
                print(f"[workspace {self.workspace_id}] send failed: {exc}", flush=True)
                traceback.print_exc()
                yield {
                    "type": "error",
                    "conversation_id": self.parent_conversation_id,
                    "workspace_id": self.workspace_id,
                    "message": str(exc),
                }

    async def interrupt(self) -> None:
        if self._client is None:
            return
        try:
            await self._client.interrupt()
        except Exception:
            pass

    async def close(self) -> None:
        if self._client is not None:
            try:
                await self._client.disconnect()
            except Exception:
                pass
            self._client = None
