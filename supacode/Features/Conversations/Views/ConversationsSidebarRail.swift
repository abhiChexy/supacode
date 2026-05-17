import ComposableArchitecture
import SupacodeSettingsShared
import SwiftUI

/// A thin always-visible rail of conversation icons. Shown when the main
/// navigation sidebar is collapsed (the user clicked the system toggle).
/// Lets you re-select / re-open the sidebar without losing access to the
/// conversation list — same idea as Warp's vertical tab strip.
struct ConversationsSidebarRail: View {
  @Bindable var store: StoreOf<ConversationFeature>
  let onExpand: () -> Void

  var body: some View {
    VStack(spacing: Theme.Spacing.xs) {
      Button {
        onExpand()
      } label: {
        Image(systemName: "sidebar.left")
          .font(.system(size: 14, weight: .medium))
          .foregroundStyle(Theme.Color.textSecondary)
          .frame(width: 32, height: 32)
          .background(Theme.Color.backgroundElevated)
          .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.pill))
      }
      .buttonStyle(.plain)
      .help("Expand sidebar (⌃⌘S)")
      .padding(.top, Theme.Spacing.s)

      Button {
        store.send(.createConversation(title: ""))
        onExpand()
      } label: {
        Image(systemName: "square.and.pencil")
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(Theme.Color.accent)
          .frame(width: 32, height: 32)
          .background(Theme.Color.accent.opacity(0.15))
          .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.pill))
      }
      .buttonStyle(.plain)
      .help("New conversation (⌘N)")
      .keyboardShortcut("n", modifiers: .command)

      Divider().background(Theme.Color.borderSubtle).padding(.horizontal, Theme.Spacing.s)

      ScrollView(showsIndicators: false) {
        VStack(spacing: Theme.Spacing.xs) {
          ForEach(store.conversations) { conversation in
            railRow(for: conversation)
          }
        }
        .padding(.vertical, Theme.Spacing.xs)
      }

      Spacer()
    }
    .frame(width: 44)
    .frame(maxHeight: .infinity)
    .background(Theme.Color.backgroundPrimary)
    .overlay(
      Divider().background(Theme.Color.borderSubtle),
      alignment: .trailing
    )
  }

  @ViewBuilder
  private func railRow(for conversation: Conversation) -> some View {
    let isSelected = store.selectedConversationID == conversation.id
    let isInFlight = store.inFlightConversationIDs.contains(conversation.id)
    Button {
      store.send(.selectConversation(conversation.id))
    } label: {
      ZStack(alignment: .topTrailing) {
        Text(initials(conversation.title))
          .font(.system(size: 10, weight: .semibold, design: .rounded))
          .foregroundStyle(isSelected ? Color.white : Theme.Color.textSecondary)
          .frame(width: 32, height: 32)
          .background(isSelected ? Theme.Color.accent : Theme.Color.backgroundElevated)
          .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.pill))
        if isInFlight {
          Circle()
            .fill(Theme.Color.statusSuccess)
            .frame(width: 7, height: 7)
            .overlay(Circle().stroke(Theme.Color.backgroundPrimary, lineWidth: 1.5))
            .offset(x: 2, y: -2)
        }
      }
    }
    .buttonStyle(.plain)
    .help(conversation.title.isEmpty ? "Untitled" : conversation.title)
    .contextMenu {
      Button("Delete", role: .destructive) {
        store.send(.deleteConversation(conversation.id))
      }
    }
  }

  private func initials(_ title: String) -> String {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "—" }
    let words = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
    if words.count >= 2, let a = words[0].first, let b = words[1].first {
      return "\(a)\(b)".uppercased()
    }
    return String(trimmed.prefix(2)).uppercased()
  }
}
