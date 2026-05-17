import Combine
import ComposableArchitecture
import SupacodeSettingsShared
import SwiftUI

/// Center-pane chat with the orchestrator agent.
struct OrchestratorChatView: View {
  @Bindable var store: StoreOf<ConversationFeature>
  let conversation: Conversation
  @State private var draft: String = ""
  @State private var composerHeight: CGFloat = 22
  @State private var isUserScrolledAway = false
  @State private var isInspectorPresented = false
  @State private var bottomAnchorY: CGFloat?
  @State private var containerBottomY: CGFloat?
  @State private var scrollProxy: ScrollViewProxy?

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
      if let activeTool = activeToolDescriptor {
        ActiveToolBar(tool: activeTool)
      }
      composer
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Theme.Color.backgroundSecondary)
    .foregroundStyle(Theme.Color.textPrimary)
    .sheet(isPresented: $isInspectorPresented) {
      SessionInspectorView(
        conversationID: conversation.id,
        conversationTitle: conversation.title,
        model: runtime.model,
        cwd: runtime.cwd,
        sessionID: conversation.orchestratorSessionID,
        usageInputTokens: runtime.totalInputTokens,
        usageOutputTokens: runtime.totalOutputTokens,
        usageCacheReadTokens: runtime.totalCacheReadTokens,
        usageCostUSD: runtime.totalCostUSD
      )
    }
  }

  /// The most-recently-issued tool_use that has no matching tool_result yet,
  /// when the turn is in flight. Drives the active-tool status bar.
  private var activeToolDescriptor: ActiveToolDescriptor? {
    guard isInFlight else { return nil }
    let messages = conversation.orchestratorMessages
    let resolvedIDs = Set(
      messages
        .filter { $0.role == .toolResult }
        .compactMap { JSON.string($0.content, key: "tool_use_id") }
    )
    guard let last = messages.last(where: {
      $0.role == .toolUse
        && !resolvedIDs.contains(JSON.string($0.content, key: "id") ?? "")
    }) else { return nil }
    return ActiveToolDescriptor(
      tool: JSON.string(last.content, key: "tool") ?? "tool",
      startedAt: last.timestamp
    )
  }

  // MARK: Header

  private var header: some View {
    HStack(spacing: Theme.Spacing.s) {
      ActivityDot(isActive: isInFlight)
      Text(conversation.title.isEmpty ? "Untitled" : conversation.title)
        .font(.system(size: 13, weight: .semibold))
      Spacer()
      Text(sessionStatusLabel)
        .font(Theme.Font.monoTiny)
        .foregroundStyle(Theme.Color.textTertiary)
    }
    .padding(.horizontal, Theme.Spacing.l)
    .padding(.vertical, Theme.Spacing.m)
  }

  private var sessionStatusLabel: String {
    if let sessionID = conversation.orchestratorSessionID {
      return isInFlight ? "running · \(sessionID.prefix(8))" : "session \(sessionID.prefix(8))"
    }
    return isInFlight ? "starting…" : "ready"
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
            .background(
              GeometryReader { proxy in
                Color.clear
                  .preference(key: BottomVisibilityKey.self, value: proxy.frame(in: .global).minY)
              }
            )
        }
        .padding(Theme.Spacing.l)
        .background(
          GeometryReader { outer in
            Color.clear
              .preference(key: ScrollContainerKey.self, value: outer.frame(in: .global).maxY)
          }
        )
      }
      .onPreferenceChange(BottomVisibilityKey.self) { anchorY in
        bottomAnchorY = anchorY
        recomputeScrollAway()
      }
      .onPreferenceChange(ScrollContainerKey.self) { containerY in
        containerBottomY = containerY
        recomputeScrollAway()
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
      .background(
        // Capture proxy for the Jump button.
        Color.clear
          .onAppear { scrollProxy = proxy }
      )
    }
  }

  private func recomputeScrollAway() {
    guard let bottom = bottomAnchorY, let container = containerBottomY else { return }
    // If the bottom anchor is more than 80pt below the visible container,
    // we're scrolled away. Hysteresis prevents the pill from flickering
    // during small autoscrolls.
    let away = bottom > container + 80
    if away != isUserScrolledAway {
      isUserScrolledAway = away
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
      if let scrollProxy {
        withAnimation(Theme.Motion.messageFade) {
          scrollProxy.scrollTo("bottom-anchor", anchor: .bottom)
        }
      }
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
      if let suggestions = slashSuggestions {
        SlashCommandMenu(
          query: slashQuery,
          suggestions: suggestions,
          onPick: { command in
            draft = "/" + command + " "
          }
        )
        .padding(.horizontal, Theme.Spacing.m)
        .padding(.top, Theme.Spacing.s)
      }
      ComposerTextEditor(
        text: $draft,
        measuredHeight: $composerHeight,
        maxHeight: 200,
        onCommit: send
      )
      .frame(height: composerHeight)
      .padding(.horizontal, Theme.Spacing.m)
      .padding(.top, Theme.Spacing.s)
      .padding(.bottom, Theme.Spacing.xs)
      composerToolbar
    }
    .background(Theme.Color.backgroundElevated)
    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.input))
    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.input).stroke(Theme.Color.borderSubtle, lineWidth: 1))
    .padding(Theme.Spacing.m)
  }

  private var slashQuery: String {
    guard draft.hasPrefix("/") else { return "" }
    let afterSlash = draft.dropFirst()
    if let space = afterSlash.firstIndex(of: " ") {
      return String(afterSlash[..<space])
    }
    return String(afterSlash)
  }

  private var slashSuggestions: [SlashCommandSpec]? {
    guard draft.hasPrefix("/"), !draft.contains(" ") else { return nil }
    let q = slashQuery.lowercased()
    let matches = SlashCommandSpec.all.filter { q.isEmpty || $0.name.contains(q) }
    return matches.isEmpty ? nil : Array(matches.prefix(8))
  }

  private var composerToolbar: some View {
    HStack(spacing: Theme.Spacing.s) {
      ModelPickerPill(
        currentModel: runtime.model,
        onPick: { model in
          store.send(.setModel(conversationID: conversation.id, model: model))
        }
      )
      ContextGaugePill(
        percentUsed: runtime.contextPercentUsed,
        usedTokens: runtime.lastTurnContextTokens,
        windowTokens: runtime.contextWindow
      )
      .help(contextTooltip)
      Pill(icon: "folder", label: cwdShortLabel(runtime.cwd ?? NSHomeDirectory()))
        .help("Working directory: \(runtime.cwd ?? NSHomeDirectory())")
      Spacer()
      Button {
        isInspectorPresented = true
      } label: {
        Image(systemName: "info.circle")
          .font(.system(size: 12))
          .foregroundStyle(Theme.Color.textSecondary)
          .frame(width: 24, height: 24)
      }
      .buttonStyle(.plain)
      .help("MCP servers, context usage, subagents")

      Button(action: presentAttachmentPicker) {
        Image(systemName: "paperclip")
          .font(.system(size: 12))
          .foregroundStyle(Theme.Color.textSecondary)
          .frame(width: 24, height: 24)
      }
      .buttonStyle(.plain)
      .help("Attach file path")
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

  private var contextTooltip: String {
    let pct = Int((runtime.contextPercentUsed * 100).rounded())
    return """
    Context window: \(pct)% used
    \(Self.compact(runtime.lastTurnContextTokens)) / \(Self.compact(runtime.contextWindow)) tokens

    Total input · output · cache reads:
    \(runtime.totalInputTokens) · \(runtime.totalOutputTokens) · \(runtime.totalCacheReadTokens)
    """
  }

  static func compact(_ n: Int) -> String {
    if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
    if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1_000) }
    return "\(n)"
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

  private func presentAttachmentPicker() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = true
    panel.directoryURL = URL(fileURLWithPath: runtime.cwd ?? NSHomeDirectory())
    if panel.runModal() == .OK {
      let paths = panel.urls.map { $0.path(percentEncoded: false) }
      let snippet = paths.map { "@\($0)" }.joined(separator: " ")
      if draft.isEmpty {
        draft = snippet + " "
      } else if draft.hasSuffix(" ") {
        draft += snippet + " "
      } else {
        draft += " " + snippet + " "
      }
    }
  }
}

