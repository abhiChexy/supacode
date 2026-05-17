import ComposableArchitecture
import Foundation
import SupacodeSettingsShared

/// Wires the Python sidecar's HTTP callbacks (`POST /commands/<verb>`) into
/// TCA actions on `AppFeature`. Real implementations — no longer stubs.
@MainActor
enum OrchestratorBridgeHandlers {
  private static let logger = SupaLogger("OrchestratorBridge")

  static func register(
    on server: OrchestratorBridgeServer,
    store: StoreOf<AppFeature>,
    terminalManager: WorktreeTerminalManager
  ) {
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
      let repoPath = (body["repo_path"] as? String) ?? ""
      let branch = (body["branch_name"] as? String) ?? ""
      let initialTask = (body["initial_task"] as? String) ?? ""
      let baseBranch = body["base_branch"] as? String
      guard !repoPath.isEmpty, !branch.isEmpty else {
        return ["error": "repo_path and branch_name are required"]
      }
      let repo: Repository
      if let existing = matchRepository(in: store, path: repoPath) {
        repo = existing
      } else {
        // Repo isn't in Supacode's sidebar yet — auto-register it so the
        // user doesn't have to do a manual "Add Repository" step. The
        // agent has access to all of ~, so any reachable git repo is
        // fair game.
        let url = resolveRepoURL(repoPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
          return ["error": "Path does not exist: \(url.path(percentEncoded: false))"]
        }
        guard Repository.isGitRepository(at: url) else {
          return ["error": "\(url.path(percentEncoded: false)) is not a git repository"]
        }
        logger.info("Auto-registering repo at \(url.path(percentEncoded: false)) for orchestrator")
        store.send(.repositories(.openRepositories([url])))
        guard let registered = await awaitRepository(store: store, url: url) else {
          return ["error": "Repo registration timed out for \(url.path(percentEncoded: false))"]
        }
        repo = registered
      }
      logger.info("create_workspace repo=\(repo.name) branch=\(branch)")
      store.send(
        .repositories(
          .createWorktreeInRepository(
            repositoryID: repo.id,
            nameSource: .explicit(branch),
            baseRefSource: baseBranch.map { .explicit($0) } ?? .repositorySetting,
            fetchOrigin: true
          )
        )
      )
      // Wait up to 60s for the worktree to materialize in state.
      let worktree = await awaitWorktree(store: store, repoID: repo.id, branch: branch)
      guard let worktree else {
        return ["error": "Worktree creation timed out for branch \(branch)"]
      }
      // Open a terminal tab inside the new worktree running Claude Code.
      let trimmedTask = initialTask.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmedTask.isEmpty {
        terminalManager.handleCommand(
          .ensureInitialTab(worktree, runSetupScriptIfNew: true, focusing: false)
        )
      } else {
        let escaped = trimmedTask.replacingOccurrences(of: "'", with: "'\\''")
        let command = "claude '\(escaped)'\n"
        terminalManager.handleCommand(
          .createTabWithInput(worktree, input: command, runSetupScriptIfNew: true)
        )
      }
      return [
        "workspace_id": worktree.id,
        "repo": repo.name,
        "branch": worktree.name,
        "path": worktree.workingDirectory.path(percentEncoded: false),
      ]
    }

    server.register(path: "/commands/send_to_workspace") { body in
      let workspaceID = (body["workspace_id"] as? String) ?? ""
      let text = (body["text"] as? String) ?? ""
      guard let worktree = findWorktree(in: store, id: workspaceID) else {
        return ["error": "workspace not found: \(workspaceID)"]
      }
      guard let tabID = terminalManager.stateIfExists(for: worktree.id)?.tabManager.selectedTabId else {
        return ["error": "no active tab for workspace"]
      }
      terminalManager.handleCommand(
        .selectTab(worktree, tabID: tabID)
      )
      // TerminalClient.focusSurface accepts an `input: String?` parameter.
      // We don't know the surface ID here without scrollback access; the
      // simplest reliable path is to spawn a fresh tab carrying the input.
      terminalManager.handleCommand(
        .createTabWithInput(worktree, input: text, runSetupScriptIfNew: false)
      )
      return nil
    }

