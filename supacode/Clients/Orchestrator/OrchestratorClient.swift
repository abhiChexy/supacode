import ComposableArchitecture
import Dependencies
import Foundation

/// TCA dependency that owns the Python sidecar process and exposes a
/// request/response API over local HTTP, plus a streamed event channel from
/// the sidecar's WebSocket.
nonisolated struct OrchestratorClient: Sendable {
  var startSession: @Sendable (_ conversationID: UUID, _ resumeSessionID: String?) async throws -> String?
  var sendUserMessage: @Sendable (_ conversationID: UUID, _ content: String) async throws -> Void
  var killSession: @Sendable (_ conversationID: UUID) async throws -> Void
  var interruptSession: @Sendable (_ conversationID: UUID) async throws -> Void
  var setModel: @Sendable (_ conversationID: UUID, _ model: String) async throws -> Void
  var events: @Sendable () -> AsyncStream<OrchestratorEvent>
  var isReady: @Sendable () -> Bool

  nonisolated static let live = OrchestratorClient(
    startSession: { conversationID, resumeSessionID in
      try await OrchestratorRuntime.shared.startSession(
        conversationID: conversationID,
        resumeSessionID: resumeSessionID
      )
    },
    sendUserMessage: { conversationID, content in
      try await OrchestratorRuntime.shared.sendUserMessage(
        conversationID: conversationID,
        content: content
      )
    },
    killSession: { conversationID in
      try await OrchestratorRuntime.shared.killSession(conversationID: conversationID)
    },
    interruptSession: { conversationID in
      try await OrchestratorRuntime.shared.interruptSession(conversationID: conversationID)
    },
    setModel: { conversationID, model in
      try await OrchestratorRuntime.shared.setModel(conversationID: conversationID, model: model)
    },
    events: { OrchestratorRuntime.shared.events() },
    isReady: { OrchestratorRuntime.shared.isReady }
  )

  nonisolated static let test = OrchestratorClient(
    startSession: { _, _ in nil },
    sendUserMessage: { _, _ in },
    killSession: { _ in },
    interruptSession: { _ in },
    setModel: { _, _ in },
    events: { AsyncStream { $0.finish() } },
    isReady: { false }
  )
}

nonisolated enum OrchestratorEvent: Equatable, Sendable {
  case assistantDelta(conversationID: UUID, text: String)
  case toolUse(conversationID: UUID, tool: String, id: String, inputJSON: String)
  case toolResult(conversationID: UUID, toolUseID: String, resultJSON: String)
  case turnComplete(conversationID: UUID, sessionID: String?)
  case sessionInfo(conversationID: UUID, model: String?, permissionMode: String?, cwd: String?)
  case usage(conversationID: UUID, inputTokens: Int, outputTokens: Int, cacheReadTokens: Int, cacheCreationTokens: Int, costUSD: Double?)
  case error(conversationID: UUID?, message: String)
}

nonisolated enum OrchestratorClientKey: DependencyKey {
  static let liveValue: OrchestratorClient = .live
  static let testValue: OrchestratorClient = .test
}

extension DependencyValues {
  nonisolated var orchestratorClient: OrchestratorClient {
    get { self[OrchestratorClientKey.self] }
    set { self[OrchestratorClientKey.self] = newValue }
  }
}
