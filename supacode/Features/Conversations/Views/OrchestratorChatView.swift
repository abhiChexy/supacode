import ComposableArchitecture
import SupacodeSettingsShared
import SwiftUI

/// Center-pane chat with the orchestrator agent.
struct OrchestratorChatView: View {
  @Bindable var store: StoreOf<ConversationFeature>
  let conversation: Conversation
  @State private var draft: String = ""
  @State private var isUserScrolledAway = false

  private var isInFlight: Bool {
    store.inFlightConversationIDs.contains(conversation.id)
  }
  private var runtime: ConversationFeature.ConversationRuntime {
    store.runtimeByConversationID[conversation.id] ?? .init()
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider().background(Theme.Color.borderSubtle)
      ZStack(alignment: .bottom) {
        messages
        if isUserScrolledAway {
          scrollToBottomPill
            .padding(.bottom, Theme.Spacing.s)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
      }
      composer
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Theme.Color.backgroundSecondary)
    .foregroundStyle(Theme.Color.textPrimary)
  }

  // MARK: Header

  private var header: some View {
    HStack(spacing: Theme.Spacing.s) {
      ActivityDot(isActive: isInFlight)
      Text(conversation.title.isEmpty ? "Untitled" : conversation.title)
        .font(.system(size: 13, weight: .semibold))
      Spacer()
      if let sessionID = conversation.orchestratorSessionID {
        Text("session \(sessionID.prefix(8))…")
          .font(Theme.Font.monoTiny)
          .foregroundStyle(Theme.Color.textTertiary)
      } else {
        Text("no session")
          .font(Theme.Font.monoTiny)
          .foregroundStyle(Theme.Color.textTertiary)
      }
    }
    .padding(.horizontal, Theme.Spacing.l)
    .padding(.vertical, Theme.Spacing.m)
  }

  // MARK: Messages

