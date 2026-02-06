//
//  TabManager.swift
//  DynamicTabBar
//
//  Server-driven tab navigation reconciliation
//  Handles 11 cases of tab transitions while preserving active navigator,
//  plus graceful tab removal via deprecated/replaces extensions.
//

import Foundation
import Combine
import os.log

// MARK: - Types

/// Server's representation of a tab
struct TabData: Codable, Hashable {
    let id: String       // Server ID
    let title: String
    let icon: String
    let path: String
    var deprecated: String? = nil  // "soft" or "hard" (nil = not deprecated)
    var replaces: String? = nil    // ID of deprecated tab this one replaces
}

/// Server directive for tab configuration
enum TabsDirective: Equatable {
    case bootstrap                              // No tabs, hidden tab bar
    case tabbed(active: String, tabs: [TabData]) // Multiple tabs, visible tab bar

    var tabs: [TabData] {
        switch self {
        case .bootstrap:
            return []
        case .tabbed(_, let tabs):
            return tabs
        }
    }
}

/// Client's internal representation of a tab
struct TabItem: Identifiable, Equatable {
    let uuid: UUID                  // Client-side stable ID
    var serverId: String           // Server's ID (empty for bootstrap)
    var title: String
    var icon: String
    var path: String

    var id: UUID { uuid }
}

extension TabData {
    func toTabItem(uuid: UUID = UUID()) -> TabItem {
        TabItem(uuid: uuid, serverId: id, title: title, icon: icon, path: path)
    }
}

// MARK: - TabManager

/// Manages tab state and reconciliation with server directives
///
/// Core principle: The active navigator must survive all transitions.
/// Everything else is just bookkeeping.
@MainActor
final class TabManager: ObservableObject {
    private let logger = Logger(subsystem: "com.example.dynamictabbar", category: "TabManager")

    @Published private(set) var tabs: [TabItem] = []
    @Published private(set) var selectedUuid: UUID = UUID()

    /// Tracks deprecated tabs that are still visible, keyed by server ID.
    /// Stores the deprecation level and optional replacement TabData.
    private(set) var deprecationInfo: [String: DeprecationEntry] = [:]

    struct DeprecationEntry {
        let level: String        // "soft" or "hard"
        let replacement: TabData? // Tab to show when this one is removed
    }

    /// Whether currently in bootstrap mode (single tab, no tab bar)
    var isBootstrap: Bool {
        tabs.count == 1
    }

    /// Active tab (always exists - tabs is never empty)
    var activeTab: TabItem {
        tabs.first { $0.uuid == selectedUuid }!
    }

    // MARK: - Initialization

    init() {
        let uuid = UUID()
        self.tabs = [
            TabItem(uuid: uuid, serverId: "", title: "Bootstrap", icon: "", path: "/")
        ]
        self.selectedUuid = uuid
        logger.info("TabManager initialized in bootstrap mode")
    }

    // MARK: - Public API

    /// Select a tab by server ID (user interaction)
    func selectTab(serverId: String) {
        guard let tab = tabs.first(where: { $0.serverId == serverId }) else { return }
        let previousTab = activeTab
        selectedUuid = tab.uuid
        logger.info("User selected tab: \(serverId)")

        if tab.uuid != previousTab.uuid {
            handleHardDeprecationOnSwitch(previousServerId: previousTab.serverId)
        }
    }

    /// Select a tab by UUID (for SwiftUI TabView binding)
    func selectTab(uuid: UUID) {
        guard tabs.contains(where: { $0.uuid == uuid }) else { return }
        let previousTab = activeTab
        selectedUuid = uuid

        if uuid != previousTab.uuid {
            handleHardDeprecationOnSwitch(previousServerId: previousTab.serverId)
        }
    }

