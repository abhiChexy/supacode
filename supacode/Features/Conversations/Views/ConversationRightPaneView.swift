import ComposableArchitecture
import SupacodeSettingsShared
import SwiftUI

/// Right pane for a selected conversation. Per spec §7.5.3 / §5.5: shows the
/// conversation's workspaces as cards. Placeholder when none.
struct ConversationRightPaneView: View {
  let conversation: Conversation
  let knownWorktrees: [WorkspaceCardModel]
  let onInspect: (String) -> Void

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
              WorkspaceCard(card: card, onInspect: { onInspect(card.id) })
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
  var status: Status = .idle
  var addedLines: Int?
  var removedLines: Int?

  enum Status: Equatable {
    case idle, running, waitingForInput, notifying
    var label: String {
      switch self {
      case .idle: return "idle"
      case .running: return "running"
      case .waitingForInput: return "waiting for input"
      case .notifying: return "notification"
      }
    }
    var color: Color {
      switch self {
      case .idle: return Theme.Color.textTertiary
      case .running: return Theme.Color.statusSuccess
      case .waitingForInput: return Theme.Color.statusWarning
      case .notifying: return Theme.Color.accent
      }
    }
  }
}

private struct WorkspaceCard: View {
  let card: WorkspaceCardModel
  let onInspect: () -> Void
  @State private var hovering = false

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
        statusPill
      }
      HStack(spacing: Theme.Spacing.s) {
        Text(card.repoName)
          .font(Theme.Font.metadata)
          .foregroundStyle(Theme.Color.textTertiary)
        if let added = card.addedLines, let removed = card.removedLines, added + removed > 0 {
          Text("+\(added)")
            .font(Theme.Font.monoTiny)
            .foregroundStyle(Theme.Color.statusSuccess)
          Text("-\(removed)")
            .font(Theme.Font.monoTiny)
            .foregroundStyle(Theme.Color.statusError)
        }
      }
      Text(card.path)
        .font(Theme.Font.monoTiny)
        .foregroundStyle(Theme.Color.textTertiary)
        .lineLimit(1)
        .truncationMode(.middle)

      HStack(spacing: Theme.Spacing.xs) {
        Button(action: onInspect) {
          actionLabel("View terminal", icon: "terminal.fill")
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .help("Watch the child agent live")

        Button {
          NSWorkspace.shared.open(URL(fileURLWithPath: card.path))
        } label: {
          actionLabel("Finder", icon: "folder")
        }
        .buttonStyle(.plain)
        .help("Open in Finder")

        Button {
          let url = URL(fileURLWithPath: card.path)
          NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
        } label: {
          actionLabel("VS Code", icon: "chevron.left.forwardslash.chevron.right")
        }
        .buttonStyle(.plain)
        .help("Reveal path")

        Spacer()
      }
      .padding(.top, Theme.Spacing.xs)
    }
    .padding(Theme.Spacing.m)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(hovering ? Theme.Color.backgroundElevated.opacity(0.85) : Theme.Color.backgroundElevated)
    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
    .themeBorder()
    .onHover { hovering = $0 }
  }

  @State private var pulse = false

  private var statusPill: some View {
    HStack(spacing: 4) {
      Circle()
        .fill(card.status.color)
        .frame(width: 6, height: 6)
        .opacity(card.status == .running && pulse ? 0.4 : 1.0)
        .onAppear {
          if card.status == .running {
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
              pulse.toggle()
            }
          }
        }
      Text(card.status.label)
        .font(Theme.Font.monoTiny)
        .foregroundStyle(card.status.color)
    }
    .padding(.horizontal, 6)
    .padding(.vertical, 2)
    .background(card.status.color.opacity(0.12))
    .clipShape(Capsule())
  }

  private func actionLabel(_ text: String, icon: String) -> some View {
    HStack(spacing: 4) {
      Image(systemName: icon)
        .font(.system(size: 9))
      Text(text)
        .font(Theme.Font.monoTiny)
    }
    .foregroundStyle(Theme.Color.textSecondary)
    .padding(.horizontal, 6)
    .padding(.vertical, 3)
    .background(text == "View terminal" ? Theme.Color.accent : Theme.Color.backgroundPrimary.opacity(0.6))
    .clipShape(Capsule())
  }

}
