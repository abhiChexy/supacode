import ComposableArchitecture
import Foundation
import SupacodeSettingsShared

/// Wires the Python sidecar's HTTP callbacks (`POST /commands/<verb>`) into
/// TCA actions on `AppFeature`. Each handler is intentionally thin — most of
/// the heavy lifting (worktree creation, terminal interaction) goes through
/// existing `RepositoriesFeature` + `TerminalClient` so orchestrator-created
/// workspaces look identical to user-created ones.
///
/// Some endpoints are stubbed in Phase 3 (returning shape-correct but
/// best-effort responses) so the sidecar contract is intact while the
/// per-endpoint dispatch is filled in during Phase 4 dogfooding.
@MainActor
enum OrchestratorBridgeHandlers {
  static func register(on server: OrchestratorBridgeServer, store: StoreOf<AppFeature>) {
    server.register(path: "/commands/list_known_repos") { _ in
      let repos = store.state.repositories.repositories
      let payload = repos.map { repo -> [String: Any] in
        [
          "id": repo.id,
          "root_path": repo.rootURL.path(percentEncoded: false),
          "name": repo.name,
          "is_git": repo.isGitRepository,
        ]
      }
      return ["repos": payload]
    }

    server.register(path: "/commands/list_workspaces") { _ in
      let worktrees = store.state.repositories.repositories.flatMap { repo in
        repo.worktrees.map { worktree -> [String: Any] in
          [
            "id": worktree.id,
            "repo": repo.name,
            "name": worktree.name,
            "detail": worktree.detail,
            "path": worktree.workingDirectory.path(percentEncoded: false),
          ]
        }
      }
      return ["workspaces": worktrees]
    }

    server.register(path: "/commands/create_workspace") { body in
      // Real dispatch: route through RepositoriesFeature.createWorktreeInRepository
      // with the agent-side `initial_task` becoming the createTabWithInput
      // payload. Filled in Phase 4 dogfooding.
      let repoPath = body["repo_path"] as? String ?? ""
      let branch = body["branch_name"] as? String ?? ""
      SupaLogger("OrchestratorBridge").info("create_workspace request: repo=\(repoPath) branch=\(branch) (stubbed in Phase 3)")
      return [
        "workspace_id": UUID().uuidString,
        "status": "stubbed",
        "note": "Phase 3 wiring stub — implement RepositoriesFeature dispatch in Phase 4.",
      ]
    }

    server.register(path: "/commands/send_to_workspace") { body in
      let workspaceID = body["workspace_id"] as? String ?? ""
      SupaLogger("OrchestratorBridge").info("send_to_workspace request: id=\(workspaceID) (stubbed in Phase 3)")
      return nil
    }

    server.register(path: "/commands/peek_workspace") { body in
      let workspaceID = body["workspace_id"] as? String ?? ""
      SupaLogger("OrchestratorBridge").info("peek_workspace request: id=\(workspaceID) (stubbed in Phase 3)")
      return [
        "scrollback": "",
        "agent_status": "unknown",
      ]
    }

    server.register(path: "/commands/merge_workspace") { _ in
      ["result": "noop", "note": "Phase 4 wiring"]
    }

    server.register(path: "/commands/cleanup_workspace") { _ in
      nil
    }
  }
}
