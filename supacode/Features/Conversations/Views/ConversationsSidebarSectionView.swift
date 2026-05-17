import ComposableArchitecture
import SupacodeSettingsShared
import SwiftUI

/// Top-of-sidebar list of conversations. Additive surface above the existing
/// repository sidebar.
struct ConversationsSidebarSectionView: View {
  @Bindable var store: StoreOf<ConversationFeature>
  @State private var hoveredID: UUID?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
        .padding(.horizontal, Theme.Spacing.m)
        .padding(.vertical, Theme.Spacing.s)

      if store.conversations.isEmpty {
        Button(action: createConversation) {
          HStack(spacing: Theme.Spacing.s) {
            Image(systemName: "plus.circle")
              .font(.system(size: 12))
            Text("New conversation")
              .font(Theme.Font.sidebarRow)
          }
          .foregroundStyle(Theme.Color.textSecondary)
          .padding(.horizontal, Theme.Spacing.m)
          .padding(.vertical, 6)
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      } else {
        ForEach(orderedConversations) { conversation in
          row(for: conversation)
        }
      }

      Divider()
        .background(Theme.Color.borderSubtle)
        .padding(.top, Theme.Spacing.xs)
    }
  }

  private var orderedConversations: [Conversation] {
    store.conversations.sorted { $0.createdAt > $1.createdAt }
  }

  private var header: some View {
    HStack(spacing: Theme.Spacing.xs) {
      Text("Conversations")
        .font(Theme.Font.headerSection)
        .foregroundStyle(Theme.Color.textSecondary)
        .textCase(.uppercase)
      Spacer()
      Button(action: createConversation) {
        Image(systemName: "square.and.pencil")
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(Theme.Color.textSecondary)
          .frame(width: 22, height: 22)
          .background(Theme.Color.backgroundElevated)
          .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.pill))
      }
      .buttonStyle(.plain)
      .help("New Conversation (⌘N)")
      .keyboardShortcut("n", modifiers: .command)
    }
  }

  @ViewBuilder
  private func row(for conversation: Conversation) -> some View {
    let isSelected = store.selectedConversationID == conversation.id
    let isInFlight = store.inFlightConversationIDs.contains(conversation.id)
    let isHovered = hoveredID == conversation.id
    HStack(spacing: Theme.Spacing.s) {
      Circle()
        .fill(isInFlight ? Theme.Color.statusSuccess : Theme.Color.textTertiary)
        .frame(width: 6, height: 6)
      Text(conversation.title.isEmpty ? "Untitled" : conversation.title)
        .font(Theme.Font.sidebarRow)
        .foregroundStyle(Theme.Color.textPrimary)
        .lineLimit(1)
        .truncationMode(.tail)
      Spacer(minLength: Theme.Spacing.xs)
      if isHovered {
        Button {
          store.send(.deleteConversation(conversation.id))
        } label: {
          Image(systemName: "trash")
            .font(.system(size: 10))
            .foregroundStyle(Theme.Color.textSecondary)
            .frame(width: 18, height: 18)
            .background(Theme.Color.backgroundElevated)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .help("Delete conversation")
      } else {
        if !conversation.workspaceIDs.isEmpty {
          Text("\(conversation.workspaceIDs.count)")
            .font(Theme.Font.monoTiny)
            .foregroundStyle(Theme.Color.textTertiary)
        }
        Text(relativeTime(for: conversation.createdAt))
          .font(Theme.Font.monoTiny)
          .foregroundStyle(Theme.Color.textTertiary)
      }
    }
    .padding(.horizontal, Theme.Spacing.m)
    .padding(.vertical, 5)
    .contentShape(Rectangle())
    .background(
      Group {
        if isSelected {
          Color.white.opacity(0.08)
        } else if isHovered {
          Color.white.opacity(0.04)
        } else {
          Color.clear
        }
      }
    )
    .onTapGesture {
      store.send(.selectConversation(conversation.id))
    }
    .onHover { hovering in
      hoveredID = hovering ? conversation.id : (hoveredID == conversation.id ? nil : hoveredID)
    }
    .help(conversation.title.isEmpty ? "Untitled" : conversation.title)
    .contextMenu {
      Button("Delete", role: .destructive) {
        store.send(.deleteConversation(conversation.id))
      }
    }
  }

  private func createConversation() {
    store.send(.createConversation(title: ""))
  }

  /// Slack/Cursor-style compact relative time: "now" / "5m" / "3h" / "2d" / "5w" / "Jan 4".
  private func relativeTime(for date: Date) -> String {
    let seconds = Date().timeIntervalSince(date)
    if seconds < 60 { return "now" }
    let minutes = Int(seconds / 60)
    if minutes < 60 { return "\(minutes)m" }
    let hours = minutes / 60
    if hours < 24 { return "\(hours)h" }
    let days = hours / 24
    if days < 7 { return "\(days)d" }
    let weeks = days / 7
    if weeks < 5 { return "\(weeks)w" }
    let fmt = DateFormatter()
    fmt.dateFormat = "MMM d"
    return fmt.string(from: date)
  }
}
