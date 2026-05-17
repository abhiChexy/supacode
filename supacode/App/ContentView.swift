//
//  ContentView.swift
//  supacode
//
//  Created by khoi on 20/1/26.
//

import ComposableArchitecture
import SupacodeSettingsShared
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
  @Bindable var store: StoreOf<AppFeature>
  @Bindable var repositoriesStore: StoreOf<RepositoriesFeature>
  let terminalManager: WorktreeTerminalManager
  @Environment(\.scenePhase) private var scenePhase
  @Environment(GhosttyShortcutManager.self) private var ghosttyShortcuts
  @State private var sidebarMode: SidebarMode = .expanded
  @State private var sidebarWidth: CGFloat = 260
  @State private var isSearchPresented: Bool = false

  private enum SidebarMode { case expanded, collapsed }
  private var effectiveSidebarWidth: CGFloat {
    switch sidebarMode {
    case .expanded: return sidebarWidth
    case .collapsed: return 44
    }
  }

  init(store: StoreOf<AppFeature>, terminalManager: WorktreeTerminalManager) {
    self.store = store
    repositoriesStore = store.scope(state: \.repositories, action: \.repositories)
    self.terminalManager = terminalManager
  }

  var body: some View {
    VStack(spacing: 0) {
      topBar
      Divider().background(Theme.Color.borderSubtle)
      HStack(spacing: 0) {
        sidebar
          .frame(width: effectiveSidebarWidth)
        Divider()
          .background(Theme.Color.borderSubtle)
        detailPane
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .ignoresSafeArea(edges: .top)
    .background(Theme.Color.backgroundSecondary.ignoresSafeArea())
    .containerBackground(Theme.Color.backgroundPrimary, for: .window)
    .disabled(!store.repositories.isInitialLoadComplete)
    .onChange(of: scenePhase) { _, newValue in
      store.send(.scenePhaseChanged(newValue))
    }
    .fileImporter(
      isPresented: $repositoriesStore.isOpenPanelPresented.sending(\.setOpenPanelPresented),
      allowedContentTypes: [.folder],
      allowsMultipleSelection: true
    ) { result in
      switch result {
      case .success(let urls):
        store.send(.repositories(.openRepositories(urls)))
      case .failure:
        store.send(
          .repositories(
            .presentAlert(
              title: "Unable to open folders",
              message: "Supacode could not read the selected folders."
            )
          )
        )
      }
    }
    .alert($repositoriesStore.scope(state: \.alert, action: \.alert))
    .alert($store.scope(state: \.alert, action: \.alert))
    .sheet(
      item: $store.scope(state: \.deeplinkInputConfirmation, action: \.deeplinkInputConfirmation)
    ) { confirmationStore in
      DeeplinkInputConfirmationView(store: confirmationStore)
    }
    .sheet(
      item: $repositoriesStore.scope(state: \.worktreeCreationPrompt, action: \.worktreeCreationPrompt)
    ) { promptStore in
      WorktreeCreationPromptView(store: promptStore)
    }
    .sheet(
      item: $repositoriesStore.scope(
        state: \.repositoryCustomization,
        action: \.repositoryCustomization
      )
    ) { customizationStore in
      RepositoryCustomizationView(store: customizationStore)
    }
    .focusedSceneValue(\.toggleLeftSidebarAction, toggleLeftSidebar)
    .focusedSceneValue(\.revealInSidebarAction, revealInSidebarAction)
    .sheet(isPresented: $isSearchPresented) {
      ConversationSearchView(
        store: store.scope(state: \.conversations, action: \.conversations)
      )
    }
    .background(
      Group {
        Button("") { isSearchPresented = true }
          .keyboardShortcut("f", modifiers: .command)
        Button("") { closeCurrentConversation() }
          .keyboardShortcut("w", modifiers: .command)
        Button("") { toggleLeftSidebar() }
          .keyboardShortcut("b", modifiers: .command)
      }
      .hidden()
    )
    .overlay {
      CommandPaletteOverlayView(
        store: store.scope(state: \.commandPalette, action: \.commandPalette),
        items: CommandPaletteFeature.commandPaletteItems(
          from: store.repositories,
          ghosttyCommands: ghosttyShortcuts.commandPaletteEntries,
          scripts: store.allScripts,
          runningScriptIDs: store.runningScriptIDs
        )
      )
    }
    .background(WindowTabbingDisabler())
    .background(WindowChromeObserver(runtime: terminalManager.ghosttyRuntime))
    .navigationTitle(
      WindowTitle.compute(
        repositories: store.repositories,
        terminalManager: terminalManager
      )
    )
  }

  /// Unified top bar that spans the full window width, holding the traffic
  /// lights (left, via window padding) and our app-level chrome. Same
  /// visual treatment as Cursor / Warp.
  private var topBar: some View {
    HStack(spacing: Theme.Spacing.s) {
      // Reserve space for the macOS traffic lights on the left.
      Spacer().frame(width: 72)
      Button {
        toggleLeftSidebar()
      } label: {
        Image(systemName: "sidebar.left")
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(Theme.Color.textSecondary)
          .frame(width: 26, height: 22)
          .background(Theme.Color.backgroundElevated)
          .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.pill))
      }
      .buttonStyle(.plain)
      .help("Toggle sidebar (⌘B)")
      Spacer()
      if let cid = store.conversations.selectedConversationID,
        let title = store.conversations.conversations[id: cid]?.title,
        !title.isEmpty
      {
        Text(title)
          .font(Theme.Font.body.weight(.medium))
          .foregroundStyle(Theme.Color.textPrimary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      Spacer()
      Button {
        isSearchPresented = true
      } label: {
        Image(systemName: "magnifyingglass")
          .font(.system(size: 11))
          .foregroundStyle(Theme.Color.textSecondary)
          .frame(width: 26, height: 22)
          .background(Theme.Color.backgroundElevated)
          .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.pill))
      }
      .buttonStyle(.plain)
      .help("Search conversations (⌘F)")
    }
    .padding(.horizontal, Theme.Spacing.s)
    .frame(height: 36)
    .background(Theme.Color.backgroundPrimary.ignoresSafeArea(edges: .top))
  }

  @ViewBuilder
  private var sidebar: some View {
    Group {
      switch sidebarMode {
      case .collapsed:
        ConversationsSidebarRail(
          store: store.scope(state: \.conversations, action: \.conversations),
          onExpand: toggleLeftSidebar
        )
      case .expanded:
        ZStack {
          Theme.Color.backgroundPrimary.ignoresSafeArea()
          VStack(spacing: 0) {
            ConversationsSidebarSectionView(
              store: store.scope(state: \.conversations, action: \.conversations)
            )
            // Supacode's legacy repo/worktree sidebar is intentionally
            // hidden in orchestrator mode — workspaces show in the
            // conversation's right pane instead. Reinstate by adding
            // SidebarView(...) back here if you want the full Supacode
            // experience.
            Spacer(minLength: 0)
          }
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Theme.Color.backgroundPrimary)
  }

  @ViewBuilder
  private var detailPane: some View {
    if let id = store.conversations.selectedConversationID,
      let conversation = store.conversations.conversations[id: id]
    {
      HStack(spacing: 0) {
        OrchestratorChatView(
          store: store.scope(state: \.conversations, action: \.conversations),
          conversation: conversation
        )
        .id(conversation.id)
        Divider().background(Theme.Color.borderSubtle)
        ConversationRightPaneView(
          conversation: conversation,
          knownWorktrees: knownWorktreeCards
        )
        .id(conversation.id)
        .frame(minWidth: 240, idealWidth: 320, maxWidth: 420)
      }
    } else if store.repositories.selectedWorktreeID != nil {
      WorktreeDetailView(store: store, terminalManager: terminalManager)
    } else {
      ConversationEmptyStateView(
        store: store.scope(state: \.conversations, action: \.conversations)
      )
    }
  }

  /// Cmd+W: close the active conversation. Falls back to the system close
  /// behavior (window close) when nothing is selected.
  private func closeCurrentConversation() {
    guard let id = store.conversations.selectedConversationID else {
      NSApp.keyWindow?.performClose(nil)
      return
    }
    store.send(.conversations(.deleteConversation(id)))
  }

  private var knownWorktreeCards: [WorkspaceCardModel] {
    store.repositories.repositories.flatMap { repo in
      repo.worktrees.map { wt in
        WorkspaceCardModel(
          id: wt.id,
          repoName: repo.name,
          branch: wt.name,
          path: wt.workingDirectory.path(percentEncoded: false)
        )
      }
    }
  }

  private func toggleLeftSidebar() {
    withAnimation(.easeOut(duration: 0.18)) {
      sidebarMode = sidebarMode == .expanded ? .collapsed : .expanded
    }
  }

  private var revealInSidebarAction: (() -> Void)? {
    guard store.repositories.selectedWorktreeID != nil else { return nil }
    return { revealInSidebar() }
  }

  private func revealInSidebar() {
    withAnimation(.easeOut(duration: 0.18)) {
      sidebarMode = .expanded
    }
    store.send(.repositories(.revealSelectedWorktreeInSidebar))
  }

}