    /// Accept a directive from the server and reconcile tabs
    func accept(_ directive: TabsDirective) {
        let wantsBootstrap = directive.tabs.isEmpty
        let isCurrentlyBootstrap = isBootstrap

        logger.info("Received directive: \(wantsBootstrap ? "Bootstrap" : "Tabbed(\(directive.tabs.count))")")

        // Case 1: Bootstrap → Bootstrap
        if isCurrentlyBootstrap && wantsBootstrap {
            deprecationInfo.removeAll()
            logger.info("  Case 1: Bootstrap → Bootstrap (no-op)")
            return
        }

        // Case 2: Bootstrap → Tabbed
        if isCurrentlyBootstrap && !wantsBootstrap {
            logger.info("  Case 2: Bootstrap → Tabbed")
            guard case .tabbed(let active, let tabsData) = directive else { return }
            let (filtered, effectiveActive) = filterForDeprecation(allTabs: tabsData, serverActive: active)
            upgradeToTabs(active: effectiveActive, tabs: filtered)
            return
        }

        // Case 3: Tabbed → Bootstrap
        if !isCurrentlyBootstrap && wantsBootstrap {
            logger.info("  Case 3: Tabbed → Bootstrap")
            deprecationInfo.removeAll()
            downgradeToBootstrap()
            return
        }

        // Both tabbed - filter for deprecation, then reconcile (Cases 4-11)
        guard case .tabbed(let active, let tabsData) = directive else { return }
        let (filtered, effectiveActive) = filterForDeprecation(allTabs: tabsData, serverActive: active)

        if filtered.isEmpty {
            downgradeToBootstrap()
            return
        }

        reconcileTabs(active: effectiveActive, tabs: filtered)
    }

    // MARK: - Deprecation Filtering

    /// Pre-processes tabs from the server directive, applying deprecated/replaces logic.
    ///
    /// - In bootstrap → tabbed: deprecated tabs are excluded, replacements shown
    /// - In tabbed → tabbed:
    ///   - Soft-deprecated tabs already visible are kept; their replacements hidden
    ///   - Hard-deprecated tabs already visible are kept only if user is on them
    ///   - Deprecated tabs not yet visible are excluded; their replacements shown
    ///
    /// Also populates `deprecationInfo` for tabs that remain visible despite deprecation.
    private func filterForDeprecation(allTabs: [TabData], serverActive: String) -> (tabs: [TabData], active: String) {
        let currentIds = Set(tabs.map { $0.serverId })

        // Build replacement map: deprecatedId → replacement TabData
        let replacementsByDeprecated: [String: TabData] = Dictionary(
            uniqueKeysWithValues: allTabs.compactMap { tab in
                tab.replaces.map { ($0, tab) }
            }
        )

        // Pass 1: Decide which deprecated tabs to keep
        var keptDeprecatedIds = Set<String>()

        for tab in allTabs {
            guard let deprecation = tab.deprecated else { continue }

            if currentIds.contains(tab.id) {
                // Tab is already visible
                switch deprecation {
                case "soft":
                    keptDeprecatedIds.insert(tab.id)
                case "hard":
                    if activeTab.serverId == tab.id {
                        // User is currently on this tab — keep it
                        keptDeprecatedIds.insert(tab.id)
                    }
                    // else: user is not on it — don't keep, remove immediately
                default:
                    break
                }
            }
            // else: tab not currently visible — don't add deprecated tabs
        }

        // Pass 2: Build filtered list + update deprecation tracking
        var result: [TabData] = []
        deprecationInfo.removeAll()

        for tab in allTabs {
            if tab.deprecated != nil {
                if keptDeprecatedIds.contains(tab.id) {
                    result.append(tab)
                    deprecationInfo[tab.id] = DeprecationEntry(
                        level: tab.deprecated!,
                        replacement: replacementsByDeprecated[tab.id]
                    )
                }
                // else: deprecated tab filtered out
            } else if let replacesId = tab.replaces {
                if keptDeprecatedIds.contains(replacesId) {
                    // Deprecated tab still visible — hide its replacement
                } else {
                    // Deprecated tab gone — show replacement
                    result.append(tab)
                }
            } else {
                // Normal tab
                result.append(tab)
            }
        }

        // Adjust active if the server's active was filtered out
        let effectiveActive: String
        if result.contains(where: { $0.id == serverActive }) {
            effectiveActive = serverActive
        } else {
            effectiveActive = result.first?.id ?? serverActive
        }

        return (result, effectiveActive)
    }

