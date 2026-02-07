//
//  TabbedNavigator.swift
//  DynamicTabBar
//
//  UITabBarController-based tabbed navigation container.
//  Same NavigatorStore and TabManager as the SwiftUI version.
//  SwiftUI diffs for us via ForEach identity; here we are the
//  diffing runtime — see applyTabState().
//

import UIKit
import os.log
import HotwireNative

// MARK: - NavigatorStore

/// Stores Navigators by tab UUID.
/// Navigators are created lazily and cached for reuse.
/// Same role as the SwiftUI version, minus ObservableObject.
@MainActor
final class NavigatorStore {
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

/// UITabBarController subclass that manages server-driven tabs.
/// Uses navigator.rootViewController directly as each tab's VC
/// (no bridging layer needed, unlike the SwiftUI version's HotwireView).
@MainActor
final class TabbedNavigator: UITabBarController, UITabBarControllerDelegate {
    private let logger = Logger(subsystem: "com.example.dynamictabbar", category: "TabbedNavigator")
    private let tabManager: TabManager
    private let store: NavigatorStore
    private var notificationObserver: NSObjectProtocol?

    init(tabManager: TabManager, baseURL: URL) {
        self.tabManager = tabManager

        let bootstrapUuid = tabManager.tabs[0].uuid
        let initialNavigator = Navigator(configuration: .init(name: "main", startLocation: baseURL))

        self.store = NavigatorStore(
            baseURL: baseURL,
            bootstrapUuid: bootstrapUuid,
            bootstrapNavigator: initialNavigator
        )

        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        delegate = self

        // Subscribe to tab configuration changes from NavigationComponent
        notificationObserver = NotificationCenter.default.addObserver(
            forName: .tabConfigurationDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                self?.handleTabConfigurationDidChange(notification)
            }
        }

        // Apply initial bootstrap state
        applyTabState()
    }

    deinit {
        if let observer = notificationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Notification Handling

    private func handleTabConfigurationDidChange(_ notification: Notification) {
        guard let directive = notification.userInfo?["directive"] as? TabsDirective else { return }

        let previousUuids = Set(tabManager.tabs.map { $0.uuid })
        tabManager.accept(directive)
        gcRemovedNavigators(previousUuids: previousUuids)
        applyTabState()
    }

    // MARK: - UITabBarControllerDelegate

    func tabBarController(_ tabBarController: UITabBarController, didSelect viewController: UIViewController) {
        guard let index = viewControllers?.firstIndex(of: viewController),
              index < tabManager.tabs.count else { return }

        let previousUuids = Set(tabManager.tabs.map { $0.uuid })
        tabManager.selectTab(uuid: tabManager.tabs[index].uuid)
        gcRemovedNavigators(previousUuids: previousUuids)
        applyTabState()
    }

    // MARK: - State Application

    /// Reads tabManager state and updates UITabBarController to match.
    /// Mirrors SwiftUI's diff-by-identity: structural changes (add/remove/reorder)
    /// go through setViewControllers; property changes (title/icon) update in-place.
    private func applyTabState() {
        let tabs = tabManager.tabs
        let currentVCs = viewControllers ?? []

        // Build desired VC list from navigator store
        let desiredVCs: [UIViewController] = tabs.map { tab in
            store.navigator(for: tab).rootViewController
        }

        // Structural change: only call setViewControllers when the VC list
        // identity changes (tab added, removed, or reordered).
        if !vcListsMatch(currentVCs, desiredVCs) {
            setViewControllers(desiredVCs, animated: false)
        }

        // Surgical update: modify existing tabBarItem properties in-place.
        for (tab, vc) in zip(tabs, desiredVCs) {
            vc.tabBarItem.title = tab.title
            vc.tabBarItem.image = UIImage(systemName: tab.icon)
        }

        // Sync selection and start the selected navigator.
        // Non-selected navigators start lazily on first selection,
        // matching HotwireTabBarController's pattern.
        if let selectedIndex = tabs.firstIndex(where: { $0.uuid == tabManager.selectedUuid }) {
            self.selectedIndex = selectedIndex
            store.navigator(for: tabs[selectedIndex]).start()
        }

        tabBar.isHidden = tabManager.isBootstrap
    }

    private func vcListsMatch(_ a: [UIViewController], _ b: [UIViewController]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { $0 === $1 }
    }

    // MARK: - Garbage Collection

    /// Clean up navigators for tabs that were removed during reconciliation.
    private func gcRemovedNavigators(previousUuids: Set<UUID>) {
        let currentUuids = Set(tabManager.tabs.map { $0.uuid })
        let removedUuids = previousUuids.subtracting(currentUuids)
        guard !removedUuids.isEmpty else { return }
        store.remove(uuids: removedUuids)
    }
}
