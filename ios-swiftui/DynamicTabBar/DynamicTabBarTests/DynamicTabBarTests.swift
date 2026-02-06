//
//  DynamicTabBarTests.swift
//  DynamicTabBarTests
//
//  Unit tests for TabManager reconciliation algorithm
//  Tests all 11 cases of tab transitions
//  Using Swift Testing framework
//

import Testing
@testable import DynamicTabBar

@Suite("TabManager Reconciliation")
@MainActor
struct TabManagerTests {

    // MARK: - Test Case 1: Bootstrap → Bootstrap

    @Test("Case 1: Bootstrap to Bootstrap (no-op)")
    func bootstrapToBootstrap() {
        let manager = TabManager()

        #expect(manager.tabs.count == 1)
        #expect(manager.isBootstrap)
        let initialUuid = manager.tabs[0].uuid

        // When: Send bootstrap directive again
        manager.accept(.bootstrap)

        // Then: No change, UUID preserved
        #expect(manager.tabs.count == 1)
        #expect(manager.isBootstrap)
        #expect(manager.tabs[0].uuid == initialUuid)
    }

    // MARK: - Test Case 2: Bootstrap → Tabbed (A Active)

    @Test("Case 2: Bootstrap to Tabbed with first tab active")
    func bootstrapToTabbedFirstActive() {
        let manager = TabManager()
        let bootstrapUuid = manager.tabs[0].uuid

        // When: Upgrade to 5 tabs with A active
        let directive = TabsDirective.tabbed(
            active: "A",
            tabs: fiveTabs
        )
        manager.accept(directive)

        // Then: 5 tabs exist, bootstrap UUID promoted to A
        #expect(manager.tabs.count == 5)
        #expect(!manager.isBootstrap)

        let tabA = manager.tabs.first { $0.serverId == "A" }
        #expect(tabA != nil)
        #expect(tabA?.uuid == bootstrapUuid, "Bootstrap container should be promoted to A")
        #expect(manager.selectedUuid == bootstrapUuid, "Tab A should be selected")
    }

    // MARK: - Test Case 2b: Bootstrap → Tabbed (B Active)

    @Test("Case 2b: Bootstrap to Tabbed with non-first tab active")
    func bootstrapToTabbedNonFirstActive() {
        let manager = TabManager()
        let bootstrapUuid = manager.tabs[0].uuid

        // When: Upgrade to 5 tabs with B active
        let directive = TabsDirective.tabbed(
            active: "B",
            tabs: fiveTabs
        )
        manager.accept(directive)

        // Then: Bootstrap UUID promoted to B
        let tabB = manager.tabs.first { $0.serverId == "B" }
        #expect(tabB != nil)
        #expect(tabB?.uuid == bootstrapUuid, "Bootstrap container should be promoted to B")
        #expect(manager.selectedUuid == bootstrapUuid, "Tab B should be selected")
    }

    // MARK: - Test Case 3: Tabbed → Bootstrap

    @Test("Case 3: Tabbed to Bootstrap")
    func tabbedToBootstrap() {
        let manager = TabManager()

        // Given: Manager with 5 tabs, B selected
        upgradeToFiveTabs(manager: manager, active: "B")
        manager.selectTab(serverId: "B")

        let uuidB = manager.tabs.first { $0.serverId == "B" }!.uuid

        // When: Downgrade to bootstrap
        manager.accept(.bootstrap)

        // Then: Single bootstrap tab, B's UUID preserved
        #expect(manager.tabs.count == 1)
        #expect(manager.isBootstrap)
        #expect(manager.tabs[0].uuid == uuidB, "Active container should be preserved as bootstrap")
    }

    // MARK: - Test Case 4: Tabbed → Tabbed (No Change)

    @Test("Case 4: Tabbed with no changes (no-op)")
    func tabbedNoChange() {
        let manager = TabManager()

        // Given: Manager with 5 tabs
        upgradeToFiveTabs(manager: manager, active: "A")
        let uuidsBefore = manager.tabs.map { $0.uuid }

        // When: Send identical directive
        let directive = fiveTabsDirective(active: "A")
        manager.accept(directive)

        // Then: No changes, UUIDs identical
        let uuidsAfter = manager.tabs.map { $0.uuid }
        #expect(uuidsBefore == uuidsAfter, "No UUIDs should change")
    }

