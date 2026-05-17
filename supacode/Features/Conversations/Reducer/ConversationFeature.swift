import ComposableArchitecture
import Foundation
import IdentifiedCollections
import SupacodeSettingsShared

@Reducer
struct ConversationFeature {
  @ObservableState
  struct State: Equatable {
    var conversations: IdentifiedArrayOf<Conversation> = []
    var selectedConversationID: UUID?
    var isLoaded: Bool = false
  }

  enum Action: Equatable {
    case onAppear
    case loaded(IdentifiedArrayOf<Conversation>)
    case createConversation(title: String)
    case selectConversation(UUID?)
    case deleteConversation(UUID)
    case assignWorkspace(workspaceID: String, conversationID: UUID)
    case unassignWorkspace(workspaceID: String, conversationID: UUID)
    case renameConversation(id: UUID, title: String)
    case appendMessage(conversationID: UUID, message: OrchestratorMessage)
  }

  @Dependency(\.conversationStore) var conversationStore
  @Dependency(\.uuid) var uuid
  @Dependency(\.date) var date

  private let logger = SupaLogger("Conversations")

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .onAppear:
        guard !state.isLoaded else { return .none }
        return .run { send in
          do {
            let loaded = try conversationStore.loadAll()
            await send(.loaded(loaded))
          } catch {
            await send(.loaded([]))
          }
        }

      case .loaded(let conversations):
        state.conversations = conversations
        state.isLoaded = true
        return .none

      case .createConversation(let title):
        let conversation = Conversation(
          id: uuid(),
          title: title,
          createdAt: date.now
        )
        state.conversations.append(conversation)
        state.selectedConversationID = conversation.id
        return persist(conversation)

      case .selectConversation(let id):
        state.selectedConversationID = id
        return .none

      case .deleteConversation(let id):
        state.conversations.remove(id: id)
        if state.selectedConversationID == id {
          state.selectedConversationID = nil
        }
        return .run { _ in
          try? conversationStore.delete(id)
        }

      case .assignWorkspace(let workspaceID, let conversationID):
        guard var conversation = state.conversations[id: conversationID] else { return .none }
        // Each workspace can belong to at most one conversation.
        for (otherID, var other) in zip(state.conversations.ids, state.conversations) {
          guard otherID != conversationID else { continue }
          if let idx = other.workspaceIDs.firstIndex(of: workspaceID) {
            other.workspaceIDs.remove(at: idx)
            state.conversations[id: otherID] = other
          }
        }
        if !conversation.workspaceIDs.contains(workspaceID) {
          conversation.workspaceIDs.append(workspaceID)
        }
        state.conversations[id: conversationID] = conversation
        return persistAffected(state.conversations)

      case .unassignWorkspace(let workspaceID, let conversationID):
        guard var conversation = state.conversations[id: conversationID] else { return .none }
        conversation.workspaceIDs.removeAll { $0 == workspaceID }
        state.conversations[id: conversationID] = conversation
        return persist(conversation)

      case .renameConversation(let id, let title):
        guard var conversation = state.conversations[id: id] else { return .none }
        conversation.title = title
        state.conversations[id: id] = conversation
        return persist(conversation)

      case .appendMessage(let conversationID, let message):
        guard var conversation = state.conversations[id: conversationID] else { return .none }
        conversation.orchestratorMessages.append(message)
        state.conversations[id: conversationID] = conversation
        return persist(conversation)
      }
    }
  }

  private func persist(_ conversation: Conversation) -> Effect<Action> {
    .run { _ in
      do {
        try conversationStore.save(conversation)
      } catch {
        logger.error("Failed to persist conversation \(conversation.id): \(error)")
      }
    }
  }

  private func persistAffected(_ conversations: IdentifiedArrayOf<Conversation>) -> Effect<Action> {
    .run { _ in
      for conversation in conversations {
        do {
          try conversationStore.save(conversation)
        } catch {
          logger.error("Failed to persist conversation \(conversation.id): \(error)")
        }
      }
    }
  }
}
