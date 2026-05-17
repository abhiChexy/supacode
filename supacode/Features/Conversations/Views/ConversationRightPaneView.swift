import ComposableArchitecture
import SupacodeSettingsShared
import SwiftUI

/// Right pane for a selected conversation. Per spec §7.5.3 / §5.5: shows the
/// conversation's workspaces as cards. Placeholder when none.
struct ConversationRightPaneView: View {
  let conversation: Conversation
  let knownWorktrees: [WorkspaceCardModel]

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Divider().background(Theme.Color.borderSubtle)
      ScrollView {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
          if conversation.workspaceIDs.isEmpty {
            emptyState
          } else {
            ForEach(workspaceCards, id: \.id) { card in
              WorkspaceCard(card: card)
            }
            if conversation.workspaceIDs.count > workspaceCards.count {
              ghostCards
            }
          }
        }
        .padding(Theme.Spacing.l)
      }
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Theme.Color.backgroundTertiary)
    .foregroundStyle(Theme.Color.textPrimary)
  }

  private var header: some View {
    HStack {
      Text("Workspaces")
        .font(Theme.Font.headerSection)
        .foregroundStyle(Theme.Color.textSecondary)
        .textCase(.uppercase)
      Spacer()
      Text("\(conversation.workspaceIDs.count)")
        .font(Theme.Font.monoSmall)
        .foregroundStyle(Theme.Color.textTertiary)
    }
    .padding(.horizontal, Theme.Spacing.l)
    .padding(.vertical, Theme.Spacing.m)
  }

  private var emptyState: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.s) {
      Text("No workspaces yet")
        .font(Theme.Font.body)
        .foregroundStyle(Theme.Color.textSecondary)
      Text("The orchestrator will create workspaces as it plans the work.")
        .font(Theme.Font.metadata)
        .foregroundStyle(Theme.Color.textTertiary)
    }
    .padding(.vertical, Theme.Spacing.l)
  }

  private var workspaceCards: [WorkspaceCardModel] {
    knownWorktrees.filter { conversation.workspaceIDs.contains($0.id) }
  }

  private var ghostCards: some View {
    let resolved = Set(workspaceCards.map(\.id))
    let unknown = conversation.workspaceIDs.filter { !resolved.contains($0) }
    return ForEach(unknown, id: \.self) { id in
      VStack(alignment: .leading, spacing: 2) {
        Text(id.prefix(12).uppercased())
          .font(Theme.Font.monoSmall)
          .foregroundStyle(Theme.Color.textTertiary)
        Text("Workspace unavailable")
          .font(Theme.Font.metadata)
          .foregroundStyle(Theme.Color.textTertiary)
      }
      .padding(Theme.Spacing.m)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Theme.Color.backgroundElevated.opacity(0.5))
      .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
    }
  }
}

struct WorkspaceCardModel: Equatable, Identifiable {
  let id: String
  let repoName: String
  let branch: String
  let path: String
}

private struct WorkspaceCard: View {
  let card: WorkspaceCardModel

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
      HStack(spacing: Theme.Spacing.s) {
        Image(systemName: "arrow.triangle.branch")
          .font(.system(size: 11))
          .foregroundStyle(Theme.Color.textSecondary)
        Text(card.branch)
          .font(Theme.Font.mono)
          .foregroundStyle(Theme.Color.textPrimary)
          .lineLimit(1)
          .truncationMode(.middle)
        Spacer()
      }
      Text(card.repoName)
        .font(Theme.Font.metadata)
        .foregroundStyle(Theme.Color.textTertiary)
      Text(card.path)
        .font(Theme.Font.monoTiny)
        .foregroundStyle(Theme.Color.textTertiary)
        .lineLimit(1)
        .truncationMode(.middle)
    }
    .padding(Theme.Spacing.m)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Theme.Color.backgroundElevated)
    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
    .themeBorder()
  }
}