    // MARK: - Test Case 5: Tabbed → Tabbed (Active Hint Changed - Ignored)

    @Test("Case 5: Active changed hint ignored (HIG compliance)")
    func activeChangedIgnored() {
        let manager = TabManager()

        // Given: Manager with 5 tabs, A selected
        upgradeToFiveTabs(manager: manager, active: "A")
        let selectedBefore = manager.selectedUuid

        // When: Server wants C active (but we ignore)
        let directive = fiveTabsDirective(active: "C")
        manager.accept(directive)

        // Then: Selection unchanged (HIG compliance)
        #expect(manager.selectedUuid == selectedBefore, "Client selection should be preserved")
    }

    // MARK: - Test Case 6: Tabbed → Tabbed (Ordering Changed - Ignored)

    @Test("Case 6: Ordering changed ignored")
    func orderingChangedIgnored() {
        let manager = TabManager()

        // Given: Manager with 5 tabs
        upgradeToFiveTabs(manager: manager, active: "A")
        let orderBefore = manager.tabs.map { $0.serverId }

        // When: Server reorders tabs
        let directive = TabsDirective.tabbed(
            active: "A",
            tabs: [
                TabData(id: "A", title: "Home", icon: "house.fill", path: "/"),
                TabData(id: "E", title: "Settings", icon: "gearshape.fill", path: "/settings"),
                TabData(id: "D", title: "Activity", icon: "chart.bar.fill", path: "/activity"),
                TabData(id: "C", title: "Search", icon: "magnifyingglass", path: "/search"),
                TabData(id: "B", title: "Explore", icon: "safari.fill", path: "/explore")
            ]
        )
        manager.accept(directive)

        // Then: Ordering unchanged
        let orderAfter = manager.tabs.map { $0.serverId }
        #expect(orderBefore == orderAfter, "Ordering should be ignored during normal navigation")
    }

    // MARK: - Test Case 7: Tabbed → Tabbed (Tabs Added)

    @Test("Case 7: Tabs added (adopts server ordering)")
    func tabsAdded() {
        let manager = TabManager()

        // Given: Manager with 2 tabs
        upgradeToTwoTabs(manager: manager)
        let uuidA = manager.tabs.first { $0.serverId == "A" }!.uuid

        // When: Expand to 5 tabs
        let directive = fiveTabsDirective(active: "A")
        manager.accept(directive)

        // Then: 5 tabs, A's UUID preserved, server ordering adopted
        #expect(manager.tabs.count == 5)
        #expect(manager.tabs.map { $0.serverId } == ["A", "B", "C", "D", "E"])
        #expect(manager.tabs.first { $0.serverId == "A" }?.uuid == uuidA, "Existing tab UUID preserved")
    }

    // MARK: - Test Case 8: Tabbed → Tabbed (Tabs Removed)

    @Test("Case 8: Tabs removed (UUIDs preserved)")
    func tabsRemoved() {
        let manager = TabManager()

        // Given: Manager with 5 tabs
        upgradeToFiveTabs(manager: manager, active: "A")
        let uuidA = manager.tabs.first { $0.serverId == "A" }!.uuid

        // When: Remove to 2 tabs
        let directive = TabsDirective.tabbed(
            active: "A",
            tabs: [
                TabData(id: "A", title: "Home", icon: "house.fill", path: "/"),
                TabData(id: "B", title: "Explore", icon: "safari.fill", path: "/explore")
            ]
        )
        manager.accept(directive)

        // Then: 2 tabs, UUIDs preserved
        #expect(manager.tabs.count == 2)
        #expect(manager.tabs.first { $0.serverId == "A" }?.uuid == uuidA, "Existing tab UUID preserved")
    }

    // MARK: - Test Case 9: Tabbed → Tabbed (Active Tab Removed → Morph)

