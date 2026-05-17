import ComposableArchitecture
import Dependencies
import Foundation

/// TCA dependency that owns the Python sidecar process and exposes a
/// request/response API over local HTTP, plus a streamed event channel from
/// the sidecar's WebSocket.
///
/// Lifecycle is owned at the app layer (see `OrchestratorRuntime` for the
/// concrete impl bound into `liveValue`). Reducers consume the
/// dependency-style facade.
struct OrchestratorClient: Sendable {
  var startSession: @Sendable (_ conversationID: UUID, _ resumeSessionID: String?) async throws -> String?
  var sendUserMessage: @Sendable (_ conversationID: UUID, _ content: String) async throws -> Void
  var killSession: @Sendable (_ conversationID: UUID) async throws -> Void
  var events: @Sendable () -> AsyncStream<OrchestratorEvent>
  var isReady: @Sendable () -> Bool
}

/// Normalized sidecar event for downstream TCA consumption.
enum OrchestratorEvent: Equatable, Sendable {
  case assistantDelta(conversationID: UUID, text: String)
  case toolUse(conversationID: UUID, tool: String, id: String, inputJSON: String)
  case toolResult(conversationID: UUID, toolUseID: String, resultJSON: String)
  case turnComplete(conversationID: UUID, sessionID: String?)
  case error(conversationID: UUID?, message: String)
}

extension OrchestratorClient: DependencyKey {
  static let liveValue = OrchestratorClient(
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
    events: { OrchestratorRuntime.shared.events() },
    isReady: { OrchestratorRuntime.shared.isReady }
  )

  static let testValue = OrchestratorClient(
    startSession: { _, _ in nil },
    sendUserMessage: { _, _ in },
    killSession: { _ in },
    events: { AsyncStream { $0.finish() } },
    isReady: { false }
  )
}

extension DependencyValues {
  var orchestratorClient: OrchestratorClient {
    get { self[OrchestratorClient.self] }
    set { self[OrchestratorClient.self] = newValue }
  }
}