    server.register(path: "/commands/peek_workspace") { body in
      let workspaceID = (body["workspace_id"] as? String) ?? ""
      guard let worktree = findWorktree(in: store, id: workspaceID) else {
        return ["error": "workspace not found"]
      }
      // Scrollback isn't exposed by GhosttySurface in a clean way yet;
      // return a thin status snapshot the agent can reason about.
      let hasTab = terminalManager.stateIfExists(for: worktree.id)?.tabManager.selectedTabId != nil
      return [
        "workspace_id": worktree.id,
        "branch": worktree.name,
        "path": worktree.workingDirectory.path(percentEncoded: false),
        "agent_status": hasTab ? "tab_active" : "no_tab",
        "scrollback": "",
        "note": "Scrollback capture not yet wired — only status reported.",
      ]
    }

    server.register(path: "/commands/cleanup_workspace") { body in
      let workspaceID = (body["workspace_id"] as? String) ?? ""
      guard let worktree = findWorktree(in: store, id: workspaceID) else {
        return ["error": "workspace not found"]
      }
      store.send(
        .repositories(
          .requestArchiveWorktree(worktree.id, repositoryIDForWorktree(in: store, id: worktree.id) ?? "")
        )
      )
      return nil
    }
  }

  // MARK: - Helpers

  /// Match the requested repo path against state. Accepts exact path,
  /// expanded tilde paths, and basename matches as a last resort.
  private static func matchRepository(in store: StoreOf<AppFeature>, path: String) -> Repository? {
    let normalized = resolveRepoURL(path).standardizedFileURL.path(percentEncoded: false)
    let repos = store.state.repositories.repositories
    if let exact = repos.first(where: { $0.rootURL.standardizedFileURL.path(percentEncoded: false) == normalized }) {
      return exact
    }
    if let byName = repos.first(where: { $0.name.caseInsensitiveCompare(URL(fileURLWithPath: normalized).lastPathComponent) == .orderedSame }) {
      return byName
    }
    return nil
  }

  /// Resolve `~`, relative paths, and bare names. A bare basename (e.g.
  /// "chexyCore") expands to ~/chexyCore.
  private static func resolveRepoURL(_ path: String) -> URL {
    let expanded = (path as NSString).expandingTildeInPath
    if expanded.hasPrefix("/") {
      return URL(fileURLWithPath: expanded).standardizedFileURL
    }
    return URL(fileURLWithPath: NSHomeDirectory()).appending(path: expanded).standardizedFileURL
  }

  /// Poll for a freshly-registered repo to appear in state.
  private static func awaitRepository(
    store: StoreOf<AppFeature>,
    url: URL
  ) async -> Repository? {
    let target = url.standardizedFileURL.path(percentEncoded: false)
    let deadline = Date().addingTimeInterval(20)
    while Date() < deadline {
      if let repo = store.state.repositories.repositories.first(where: {
        $0.rootURL.standardizedFileURL.path(percentEncoded: false) == target
      }) {
        return repo
      }
      try? await Task.sleep(for: .milliseconds(200))
    }
    return nil
  }

  private static func findWorktree(in store: StoreOf<AppFeature>, id: String) -> Worktree? {
    for repo in store.state.repositories.repositories {
      if let wt = repo.worktrees.first(where: { $0.id == id }) {
        return wt
      }
    }
    return nil
  }

  private static func repositoryIDForWorktree(in store: StoreOf<AppFeature>, id: String) -> String? {
    store.state.repositories.repositories.first { repo in
      repo.worktrees.contains(where: { $0.id == id })
    }?.id
  }

  /// Poll the TCA state for up to 60s waiting for a worktree on `branch` to
  /// appear in `repoID`'s worktree list. Returns nil on timeout.
  private static func awaitWorktree(
    store: StoreOf<AppFeature>,
    repoID: String,
    branch: String
  ) async -> Worktree? {
    let deadline = Date().addingTimeInterval(60)
    while Date() < deadline {
      if let repo = store.state.repositories.repositories[id: repoID],
        let wt = repo.worktrees.first(where: {
          $0.name == branch || $0.detail == branch
        })
      {
        return wt
      }
      try? await Task.sleep(for: .milliseconds(300))
    }
    return nil
  }
}
