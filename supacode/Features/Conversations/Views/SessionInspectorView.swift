import ComposableArchitecture
import SwiftUI

/// Replacement for Claude Code's `/mcp`, `/agents`, `/context` slash
/// commands — those are CLI-only and can't be routed through the SDK.
/// This sheet hits the SDK directly (get_mcp_status / get_context_usage /
/// get_server_info().agents) and shows the result.
struct SessionInspectorView: View {
  let conversationID: UUID
  @Environment(\.dismiss) private var dismiss
  @Dependency(OrchestratorClientKey.self) private var orchestrator

  @State private var loading = true
  @State private var inspection: SessionInspection?
  @State private var error: String?

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("Session info")
          .font(.system(size: 14, weight: .semibold))
        Spacer()
        Button("Done") { dismiss() }
          .buttonStyle(.borderless)
          .foregroundStyle(Theme.Color.textSecondary)
          .keyboardShortcut(.escape, modifiers: [])
      }
      .padding(Theme.Spacing.m)
      Divider().background(Theme.Color.borderSubtle)
      content
    }
    .frame(minWidth: 480, minHeight: 380)
    .background(Theme.Color.backgroundSecondary)
    .foregroundStyle(Theme.Color.textPrimary)
    .task { await load() }
  }

  @ViewBuilder
  private var content: some View {
    if loading {
      VStack(spacing: Theme.Spacing.s) {
        ProgressView()
        Text("Inspecting session…")
          .font(Theme.Font.metadata)
          .foregroundStyle(Theme.Color.textSecondary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if let error {
      Text(error)
        .font(Theme.Font.metadata)
        .foregroundStyle(Theme.Color.statusError)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    } else if let inspection {
      ScrollView {
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
          section(
            title: "MCP servers",
            empty: "No MCP servers configured for this session."
          ) {
            ForEach(inspection.mcpServers) { server in
              HStack(spacing: Theme.Spacing.s) {
                Circle()
                  .fill(statusColor(server.status))
                  .frame(width: 8, height: 8)
                Text(server.name)
                  .font(Theme.Font.mono)
                Spacer()
                Text(server.status)
                  .font(Theme.Font.monoSmall)
                  .foregroundStyle(Theme.Color.textTertiary)
              }
            }
          }

          section(title: "Context usage", empty: "No context usage data yet — send a message first.") {
            ForEach(inspection.contextUsage.keys.sorted(), id: \.self) { key in
              HStack {
                Text(key)
                  .font(Theme.Font.monoSmall)
                  .foregroundStyle(Theme.Color.textSecondary)
                Spacer()
                Text(inspection.contextUsage[key] ?? "")
                  .font(Theme.Font.monoSmall)
                  .foregroundStyle(Theme.Color.textPrimary)
              }
            }
          }

          section(title: "Available subagents", empty: "No subagents loaded.") {
            ForEach(inspection.agents, id: \.self) { agent in
              Text(agent)
                .font(Theme.Font.monoSmall)
                .foregroundStyle(Theme.Color.textPrimary)
            }
          }
        }
        .padding(Theme.Spacing.l)
      }
    }
  }

  @ViewBuilder
  private func section<Content: View>(
    title: String,
    empty: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.s) {
      Text(title.uppercased())
        .font(Theme.Font.headerSection)
        .foregroundStyle(Theme.Color.textSecondary)
      let inner = content()
      let mirror = Mirror(reflecting: inner)
      let hasChildren = mirror.children.contains(where: { _ in true })
      if hasChildren {
        inner
      } else {
        Text(empty)
          .font(Theme.Font.metadata)
          .foregroundStyle(Theme.Color.textTertiary)
      }
    }
  }

  private func statusColor(_ status: String) -> Color {
    switch status {
    case "connected": return Theme.Color.statusSuccess
    case "needs-auth", "pending": return Theme.Color.statusWarning
    case "failed", "error": return Theme.Color.statusError
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
