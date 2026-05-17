import Combine
import ComposableArchitecture
import SwiftUI

/// Persistent usage panel — sits above the sidebar's bottom toolbar.
///
/// Shows the user's Anthropic rate-limit windows (5h, weekly messages,
/// weekly Opus) the same way Claude desktop does: percentage utilization
/// + reset countdown. Falls back to a per-session tokens-used line when
/// no rate-limit info has arrived yet.
struct ConversationTotalsCard: View {
  @Bindable var store: StoreOf<ConversationFeature>
  @State private var now = Date()
  private let ticker = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

  private var totalTokens: Int {
    store.runtimeByConversationID.values
      .map { $0.totalInputTokens + $0.totalOutputTokens }
      .reduce(0, +)
  }
  private var activeCount: Int {
    store.inFlightConversationIDs.count
  }
  private var orderedWindows: [ConversationFeature.RateLimitWindow] {
    let priority = ["five_hour", "weekly_messages", "weekly_opus", "weekly"]
    return priority.compactMap { store.rateLimitWindows[$0] }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.s) {
      header
      if orderedWindows.isEmpty {
        sessionRow
      } else {
        ForEach(orderedWindows, id: \.window) { window in
          windowRow(window)
        }
      }
    }
    .padding(.horizontal, Theme.Spacing.m)
    .padding(.vertical, Theme.Spacing.s)
    .background(Theme.Color.backgroundElevated)
    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.Color.borderSubtle, lineWidth: 1))
    .padding(.horizontal, Theme.Spacing.s)
    .padding(.vertical, Theme.Spacing.xs)
    .onReceive(ticker) { now = $0 }
  }

  private var header: some View {
    HStack {
      Text("Usage")
        .font(Theme.Font.monoTiny)
        .foregroundStyle(Theme.Color.textTertiary)
      Spacer()
      if activeCount > 0 {
        HStack(spacing: 4) {
          Circle()
            .fill(Theme.Color.statusSuccess)
            .frame(width: 6, height: 6)
          Text("\(activeCount) active")
            .font(Theme.Font.monoTiny)
            .foregroundStyle(Theme.Color.textSecondary)
        }
      }
    }
  }

  private var sessionRow: some View {
    HStack {
      Text("This session")
        .font(Theme.Font.metadata)
        .foregroundStyle(Theme.Color.textSecondary)
      Spacer()
      Text("\(OrchestratorChatView.compact(totalTokens)) tokens")
        .font(Theme.Font.body.weight(.medium))
        .foregroundStyle(Theme.Color.textPrimary)
    }
  }

  @ViewBuilder
  private func windowRow(_ window: ConversationFeature.RateLimitWindow) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack {
        Text(label(for: window.window))
          .font(Theme.Font.metadata)
          .foregroundStyle(Theme.Color.textSecondary)
        Spacer()
        Text(rightLabel(window))
          .font(Theme.Font.monoTiny)
          .foregroundStyle(Theme.Color.textTertiary)
      }
      gauge(for: window)
    }
  }

  private func label(for window: String) -> String {
    switch window {
    case "five_hour": return "5h window"
    case "weekly_messages", "weekly": return "Weekly"
    case "weekly_opus": return "Weekly Opus"
    default: return window.replacing("_", with: " ").capitalized
    }
  }

  private func rightLabel(_ window: ConversationFeature.RateLimitWindow) -> String {
    if let resetsAt = window.resetsAt {
      let interval = resetsAt.timeIntervalSince(now)
      if interval > 0 {
        return "resets in \(formatInterval(interval))"
      }
    }
    return window.status ?? ""
  }

  @ViewBuilder
  private func gauge(for window: ConversationFeature.RateLimitWindow) -> some View {
    let pct = max(0, min(1, window.utilization ?? 0))
    let color = gaugeColor(pct: pct, status: window.status)
    GeometryReader { geo in
      ZStack(alignment: .leading) {
        Capsule()
          .fill(Theme.Color.backgroundPrimary.opacity(0.8))
          .frame(height: 5)
        Capsule()
          .fill(color)
          .frame(width: max(2, geo.size.width * pct), height: 5)
      }
    }
    .frame(height: 5)
  }

  private func gaugeColor(pct: Double, status: String?) -> Color {
    if status == "limited" { return Theme.Color.statusError }
    if pct >= 0.85 { return Theme.Color.statusError }
    if pct >= 0.6 { return Theme.Color.statusWarning }
    return Theme.Color.statusSuccess
  }

  private func formatInterval(_ seconds: TimeInterval) -> String {
    let s = Int(seconds)
    let days = s / 86400
    let hours = (s % 86400) / 3600
    let minutes = (s % 3600) / 60
    if days > 0 { return "\(days)d \(hours)h" }
    if hours > 0 { return "\(hours)h \(minutes)m" }
    return "\(max(1, minutes))m"
  }
}
