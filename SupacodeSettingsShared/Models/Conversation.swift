import Foundation

/// A conversation between the user and an orchestrator agent. Conversations
/// group workspaces (worktrees) under a single coordinated task. The
/// `workspaceIDs` are references, not ownership — workspaces continue to
/// live in `RepositoriesFeature`.
public struct Conversation: Identifiable, Codable, Equatable, Sendable {
  public let id: UUID
  public var title: String
  public var createdAt: Date
  public var workspaceIDs: [String]
  public var orchestratorMessages: [OrchestratorMessage]
  /// The `claude-agent-sdk` session id, captured after the first turn. Used
  /// to resume the session across app restarts. `nil` until first turn.
  public var orchestratorSessionID: String?

  public init(
    id: UUID = UUID(),
    title: String,
    createdAt: Date = Date(),
    workspaceIDs: [String] = [],
    orchestratorMessages: [OrchestratorMessage] = [],
    orchestratorSessionID: String? = nil
  ) {
    self.id = id
    self.title = title
    self.createdAt = createdAt
    self.workspaceIDs = workspaceIDs
    self.orchestratorMessages = orchestratorMessages
    self.orchestratorSessionID = orchestratorSessionID
  }
}

public struct OrchestratorMessage: Identifiable, Codable, Equatable, Sendable {
  public let id: UUID
  public let role: Role
  /// Raw text. Tool messages (`toolUse`, `toolResult`) carry JSON-encoded payloads.
  public let content: String
  public let timestamp: Date

  public enum Role: String, Codable, Sendable {
    case user
    case assistant
    case toolUse = "tool_use"
    case toolResult = "tool_result"
    case system
  }

  public init(id: UUID = UUID(), role: Role, content: String, timestamp: Date = Date()) {
    self.id = id
    self.role = role
    self.content = content
    self.timestamp = timestamp
  }
}