    @Test("Case 9: Active tab removed (morphing)")
    func activeTabRemoved() {
        let manager = TabManager()

        // Given: Manager with 5 tabs, B selected
        upgradeToFiveTabs(manager: manager, active: "B")
        manager.selectTab(serverId: "B")

        let uuidB = manager.tabs.first { $0.serverId == "B" }!.uuid

        // When: Remove B, server wants A active
        let directive = TabsDirective.tabbed(
            active: "A",
            tabs: [
                TabData(id: "A", title: "Home", icon: "house.fill", path: "/"),
                TabData(id: "C", title: "Search", icon: "magnifyingglass", path: "/search"),
                TabData(id: "D", title: "Activity", icon: "chart.bar.fill", path: "/activity"),
                TabData(id: "E", title: "Settings", icon: "gearshape.fill", path: "/settings")
            ]
        )
        manager.accept(directive)

        // Then: B's UUID morphed into A
        let tabA = manager.tabs.first { $0.serverId == "A" }
        #expect(tabA != nil)
        #expect(tabA?.uuid == uuidB, "Active container should morph into A")
        #expect(manager.selectedUuid == uuidB, "Selection should follow morphed container")
    }

    // MARK: - UUID Stability Test

    @Test("UUID Stability: Verify UUIDs are preserved correctly across all operations")
    func uuidStability() {
        let manager = TabManager()
        let bootstrapUuid = manager.tabs[0].uuid

        // Step 1: Bootstrap → Tabbed (A active)
        manager.accept(fiveTabsDirective(active: "A"))
        let uuidA = manager.tabs.first { $0.serverId == "A" }!.uuid
        let uuidB = manager.tabs.first { $0.serverId == "B" }!.uuid
        let uuidC = manager.tabs.first { $0.serverId == "C" }!.uuid

        #expect(uuidA == bootstrapUuid, "Bootstrap UUID should transfer to A")

        // Step 2: Metadata update (no tab changes) — UUIDs stable
        manager.accept(fiveTabsDirective(active: "A"))
        #expect(manager.tabs.first { $0.serverId == "A" }?.uuid == uuidA, "A UUID stable")
        #expect(manager.tabs.first { $0.serverId == "B" }?.uuid == uuidB, "B UUID stable")
        #expect(manager.tabs.first { $0.serverId == "C" }?.uuid == uuidC, "C UUID stable")

        // Step 3: Remove some tabs — remaining UUIDs preserved
        let directive = TabsDirective.tabbed(
            active: "A",
            tabs: [
                TabData(id: "A", title: "Home", icon: "house.fill", path: "/"),
                TabData(id: "B", title: "Explore", icon: "safari.fill", path: "/explore")
            ]
        )
        manager.accept(directive)
        #expect(manager.tabs.count == 2, "Should have 2 tabs")
        #expect(manager.tabs.first { $0.serverId == "A" }?.uuid == uuidA, "A UUID preserved")
        #expect(manager.tabs.first { $0.serverId == "B" }?.uuid == uuidB, "B UUID preserved")

        // Step 4: Add tabs back — existing UUIDs kept, removed tabs get new UUIDs
        manager.accept(fiveTabsDirective(active: "A"))
        #expect(manager.tabs.first { $0.serverId == "A" }?.uuid == uuidA, "A UUID still preserved")
        #expect(manager.tabs.first { $0.serverId == "B" }?.uuid == uuidB, "B UUID still preserved")

        let newUuidC = manager.tabs.first { $0.serverId == "C" }!.uuid
        #expect(newUuidC != uuidC, "C should have NEW UUID (was removed and re-added)")

        // Step 5: Active tab removed (morphing)
        manager.selectTab(serverId: "B")
        let activeBUuid = manager.tabs.first { $0.serverId == "B" }!.uuid

        let withoutB = TabsDirective.tabbed(
            active: "A",
            tabs: [
                TabData(id: "A", title: "Home", icon: "house.fill", path: "/"),
                TabData(id: "C", title: "Search", icon: "magnifyingglass", path: "/search"),
                TabData(id: "D", title: "Activity", icon: "chart.bar.fill", path: "/activity"),
                TabData(id: "E", title: "Settings", icon: "gearshape.fill", path: "/settings")
            ]
        )
        manager.accept(withoutB)

        let morphedAUuid = manager.tabs.first { $0.serverId == "A" }!.uuid
        #expect(morphedAUuid == activeBUuid, "Active container UUID (B) should morph into A")

        // Step 6: Tabbed → Bootstrap — active tab's UUID transfers
        manager.selectTab(serverId: "C")
        let activeCUuid = manager.tabs.first { $0.serverId == "C" }!.uuid

        manager.accept(.bootstrap)
        #expect(manager.tabs.count == 1, "Should be bootstrap mode")
        #expect(manager.tabs[0].uuid == activeCUuid, "Bootstrap should preserve active container UUID")
    }

