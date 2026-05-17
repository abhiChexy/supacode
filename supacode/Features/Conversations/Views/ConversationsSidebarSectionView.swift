import ComposableArchitecture
import SupacodeSettingsShared
import SwiftUI

/// Top-of-sidebar list of conversations. Additive surface above the existing
/// repository sidebar.
struct ConversationsSidebarSectionView: View {
  @Bindable var store: StoreOf<ConversationFeature>
  @State private var newConversationTitle: String = ""
  @State private var isAddingConversation = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
        .padding(.horizontal, Theme.Spacing.m)
        .padding(.vertical, Theme.Spacing.s)

      if isAddingConversation {
        TextField("Conversation title", text: $newConversationTitle)
          .textFieldStyle(.plain)
          .font(Theme.Font.sidebarRow)
          .padding(.horizontal, Theme.Spacing.s)
          .padding(.vertical, Theme.Spacing.xs)
          .background(Theme.Color.backgroundElevated)
          .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.pill))
          .padding(.horizontal, Theme.Spacing.m)
          .padding(.bottom, Theme.Spacing.s)
          .onSubmit(commitNewConversation)
      }

      if store.conversations.isEmpty {
        Text("No conversations yet")
          .font(Theme.Font.metadata)
          .foregroundStyle(Theme.Color.textTertiary)
          .padding(.horizontal, Theme.Spacing.m)
          .padding(.bottom, Theme.Spacing.s)
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
        isAddingConversation.toggle()
        if !isAddingConversation { newConversationTitle = "" }
      } label: {
        Image(systemName: "plus")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(Theme.Color.textSecondary)
      }
      .buttonStyle(.borderless)
      .help("New Conversation")
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

  private func commitNewConversation() {
    let title = newConversationTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else { return }
    store.send(.createConversation(title: title))
    newConversationTitle = ""
    isAddingConversation = false
  }
}
