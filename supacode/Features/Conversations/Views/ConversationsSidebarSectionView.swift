import ComposableArchitecture
import SupacodeSettingsShared
import SwiftUI

/// Top-of-sidebar list of conversations. Additive surface above the existing
/// repository sidebar.
struct ConversationsSidebarSectionView: View {
  @Bindable var store: StoreOf<ConversationFeature>

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
        .padding(.horizontal, Theme.Spacing.m)
        .padding(.vertical, Theme.Spacing.s)

      if store.conversations.isEmpty {
        Button {
          createConversation()
        } label: {
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
        ForEach(store.conversations) { conversation in
          row(for: conversation)
        }
      }

      Divider()
        .background(Theme.Color.borderSubtle)
        .padding(.top, Theme.Spacing.xs)
    }
  }

  private var header: some View {
    HStack(spacing: Theme.Spacing.xs) {
      Text("Conversations")
        .font(Theme.Font.headerSection)
        .foregroundStyle(Theme.Color.textSecondary)
        .textCase(.uppercase)
      Spacer()
      Button {
        createConversation()
      } label: {
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
    HStack(spacing: Theme.Spacing.s) {
      Circle()
        .fill(isInFlight ? Theme.Color.statusSuccess : Theme.Color.textTertiary)
        .frame(width: 6, height: 6)
      Text(conversation.title.isEmpty ? "Untitled" : conversation.title)
        .font(Theme.Font.sidebarRow)
        .foregroundStyle(Theme.Color.textPrimary)
        .lineLimit(1)
        .truncationMode(.middle)
      Spacer(minLength: Theme.Spacing.xs)
      if !conversation.workspaceIDs.isEmpty {
        Text("\(conversation.workspaceIDs.count)")
          .font(Theme.Font.monoTiny)
          .foregroundStyle(Theme.Color.textTertiary)
      }
    }
    .padding(.horizontal, Theme.Spacing.m)
    .padding(.vertical, 5)
    .contentShape(Rectangle())
    .background(isSelected ? Color.white.opacity(0.08) : Color.clear)
    .onTapGesture {
      store.send(.selectConversation(conversation.id))
    }
    .contextMenu {
      Button("Delete", role: .destructive) {
        store.send(.deleteConversation(conversation.id))
      }
    }
  }

  private func createConversation() {
    // Empty title — auto-filled from the first user message.
    store.send(.createConversation(title: ""))
  }
}