    // MARK: - Test Case 5 Again (Server Active Changed)

    @Test("Case 5 again: Server active hint ignored")
    func serverActiveIgnoredAgain() {
        let manager = TabManager()

        // Given: Manager with 5 tabs, A selected
        upgradeToFiveTabs(manager: manager, active: "A")
        let uuidA = manager.tabs.first { $0.serverId == "A" }!.uuid
        #expect(manager.selectedUuid == uuidA)

        // When: Server directive has different active (but no tab changes)
        let directive = fiveTabsDirective(active: "B")
        manager.accept(directive)

        // Then: Client selection unchanged
        #expect(manager.selectedUuid == uuidA, "User's selection should be preserved")
    }

    // MARK: - Tab Data Fixtures

    private let fiveTabs: [TabData] = [
        TabData(id: "A", title: "Home", icon: "house.fill", path: "/"),
        TabData(id: "B", title: "Explore", icon: "safari.fill", path: "/explore"),
        TabData(id: "C", title: "Search", icon: "magnifyingglass", path: "/search"),
        TabData(id: "D", title: "Activity", icon: "chart.bar.fill", path: "/activity"),
        TabData(id: "E", title: "Settings", icon: "gearshape.fill", path: "/settings")
    ]

    // MARK: - Helper Methods

    private func upgradeToFiveTabs(manager: TabManager, active: String) {
        let directive = fiveTabsDirective(active: active)
        manager.accept(directive)
    }

    private func upgradeToTwoTabs(manager: TabManager) {
        let directive = TabsDirective.tabbed(
            active: "A",
            tabs: [
                TabData(id: "A", title: "Home", icon: "house.fill", path: "/"),
                TabData(id: "B", title: "Explore", icon: "safari.fill", path: "/explore")
            ]
        )
        manager.accept(directive)
    }

    private func fiveTabsDirective(active: String) -> TabsDirective {
        return .tabbed(active: active, tabs: fiveTabs)
    }
}

// MARK: - Deprecation Tests

@Suite("Graceful Tab Removal (deprecated/replaces)")
@MainActor
struct DeprecationTests {

    // MARK: - Fixtures

    /// Standard 4-tab layout: Home, Explore, Library, Profile
    private let fourTabs: [TabData] = [
        TabData(id: "home", title: "Home", icon: "house.fill", path: "/"),
        TabData(id: "explore", title: "Explore", icon: "magnifyingglass", path: "/explore"),
        TabData(id: "library", title: "Library", icon: "books.vertical", path: "/library"),
        TabData(id: "profile", title: "Profile", icon: "person.crop.circle", path: "/profile")
    ]

    /// Directive with Explore soft-deprecated and Favorites replacing it
    private var softDeprecationDirective: TabsDirective {
        .tabbed(active: "home", tabs: [
            TabData(id: "home", title: "Home", icon: "house.fill", path: "/"),
            TabData(id: "explore", title: "Explore", icon: "magnifyingglass", path: "/explore", deprecated: "soft"),
            TabData(id: "favorites", title: "Favorites", icon: "heart.fill", path: "/favorites", replaces: "explore"),
            TabData(id: "library", title: "Library", icon: "books.vertical", path: "/library"),
            TabData(id: "profile", title: "Profile", icon: "person.crop.circle", path: "/profile")
        ])
    }

    /// Directive with Explore hard-deprecated and Favorites replacing it
    private var hardDeprecationDirective: TabsDirective {
        .tabbed(active: "home", tabs: [
            TabData(id: "home", title: "Home", icon: "house.fill", path: "/"),
            TabData(id: "explore", title: "Explore", icon: "magnifyingglass", path: "/explore", deprecated: "hard"),
            TabData(id: "favorites", title: "Favorites", icon: "heart.fill", path: "/favorites", replaces: "explore"),
            TabData(id: "library", title: "Library", icon: "books.vertical", path: "/library"),
            TabData(id: "profile", title: "Profile", icon: "person.crop.circle", path: "/profile")
        ])
    }

