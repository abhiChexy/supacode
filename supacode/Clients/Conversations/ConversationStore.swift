import ComposableArchitecture
import Dependencies
import Foundation
import IdentifiedCollections
import SupacodeSettingsShared

/// Filesystem-backed store for `Conversation` JSON files under
/// `~/.supacode/conversations/<uuid>.json`. Mirrors the load/save shape of
/// `SettingsFileStorage` but operates on a directory rather than a single file
/// because conversations are independently loaded.
struct ConversationStore: Sendable {
  var loadAll: @Sendable () throws -> IdentifiedArrayOf<Conversation>
  var save: @Sendable (Conversation) throws -> Void
  var delete: @Sendable (UUID) throws -> Void
}

extension ConversationStore: DependencyKey {
  static let liveValue = ConversationStore(
    loadAll: {
      let dir = SupacodePaths.conversationsDirectory
      let fm = FileManager.default
      var conversations: [Conversation] = []
      guard fm.fileExists(atPath: dir.path(percentEncoded: false)) else {
        return []
      }
      let urls = try fm.contentsOfDirectory(
        at: dir,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
      )
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      for url in urls where url.pathExtension == "json" {
        do {
          let data = try Data(contentsOf: url)
          let conversation = try decoder.decode(Conversation.self, from: data)
          conversations.append(conversation)
        } catch {
          // Skip malformed conversation files rather than failing the whole load.
          continue
        }
      }
      conversations.sort { $0.createdAt < $1.createdAt }
      return IdentifiedArray(uniqueElements: conversations)
    },
    save: { conversation in
      let url = SupacodePaths.conversationURL(for: conversation.id)
      let dir = url.deletingLastPathComponent()
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      let data = try encoder.encode(conversation)
      try data.write(to: url, options: [.atomic])
    },
    delete: { id in
      let url = SupacodePaths.conversationURL(for: id)
      try? FileManager.default.removeItem(at: url)
    }
  )

  static let testValue: ConversationStore = {
    let storage = LockIsolated<IdentifiedArrayOf<Conversation>>([])
    return ConversationStore(
      loadAll: { storage.value },
      save: { conversation in
        storage.withValue { $0[id: conversation.id] = conversation }
      },
      delete: { id in
        storage.withValue { _ = $0.remove(id: id) }
      }
    )
  }()
}

extension DependencyValues {
  var conversationStore: ConversationStore {
    get { self[ConversationStore.self] }
    set { self[ConversationStore.self] = newValue }
  }
}
