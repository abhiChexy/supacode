import ComposableArchitecture
import SwiftUI

/// Shown in the detail pane when nothing is selected. Foregrounds the
/// orchestrator (the v1 entry point) over the legacy "open a repository"
/// affordance.
struct ConversationEmptyStateView: View {
  @Bindable var store: StoreOf<ConversationFeature>

  var body: some View {
    VStack(spacing: Theme.Spacing.m) {
      Spacer()
      Image(systemName: "bubble.left.and.bubble.right")
        .font(.system(size: 40, weight: .thin))
        .foregroundStyle(Theme.Color.textTertiary)
      VStack(spacing: Theme.Spacing.xs) {
        Text("Start a conversation")
          .font(.system(size: 18, weight: .semibold))
          .foregroundStyle(Theme.Color.textPrimary)
        Text("Tell the orchestrator what you want to coordinate across your repos.")
          .font(Theme.Font.body)
          .foregroundStyle(Theme.Color.textSecondary)
          .multilineTextAlignment(.center)
          .frame(maxWidth: 380)
      }
      Button {
        store.send(.createConversation(title: ""))
      } label: {
        HStack(spacing: Theme.Spacing.s) {
          Image(systemName: "square.and.pencil")
            .font(.system(size: 12, weight: .medium))
          Text("New conversation")
            .font(Theme.Font.body.weight(.medium))
          Text("⌘N")
            .font(Theme.Font.monoTiny)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Color.white.opacity(0.16))
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .padding(.horizontal, Theme.Spacing.m)
        .padding(.vertical, Theme.Spacing.s)
        .background(Theme.Color.accent)
        .foregroundStyle(.white)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
      }
      .buttonStyle(.plain)
      .keyboardShortcut("n", modifiers: .command)
      .padding(.top, Theme.Spacing.s)
      Spacer()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Theme.Color.backgroundSecondary)
  }
}
