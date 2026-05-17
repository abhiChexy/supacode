import ComposableArchitecture
import SwiftUI

/// Aggregate spend + token usage across every conversation. Sits above the
/// sidebar's bottom toolbar so the user always sees their running total
/// without opening a conversation.
struct ConversationTotalsCard: View {
  @Bindable var store: StoreOf<ConversationFeature>

  private var totalCost: Double {
    store.runtimeByConversationID.values.map(\.totalCostUSD).reduce(0, +)
  }
  private var totalTokens: Int {
    store.runtimeByConversationID.values
      .map { $0.totalInputTokens + $0.totalOutputTokens }
      .reduce(0, +)
  }
  private var activeCount: Int {
    store.inFlightConversationIDs.count
  }

  var body: some View {
    HStack(spacing: Theme.Spacing.s) {
      VStack(alignment: .leading, spacing: 1) {
        Text("Spend")
          .font(Theme.Font.monoTiny)
          .foregroundStyle(Theme.Color.textTertiary)
        Text(String(format: "$%.2f", totalCost))
          .font(Theme.Font.body.weight(.medium))
          .foregroundStyle(Theme.Color.textPrimary)
      }
      Spacer()
      VStack(alignment: .trailing, spacing: 1) {
        Text("Tokens")
          .font(Theme.Font.monoTiny)
          .foregroundStyle(Theme.Color.textTertiary)
        Text(OrchestratorChatView.compact(totalTokens))
          .font(Theme.Font.body.weight(.medium))
          .foregroundStyle(Theme.Color.textPrimary)
      }
      if activeCount > 0 {
        Divider().frame(height: 18).background(Theme.Color.borderSubtle)
        HStack(spacing: 4) {
          Circle()
            .fill(Theme.Color.statusSuccess)
            .frame(width: 6, height: 6)
          Text("\(activeCount)")
            .font(Theme.Font.body.weight(.medium))
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
    .help("Total across all conversations this session. Active count: in-flight turns.")
  }
}