    private func upgradeToFourTabs(manager: TabManager, active: String) {
        manager.accept(.tabbed(active: active, tabs: fourTabs))
    }

    // MARK: - Bootstrap → Tabbed with Deprecation

    @Test("Fresh bootstrap skips deprecated tabs and shows replacements")
    func bootstrapSkipsDeprecated() {
        let manager = TabManager()

        // When: Bootstrap → Tabbed with deprecated Explore and replacement Favorites
        manager.accept(softDeprecationDirective)

        // Then: 4 tabs shown (Home, Favorites, Library, Profile) — Explore skipped
        #expect(manager.tabs.count == 4)
        let ids = manager.tabs.map { $0.serverId }
        #expect(ids == ["home", "favorites", "library", "profile"])
        #expect(!ids.contains("explore"), "Deprecated Explore should not appear on fresh bootstrap")
    }

    // MARK: - Soft Deprecation

    @Test("Soft-deprecated tab kept when already visible")
    func softDeprecatedKept() {
        let manager = TabManager()

        // Given: Already showing 4 tabs including Explore
        upgradeToFourTabs(manager: manager, active: "home")
        #expect(manager.tabs.map { $0.serverId } == ["home", "explore", "library", "profile"])
        let exploreUuid = manager.tabs.first { $0.serverId == "explore" }!.uuid

        // When: Receive directive with Explore soft-deprecated
        manager.accept(softDeprecationDirective)

        // Then: Explore still visible, Favorites hidden, UUID preserved
        let ids = manager.tabs.map { $0.serverId }
        #expect(ids == ["home", "explore", "library", "profile"])
        #expect(!ids.contains("favorites"), "Replacement should be hidden while deprecated tab is visible")
        #expect(manager.tabs.first { $0.serverId == "explore" }?.uuid == exploreUuid, "UUID preserved")
        #expect(manager.deprecationInfo["explore"] != nil, "Deprecation info tracked")
        #expect(manager.deprecationInfo["explore"]?.level == "soft")
    }

    @Test("Soft-deprecated tab survives across repeated directives")
    func softDeprecatedSurvivesRepeats() {
        let manager = TabManager()

        // Given: Already showing Explore
        upgradeToFourTabs(manager: manager, active: "home")

        // When: Send soft-deprecation directive multiple times
        manager.accept(softDeprecationDirective)
        manager.accept(softDeprecationDirective)
        manager.accept(softDeprecationDirective)

        // Then: Explore still visible
        let ids = manager.tabs.map { $0.serverId }
        #expect(ids.contains("explore"), "Soft-deprecated tab should survive repeated directives")
        #expect(!ids.contains("favorites"))
    }

    @Test("Soft-deprecated tab removed on next bootstrap→tabbed transition")
    func softDeprecatedRemovedOnBootstrapCycle() {
        let manager = TabManager()

        // Given: Explore is soft-deprecated but still visible
        upgradeToFourTabs(manager: manager, active: "home")
        manager.accept(softDeprecationDirective)
        #expect(manager.tabs.map { $0.serverId }.contains("explore"))

        // When: Go through bootstrap cycle (sign out → sign in)
        manager.accept(.bootstrap)
        manager.accept(softDeprecationDirective)

        // Then: Explore removed, Favorites shown
        let ids = manager.tabs.map { $0.serverId }
        #expect(!ids.contains("explore"), "Soft-deprecated tab removed after bootstrap cycle")
        #expect(ids.contains("favorites"), "Replacement shown after bootstrap cycle")
        #expect(ids == ["home", "favorites", "library", "profile"])
    }

    // MARK: - Hard Deprecation

    @Test("Hard-deprecated tab removed immediately when user is NOT on it")
    func hardDeprecatedRemovedImmediately() {
        let manager = TabManager()

        // Given: Showing 4 tabs, user on Home (not Explore)
        upgradeToFourTabs(manager: manager, active: "home")

        // When: Receive directive with Explore hard-deprecated
        manager.accept(hardDeprecationDirective)

        // Then: Explore removed immediately, Favorites shown
        let ids = manager.tabs.map { $0.serverId }
        #expect(!ids.contains("explore"), "Hard-deprecated tab removed when user is not on it")
        #expect(ids.contains("favorites"), "Replacement shown immediately")
        #expect(ids == ["home", "favorites", "library", "profile"])
    }

