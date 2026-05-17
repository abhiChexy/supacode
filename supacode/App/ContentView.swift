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
  @State private var leftSidebarVisibility: NavigationSplitViewVisibility = .all
  @State private var isSearchPresented: Bool = false

  init(store: StoreOf<AppFeature>, terminalManager: WorktreeTerminalManager) {
    self.store = store
    repositoriesStore = store.scope(state: \.repositories, action: \.repositories)
    self.terminalManager = terminalManager
  }

  var body: some View {
    NavigationSplitView(columnVisibility: $leftSidebarVisibility) {
      VStack(spacing: 0) {
        ConversationsSidebarSectionView(
          store: store.scope(state: \.conversations, action: \.conversations)
        )
        SidebarView(store: repositoriesStore, terminalManager: terminalManager)
      }
      .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
      .safeAreaInset(edge: .bottom, spacing: 0) {
        VStack(spacing: 0) {
          ConversationTotalsCard(
            store: store.scope(state: \.conversations, action: \.conversations)
          )
          SidebarBottomCardView(store: store)
        }
      }
    } detail: {
      HStack(spacing: 0) {
        if leftSidebarVisibility == .detailOnly {
          ConversationsSidebarRail(
            store: store.scope(state: \.conversations, action: \.conversations),
            onExpand: { withAnimation(.easeOut(duration: 0.2)) { leftSidebarVisibility = .all } }
          )
          .transition(.move(edge: .leading).combined(with: .opacity))
        }
        detailPane
      }
    }
    .navigationSplitViewStyle(.automatic)
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
    withAnimation(.easeOut(duration: 0.2)) {
      leftSidebarVisibility = leftSidebarVisibility == .detailOnly ? .all : .detailOnly
    }
  }

  private var revealInSidebarAction: (() -> Void)? {
    guard store.repositories.selectedWorktreeID != nil else { return nil }
    return { revealInSidebar() }
  }

  private func revealInSidebar() {
    withAnimation(.easeOut(duration: 0.2)) {
      leftSidebarVisibility = .all
    }
    store.send(.repositories(.revealSelectedWorktreeInSidebar))
  }

}
