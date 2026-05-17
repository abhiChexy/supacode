import ComposableArchitecture
import SupacodeSettingsShared
import SwiftUI

/// Top-of-sidebar list of conversations. Additive surface that sits above the
/// existing repository sidebar. Picking a conversation deselects any worktree
/// selection (handled in `AppFeature`).
struct ConversationsSidebarSectionView: View {
  @Bindable var store: StoreOf<ConversationFeature>
  @State private var newConversationTitle: String = ""
  @State private var isAddingConversation = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
        .padding(.horizontal, 12)
        .padding(.vertical, 8)

      if isAddingConversation {
        TextField("Title", text: $newConversationTitle)
          .textFieldStyle(.roundedBorder)
          .padding(.horizontal, 12)
          .padding(.bottom, 8)
          .onSubmit(commitNewConversation)
      }

      if store.conversations.isEmpty {
        Text("No conversations yet")
          .font(.system(size: 11))
          .foregroundStyle(.tertiary)
          .padding(.horizontal, 12)
          .padding(.bottom, 8)
      } else {
        ForEach(store.conversations) { conversation in
          row(for: conversation)
        }
      }

      Divider().padding(.top, 4)
    }
  }

  private var header: some View {
    HStack(spacing: 4) {
      Text("Conversations")
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
        .textCase(.uppercase)
      Spacer()
      Button {
        isAddingConversation.toggle()
        if !isAddingConversation { newConversationTitle = "" }
      } label: {
        Image(systemName: "plus")
          .font(.system(size: 10, weight: .semibold))
      }
      .buttonStyle(.borderless)
      .help("New Conversation")
    }
  }

  @ViewBuilder
  private func row(for conversation: Conversation) -> some View {
    let isSelected = store.selectedConversationID == conversation.id
    HStack(spacing: 6) {
      Image(systemName: "bubble.left.and.bubble.right")
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
      Text(conversation.title.isEmpty ? "Untitled" : conversation.title)
        .lineLimit(1)
        .truncationMode(.middle)
      Spacer(minLength: 4)
      if !conversation.workspaceIDs.isEmpty {
        Text("\(conversation.workspaceIDs.count)")
          .font(.system(size: 10, design: .monospaced))
          .foregroundStyle(.tertiary)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 5)
    .contentShape(Rectangle())
    .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
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
