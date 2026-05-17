# Architecture Tour

A map of the parts of upstream Supacode we will extend in the orchestrator fork. For each entry: file path(s), short summary, and the "seam" — the line(s) where new behavior plugs in.

## 1. App entry & store wiring

**Path:** `supacode/App/supacodeApp.swift`

`@main` SwiftUI app. `SupacodeAppDelegate` owns the root `StoreOf<AppFeature>` and a `WorktreeTerminalManager`. On `applicationDidFinishLaunching` it sends `.appLaunched`. Telemetry (`AppCrashReporting.setup`, `AppTelemetry.setup`) is configured here from `Info.plist` values. Deeplinks (`supacode://…`) are buffered until the store exists, then routed via `appStore.send(.deeplinkReceived(url))`.

**Seam:** the spot just after `terminalManager` construction in `SupacodeAppDelegate` is where we will instantiate and inject the orchestrator `BridgeServer` and the sidecar `Process`. Wire as a TCA `@Dependency` so reducers can depend on it.

## 2. Root reducer — `AppFeature`

**Path:** `supacode/Features/App/Reducer/AppFeature.swift` (~1.8k lines)

Composes `RepositoriesFeature`, `SettingsFeature`, `UpdatesFeature`, `AgentPresenceFeature`, `CommandPaletteFeature`. State holds top-level concerns: notification indicator, deeplink queue, alerts, script lists (repo + global, merged via `[ScriptDefinition].merged(repo:global:)`). Subscribes to `terminalClient.events()` and `worktreeInfoWatcher.events()` on `.appLaunched`.

**Seam:** compose `ConversationFeature` here as a sibling of `RepositoriesFeature`. Forward orchestrator-triggered TCA actions (create-worktree, send-to-tab, peek-buffer) by re-using existing `RepositoriesFeature` and `TerminalClient.Command` cases — don't introduce parallel paths.

## 3. Terminal layer — `TerminalClient` + `WorktreeTerminalManager`

**Paths:**
- `supacode/Clients/Terminal/TerminalClient.swift` — the TCA boundary (`Command` enum, `Event` enum, AsyncStream of events).
- `supacode/Features/Terminal/BusinessLogic/WorktreeTerminalManager.swift` (~600 lines) — `@MainActor @Observable final class` that owns `WorktreeTerminalState` per worktree.
- `supacode/Features/Terminal/Models/TerminalTabManager.swift` — per-worktree tab/split tree.
- `supacode/Infrastructure/Ghostty/*` — `GhosttyRuntime`, `GhosttySurfaceState`, `GhosttySurfaceBridge`, `GhosttySurfaceView`.

End-to-end tab creation: `Reducer → terminalClient.send(.createTab(worktree, ...))` → `WorktreeTerminalManager.createTabAsync` → reads `RepositorySettings` for the repo, allocates a `TerminalTabID`, spins up a `GhosttySurfaceState` via `GhosttyRuntime` → `.tabCreated(worktreeID:)` event flows back through the AsyncStream.

Crucially, `TerminalClient.Command` already includes `.createTabWithInput(Worktree, input:, runSetupScriptIfNew:, id:)` — exactly the verb the orchestrator needs to "create a tab and immediately run `claude '...'`". No new command needed for that case. We also have `.focusSurface(... input: String?)` for sending text into an existing surface, which is what `send_to_workspace` will use.

**Seams:**
- `TerminalClient.Command` — extend with new cases only if existing ones don't cover the orchestrator's needs. So far they do.
- `TerminalClient.Event` — we may add `worktreeScrollbackSnapshot(worktreeID:, surfaceID:, lines:)` for `peek_workspace` if scrollback isn't accessible directly from `GhosttySurfaceState`.

## 4. Repo & worktree models