    /// When the user switches away from a hard-deprecated tab, remove it
    /// and insert its replacement (if any) at the same position.
    private func handleHardDeprecationOnSwitch(previousServerId: String) {
        guard let info = deprecationInfo[previousServerId], info.level == "hard" else { return }
        guard let deprecatedIndex = tabs.firstIndex(where: { $0.serverId == previousServerId }) else { return }

        var newTabs = tabs
        newTabs.remove(at: deprecatedIndex)

        if let replacement = info.replacement {
            newTabs.insert(replacement.toTabItem(), at: min(deprecatedIndex, newTabs.count))
        }

        self.tabs = newTabs
        deprecationInfo.removeValue(forKey: previousServerId)

        logger.info("Hard-deprecated tab '\(previousServerId)' removed on tab switch")
    }

    // MARK: - Private Implementation

    /// Case 2: Bootstrap → Tabbed
    /// Promote bootstrap navigator to server's active tab
    private func upgradeToTabs(active: String, tabs tabsData: [TabData]) {
        let bootstrapUuid = self.tabs[0].uuid

        self.tabs = tabsData.map { data in
            data.toTabItem(uuid: data.id == active ? bootstrapUuid : UUID())
        }
        self.selectedUuid = bootstrapUuid

        logger.info("Upgraded to \(self.tabs.count) tabs, active: \(active), preserved bootstrap UUID")
    }

    /// Case 3: Tabbed → Bootstrap
    /// Keep active navigator UUID, demote to single bootstrap tab
    private func downgradeToBootstrap() {
        let active = activeTab

        self.tabs = [
            TabItem(uuid: active.uuid, serverId: "", title: "Bootstrap", icon: "", path: active.path)
        ]

        logger.info("Downgraded to bootstrap, preserved UUID from: \(active.serverId)")
    }

    /// Cases 4-11: Tabbed → Tabbed reconciliation
    private func reconcileTabs(active: String, tabs tabsData: [TabData]) {
        let currentIds = Set(tabs.map { $0.serverId })
        let targetIds = Set(tabsData.map { $0.id })

        // Quick check for changes
        let added = tabsData.contains { !currentIds.contains($0.id) }
        let removed = tabs.contains { !targetIds.contains($0.serverId) }

        // Case 4 & 6: No change or ordering change (both ignored)
        if !added && !removed {
            let sameOrder = tabs.enumerated().allSatisfy { index, tab in
                index < tabsData.count && tabsData[index].id == tab.serverId
            }
            logger.info("\(sameOrder ? "  Case 4: No change (no-op)" : "  Case 6: Ordering changed (ignored)")")
            return
        }

        // Log what type of change
        if added && !removed {
            logger.info("  Case 7: Tabs added (adopt server ordering)")
        } else if removed && !added {
            logger.info("  Case 8: Tabs removed (adopt server ordering)")
        } else {
            logger.info("  Case 10/11: Tabs replaced (adopt server ordering)")
        }

        // Check if active tab needs morphing (Case 9)
        let activeTab = self.activeTab
        let activeStillExists = targetIds.contains(activeTab.serverId)

        if !activeStillExists {
            logger.info("  Case 9: Active tab removed (morphing)")
            morphAndReconcile(active: active, tabs: tabsData)
        } else {
            simpleReconcile(tabs: tabsData)
        }
    }

    /// Case 9: Active tab removed - morph it into server's active tab
    private func morphAndReconcile(active: String, tabs tabsData: [TabData]) {
        let activeTab = self.activeTab

        // Build map of existing tabs (excluding the active one — its UUID will be reassigned)
        let existingByServerId = Dictionary(
            uniqueKeysWithValues: tabs
                .filter { $0.uuid != activeTab.uuid }
                .map { ($0.serverId, $0) }
        )

        self.tabs = tabsData.map { data in
            if data.id == active {
                return data.toTabItem(uuid: activeTab.uuid)
            }
            return data.toTabItem(uuid: existingByServerId[data.id]?.uuid ?? UUID())
        }

        logger.info("Morphed '\(activeTab.serverId)' → '\(active)', UUID preserved")
    }

    /// Cases 7, 8, 10: Simple reconciliation (active tab still exists)
    private func simpleReconcile(tabs tabsData: [TabData]) {
        let existingByServerId = Dictionary(
            uniqueKeysWithValues: tabs.map { ($0.serverId, $0) }
        )

        self.tabs = tabsData.map { data in
            data.toTabItem(uuid: existingByServerId[data.id]?.uuid ?? UUID())
        }

        logger.info("Reconciled to \(self.tabs.count) tabs, active preserved")
    }
}
