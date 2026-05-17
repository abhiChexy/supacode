"""Custom orchestrator tools exposed to the agent via an in-process MCP server.

Each tool is a thin shim around a Supacode bridge endpoint
(POST /commands/<verb>). The descriptions are part of the agent's
effective prompt and steer behavior.
"""

from __future__ import annotations

from typing import Any

from claude_agent_sdk import create_sdk_mcp_server, tool


def build_orchestrator_mcp(bridge):  # noqa: ANN001 — bridge is a SupacodeBridge
    """Returns an SdkMcpServerConfig with all six orchestrator tools."""

    @tool(
        "create_workspace",
        (
            "Create a new workspace: a git worktree on a new branch with a "
            "terminal tab running Claude Code on `initial_task`. Use this "
            "whenever the user's request involves code changes in a "
            "specific repository. DO NOT exceed 3 workspaces per turn "
            "without checking with the user first."
        ),
        {
            "type": "object",
            "properties": {
                "repo_path": {
                    "type": "string",
                    "description": "Absolute path to the repository root (e.g. /Users/abhi/chexyCore).",
                },
                "branch_name": {
                    "type": "string",
                    "description": "New branch name. Will be created from base_branch.",
                },
                "initial_task": {
                    "type": "string",
                    "description": "Prompt sent to Claude Code in the new workspace as its first user message.",
                },
                "base_branch": {
                    "type": "string",
                    "description": "Branch to fork from. Defaults to 'main'.",
                    "default": "main",
                },
            },
            "required": ["repo_path", "branch_name", "initial_task"],
        },
    )
    async def create_workspace(args: dict[str, Any]) -> dict[str, Any]:
        result = await bridge.post(
            "/commands/create_workspace",
            {
                "repo_path": args["repo_path"],
                "branch_name": args["branch_name"],
                "initial_task": args["initial_task"],
                "base_branch": args.get("base_branch", "main"),
            },
        )
        return _text(result)

    @tool(
        "send_to_workspace",
        (
            "Send a follow-up message into an existing workspace's Claude "
            "Code session. Use to give it more instructions, answer its "
            "questions, or correct course."
        ),
        {
            "type": "object",
            "properties": {
                "workspace_id": {"type": "string"},
                "message": {"type": "string"},
            },
            "required": ["workspace_id", "message"],
        },
    )
    async def send_to_workspace(args: dict[str, Any]) -> dict[str, Any]:
        result = await bridge.post(
            "/commands/send_to_workspace",
            {"workspace_id": args["workspace_id"], "text": args["message"] + "\n"},
        )
        return _text(result or {"ok": True})

    @tool(
        "peek_workspace",
        (
            "Read the last N lines of terminal scrollback from a workspace. "
            "Use LAZILY — only when about to summarize for the user or when "
            "the user asks. Aggressive polling burns context."
        ),
        {
            "type": "object",
            "properties": {
                "workspace_id": {"type": "string"},
                "max_lines": {"type": "integer", "default": 200},
            },
            "required": ["workspace_id"],
        },
    )
    async def peek_workspace(args: dict[str, Any]) -> dict[str, Any]:
        result = await bridge.post(
            "/commands/peek_workspace",
            {
                "workspace_id": args["workspace_id"],
                "max_lines": args.get("max_lines", 200),
            },
        )
        return _text(result)

    @tool(
        "list_workspaces",
        "List all workspaces attached to this conversation with their current status.",
        {"type": "object", "properties": {}},
    )
    async def list_workspaces(args: dict[str, Any]) -> dict[str, Any]:
        result = await bridge.post("/commands/list_workspaces", {})
        return _text(result)

    @tool(
        "list_known_repos",
        (
            "List the repositories Supacode knows about (paths + display "
            "names). Use this before create_workspace so you ground branch "
            "and repo names in what actually exists."
        ),
        {"type": "object", "properties": {}},
    )
    async def list_known_repos(args: dict[str, Any]) -> dict[str, Any]:
        result = await bridge.post("/commands/list_known_repos", {})
        return _text(result)

    @tool(
        "cleanup_workspace",
        "Archive/remove a workspace once its task is finished and merged.",
        {
            "type": "object",
            "properties": {"workspace_id": {"type": "string"}},
            "required": ["workspace_id"],
        },
    )
    async def cleanup_workspace(args: dict[str, Any]) -> dict[str, Any]:
        await bridge.post(
            "/commands/cleanup_workspace",
            {"workspace_id": args["workspace_id"]},
        )
        return _text({"ok": True})

    return create_sdk_mcp_server(
        name="supacode_orchestrator",
        version="0.1.0",
        tools=[
            create_workspace,
            send_to_workspace,
            peek_workspace,
            list_workspaces,
            list_known_repos,
            cleanup_workspace,
        ],
    )


def _text(payload: Any) -> dict[str, Any]:
    """Wrap a JSON-serializable result in the MCP content-block shape."""
    import json

    body = json.dumps(payload, default=str)
    return {"content": [{"type": "text", "text": body}]}