  private var messages: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: Theme.Spacing.l) {
          if conversation.orchestratorMessages.isEmpty {
            emptyState
          }
          ForEach(messageRows) { row in
            messageRow(row)
              .id(row.id)
              .transition(.opacity)
          }
          if isInFlight {
            ThinkingRow()
          }
          Color.clear
            .frame(height: 1)
            .id("bottom-anchor")
            .onAppear { isUserScrolledAway = false }
            .onDisappear { isUserScrolledAway = true }
        }
        .padding(Theme.Spacing.l)
      }
      .onChange(of: conversation.orchestratorMessages.count) { _, _ in
        autoScroll(proxy)
      }
      .onChange(of: lastMessageContentLength) { _, _ in
        autoScroll(proxy)
      }
      .onChange(of: isInFlight) { _, newValue in
        if newValue { isUserScrolledAway = false }
        autoScroll(proxy)
      }
      .onChange(of: store.selectedConversationID) { _, _ in
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
          proxy.scrollTo("bottom-anchor", anchor: .bottom)
        }
      }
    }
  }

  /// Used as a change-detection anchor so streaming deltas trigger autoscroll.
  private var lastMessageContentLength: Int {
    conversation.orchestratorMessages.last?.content.count ?? 0
  }

  private func autoScroll(_ proxy: ScrollViewProxy) {
    guard !isUserScrolledAway else { return }
    withAnimation(Theme.Motion.messageFade) {
      proxy.scrollTo("bottom-anchor", anchor: .bottom)
    }
  }

  private var scrollToBottomPill: some View {
    Button {
      isUserScrolledAway = false
    } label: {
      HStack(spacing: 4) {
        Image(systemName: "chevron.down")
          .font(.system(size: 10, weight: .bold))
        Text("Jump to latest")
          .font(Theme.Font.metadata)
      }
      .padding(.horizontal, Theme.Spacing.m)
      .padding(.vertical, 6)
      .background(Theme.Color.backgroundElevated)
      .foregroundStyle(Theme.Color.textPrimary)
      .clipShape(Capsule())
      .overlay(Capsule().stroke(Theme.Color.borderSubtle, lineWidth: 1))
    }
    .buttonStyle(.plain)
  }

  private var emptyState: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.s) {
      Text("Tell the orchestrator what you want to coordinate.")
        .font(Theme.Font.body)
        .foregroundStyle(Theme.Color.textSecondary)
      Text("It will propose a workspace plan before fanning out.")
        .font(Theme.Font.metadata)
        .foregroundStyle(Theme.Color.textTertiary)
    }
    .padding(.vertical, Theme.Spacing.xl)
  }

  /// Group tool_use + matching tool_result into a single visual row.
  private var messageRows: [MessageRow] {
    let messages = conversation.orchestratorMessages
    var rows: [MessageRow] = []
    var resultsByID: [String: OrchestratorMessage] = [:]
    for m in messages where m.role == .toolResult {
      if let id = JSON.string(m.content, key: "tool_use_id") {
        resultsByID[id] = m
      }
    }
    for m in messages {
      switch m.role {
      case .toolResult:
        continue
      case .toolUse:
        let toolID = JSON.string(m.content, key: "id") ?? ""
        let result = resultsByID[toolID]
        rows.append(MessageRow(id: m.id, kind: .toolCall(use: m, result: result)))
      default:
        rows.append(MessageRow(id: m.id, kind: .text(m)))
      }
    }
    return rows
  }

  @ViewBuilder
  private func messageRow(_ row: MessageRow) -> some View {
    switch row.kind {
    case .text(let message):
      switch message.role {
      case .user:
        UserBubble(text: message.content)
      case .assistant:
        AssistantBubble(text: message.content)
      case .system:
        SystemNote(text: message.content)
      case .toolUse, .toolResult:
        EmptyView()
      }
    case .toolCall(let use, let result):
      ToolCallCard(
        use: use,
        result: result,
        isTurnInFlight: isInFlight,
        onAnswerQuestion: { answer in
          store.send(.sendUserMessage(conversationID: conversation.id, content: answer))
        }
      )
    }
  }

  // MARK: Composer

  private var composer: some View {
    VStack(alignment: .leading, spacing: 0) {
      ComposerTextEditor(text: $draft, onCommit: send)
        .frame(minHeight: 40, maxHeight: 200)
        .padding(.horizontal, Theme.Spacing.m)
        .padding(.top, Theme.Spacing.m)
        .padding(.bottom, Theme.Spacing.s)
      composerToolbar
    }
    .background(Theme.Color.backgroundElevated)
    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.input))
    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.input).stroke(Theme.Color.borderSubtle, lineWidth: 1))
    .padding(Theme.Spacing.m)
  }

  private var composerToolbar: some View {
    HStack(spacing: Theme.Spacing.s) {
      Pill(icon: "sparkle", label: runtime.model ?? "claude")
      if runtime.totalInputTokens > 0 || runtime.totalOutputTokens > 0 {
        Pill(icon: "circle.lefthalf.filled",
             label: usageLabel)
      }
      if let cwd = runtime.cwd {
        Pill(icon: "folder", label: cwdShortLabel(cwd))
      }
      Spacer()
      if isInFlight {
        Button {
          store.send(.interruptCurrent(conversationID: conversation.id))
        } label: {
          Image(systemName: "stop.fill")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 26, height: 26)
            .background(Theme.Color.statusError)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(".", modifiers: .command)
        .help("Stop (⌘.)")
      } else {
        Button(action: send) {
          Image(systemName: "arrow.up")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(canSend ? .white : Theme.Color.textTertiary)
            .frame(width: 26, height: 26)
            .background(canSend ? Theme.Color.accent : Theme.Color.backgroundPrimary)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(!canSend)
        .help("Send (Return)")
      }
    }
    .padding(.horizontal, Theme.Spacing.s)
    .padding(.vertical, Theme.Spacing.xs)
    .padding(.bottom, Theme.Spacing.xs)
  }

  private var usageLabel: String {
    let total = runtime.totalInputTokens + runtime.totalOutputTokens
    let formatted: String
    if total >= 1_000_000 { formatted = String(format: "%.1fM", Double(total) / 1_000_000) }
    else if total >= 1_000 { formatted = String(format: "%.1fk", Double(total) / 1_000) }
    else { formatted = "\(total)" }
    if runtime.totalCostUSD > 0 {
      return "\(formatted) · $\(String(format: "%.2f", runtime.totalCostUSD))"
    }
    return formatted
  }

  private func cwdShortLabel(_ path: String) -> String {
    let home = NSHomeDirectory()
    if path == home { return "~" }
    if path.hasPrefix(home + "/") { return "~/" + String(path.dropFirst(home.count + 1)) }
    return path
  }

  private var canSend: Bool {
    !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isInFlight
  }

  private func send() {
    guard canSend else { return }
    let content = draft
    draft = ""
    store.send(.sendUserMessage(conversationID: conversation.id, content: content))
  }
}