    @Test("Hard-deprecated tab kept when user IS on it")
    func hardDeprecatedKeptWhenActive() {
        let manager = TabManager()

        // Given: Showing 4 tabs, user on Explore
        upgradeToFourTabs(manager: manager, active: "explore")
        manager.selectTab(serverId: "explore")

        // When: Receive directive with Explore hard-deprecated
        manager.accept(hardDeprecationDirective)

        // Then: Explore still visible (user is on it), Favorites hidden
        let ids = manager.tabs.map { $0.serverId }
        #expect(ids.contains("explore"), "Hard-deprecated tab kept while user is on it")
        #expect(!ids.contains("favorites"), "Replacement hidden while deprecated tab is active")
        #expect(manager.deprecationInfo["explore"]?.level == "hard")
    }

    @Test("Hard-deprecated tab removed when user switches away")
    func hardDeprecatedRemovedOnSwitch() {
        let manager = TabManager()

        // Given: User is on hard-deprecated Explore
        upgradeToFourTabs(manager: manager, active: "explore")
        manager.selectTab(serverId: "explore")
        manager.accept(hardDeprecationDirective)
        #expect(manager.tabs.map { $0.serverId }.contains("explore"))

        // When: User switches to Home
        manager.selectTab(serverId: "home")

        // Then: Explore removed, Favorites appears in its place
        let ids = manager.tabs.map { $0.serverId }
        #expect(!ids.contains("explore"), "Hard-deprecated tab removed on switch")
        #expect(ids.contains("favorites"), "Replacement inserted at deprecated tab's position")
        #expect(manager.deprecationInfo["explore"] == nil, "Deprecation info cleared")
    }

    // MARK: - Tab Count Stability

    @Test("Tab count stays stable through deprecation cycle")
    func tabCountStability() {
        let manager = TabManager()

        // Start with 4 tabs
        upgradeToFourTabs(manager: manager, active: "home")
        #expect(manager.tabs.count == 4)

        // Soft-deprecate Explore: still 4 tabs (Explore kept, Favorites hidden)
        manager.accept(softDeprecationDirective)
        #expect(manager.tabs.count == 4, "Count stable during soft deprecation")

        // Bootstrap cycle: still 4 tabs (Explore gone, Favorites shown)
        manager.accept(.bootstrap)
        manager.accept(softDeprecationDirective)
        #expect(manager.tabs.count == 4, "Count stable after deprecation resolved")
    }

    // MARK: - Deprecated Without Replacement

    @Test("Deprecated tab without replacement is handled correctly")
    func deprecatedWithoutReplacement() {
        let manager = TabManager()

        // Given: 4 tabs, user on Home
        upgradeToFourTabs(manager: manager, active: "home")

        // When: Explore hard-deprecated with no replacement
        let directive = TabsDirective.tabbed(active: "home", tabs: [
            TabData(id: "home", title: "Home", icon: "house.fill", path: "/"),
            TabData(id: "explore", title: "Explore", icon: "magnifyingglass", path: "/explore", deprecated: "hard"),
            TabData(id: "library", title: "Library", icon: "books.vertical", path: "/library"),
            TabData(id: "profile", title: "Profile", icon: "person.crop.circle", path: "/profile")
        ])
        manager.accept(directive)

        // Then: Explore removed, 3 tabs remain
        let ids = manager.tabs.map { $0.serverId }
        #expect(!ids.contains("explore"))
        #expect(ids == ["home", "library", "profile"])
        #expect(manager.tabs.count == 3)
    }

    // MARK: - Bootstrap Clears Deprecation State

    @Test("Bootstrap transition clears deprecation tracking")
    func bootstrapClearsDeprecation() {
        let manager = TabManager()

        // Given: Explore is soft-deprecated and tracked
        upgradeToFourTabs(manager: manager, active: "home")
        manager.accept(softDeprecationDirective)
        #expect(!manager.deprecationInfo.isEmpty)

        // When: Downgrade to bootstrap
        manager.accept(.bootstrap)

        // Then: Deprecation state cleared
        #expect(manager.deprecationInfo.isEmpty, "Bootstrap should clear deprecation tracking")
    }
}
