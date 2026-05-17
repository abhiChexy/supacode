import ComposableArchitecture
import SupacodeSettingsShared
import SwiftUI

/// Placeholder for the orchestrator chat pane. The real sidecar-backed
/// chat lands in Phase 3.
struct OrchestratorChatPlaceholderView: View {
  let conversation: Conversation

  var body: some View {
    VStack(spacing: 16) {
      Spacer()
      Image(systemName: "bubble.left.and.bubble.right")
        .font(.system(size: 36))
        .foregroundStyle(.tertiary)
      Text(conversation.title.isEmpty ? "Untitled" : conversation.title)
        .font(.title2.weight(.semibold))
      Text("Orchestrator agent not yet connected.")
        .font(.callout)
        .foregroundStyle(.secondary)
      Text("Phase 3 wires the claude-agent-sdk sidecar.")
        .font(.caption)
        .foregroundStyle(.tertiary)
      if !conversation.workspaceIDs.isEmpty {
        Text("Workspaces: \(conversation.workspaceIDs.count)")
          .font(.caption)
          .foregroundStyle(.tertiary)
      }
      Spacer()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(.background)
  }
}