**Paths:**
- `supacode/Domain/Repository.swift` — `Repository` with `rootURL`, kind (git vs folder), `sidebarDisplayName`, `folderWorktreeID(for:)`, `isGitRepository(at:)`.
- `supacode/Domain/Worktree.swift` — `Worktree` (id, repositoryRootURL, workingDirectory, branch).
- `supacode/Features/Repositories/Reducer/RepositoriesFeature.swift` (~4.8k lines) — owns the list of repos, the sidebar state, archive/delete flows, PR tracking, per-row `SidebarItemFeature` children. The reducer that the orchestrator's tool-side bridge will most often poke.
- `supacode/Features/Repositories/BusinessLogic/SidebarStructure.swift` — pure transformation from per-row state to the rendered sidebar tree.

**Seams:**
- Reuse `RepositoriesFeature.Action` for worktree creation (the orchestrator should not bypass it — going through TCA keeps sidebar + watchers + PR refresh + scripts consistent). Look for the existing "create worktree" action — likely `.createRandomWorktreeInRepository` or `.createWorktreeInRepository`.
- Conversation membership = a new `IdentifiedArray<UUID, Conversation>` in `ConversationFeature.State`, with `workspaceIDs: [Worktree.ID]` references. **Conversations group, they do not own.**

## 5. Sidebar UI

**Paths:**
- `supacode/Features/Repositories/Views/SidebarListView.swift` — top-level renderer.
- `supacode/Features/Repositories/Views/SidebarItemsView.swift`, `SidebarItemView.swift`, `RepoSectionHeaderView.swift`, `SidebarHighlightSectionsView.swift`.
- `supacode/Features/Repositories/Views/SidebarView.swift` — outer container.

The sidebar is a "dumb renderer" over `RepositoriesFeature.State.sidebarStructure` (computed in a reducer post-reduce hook, gated by `\.sidebarStructureAutoRecompute`). Per-row state lives in `sidebarItems: IdentifiedArrayOf<SidebarItemFeature.State>`.

**Seam:** insert a new top-level `ConversationsSection` *above* the existing `.highlight` / `.repository` / `.folder` cases in `SidebarStructure.sections`. The view's single `ForEach(structure.sections)` + `SidebarSectionDispatcher` switch will naturally pick it up if we extend the enum. Per-leaf "loose workspaces" stay under their repo unchanged.

## 6. Settings architecture & `ScriptDefinition`

**Paths:**
- `SupacodeSettingsFeature/` (Reducer/Models/Views) — settings UI (TCA feature, static framework).
- `SupacodeSettingsShared/Models/ScriptDefinition.swift` — the `ScriptDefinition` model (kind: setup / archive / delete / run / custom; tintColor, systemImage, command).
- `SupacodeSettingsShared/BusinessLogic/SettingsFilePersistence.swift` — `SettingsFileStorage` dep, `settingsFile` shared key, `@Shared(.settingsFile)` access pattern.
- `SupacodeSettingsShared/Support/SupacodePaths.swift` — single source of truth for on-disk paths (base `~/.supacode/`, `settings.json`, `layouts.json`, `sidebar.json`, per-repo `<repoRoot>/supacode.json`).

Persistence pattern: pointfree's `swift-sharing` `@Shared(.settingsFile)` backed by a `SettingsFileStorage` dependency (load/save closures) and a `SettingsFileURLKey` dependency. JSON files under `~/.supacode/`. Tests use `inMemory()`.

**Seam for our `ConversationStore`:** mirror this exactly.
- Add `SupacodePaths.conversationsDirectoryURL` → `~/.supacode/conversations/` (one JSON file per conversation, `{uuid}.json`).
- Define `ConversationStore` as a `swift-dependencies` client (`load(id:)`, `save(_:)`, `delete(id:)`, `loadAll()`), with a `liveValue` that talks to the filesystem and a `testValue` returning `inMemory()`-style storage. Don't introduce a new dependency client just to wrap `@Shared` (per CLAUDE.md guidance) — but conversations are a list of independently-loaded files, not a single document, so a dedicated client is the right shape.

## 7. The bundled `wt` CLI

