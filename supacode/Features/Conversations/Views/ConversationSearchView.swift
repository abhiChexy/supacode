import ComposableArchitecture
import SupacodeSettingsShared
import SwiftUI

/// Cmd-F sheet to search across all conversations by title or message text.
struct ConversationSearchView: View {
  @Bindable var store: StoreOf<ConversationFeature>
  @Environment(\.dismiss) private var dismiss
  @State private var query: String = ""
  @FocusState private var fieldFocus: Bool

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: Theme.Spacing.s) {
        Image(systemName: "magnifyingglass")
          .font(.system(size: 12))
          .foregroundStyle(Theme.Color.textTertiary)
        TextField("Search conversations…", text: $query)
          .textFieldStyle(.plain)
          .font(Theme.Font.body)
          .focused($fieldFocus)
          .onSubmit { activateFirst() }
        Button("Done") { dismiss() }
          .buttonStyle(.borderless)
          .foregroundStyle(Theme.Color.textSecondary)
          .keyboardShortcut(.escape, modifiers: [])
      }
      .padding(Theme.Spacing.m)
      .background(Theme.Color.backgroundElevated)

      Divider().background(Theme.Color.borderSubtle)

      if results.isEmpty {
        VStack(spacing: Theme.Spacing.s) {
          Text(query.isEmpty ? "Start typing to search" : "No matches")
            .font(Theme.Font.body)
            .foregroundStyle(Theme.Color.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Theme.Spacing.xl)
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(results) { hit in
              SearchHitRow(hit: hit) {
                store.send(.selectConversation(hit.conversation.id))
                dismiss()
              }
              Divider().background(Theme.Color.borderSubtle).opacity(0.5)
            }
          }
        }
      }
    }
    .frame(minWidth: 540, minHeight: 360)
    .background(Theme.Color.backgroundSecondary)
    .foregroundStyle(Theme.Color.textPrimary)
    .onAppear { fieldFocus = true }
  }

  private var results: [SearchHit] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let convos = store.conversations
      .sorted { $0.createdAt > $1.createdAt }
    if trimmed.isEmpty {
      return convos.map { SearchHit(conversation: $0, snippet: snippet(for: $0, query: nil)) }
    }
    return convos.compactMap { c in
      if c.title.lowercased().contains(trimmed) {
        return SearchHit(conversation: c, snippet: snippet(for: c, query: trimmed))
      }
      if let hit = c.orchestratorMessages.first(where: { $0.content.lowercased().contains(trimmed) }) {
        return SearchHit(conversation: c, snippet: snippet(text: hit.content, query: trimmed))
      }
      return nil
    }
  }

  private func snippet(for conversation: Conversation, query: String?) -> String {
    if let q = query, let hit = conversation.orchestratorMessages.first(where: { $0.content.lowercased().contains(q) }) {
      return snippet(text: hit.content, query: q)
    }
    if let last = conversation.orchestratorMessages.last(where: { $0.role == .user || $0.role == .assistant }) {
      return snippet(text: last.content, query: nil)
    }
    return ""
  }

  private func snippet(text: String, query: String?) -> String {
    let oneLine = text.replacing(/\s+/, with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    let maxLen = 140
    guard let q = query, !q.isEmpty else {
      return oneLine.count <= maxLen ? oneLine : String(oneLine.prefix(maxLen)) + "…"
    }
    let lower = oneLine.lowercased()
    guard let r = lower.range(of: q) else {
      return oneLine.count <= maxLen ? oneLine : String(oneLine.prefix(maxLen)) + "…"
    }
    let startOffset = max(0, oneLine.distance(from: oneLine.startIndex, to: r.lowerBound) - 30)
    let start = oneLine.index(oneLine.startIndex, offsetBy: startOffset)
    let end = oneLine.index(start, offsetBy: min(maxLen, oneLine.distance(from: start, to: oneLine.endIndex)))
    var slice = String(oneLine[start..<end])
    if startOffset > 0 { slice = "…" + slice }
    if end != oneLine.endIndex { slice += "…" }
    return slice
  }

  private func activateFirst() {
    if let first = results.first {
      store.send(.selectConversation(first.conversation.id))
      dismiss()
    }
  }
}

private struct SearchHit: Identifiable {
  let conversation: Conversation
  let snippet: String
  var id: UUID { conversation.id }
}

private struct SearchHitRow: View {
  let hit: SearchHit
  let onPick: () -> Void

  var body: some View {
    Button(action: onPick) {
      VStack(alignment: .leading, spacing: 2) {
        Text(hit.conversation.title.isEmpty ? "Untitled" : hit.conversation.title)
          .font(Theme.Font.body.weight(.medium))
          .foregroundStyle(Theme.Color.textPrimary)
        if !hit.snippet.isEmpty {
          Text(hit.snippet)
            .font(Theme.Font.metadata)
            .foregroundStyle(Theme.Color.textSecondary)
            .lineLimit(2)
        }
      }
      .padding(.horizontal, Theme.Spacing.l)
      .padding(.vertical, Theme.Spacing.s)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}
