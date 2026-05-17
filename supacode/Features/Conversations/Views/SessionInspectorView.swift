import ComposableArchitecture
import SwiftUI

/// SDK-backed replacement for Claude Code's `/mcp`, `/agents`, `/context`
/// slash commands.
struct SessionInspectorView: View {
  let conversationID: UUID
  let conversationTitle: String
  let model: String?
  let cwd: String?
  let sessionID: String?
  let usageInputTokens: Int
  let usageOutputTokens: Int
  let usageCacheReadTokens: Int
  let usageCostUSD: Double

  @Environment(\.dismiss) private var dismiss
  @Dependency(OrchestratorClientKey.self) private var orchestrator

  @State private var loading = true
  @State private var inspection: SessionInspection?
  @State private var error: String?

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider().background(Theme.Color.borderSubtle)
      ScrollView {
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
          metadataCard
          mcpCard
          contextCard
          agentsCard
        }
        .padding(Theme.Spacing.l)
      }
    }
    .frame(minWidth: 560, minHeight: 520)
    .background(Theme.Color.backgroundSecondary)
    .foregroundStyle(Theme.Color.textPrimary)
    .task { await load() }
  }

  // MARK: Header

  private var header: some View {
    HStack(spacing: Theme.Spacing.s) {
      Image(systemName: "info.circle")
        .font(.system(size: 14))
        .foregroundStyle(Theme.Color.textSecondary)
      Text("Session info")
        .font(.system(size: 14, weight: .semibold))
      Spacer()
      Button {
        Task { await load() }
      } label: {
        Image(systemName: "arrow.clockwise")
          .font(.system(size: 12))
          .foregroundStyle(Theme.Color.textSecondary)
      }
      .buttonStyle(.borderless)
      .help("Refresh")
      Button("Done") { dismiss() }
        .buttonStyle(.borderless)
        .foregroundStyle(Theme.Color.textSecondary)
        .keyboardShortcut(.escape, modifiers: [])
    }
    .padding(Theme.Spacing.m)
  }

  // MARK: Cards

  private var metadataCard: some View {
    Card(title: "Conversation") {
      VStack(alignment: .leading, spacing: Theme.Spacing.s) {
        kvRow("Title", conversationTitle.isEmpty ? "Untitled" : conversationTitle)
        kvRow("Model", model ?? "—")
        kvRow("Working directory", cwd ?? "—", monospaced: true)
        kvRow("Session ID", sessionID ?? "—", monospaced: true)
        if usageInputTokens > 0 || usageOutputTokens > 0 {
          Divider().background(Theme.Color.borderSubtle).padding(.vertical, 2)
          kvRow("Input tokens", "\(usageInputTokens)")
          kvRow("Output tokens", "\(usageOutputTokens)")
          kvRow("Cache reads", "\(usageCacheReadTokens)")
          if usageCostUSD > 0 {
            kvRow("Cost", String(format: "$%.4f", usageCostUSD))
          }
        }
      }
    }
  }

  private var mcpCard: some View {
    Card(title: "MCP servers") {
      if loading {
        loadingRow
      } else if let mcp = inspection?.mcpServers, !mcp.isEmpty {
        VStack(spacing: Theme.Spacing.xs) {
          ForEach(mcp) { server in
            HStack(spacing: Theme.Spacing.s) {
              Circle()
                .fill(statusColor(server.status))
                .frame(width: 8, height: 8)
              Text(server.name)
                .font(Theme.Font.mono)
                .foregroundStyle(Theme.Color.textPrimary)
              Spacer()
              Text(server.status)
                .font(Theme.Font.monoSmall)
                .foregroundStyle(statusColor(server.status))
                .padding(.horizontal, Theme.Spacing.s)
                .padding(.vertical, 2)
                .background(statusColor(server.status).opacity(0.12))
                .clipShape(Capsule())
            }
            .padding(.vertical, 4)
          }
        }
      } else {
        emptyRow("None configured for this session.")
      }
    }
  }

  private var contextCard: some View {
    Card(title: "Context") {
      if loading {
        loadingRow
      } else if let ctx = inspection?.contextUsage, !ctx.isEmpty {
        VStack(alignment: .leading, spacing: 4) {
          ForEach(ctx.keys.sorted(), id: \.self) { key in
            kvRow(key, ctx[key] ?? "", monospaced: true)
          }
        }
      } else {
        emptyRow("Context usage isn't reported until the first turn lands.")
      }
    }
  }

  private var agentsCard: some View {
    Card(title: "Available subagents") {
      if loading {
        loadingRow
      } else if let agents = inspection?.agents, !agents.isEmpty {
        VStack(alignment: .leading, spacing: 4) {
          ForEach(agents, id: \.self) { agent in
            HStack {
              Image(systemName: "person.crop.circle")
                .font(.system(size: 11))
                .foregroundStyle(Theme.Color.textTertiary)
              Text(agent)
                .font(Theme.Font.monoSmall)
                .foregroundStyle(Theme.Color.textPrimary)
              Spacer()
            }
          }
        }
      } else {
        emptyRow("No subagents available in this session.")
      }
    }
  }

  private var loadingRow: some View {
    HStack(spacing: Theme.Spacing.s) {
      ProgressView().controlSize(.small).scaleEffect(0.7)
      Text("Loading…")
        .font(Theme.Font.metadata)
        .foregroundStyle(Theme.Color.textTertiary)
    }
    .padding(.vertical, 2)
  }

  private func emptyRow(_ text: String) -> some View {
    Text(text)
      .font(Theme.Font.metadata)
      .foregroundStyle(Theme.Color.textTertiary)
      .padding(.vertical, 2)
  }

  private func kvRow(_ key: String, _ value: String, monospaced: Bool = false) -> some View {
    HStack(alignment: .top) {
      Text(key)
        .font(Theme.Font.metadata)
        .foregroundStyle(Theme.Color.textSecondary)
        .frame(width: 140, alignment: .leading)
      Text(value)
        .font(monospaced ? Theme.Font.monoSmall : Theme.Font.body)
        .foregroundStyle(Theme.Color.textPrimary)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  // MARK: Plumbing

  private func statusColor(_ status: String) -> Color {
    switch status {
    case "connected", "ready": return Theme.Color.statusSuccess
    case "needs-auth", "pending": return Theme.Color.statusWarning
    case "failed", "error", "disconnected": return Theme.Color.statusError
    default: return Theme.Color.textTertiary
    }
  }

  private func load() async {
    loading = true
    error = nil
    do {
      inspection = try await orchestrator.inspectSession(conversationID)
    } catch {
      self.error = "Failed: \(error)"
    }
    loading = false
  }
}

private struct Card<Content: View>: View {
  let title: String
  @ViewBuilder let content: () -> Content

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.s) {
      Text(title.uppercased())
        .font(Theme.Font.headerSection)
        .foregroundStyle(Theme.Color.textSecondary)
        .padding(.horizontal, Theme.Spacing.s)
      content()
        .padding(Theme.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Color.backgroundElevated)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.Color.borderSubtle, lineWidth: 1))
    }
  }
}