**Paths:**
- `Resources/git-wt/` (git submodule from `https://github.com/khoi/git-wt.git`)
- `supacode/Clients/Git/GitClient.swift` — Supacode invokes git operations here (`createWorktreeStream`, `removeWorktree`, etc.). Look here for how `wt` is shelled out and how stdout/stderr are streamed.
- `scripts/verify-git-wt.sh` — build-phase script that asserts the `wt` binary exists in `Resources/git-wt/wt`.

**Seam:** the orchestrator's `create_workspace` Python tool will *not* shell out to `wt` directly. Instead it will POST `/commands/create_workspace` to the Supacode HTTP bridge, which dispatches the existing `RepositoriesFeature` "create worktree" action, which goes through `GitClient` and `wt` exactly like manual creation does. This guarantees sidebar, watchers, PR refresh, and persistence all stay consistent.

---

## Open questions from spec §12 — resolved

### Q1. Does `WorktreeTerminalManager` support "create a tab and immediately run command X"?

**Yes.** `TerminalClient.Command.createTabWithInput(Worktree, input: String, runSetupScriptIfNew: Bool, id: UUID?)` already exists. The orchestrator's `create_workspace` tool will use this verb after the worktree itself is created by `RepositoriesFeature`. Initial command becomes `claude '<initial_task>'\n`.

### Q2. How does Supacode persist state today?

JSON files under `~/.supacode/` via pointfree `swift-sharing` (`@Shared(.settingsFile)`) backed by a `SettingsFileStorage` dependency. See `SupacodeSettingsShared/BusinessLogic/SettingsFilePersistence.swift` and `SupacodeSettingsShared/Support/SupacodePaths.swift`. For per-repo state, a `supacode.json` lives in the repo root. We mirror this pattern: `~/.supacode/conversations/{uuid}.json` for conversation persistence; the orchestrator session_id is stored inside the JSON, so resume works across launches.

### Q3. Where does the libghostty surface expose scrollback?

To be confirmed in Phase 3 once we look inside `GhosttyRuntime` / `GhosttySurfaceBridge`. Two plausible paths: (a) `ghostty_surface_t` has a C API for buffer text we can wrap in Swift, or (b) we tee PTY output into our own ring buffer per surface. The latter is the safer plan if (a) is awkward — `peek_workspace` only needs the last ~200 lines, so a 64KB ring per surface is negligible.

### Q4. Where does Supacode's repo discovery live?

`@Shared(.settingsFile)`'s `SettingsFile.global.repos` (or analogous structure inside `RepositoriesFeature.State`). `list_known_repos` reads `$settingsFile.withLock { $0.<roots>.map(...) }` — confirm exact field in Phase 2.

### Q5. `git-wt` CLI interface — shell out directly or go through TCA?

Go through TCA. The orchestrator's bridge endpoint `POST /commands/create_workspace` will dispatch the existing `RepositoriesFeature` action that creates a worktree, which already wraps `GitClient` → `wt`. This keeps sidebar refresh, PR watchers, repo settings hooks, and existing UX consistent for orchestrator-created workspaces — they look identical to user-created ones.

---

## Reference: TCA dependency injection pattern in this codebase

- `@Dependency(\.terminalClient)` — the terminal layer boundary.
- `@Dependency(\.worktreeInfoWatcher)` — branch/file/PR watcher boundary.
- `@Dependency(\.gitClient)` — git command execution.
- `@Shared(.settingsFile)` — directly in reducers for global settings (per CLAUDE.md: "Prefer `@Shared` directly in reducers for app storage and shared settings; do not introduce new dependency clients solely to wrap `@Shared`").

New dependencies we will add:
- `@Dependency(\.conversationStore)` — load/save conversations.
- `@Dependency(\.orchestratorClient)` — talk to the Python sidecar (start_session, send_message, kill_session, plus a `events()` AsyncStream for streamed deltas).

Both follow the existing `DependencyKey` + `liveValue` / `testValue` pattern in `swift-dependencies`.