private struct Pill: View {
  let icon: String
  let label: String

  var body: some View {
    HStack(spacing: 4) {
      Image(systemName: icon)
        .font(.system(size: 9))
        .foregroundStyle(Theme.Color.textTertiary)
      Text(label)
        .font(Theme.Font.metadata)
        .foregroundStyle(Theme.Color.textSecondary)
        .lineLimit(1)
        .truncationMode(.middle)
    }
    .padding(.horizontal, Theme.Spacing.s)
    .padding(.vertical, 4)
    .background(Theme.Color.backgroundPrimary.opacity(0.6))
    .clipShape(Capsule())
  }
}

// MARK: - Row model

private struct MessageRow: Identifiable {
  let id: UUID
  let kind: Kind

  enum Kind {
    case text(OrchestratorMessage)
    case toolCall(use: OrchestratorMessage, result: OrchestratorMessage?)
  }
}

// MARK: - Subviews

private struct ActivityDot: View {
  let isActive: Bool
  @State private var pulse = false

  var body: some View {
    Circle()
      .fill(isActive ? Theme.Color.statusSuccess : Theme.Color.textTertiary)
      .frame(width: 8, height: 8)
      .opacity(isActive && pulse ? 0.4 : 1.0)
      .onAppear { pulse = isActive }
      .onChange(of: isActive) { _, new in
        withAnimation(new ? Theme.Motion.pulse : .default) { pulse = new }
      }
      .animation(isActive ? Theme.Motion.pulse : .default, value: pulse)
  }
}

private struct UserBubble: View {
  let text: String
  var body: some View {
    HStack(alignment: .top) {
      Spacer(minLength: 60)
      Text(text)
        .font(Theme.Font.body)
        .padding(.horizontal, Theme.Spacing.m)
        .padding(.vertical, Theme.Spacing.s)
        .background(Theme.Color.accent.opacity(0.18))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.input))
        .textSelection(.enabled)
    }
  }
}

private struct AssistantBubble: View {
  let text: String
  var body: some View {
    let attributed = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    return Text(attributed)
      .font(Theme.Font.body)
      .foregroundStyle(Theme.Color.textPrimary)
      .frame(maxWidth: .infinity, alignment: .leading)
      .textSelection(.enabled)
  }
}

private struct SystemNote: View {
  let text: String
  var body: some View {
    Text(text)
      .font(Theme.Font.metadata)
      .foregroundStyle(Theme.Color.statusError)
      .padding(Theme.Spacing.s)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Theme.Color.statusError.opacity(0.12))
      .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.pill))
  }
}

private struct ThinkingRow: View {
  @State private var dots = 0

  var body: some View {
    HStack(spacing: Theme.Spacing.s) {
      Circle()
        .fill(Theme.Color.accent)
        .frame(width: 6, height: 6)
        .opacity(0.6)
        .scaleEffect(scale(for: 0))
      Circle()
        .fill(Theme.Color.accent)
        .frame(width: 6, height: 6)
        .opacity(0.6)
        .scaleEffect(scale(for: 1))
      Circle()
        .fill(Theme.Color.accent)
        .frame(width: 6, height: 6)
        .opacity(0.6)
        .scaleEffect(scale(for: 2))
      Text("Thinking…")
        .font(Theme.Font.metadata)
        .foregroundStyle(Theme.Color.textSecondary)
    }
    .onAppear {
      Task {
        while !Task.isCancelled {
          try? await Task.sleep(for: .milliseconds(400))
          await MainActor.run { dots = (dots + 1) % 3 }
        }
      }
    }
  }

