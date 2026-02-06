//
//  TabbedNavigator.swift
//  DynamicTabBar
//
//  Main tabbed navigation container.
//  Always renders a TabView – bootstrap mode hides the tab bar.
//

import SwiftUI
import Combine
import os.log
import HotwireNative

// MARK: - NavigatorStore

/// Stores Navigators by tab UUID.
/// Navigators are created lazily and cached for reuse.
@MainActor
final class NavigatorStore: ObservableObject {
    private let logger = Logger(subsystem: "com.example.dynamictabbar", category: "NavigatorStore")
    private var navigators: [UUID: Navigator] = [:]
    private let baseURL: URL

    init(baseURL: URL, bootstrapUuid: UUID, bootstrapNavigator: Navigator) {
        self.baseURL = baseURL
        self.navigators[bootstrapUuid] = bootstrapNavigator
    }

    func navigator(for tab: TabItem) -> Navigator {
        if let existing = navigators[tab.uuid] {
            return existing
        }

        guard let url = URL(string: tab.path, relativeTo: baseURL) else {
            fatalError("Invalid tab path: \(tab.path)")
        }

        let navigator = Navigator(configuration: .init(name: "main", startLocation: url))
        navigators[tab.uuid] = navigator

        logger.info("Created navigator for tab: \(tab.serverId.isEmpty ? "bootstrap" : tab.serverId)")

        return navigator
    }

    func remove(uuids: Set<UUID>) {
        for uuid in uuids {
            navigators.removeValue(forKey: uuid)
            logger.info("Removed navigator for UUID: \(uuid)")
        }
    }
}

// MARK: - TabbedNavigator

/// The main tabbed navigation container.
/// Renders tabs, manages navigators, and responds to server directives.
struct TabbedNavigator: View {
    @ObservedObject var tabManager: TabManager
    @StateObject private var store: NavigatorStore

    init(tabManager: TabManager, baseURL: URL) {
        self.tabManager = tabManager

        let bootstrapUuid = tabManager.tabs[0].uuid
        let initialNavigator = Navigator(configuration: .init(name: "main", startLocation: baseURL))

        _store = StateObject(wrappedValue: NavigatorStore(
            baseURL: baseURL,
            bootstrapUuid: bootstrapUuid,
            bootstrapNavigator: initialNavigator
        ))
    }

    var body: some View {
        TabView(selection: Binding(
            get: { tabManager.selectedUuid },
            set: { tabManager.selectTab(uuid: $0) }
        )) {
            ForEach(tabManager.tabs) { tab in
                Tab(tab.title, systemImage: tab.icon, value: tab.uuid) {
                    HotwireView(navigator: store.navigator(for: tab))
                        .ignoresSafeArea()
                        .toolbar(tabManager.isBootstrap ? .hidden : .visible, for: .tabBar)
                }
            }
        }
        // Server tab configuration
        .onReceive(NotificationCenter.default.publisher(for: .tabConfigurationDidChange)) { notification in
            guard let directive = notification.userInfo?["directive"] as? TabsDirective else { return }
            tabManager.accept(directive)
        }
        // GC removed navigators
        .onChange(of: tabManager.tabs) { oldTabs, newTabs in
            let removedUuids = Set(oldTabs.map { $0.uuid }).subtracting(newTabs.map { $0.uuid })
            guard !removedUuids.isEmpty else { return }
            Task { @MainActor in
                store.remove(uuids: removedUuids)
            }
        }
    }
}