private struct BottomVisibilityKey: PreferenceKey {
  static let defaultValue: CGFloat? = nil
  static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
    value = nextValue() ?? value
  }
}

private struct ScrollContainerKey: PreferenceKey {
  static let defaultValue: CGFloat? = nil
  static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
    value = nextValue() ?? value
  }
}

private struct SlashCommandSpec: Identifiable, Hashable {
  let name: String
  let description: String
  var id: String { name }

  // Only commands that work as plain prompts to the agent. The CLI's
  // interactive built-ins (/mcp, /agents, /clear, /resume, /compact,
  // /heapdump, /context, /usage) are parsed by the claude REPL itself and
  // don't round-trip through the SDK — they'd come back as "not available."
  // We surface those through dedicated UI affordances (model pill,
  // settings sheet) instead.
  static let all: [SlashCommandSpec] = [
    .init(name: "review", description: "Review the current PR / branch"),
    .init(name: "security-review", description: "Security review of changes"),
    .init(name: "init", description: "Initialize a CLAUDE.md in cwd"),
  ]
}

private struct SlashCommandMenu: View {
  let query: String
  let suggestions: [SlashCommandSpec]
  let onPick: (String) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(suggestions) { cmd in
        Button {
          onPick(cmd.name)
        } label: {
          HStack(spacing: Theme.Spacing.s) {
            Text("/" + cmd.name)
              .font(Theme.Font.monoSmall)
              .foregroundStyle(Theme.Color.textPrimary)
            Text(cmd.description)
              .font(Theme.Font.metadata)
              .foregroundStyle(Theme.Color.textSecondary)
              .lineLimit(1)
            Spacer()
          }
          .padding(.horizontal, Theme.Spacing.s)
          .padding(.vertical, 6)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Color.clear)
        .onHover { hovering in
          // SwiftUI Menu lacks native row hover; visual feedback via list
          _ = hovering
        }
      }
    }
    .padding(Theme.Spacing.xs)
    .background(Theme.Color.backgroundPrimary.opacity(0.6))
    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.Color.borderSubtle, lineWidth: 1))
  }
}