  private func scale(for index: Int) -> CGFloat {
    dots == index ? 1.4 : 1.0
  }
}

private struct ToolCallCard: View {
  let use: OrchestratorMessage
  let result: OrchestratorMessage?
  let isTurnInFlight: Bool
  let onAnswerQuestion: (String) -> Void
  @State private var expanded = false

  private var toolName: String { JSON.string(use.content, key: "tool") ?? "tool" }
  private var inputJSON: String { JSON.prettyValue(use.content, key: "input") ?? "{}" }

  /// Single-line summary of the most salient input field for this tool.
  private var inputSummary: String {
    guard let data = use.content.data(using: .utf8),
      let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
      let input = dict["input"] as? [String: Any]
    else { return "" }
    let candidate: String? = {
      switch toolName {
      case "Bash": return input["command"] as? String
      case "Read", "Edit", "Write": return input["file_path"] as? String
      case "Grep", "Glob": return input["pattern"] as? String
      case "WebFetch", "WebSearch": return (input["url"] as? String) ?? (input["query"] as? String)
      default: return input["title"] as? String ?? input["description"] as? String
      }
    }()
    return (candidate ?? "").split(separator: "\n").first.map(String.init) ?? ""
  }
  private var resultPretty: String? {
    guard let result else { return nil }
    return JSON.prettyValue(result.content, key: "result") ?? result.content
  }

  private var icon: String {
    switch toolName {
    case "AskUserQuestion": return "questionmark.circle"
    case "Skill", "Bash": return "terminal"
    case "Read", "Glob", "Grep": return "doc.text.magnifyingglass"
    case "Edit", "Write", "NotebookEdit": return "pencil"
    case "WebFetch", "WebSearch": return "globe"
    case let n where n.hasPrefix("create_workspace"): return "folder.badge.plus"
    case let n where n.hasPrefix("send_to_workspace"): return "paperplane"
    case let n where n.hasPrefix("peek_workspace"): return "eye"
    default: return "wrench.and.screwdriver"
    }
  }

  private var statusIcon: some View {
    Group {
      if result != nil {
        Image(systemName: "checkmark")
          .font(.system(size: 9, weight: .bold))
          .foregroundStyle(Theme.Color.statusSuccess)
      } else if isTurnInFlight {
        ProgressView().scaleEffect(0.5).frame(width: 12, height: 12)
      } else {
        // Orphan tool_use from a completed turn whose tool_result was
        // never persisted (legacy conversations recorded before the
        // UserMessage / ToolResultBlock fix).
        Image(systemName: "minus")
          .font(.system(size: 9, weight: .bold))
          .foregroundStyle(Theme.Color.textTertiary)
      }
    }
  }

  private var askQuestion: AskQuestionPayload? {
    guard toolName == "AskUserQuestion" else { return nil }
    return AskQuestionPayload(rawJSON: inputJSON)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
      Button {
        withAnimation(Theme.Motion.toolExpand) { expanded.toggle() }
      } label: {
        HStack(spacing: Theme.Spacing.s) {
          Image(systemName: expanded ? "chevron.down" : "chevron.right")
            .font(.system(size: 9))
            .foregroundStyle(Theme.Color.textTertiary)
            .frame(width: 10)
          Image(systemName: icon)
            .font(.system(size: 11))
            .foregroundStyle(Theme.Color.textSecondary)
          Text(toolName)
            .font(Theme.Font.monoSmall)
            .foregroundStyle(Theme.Color.textSecondary)
          if !inputSummary.isEmpty {
            Text(inputSummary)
              .font(Theme.Font.monoSmall)
              .foregroundStyle(Theme.Color.textTertiary)
              .lineLimit(1)
              .truncationMode(.middle)
          }
          Spacer()
          statusIcon
        }
        .padding(.horizontal, Theme.Spacing.m)
        .padding(.vertical, Theme.Spacing.s)
        .background(Theme.Color.backgroundElevated)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
      }
      .buttonStyle(.plain)

      if let askQuestion {
        AskUserQuestionInline(payload: askQuestion, onPick: onAnswerQuestion)
      }

      if expanded {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
          Text("input")
            .font(Theme.Font.monoTiny)
            .foregroundStyle(Theme.Color.textTertiary)
          Text(inputJSON)
            .font(Theme.Font.monoSmall)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Spacing.s)
            .background(Theme.Color.backgroundElevated.opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.pill))
          if let resultPretty {
            Text("result")
              .font(Theme.Font.monoTiny)
              .foregroundStyle(Theme.Color.textTertiary)
            Text(resultPretty)
              .font(Theme.Font.monoSmall)
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(Theme.Spacing.s)
              .background(Theme.Color.backgroundElevated.opacity(0.6))
              .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.pill))
          }
        }
        .padding(.leading, Theme.Spacing.xl)
      }
    }
  }
}

