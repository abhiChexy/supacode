import ComposableArchitecture
import SwiftUI

/// A small sheet that lists the MCP servers available to this session.
/// Replaces Claude Code's `/mcp` slash command, which is CLI-only.
///
/// Earlier versions of this sheet also showed `get_context_usage()` totals
/// and agent listings — both turned out to be debug noise the user
/// couldn't act on. Model / cost / tokens are already in the composer
/// pills, so this is just MCP status now.
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
  @State private var mcpServers: [MCPServerStatus] = []
  @State private var error: String?

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider().background(Theme.Color.borderSubtle)
      content
    }
    .frame(minWidth: 440, idealWidth: 480, minHeight: 320, idealHeight: 380)
    .background(Theme.Color.backgroundSecondary)
    .foregroundStyle(Theme.Color.textPrimary)
    .task { await load() }
  }

  private var header: some View {
    HStack(spacing: Theme.Spacing.s) {
      Text("MCP servers")
        .font(.system(size: 13, weight: .semibold))
      Spacer()
      Button {
        Task { await load() }
      } label: {
        Image(systemName: "arrow.clockwise")
          .font(.system(size: 11))
          .foregroundStyle(Theme.Color.textSecondary)
      }
      .buttonStyle(.borderless)
      .help("Refresh")
      Button("Done") { dismiss() }
        .buttonStyle(.borderless)
        .foregroundStyle(Theme.Color.textSecondary)
        .keyboardShortcut(.escape, modifiers: [])
    }
    .padding(.horizontal, Theme.Spacing.m)
    .padding(.vertical, Theme.Spacing.s)
  }

  @ViewBuilder
  private var content: some View {
    if loading {
      VStack(spacing: Theme.Spacing.s) {
        ProgressView().controlSize(.small).scaleEffect(0.8)
        Text("Loading…")
          .font(Theme.Font.metadata)
          .foregroundStyle(Theme.Color.textTertiary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if let error {
      Text(error)
        .font(Theme.Font.metadata)
        .foregroundStyle(Theme.Color.statusError)
        .padding(Theme.Spacing.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    } else if mcpServers.isEmpty {
      VStack(spacing: Theme.Spacing.s) {
        Image(systemName: "puzzlepiece.extension")
          .font(.system(size: 24, weight: .thin))
          .foregroundStyle(Theme.Color.textTertiary)
        Text("No MCP servers")
          .font(Theme.Font.body)
          .foregroundStyle(Theme.Color.textSecondary)
        Text("Configured in ~/.claude/settings.json")
          .font(Theme.Font.metadata)
          .foregroundStyle(Theme.Color.textTertiary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      ScrollView {
        VStack(spacing: 0) {
          ForEach(mcpServers) { server in
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
            .padding(.horizontal, Theme.Spacing.l)
            .padding(.vertical, Theme.Spacing.s)
            Divider().background(Theme.Color.borderSubtle).opacity(0.4)
          }
        }
      }
    }
  }

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
      mcpServers = try await orchestrator.inspectSession(conversationID).mcpServers
    } catch {
      self.error = "Failed: \(error)"
    }
    loading = false
  }
}
