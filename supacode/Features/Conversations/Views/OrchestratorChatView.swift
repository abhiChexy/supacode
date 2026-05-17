import ComposableArchitecture
import SupacodeSettingsShared
import SwiftUI

/// Center-pane chat with the orchestrator agent. Renders the conversation's
/// message stream and an input bar that dispatches `.sendUserMessage`.
struct OrchestratorChatView: View {
  @Bindable var store: StoreOf<ConversationFeature>
  let conversation: Conversation
  @State private var draft: String = ""

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      messages
      Divider()
      composer
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(.background)
  }

  private var header: some View {
    HStack(spacing: 8) {
      Text(conversation.title.isEmpty ? "Untitled" : conversation.title)
        .font(.headline)
      Spacer()
      if let sessionID = conversation.orchestratorSessionID {
        Text("session: \(sessionID.prefix(8))…")
          .font(.system(size: 10, design: .monospaced))
          .foregroundStyle(.tertiary)
      } else {
        Text("no session")
          .font(.system(size: 10, design: .monospaced))
          .foregroundStyle(.tertiary)
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
  }

  private var messages: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 16) {
          if conversation.orchestratorMessages.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
              Text("Tell the orchestrator what you want to coordinate.")
                .foregroundStyle(.secondary)
              Text("It will propose a workspace plan before fanning out.")
                .font(.callout)
                .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 24)
          }
          ForEach(conversation.orchestratorMessages) { message in
            messageRow(message)
              .id(message.id)
          }
        }
        .padding(16)
      }
      .onChange(of: conversation.orchestratorMessages.last?.id) { _, newID in
        guard let newID else { return }
        withAnimation(.easeOut(duration: 0.12)) {
          proxy.scrollTo(newID, anchor: .bottom)
        }
      }
    }
  }

  @ViewBuilder
  private func messageRow(_ message: OrchestratorMessage) -> some View {
    switch message.role {
    case .user:
      HStack(alignment: .top) {
        Spacer(minLength: 60)
        Text(message.content)
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
          .background(Color.accentColor.opacity(0.15))
          .clipShape(RoundedRectangle(cornerRadius: 10))
      }
    case .assistant:
      Text(message.content.isEmpty ? "…" : message.content)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    case .toolUse:
      ToolCallRow(label: toolLabel(for: message), payload: message.content)
    case .toolResult:
      ToolCallRow(label: "→ result", payload: message.content)
    case .system:
      Text(message.content)
        .font(.caption)
        .foregroundStyle(.red)
    }
  }

  private func toolLabel(for message: OrchestratorMessage) -> String {
    guard let data = message.content.data(using: .utf8),
      let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
      let tool = dict["tool"] as? String
    else { return "→ tool" }
    return "→ \(tool)"
  }

  private var composer: some View {
    HStack(alignment: .bottom, spacing: 8) {
      TextField("Message orchestrator…", text: $draft, axis: .vertical)
        .lineLimit(1...6)
        .textFieldStyle(.plain)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .onSubmit(send)
      Button(action: send) {
        Image(systemName: "arrow.up.circle.fill")
          .font(.system(size: 22))
      }
      .buttonStyle(.plain)
      .keyboardShortcut(.return, modifiers: .command)
      .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    .padding(12)
  }

  private func send() {
    let content = draft
    draft = ""
    store.send(.sendUserMessage(conversationID: conversation.id, content: content))
  }
}

private struct ToolCallRow: View {
  let label: String
  let payload: String
  @State private var expanded = false

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Button {
        expanded.toggle()
      } label: {
        HStack(spacing: 4) {
          Image(systemName: expanded ? "chevron.down" : "chevron.right")
            .font(.system(size: 9))
          Text(label)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary)
        }
      }
      .buttonStyle(.plain)
      if expanded {
        Text(payload)
          .font(.system(size: 11, design: .monospaced))
          .textSelection(.enabled)
          .padding(8)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(.thinMaterial)
          .clipShape(RoundedRectangle(cornerRadius: 6))
      }
    }
  }
}