private struct AskUserQuestionInline: View {
  let payload: AskQuestionPayload
  let onPick: (String) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.s) {
      ForEach(payload.questions, id: \.question) { q in
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
          Text(q.question)
            .font(Theme.Font.body.weight(.semibold))
          ForEach(q.options, id: \.label) { opt in
            Button {
              onPick("\(q.header): \(opt.label)")
            } label: {
              HStack(alignment: .top, spacing: Theme.Spacing.s) {
                Image(systemName: "circle")
                  .font(.system(size: 10))
                  .foregroundStyle(Theme.Color.textTertiary)
                VStack(alignment: .leading, spacing: 2) {
                  Text(opt.label)
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Color.textPrimary)
                  if !opt.description.isEmpty {
                    Text(opt.description)
                      .font(Theme.Font.metadata)
                      .foregroundStyle(Theme.Color.textSecondary)
                  }
                }
                Spacer()
              }
              .padding(.horizontal, Theme.Spacing.m)
              .padding(.vertical, Theme.Spacing.s)
              .frame(maxWidth: .infinity, alignment: .leading)
              .background(Theme.Color.backgroundElevated)
              .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
            }
            .buttonStyle(.plain)
          }
        }
      }
    }
    .padding(.leading, Theme.Spacing.xl)
    .padding(.top, Theme.Spacing.xs)
  }
}

private struct AskQuestionPayload {
  struct Question {
    let question: String
    let header: String
    let options: [Option]
  }
  struct Option {
    let label: String
    let description: String
  }
  let questions: [Question]

  init?(rawJSON: String) {
    guard let data = rawJSON.data(using: .utf8),
      let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
      let qs = dict["questions"] as? [[String: Any]]
    else { return nil }
    var parsed: [Question] = []
    for q in qs {
      let question = q["question"] as? String ?? ""
      let header = q["header"] as? String ?? "Choice"
      let rawOptions = q["options"] as? [[String: Any]] ?? []
      let opts = rawOptions.map { o in
        Option(label: o["label"] as? String ?? "", description: o["description"] as? String ?? "")
      }
      parsed.append(Question(question: question, header: header, options: opts))
    }
    guard !parsed.isEmpty else { return nil }
    self.questions = parsed
  }
}

// MARK: - JSON helpers

private enum JSON {
  static func string(_ raw: String, key: String) -> String? {
    guard let data = raw.data(using: .utf8),
      let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else { return nil }
    return dict[key] as? String
  }

  /// Returns a pretty-printed JSON string of the value stored at `key`, or
  /// the raw string if it isn't decodable.
  static func prettyValue(_ raw: String, key: String) -> String? {
    guard let data = raw.data(using: .utf8),
      let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else { return nil }
    guard let inner = dict[key] else { return nil }
    if let s = inner as? String { return s }
    guard let pretty = try? JSONSerialization.data(withJSONObject: inner, options: [.prettyPrinted, .sortedKeys]),
      let str = String(data: pretty, encoding: .utf8)
    else { return String(describing: inner) }
    return str
  }
}
