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
    case sendUserMessage(conversationID: UUID, content: String)
    case orchestratorEvent(OrchestratorEvent)
    case sessionStarted(conversationID: UUID, sessionID: String?)
  }

  @Dependency(\.conversationStore) var conversationStore
  @Dependency(\.orchestratorClient) var orchestratorClient
  @Dependency(\.uuid) var uuid
  @Dependency(\.date) var date

  private let logger = SupaLogger("Conversations")

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .onAppear:
        guard !state.isLoaded else { return .none }
        return .merge(
          .run { send in
            do {
              let loaded = try conversationStore.loadAll()
              await send(.loaded(loaded))
            } catch {
              await send(.loaded([]))
            }
          },
          .run { send in
            for await event in orchestratorClient.events() {
              await send(.orchestratorEvent(event))
            }
          }
        )

      case .loaded(let conversations):
        state.conversations = conversations
        state.isLoaded = true
        // Resume any sessions that have a saved sessionID.
        let resumes = conversations.compactMap { conversation -> (UUID, String)? in
          guard let sessionID = conversation.orchestratorSessionID else { return nil }
          return (conversation.id, sessionID)
        }
        guard !resumes.isEmpty else { return .none }
        return .run { send in
          for (cid, sessionID) in resumes {
            do {
              let newID = try await orchestratorClient.startSession(cid, sessionID)
              await send(.sessionStarted(conversationID: cid, sessionID: newID ?? sessionID))
            } catch {
              // sidecar not ready; skip
            }
          }
        }

      case .createConversation(let title):
        let conversation = Conversation(
          id: uuid(),
          title: title,
          createdAt: date.now
        )
        state.conversations.append(conversation)
        state.selectedConversationID = conversation.id
        let id = conversation.id
        return .merge(
          persist(conversation),
          .run { send in
            do {
              let sessionID = try await orchestratorClient.startSession(id, nil)
              await send(.sessionStarted(conversationID: id, sessionID: sessionID))
            } catch {
              // sidecar not yet ready — first user message will retry.
            }
          }
        )

      case .sessionStarted(let conversationID, let sessionID):
        guard var conversation = state.conversations[id: conversationID] else { return .none }
        conversation.orchestratorSessionID = sessionID
        state.conversations[id: conversationID] = conversation
        return persist(conversation)

      case .sendUserMessage(let conversationID, let content):
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .none }
        let message = OrchestratorMessage(id: uuid(), role: .user, content: trimmed, timestamp: date.now)
        return .merge(
          .send(.appendMessage(conversationID: conversationID, message: message)),
          .run { _ in
            try? await orchestratorClient.sendUserMessage(conversationID, trimmed)
          }
        )

      case .orchestratorEvent(let event):
        return handle(event: event, state: &state)

      case .selectConversation(let id):
        state.selectedConversationID = id
        return .none

      case .deleteConversation(let id):
        state.conversations.remove(id: id)
        if state.selectedConversationID == id {
          state.selectedConversationID = nil
        }
        return .run { _ in
          try? await orchestratorClient.killSession(id)
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

  private func handle(event: OrchestratorEvent, state: inout State) -> Effect<Action> {
    switch event {
    case .assistantDelta(let conversationID, let text):
      guard var conversation = state.conversations[id: conversationID] else { return .none }
      // Append to last assistant message in this turn, or start a new one.
      if let last = conversation.orchestratorMessages.last, last.role == .assistant {
        let updated = OrchestratorMessage(
          id: last.id,
          role: .assistant,
          content: last.content + text,
          timestamp: last.timestamp
        )
        conversation.orchestratorMessages[conversation.orchestratorMessages.count - 1] = updated
      } else {
        conversation.orchestratorMessages.append(
          OrchestratorMessage(id: uuid(), role: .assistant, content: text, timestamp: date.now)
        )
      }
      state.conversations[id: conversationID] = conversation
      return persist(conversation)

    case .toolUse(let conversationID, let tool, let id, let inputJSON):
      let payload = #"{"tool":"\#(tool)","id":"\#(id)","input":\#(inputJSON)}"#
      let message = OrchestratorMessage(id: uuid(), role: .toolUse, content: payload, timestamp: date.now)
      return .send(.appendMessage(conversationID: conversationID, message: message))

    case .toolResult(let conversationID, let toolUseID, let resultJSON):
      let payload = #"{"tool_use_id":"\#(toolUseID)","result":\#(resultJSON.isEmpty ? "\"\"" : "\"\(resultJSON.replacingOccurrences(of: "\"", with: "\\\""))\"")}"#
      let message = OrchestratorMessage(id: uuid(), role: .toolResult, content: payload, timestamp: date.now)
      return .send(.appendMessage(conversationID: conversationID, message: message))

    case .turnComplete(let conversationID, let sessionID):
      guard let sessionID, var conversation = state.conversations[id: conversationID] else { return .none }
      if conversation.orchestratorSessionID != sessionID {
        conversation.orchestratorSessionID = sessionID
        state.conversations[id: conversationID] = conversation
        return persist(conversation)
      }
      return .none

    case .error(let conversationID, let message):
      guard let conversationID else { return .none }
      let msg = OrchestratorMessage(id: uuid(), role: .system, content: "[error] \(message)", timestamp: date.now)
      return .send(.appendMessage(conversationID: conversationID, message: msg))
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
