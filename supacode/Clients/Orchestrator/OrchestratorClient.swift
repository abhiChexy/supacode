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
  var inspectSession: @Sendable (_ conversationID: UUID) async throws -> SessionInspection
  var spawnWorkspace: @Sendable (_ conversationID: UUID, _ workspaceID: String, _ cwd: String, _ initialTask: String) async throws -> Void
  var messageWorkspace: @Sendable (_ conversationID: UUID, _ workspaceID: String, _ content: String) async throws -> String
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
    inspectSession: { conversationID in
      let raw = try await OrchestratorRuntime.shared.inspectSession(conversationID: conversationID) ?? [:]
      return SessionInspection(raw: raw)
    },
    spawnWorkspace: { conversationID, workspaceID, cwd, initialTask in
      try await OrchestratorRuntime.shared.spawnWorkspace(
        conversationID: conversationID,
        workspaceID: workspaceID,
        cwd: cwd,
        initialTask: initialTask
      )
    },
    messageWorkspace: { conversationID, workspaceID, content in
      try await OrchestratorRuntime.shared.messageWorkspace(
        conversationID: conversationID,
        workspaceID: workspaceID,
        content: content
      ) ?? ""
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
    inspectSession: { _ in .init(raw: [:]) },
    spawnWorkspace: { _, _, _, _ in },
    messageWorkspace: { _, _, _ in "" },
    events: { AsyncStream { $0.finish() } },
    isReady: { false }
  )
}

nonisolated struct SessionInspection: Sendable {
  let mcpServers: [MCPServerStatus]
  let contextUsage: [String: String]
  let agents: [String]

  init(raw: [String: Any]) {
    let rawMCP = raw["mcp_servers"] as? [[String: Any]] ?? []
    self.mcpServers = rawMCP.map {
      MCPServerStatus(
        name: $0["name"] as? String ?? "?",
        status: $0["status"] as? String ?? "unknown"
      )
    }
    let rawCtx = raw["context_usage"] as? [String: Any] ?? [:]
    var ctx: [String: String] = [:]
    for (k, v) in rawCtx {
      ctx[k] = String(describing: v)
    }
    self.contextUsage = ctx
    self.agents = raw["agents"] as? [String] ?? []
  }
}

nonisolated struct MCPServerStatus: Identifiable, Sendable {
  var id: String { name }
  let name: String
  let status: String
}

nonisolated enum OrchestratorEvent: Equatable, Sendable {
  case assistantDelta(conversationID: UUID, workspaceID: String?, text: String)
  case toolUse(conversationID: UUID, workspaceID: String?, tool: String, id: String, inputJSON: String)
  case toolResult(conversationID: UUID, workspaceID: String?, toolUseID: String, resultJSON: String)
  case turnComplete(conversationID: UUID, workspaceID: String?, sessionID: String?)
  case sessionInfo(conversationID: UUID, model: String?, permissionMode: String?, cwd: String?)
  case usage(conversationID: UUID, inputTokens: Int, outputTokens: Int, cacheReadTokens: Int, cacheCreationTokens: Int, costUSD: Double?)
  case rateLimit(window: String?, status: String?, utilization: Double?, resetsAt: Date?, overageStatus: String?, overageResetsAt: Date?)
  case error(conversationID: UUID?, workspaceID: String?, message: String)
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
