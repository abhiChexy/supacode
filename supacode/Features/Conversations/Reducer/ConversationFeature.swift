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
    /// Conversations with an in-flight turn — used to drive the thinking
    /// indicator. Cleared on turn_complete or error.
    var inFlightConversationIDs: Set<UUID> = []
    /// Per-conversation runtime info — model, cwd, usage. Not persisted.
    var runtimeByConversationID: [UUID: ConversationRuntime] = [:]
  }

  struct ConversationRuntime: Equatable {
    var model: String?
    var cwd: String?
    var totalInputTokens: Int = 0
    var totalOutputTokens: Int = 0
    var totalCacheReadTokens: Int = 0
    var totalCacheCreationTokens: Int = 0
    var totalCostUSD: Double = 0
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
    case interruptCurrent(conversationID: UUID)
  }

  @Dependency(ConversationStoreKey.self) var conversationStore
  @Dependency(OrchestratorClientKey.self) var orchestratorClient
  @Dependency(\.uuid) var uuid
  @Dependency(\.date) var date

  private let logger = SupaLogger("Conversations")

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      let store = conversationStore
      let orchestrator = orchestratorClient
      switch action {
      case .onAppear:
        guard !state.isLoaded else { return .none }
        return .merge(
          .run { send in
            do {
              let loaded = try store.loadAll()
              await send(.loaded(loaded))
            } catch {
              await send(.loaded([]))
            }
          },
          .run { send in
            for await event in orchestrator.events() {
              await send(.orchestratorEvent(event))
            }
          }
        )

      case .loaded(let conversations):
        state.conversations = conversations
        state.isLoaded = true
        let resumes = conversations.compactMap { conversation -> (UUID, String)? in
          guard let sessionID = conversation.orchestratorSessionID else { return nil }
          return (conversation.id, sessionID)
        }
        guard !resumes.isEmpty else { return .none }
        return .run { send in
          for (cid, sessionID) in resumes {
            do {
              let newID = try await orchestrator.startSession(cid, sessionID)
              await send(.sessionStarted(conversationID: cid, sessionID: newID ?? sessionID))
            } catch {
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
              let sessionID = try await orchestrator.startSession(id, nil)
              await send(.sessionStarted(conversationID: id, sessionID: sessionID))
            } catch {
            }
          }
        )

      case .sendUserMessage(let conversationID, let content):
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .none }
        let message = OrchestratorMessage(id: uuid(), role: .user, content: trimmed, timestamp: date.now)
        state.inFlightConversationIDs.insert(conversationID)
        // Auto-title from the first user message — mirror Claude Desktop's
        // behavior. Only applies when the title is still the placeholder.
        var effects: [Effect<Action>] = [
          .send(.appendMessage(conversationID: conversationID, message: message)),
          .run { _ in
            try? await orchestrator.sendUserMessage(conversationID, trimmed)
          },
        ]
        if var convo = state.conversations[id: conversationID],
          convo.title.isEmpty || convo.title == "Untitled",
          convo.orchestratorMessages.allSatisfy({ $0.role != .user })
        {
          convo.title = Self.deriveTitle(from: trimmed)
          state.conversations[id: conversationID] = convo
          effects.append(persist(convo))
        }
        return .merge(effects)

      case .sessionStarted(let conversationID, let sessionID):
        guard var conversation = state.conversations[id: conversationID] else { return .none }
        conversation.orchestratorSessionID = sessionID
        state.conversations[id: conversationID] = conversation
        return persist(conversation)

      case .orchestratorEvent(let event):
        return handle(event: event, state: &state)

      case .interruptCurrent(let conversationID):
        return .run { _ in
          try? await orchestrator.interruptSession(conversationID)
        }

      case .selectConversation(let id):
        state.selectedConversationID = id
        return .none

      case .deleteConversation(let id):
        state.conversations.remove(id: id)
        if state.selectedConversationID == id {
          state.selectedConversationID = nil
        }
        return .run { _ in
          try? await orchestrator.killSession(id)
          try? store.delete(id)
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
      state.inFlightConversationIDs.remove(conversationID)
      guard var conversation = state.conversations[id: conversationID] else { return .none }
      if let sessionID, conversation.orchestratorSessionID != sessionID {
        conversation.orchestratorSessionID = sessionID
        state.conversations[id: conversationID] = conversation
        return persist(conversation)
      }
      return .none

    case .error(let conversationID, let message):
      guard let conversationID else { return .none }
      state.inFlightConversationIDs.remove(conversationID)
      let msg = OrchestratorMessage(id: uuid(), role: .system, content: "[error] \(message)", timestamp: date.now)
      return .send(.appendMessage(conversationID: conversationID, message: msg))

    case .sessionInfo(let conversationID, let model, _, let cwd):
      var runtime = state.runtimeByConversationID[conversationID] ?? ConversationRuntime()
      if let model { runtime.model = model }
      if let cwd { runtime.cwd = cwd }
      state.runtimeByConversationID[conversationID] = runtime
      return .none

    case .usage(let conversationID, let inputTokens, let outputTokens, let cacheReadTokens, let cacheCreationTokens, let costUSD):
      var runtime = state.runtimeByConversationID[conversationID] ?? ConversationRuntime()
      runtime.totalInputTokens += inputTokens
      runtime.totalOutputTokens += outputTokens
      runtime.totalCacheReadTokens += cacheReadTokens
      runtime.totalCacheCreationTokens += cacheCreationTokens
      if let costUSD { runtime.totalCostUSD += costUSD }
      state.runtimeByConversationID[conversationID] = runtime
      return .none
    }
  }

  /// Derive a short conversation title from the first user message. Single
  /// line, up to ~60 chars at a word boundary, no trailing punctuation.
  static func deriveTitle(from message: String) -> String {
    let firstLine = message.split(whereSeparator: \.isNewline).first.map(String.init) ?? message
    let collapsed = firstLine.replacing(/\s+/, with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    let limit = 60
    guard collapsed.count > limit else {
      return collapsed.isEmpty ? "Untitled" : collapsed
    }
    let prefix = collapsed.prefix(limit)
    if let lastSpace = prefix.lastIndex(of: " ") {
      return String(collapsed[..<lastSpace]) + "…"
    }
    return String(prefix) + "…"
  }

  private func persist(_ conversation: Conversation) -> Effect<Action> {
    let store = conversationStore
    let log = logger
    return .run { _ in
      do {
        try store.save(conversation)
      } catch {
        log.warning("Failed to persist conversation \(conversation.id): \(error)")
      }
    }
  }

  private func persistAffected(_ conversations: IdentifiedArrayOf<Conversation>) -> Effect<Action> {
    let store = conversationStore
    let log = logger
    return .run { _ in
      for conversation in conversations {
        do {
          try store.save(conversation)
        } catch {
          log.warning("Failed to persist conversation \(conversation.id): \(error)")
        }
      }
    }
  }
}
