"""Custom tools exposed to the orchestrator agent.

Each tool is a thin wrapper around a Supacode bridge endpoint. Descriptions
matter — they steer the agent's behavior alongside the system prompt.
"""

from __future__ import annotations

from typing import Any

try:
    from claude_agent_sdk import tool  # type: ignore[import-not-found]
except ImportError:  # pragma: no cover — sdk not installed during early dev
    def tool(func):  # type: ignore[no-redef]
        func._is_tool = True  # noqa: SLF001
        return func


def build_tools(bridge):  # noqa: ANN001 — bridge is a SupacodeBridge
    """Returns the list of @tool-decorated callables, closing over the bridge."""

    @tool
    async def create_workspace(
        repo_path: str,
        branch_name: str,
        initial_task: str,
        base_branch: str = "main",
    ) -> dict[str, Any]:
        """Create a new workspace (git worktree + terminal tab with Claude Code running).

        Use when the user's request requires code changes in a specific
        repository. The workspace is created from `base_branch` on a new branch
        named `branch_name`. `initial_task` is the prompt sent to Claude Code
        in the new workspace as its first message.

        Returns `workspace_id`, which you must store and reference in
        subsequent tool calls.

        DO NOT create more than 3 workspaces without checking with the user
        first — parallelism has overhead and the user often wants to scope
        tightly before fanning out.
        """
        return await bridge.post(
            "/commands/create_workspace",
            {
                "repo_path": repo_path,
                "branch_name": branch_name,
                "initial_task": initial_task,
                "base_branch": base_branch,
            },
        )

    @tool
    async def send_to_workspace(workspace_id: str, message: str) -> dict[str, Any]:
        """Send a follow-up message into an existing workspace's Claude Code session.

        Use to give a workspace's agent more instructions, answer its
        questions, or course-correct. Appends a trailing newline so the
        message is dispatched, not just queued in the input field.
        """
        return await bridge.post(
            "/commands/send_to_workspace",
            {"workspace_id": workspace_id, "text": message + "\n"},
        )

    @tool
    async def peek_workspace(workspace_id: str, max_lines: int = 200) -> dict[str, Any]:
        """Read the last `max_lines` of terminal scrollback from a workspace.

        Use LAZILY. Do not poll. Peek only when about to summarize for the
        user, or when the user asks. Aggressive peeking burns context.
        """
        return await bridge.post(
            "/commands/peek_workspace",
            {"workspace_id": workspace_id, "max_lines": max_lines},
        )

    @tool
    async def list_workspaces() -> dict[str, Any]:
        """List workspaces attached to the current conversation, with status."""
        return await bridge.post("/commands/list_workspaces", {})

    @tool
    async def list_known_repos() -> dict[str, Any]:
        """List the repositories Supacode knows about (paths + display names).

        Use this before `create_workspace` so you can ground branch / repo
        names in what actually exists, rather than asking the user to spell
        paths.
        """
        return await bridge.post("/commands/list_known_repos", {})

    @tool
    async def merge_workspace(
        workspace_id: str, strategy: str = "merge"
    ) -> dict[str, Any]:
        """Merge a workspace's branch. Strategy: 'merge' | 'rebase' | 'pr'."""
        return await bridge.post(
            "/commands/merge_workspace",
            {"workspace_id": workspace_id, "strategy": strategy},
        )

    @tool
    async def cleanup_workspace(workspace_id: str) -> dict[str, Any]:
        """Archive/remove a workspace when its task is finished."""
        return await bridge.post(
            "/commands/cleanup_workspace",
            {"workspace_id": workspace_id},
        )

    return [
        create_workspace,
        send_to_workspace,
        peek_workspace,
        list_workspaces,
        list_known_repos,
        merge_workspace,
        cleanup_workspace,
    ]
