import ComposableArchitecture
import SwiftUI

/// Modal that hosts the actual ghostty terminal for a workspace so the user
/// can watch / talk to the child agent live without leaving the
/// orchestrator chat.
struct WorkspaceTerminalSheet: View {
  let worktreeID: String
  @Bindable var store: StoreOf<AppFeature>
  let terminalManager: WorktreeTerminalManager
  @Environment(\.dismiss) private var dismiss

  private var worktree: Worktree? {
    for repo in store.repositories.repositories {
      if let wt = repo.worktrees.first(where: { $0.id == worktreeID }) {
        return wt
      }
    }
    return nil
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider().background(Theme.Color.borderSubtle)
      if worktree != nil {
        // Select the worktree so WorktreeDetailView mounts against it.
        WorktreeDetailView(store: store, terminalManager: terminalManager)
          .onAppear {
            store.send(.repositories(.selectWorktree(worktreeID, focusTerminal: false)))
          }
      } else {
        Text("Workspace not found")
          .foregroundStyle(Theme.Color.statusError)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .frame(minWidth: 780, minHeight: 540)
    .background(Theme.Color.backgroundSecondary)
  }

  private var header: some View {
    HStack(spacing: Theme.Spacing.s) {
      Image(systemName: "terminal")
        .font(.system(size: 12))
        .foregroundStyle(Theme.Color.textSecondary)
      Text(worktree?.name ?? worktreeID)
        .font(.system(size: 13, weight: .semibold))
      Spacer()
      Button("Done") { dismiss() }
        .buttonStyle(.borderless)
        .foregroundStyle(Theme.Color.textSecondary)
        .keyboardShortcut(.escape, modifiers: [])
    }
    .padding(Theme.Spacing.m)
  }
}
