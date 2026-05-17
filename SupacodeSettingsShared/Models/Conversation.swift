import Foundation

/// A conversation between the user and an orchestrator agent. Conversations
/// group workspaces (worktrees) under a single coordinated task. The
/// `workspaceIDs` are references, not ownership — workspaces continue to
/// live in `RepositoriesFeature`.
public nonisolated struct Conversation: Identifiable, Codable, Equatable, Sendable {
  public let id: UUID
  public var title: String
  public var createdAt: Date
  public var workspaceIDs: [String]
  public var orchestratorMessages: [OrchestratorMessage]
  /// The `claude-agent-sdk` session id, captured after the first turn. Used
  /// to resume the session across app restarts. `nil` until first turn.
  public var orchestratorSessionID: String?
  public var isPinned: Bool

  public init(
    id: UUID = UUID(),
    title: String,
    createdAt: Date = Date(),
    workspaceIDs: [String] = [],
    orchestratorMessages: [OrchestratorMessage] = [],
    orchestratorSessionID: String? = nil,
    isPinned: Bool = false
  ) {
    self.id = id
    self.title = title
    self.createdAt = createdAt
    self.workspaceIDs = workspaceIDs
    self.orchestratorMessages = orchestratorMessages
    self.orchestratorSessionID = orchestratorSessionID
    self.isPinned = isPinned
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try c.decode(UUID.self, forKey: .id)
    self.title = try c.decode(String.self, forKey: .title)
    self.createdAt = try c.decode(Date.self, forKey: .createdAt)
    self.workspaceIDs = try c.decode([String].self, forKey: .workspaceIDs)
    self.orchestratorMessages = try c.decode([OrchestratorMessage].self, forKey: .orchestratorMessages)
    self.orchestratorSessionID = try c.decodeIfPresent(String.self, forKey: .orchestratorSessionID)
    self.isPinned = try c.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
  }

  private enum CodingKeys: String, CodingKey {
    case id, title, createdAt, workspaceIDs, orchestratorMessages, orchestratorSessionID, isPinned
  }
}

public nonisolated struct OrchestratorMessage: Identifiable, Codable, Equatable, Sendable {
  public let id: UUID
  public let role: Role
  /// Raw text. Tool messages (`toolUse`, `toolResult`) carry JSON-encoded payloads.
  public let content: String
  public let timestamp: Date
  /// When non-nil, originated from a child workspace agent in this worktree.
  public let workspaceID: String?

  public enum Role: String, Codable, Sendable {
    case user
    case assistant
    case toolUse = "tool_use"
    case toolResult = "tool_result"
    case system
  }

  public init(
    id: UUID = UUID(),
    role: Role,
    content: String,
    timestamp: Date = Date(),
    workspaceID: String? = nil
  ) {
    self.id = id
    self.role = role
    self.content = content
    self.timestamp = timestamp
    self.workspaceID = workspaceID
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: MsgCodingKeys.self)
    self.id = try c.decode(UUID.self, forKey: .id)
    self.role = try c.decode(Role.self, forKey: .role)
    self.content = try c.decode(String.self, forKey: .content)
    self.timestamp = try c.decode(Date.self, forKey: .timestamp)
    self.workspaceID = try c.decodeIfPresent(String.self, forKey: .workspaceID)
  }

  private enum MsgCodingKeys: String, CodingKey {
    case id, role, content, timestamp, workspaceID
  }
}