private struct ActiveToolDescriptor: Equatable {
  let tool: String
  let startedAt: Date
}

private struct ActiveToolBar: View {
  let tool: ActiveToolDescriptor
  @State private var now = Date()
  private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

  private var elapsed: String {
    let seconds = Int(now.timeIntervalSince(tool.startedAt))
    return seconds <= 0 ? "now" : "\(seconds)s"
  }

  var body: some View {
    HStack(spacing: Theme.Spacing.s) {
      ProgressView()
        .controlSize(.small)
        .scaleEffect(0.7)
        .frame(width: 14, height: 14)
      Text("Running ")
        .font(Theme.Font.metadata)
        .foregroundStyle(Theme.Color.textSecondary)
      + Text(tool.tool)
        .font(Theme.Font.monoSmall)
        .foregroundStyle(Theme.Color.textPrimary)
      Spacer()
      Text(elapsed)
        .font(Theme.Font.monoTiny)
        .foregroundStyle(Theme.Color.textTertiary)
    }
    .padding(.horizontal, Theme.Spacing.l)
    .padding(.vertical, Theme.Spacing.xs)
    .background(Theme.Color.backgroundPrimary.opacity(0.6))
    .overlay(Divider().background(Theme.Color.borderSubtle), alignment: .top)
    .onReceive(timer) { now = $0 }
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

/// Live context-window utilization gauge. Replaces the opaque "789 · $0.18"
/// pill — that was just a number with no sense of how close we are to the
/// limit.
private struct ContextGaugePill: View {
  let percentUsed: Double
  let usedTokens: Int
  let windowTokens: Int

  private var fill: Color {
    if percentUsed >= 0.85 { return Theme.Color.statusError }
    if percentUsed >= 0.6 { return Theme.Color.statusWarning }
    return Theme.Color.statusSuccess
  }

  var body: some View {
    HStack(spacing: 6) {
      ZStack(alignment: .leading) {
        Capsule()
          .fill(Theme.Color.backgroundPrimary.opacity(0.8))
          .frame(width: 28, height: 6)
        Capsule()
          .fill(fill)
          .frame(width: max(1, min(28, 28 * percentUsed)), height: 6)
      }
      Text(usedTokens == 0 ? "context" : "\(Int((percentUsed * 100).rounded()))% · \(OrchestratorChatView.compact(windowTokens))")
        .font(Theme.Font.metadata)
        .foregroundStyle(Theme.Color.textSecondary)
    }
    .padding(.horizontal, Theme.Spacing.s)
    .padding(.vertical, 4)
    .background(Theme.Color.backgroundPrimary.opacity(0.6))
    .clipShape(Capsule())
  }
}

private struct ModelOption: Identifiable, Hashable {
  let id: String
  let display: String
}

private let modelOptions: [ModelOption] = [
  .init(id: "claude-opus-4-7", display: "Opus 4.7"),
  .init(id: "claude-sonnet-4-6", display: "Sonnet 4.6"),
  .init(id: "claude-haiku-4-5", display: "Haiku 4.5"),
  .init(id: "default", display: "Default"),
]

private struct ModelPickerPill: View {
  let currentModel: String?
  let onPick: (String) -> Void

  private var displayLabel: String {
    guard let currentModel, !currentModel.isEmpty else { return "Default" }
    if let match = modelOptions.first(where: { currentModel.hasPrefix($0.id) || currentModel == $0.id }) {
      return match.display
    }
    return currentModel
  }

  var body: some View {
    Menu {
      ForEach(modelOptions) { option in
        Button {
          onPick(option.id)
        } label: {
          HStack {
            Text(option.display)
            if let currentModel, currentModel.hasPrefix(option.id) {
              Spacer()
              Image(systemName: "checkmark")
            }
          }
        }
      }
    } label: {
      HStack(spacing: 4) {
        Image(systemName: "sparkle")
          .font(.system(size: 9))
          .foregroundStyle(Theme.Color.textTertiary)
        Text(displayLabel)
          .font(Theme.Font.metadata)
          .foregroundStyle(Theme.Color.textSecondary)
        Image(systemName: "chevron.down")
          .font(.system(size: 7, weight: .bold))
          .foregroundStyle(Theme.Color.textTertiary)
      }
      .padding(.horizontal, Theme.Spacing.s)
      .padding(.vertical, 4)
      .background(Theme.Color.backgroundPrimary.opacity(0.6))
      .clipShape(Capsule())
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
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
