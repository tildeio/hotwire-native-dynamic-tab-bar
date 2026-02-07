package io.tilde.dynamictabbar

import org.junit.Assert.*
import org.junit.Test

/**
 * Unit tests for TabManager reconciliation algorithm.
 * Tests all 11 cases of tab transitions (12 tests)
 * plus 10 deprecation tests = 22 total.
 *
 * Ported from Swift Testing (DynamicTabBarTests.swift).
 */
class TabManagerReconciliationTest {

    // MARK: - Fixtures

    private val fiveTabs = listOf(
        TabData(id = "A", title = "Home", icon = "house.fill", path = "/"),
        TabData(id = "B", title = "Explore", icon = "safari.fill", path = "/explore"),
        TabData(id = "C", title = "Search", icon = "magnifyingglass", path = "/search"),
        TabData(id = "D", title = "Activity", icon = "chart.bar.fill", path = "/activity"),
        TabData(id = "E", title = "Settings", icon = "gearshape.fill", path = "/settings")
    )

    private fun fiveTabsDirective(active: String) =
        TabsDirective.Tabbed(active = active, tabs = fiveTabs)

    private fun upgradeToFiveTabs(manager: TabManager, active: String) {
        manager.accept(fiveTabsDirective(active))
    }

    private fun upgradeToTwoTabs(manager: TabManager) {
        manager.accept(TabsDirective.Tabbed(
            active = "A",
            tabs = listOf(
                TabData(id = "A", title = "Home", icon = "house.fill", path = "/"),
                TabData(id = "B", title = "Explore", icon = "safari.fill", path = "/explore")
            )
        ))
    }

    // MARK: - Test Case 1: Bootstrap → Bootstrap

    @Test
    fun `Case 1 - Bootstrap to Bootstrap (no-op)`() {
        val manager = TabManager()

        assertEquals(1, manager.tabs.size)
        assertTrue(manager.isBootstrap)
        val initialId = manager.tabs[0].id

        // When: Send bootstrap directive again
        manager.accept(TabsDirective.Bootstrap)

        // Then: No change, ID preserved
        assertEquals(1, manager.tabs.size)
        assertTrue(manager.isBootstrap)
        assertEquals(initialId, manager.tabs[0].id)
    }

    // MARK: - Test Case 2: Bootstrap → Tabbed (A Active)

    @Test
    fun `Case 2 - Bootstrap to Tabbed with first tab active`() {
        val manager = TabManager()
        val bootstrapId = manager.tabs[0].id

        // When: Upgrade to 5 tabs with A active
        manager.accept(fiveTabsDirective("A"))

        // Then: 5 tabs exist, bootstrap ID promoted to A
        assertEquals(5, manager.tabs.size)
        assertFalse(manager.isBootstrap)

        val tabA = manager.tabs.first { it.serverId == "A" }
        assertEquals("Bootstrap container should be promoted to A", bootstrapId, tabA.id)
        assertEquals("Tab A should be selected", bootstrapId, manager.selectedId)
    }

    // MARK: - Test Case 2b: Bootstrap → Tabbed (B Active)

    @Test
    fun `Case 2b - Bootstrap to Tabbed with non-first tab active`() {
        val manager = TabManager()
        val bootstrapId = manager.tabs[0].id

        // When: Upgrade to 5 tabs with B active
        manager.accept(fiveTabsDirective("B"))

        // Then: Bootstrap ID promoted to B
        val tabB = manager.tabs.first { it.serverId == "B" }
        assertEquals("Bootstrap container should be promoted to B", bootstrapId, tabB.id)
        assertEquals("Tab B should be selected", bootstrapId, manager.selectedId)
    }

    // MARK: - Test Case 3: Tabbed → Bootstrap

    @Test
    fun `Case 3 - Tabbed to Bootstrap`() {
        val manager = TabManager()

        // Given: Manager with 5 tabs, B selected
        upgradeToFiveTabs(manager, "B")
        manager.selectTab(serverId = "B")

        val idB = manager.tabs.first { it.serverId == "B" }.id

        // When: Downgrade to bootstrap
        manager.accept(TabsDirective.Bootstrap)

        // Then: Single bootstrap tab, B's ID preserved
        assertEquals(1, manager.tabs.size)
        assertTrue(manager.isBootstrap)
        assertEquals("Active container should be preserved as bootstrap", idB, manager.tabs[0].id)
    }

    // MARK: - Test Case 4: Tabbed → Tabbed (No Change)

    @Test
    fun `Case 4 - Tabbed with no changes (no-op)`() {
        val manager = TabManager()

        // Given: Manager with 5 tabs
        upgradeToFiveTabs(manager, "A")
        val idsBefore = manager.tabs.map { it.id }

        // When: Send identical directive
        manager.accept(fiveTabsDirective("A"))

        // Then: No changes, IDs identical
        val idsAfter = manager.tabs.map { it.id }
        assertEquals("No IDs should change", idsBefore, idsAfter)
    }

    // MARK: - Test Case 5: Tabbed → Tabbed (Active Hint Changed - Ignored)

    @Test
    fun `Case 5 - Active changed hint ignored (HIG compliance)`() {
        val manager = TabManager()

        // Given: Manager with 5 tabs, A selected
        upgradeToFiveTabs(manager, "A")
        val selectedBefore = manager.selectedId

        // When: Server wants C active (but we ignore)
        manager.accept(fiveTabsDirective("C"))

        // Then: Selection unchanged (HIG compliance)
        assertEquals("Client selection should be preserved", selectedBefore, manager.selectedId)
    }

    // MARK: - Test Case 6: Tabbed → Tabbed (Ordering Changed - Ignored)

    @Test
    fun `Case 6 - Ordering changed ignored`() {
        val manager = TabManager()

        // Given: Manager with 5 tabs
        upgradeToFiveTabs(manager, "A")
        val orderBefore = manager.tabs.map { it.serverId }

        // When: Server reorders tabs
        manager.accept(TabsDirective.Tabbed(
            active = "A",
            tabs = listOf(
                TabData(id = "A", title = "Home", icon = "house.fill", path = "/"),
                TabData(id = "E", title = "Settings", icon = "gearshape.fill", path = "/settings"),
                TabData(id = "D", title = "Activity", icon = "chart.bar.fill", path = "/activity"),
                TabData(id = "C", title = "Search", icon = "magnifyingglass", path = "/search"),
                TabData(id = "B", title = "Explore", icon = "safari.fill", path = "/explore")
            )
        ))

        // Then: Ordering unchanged
        val orderAfter = manager.tabs.map { it.serverId }
        assertEquals("Ordering should be ignored during normal navigation", orderBefore, orderAfter)
    }

    // MARK: - Test Case 7: Tabbed → Tabbed (Tabs Added)

    @Test
    fun `Case 7 - Tabs added (adopts server ordering)`() {
        val manager = TabManager()

        // Given: Manager with 2 tabs
        upgradeToTwoTabs(manager)
        val idA = manager.tabs.first { it.serverId == "A" }.id

        // When: Expand to 5 tabs
        manager.accept(fiveTabsDirective("A"))

        // Then: 5 tabs, A's ID preserved, server ordering adopted
        assertEquals(5, manager.tabs.size)
        assertEquals(listOf("A", "B", "C", "D", "E"), manager.tabs.map { it.serverId })
        assertEquals("Existing tab ID preserved", idA, manager.tabs.first { it.serverId == "A" }.id)
    }

    // MARK: - Test Case 8: Tabbed → Tabbed (Tabs Removed)

    @Test
    fun `Case 8 - Tabs removed (IDs preserved)`() {
        val manager = TabManager()

        // Given: Manager with 5 tabs
        upgradeToFiveTabs(manager, "A")
        val idA = manager.tabs.first { it.serverId == "A" }.id

        // When: Remove to 2 tabs
        manager.accept(TabsDirective.Tabbed(
            active = "A",
            tabs = listOf(
                TabData(id = "A", title = "Home", icon = "house.fill", path = "/"),
                TabData(id = "B", title = "Explore", icon = "safari.fill", path = "/explore")
            )
        ))

        // Then: 2 tabs, IDs preserved
        assertEquals(2, manager.tabs.size)
        assertEquals("Existing tab ID preserved", idA, manager.tabs.first { it.serverId == "A" }.id)
    }

    // MARK: - Test Case 9: Tabbed → Tabbed (Active Tab Removed → Morph)

    @Test
    fun `Case 9 - Active tab removed (morphing)`() {
        val manager = TabManager()

        // Given: Manager with 5 tabs, B selected
        upgradeToFiveTabs(manager, "B")
        manager.selectTab(serverId = "B")

        val idB = manager.tabs.first { it.serverId == "B" }.id

        // When: Remove B, server wants A active
        manager.accept(TabsDirective.Tabbed(
            active = "A",
            tabs = listOf(
                TabData(id = "A", title = "Home", icon = "house.fill", path = "/"),
                TabData(id = "C", title = "Search", icon = "magnifyingglass", path = "/search"),
                TabData(id = "D", title = "Activity", icon = "chart.bar.fill", path = "/activity"),
                TabData(id = "E", title = "Settings", icon = "gearshape.fill", path = "/settings")
            )
        ))

        // Then: B's ID morphed into A
        val tabA = manager.tabs.first { it.serverId == "A" }
        assertEquals("Active container should morph into A", idB, tabA.id)
        assertEquals("Selection should follow morphed container", idB, manager.selectedId)
    }

    // MARK: - ID Stability Test

    @Test
    fun `ID Stability - Verify IDs are preserved correctly across all operations`() {
        val manager = TabManager()
        val bootstrapId = manager.tabs[0].id

        // Step 1: Bootstrap → Tabbed (A active)
        manager.accept(fiveTabsDirective("A"))
        val idA = manager.tabs.first { it.serverId == "A" }.id
        val idB = manager.tabs.first { it.serverId == "B" }.id
        val idC = manager.tabs.first { it.serverId == "C" }.id

        assertEquals("Bootstrap ID should transfer to A", bootstrapId, idA)

        // Step 2: Metadata update (no tab changes) — IDs stable
        manager.accept(fiveTabsDirective("A"))
        assertEquals("A ID stable", idA, manager.tabs.first { it.serverId == "A" }.id)
        assertEquals("B ID stable", idB, manager.tabs.first { it.serverId == "B" }.id)
        assertEquals("C ID stable", idC, manager.tabs.first { it.serverId == "C" }.id)

        // Step 3: Remove some tabs — remaining IDs preserved
        manager.accept(TabsDirective.Tabbed(
            active = "A",
            tabs = listOf(
                TabData(id = "A", title = "Home", icon = "house.fill", path = "/"),
                TabData(id = "B", title = "Explore", icon = "safari.fill", path = "/explore")
            )
        ))
        assertEquals("Should have 2 tabs", 2, manager.tabs.size)
        assertEquals("A ID preserved", idA, manager.tabs.first { it.serverId == "A" }.id)
        assertEquals("B ID preserved", idB, manager.tabs.first { it.serverId == "B" }.id)

        // Step 4: Add tabs back — existing IDs kept, removed tabs get new IDs
        manager.accept(fiveTabsDirective("A"))
        assertEquals("A ID still preserved", idA, manager.tabs.first { it.serverId == "A" }.id)
        assertEquals("B ID still preserved", idB, manager.tabs.first { it.serverId == "B" }.id)

        val newIdC = manager.tabs.first { it.serverId == "C" }.id
        assertNotEquals("C should have NEW ID (was removed and re-added)", idC, newIdC)

        // Step 5: Active tab removed (morphing)
        manager.selectTab(serverId = "B")
        val activeBId = manager.tabs.first { it.serverId == "B" }.id

        manager.accept(TabsDirective.Tabbed(
            active = "A",
            tabs = listOf(
                TabData(id = "A", title = "Home", icon = "house.fill", path = "/"),
                TabData(id = "C", title = "Search", icon = "magnifyingglass", path = "/search"),
                TabData(id = "D", title = "Activity", icon = "chart.bar.fill", path = "/activity"),
                TabData(id = "E", title = "Settings", icon = "gearshape.fill", path = "/settings")
            )
        ))

        val morphedAId = manager.tabs.first { it.serverId == "A" }.id
        assertEquals("Active container ID (B) should morph into A", activeBId, morphedAId)

        // Step 6: Tabbed → Bootstrap — active tab's ID transfers
        manager.selectTab(serverId = "C")
        val activeCId = manager.tabs.first { it.serverId == "C" }.id

        manager.accept(TabsDirective.Bootstrap)
        assertEquals("Should be bootstrap mode", 1, manager.tabs.size)
        assertEquals("Bootstrap should preserve active container ID", activeCId, manager.tabs[0].id)
    }

    // MARK: - Test Case 5 Again (Server Active Changed)

    @Test
    fun `Case 5 again - Server active hint ignored`() {
        val manager = TabManager()

        // Given: Manager with 5 tabs, A selected
        upgradeToFiveTabs(manager, "A")
        val idA = manager.tabs.first { it.serverId == "A" }.id
        assertEquals(idA, manager.selectedId)

        // When: Server directive has different active (but no tab changes)
        manager.accept(fiveTabsDirective("B"))

        // Then: Client selection unchanged
        assertEquals("User's selection should be preserved", idA, manager.selectedId)
    }
}

/**
 * Tests for graceful tab removal via deprecated/replaces extensions.
 * 10 tests covering soft deprecation, hard deprecation, tab count stability,
 * deprecated without replacement, and bootstrap clears deprecation.
 */
class DeprecationTest {

    // MARK: - Fixtures

    private val fourTabs = listOf(
        TabData(id = "home", title = "Home", icon = "house.fill", path = "/"),
        TabData(id = "explore", title = "Explore", icon = "magnifyingglass", path = "/explore"),
        TabData(id = "library", title = "Library", icon = "books.vertical", path = "/library"),
        TabData(id = "profile", title = "Profile", icon = "person.crop.circle", path = "/profile")
    )

    private val softDeprecationDirective = TabsDirective.Tabbed(
        active = "home",
        tabs = listOf(
            TabData(id = "home", title = "Home", icon = "house.fill", path = "/"),
            TabData(id = "explore", title = "Explore", icon = "magnifyingglass", path = "/explore", deprecated = "soft"),
            TabData(id = "favorites", title = "Favorites", icon = "heart.fill", path = "/favorites", replaces = "explore"),
            TabData(id = "library", title = "Library", icon = "books.vertical", path = "/library"),
            TabData(id = "profile", title = "Profile", icon = "person.crop.circle", path = "/profile")
        )
    )

    private val hardDeprecationDirective = TabsDirective.Tabbed(
        active = "home",
        tabs = listOf(
            TabData(id = "home", title = "Home", icon = "house.fill", path = "/"),
            TabData(id = "explore", title = "Explore", icon = "magnifyingglass", path = "/explore", deprecated = "hard"),
            TabData(id = "favorites", title = "Favorites", icon = "heart.fill", path = "/favorites", replaces = "explore"),
            TabData(id = "library", title = "Library", icon = "books.vertical", path = "/library"),
            TabData(id = "profile", title = "Profile", icon = "person.crop.circle", path = "/profile")
        )
    )

    private fun upgradeToFourTabs(manager: TabManager, active: String) {
        manager.accept(TabsDirective.Tabbed(active = active, tabs = fourTabs))
    }

    // MARK: - Bootstrap → Tabbed with Deprecation

    @Test
    fun `Fresh bootstrap skips deprecated tabs and shows replacements`() {
        val manager = TabManager()

        // When: Bootstrap → Tabbed with deprecated Explore and replacement Favorites
        manager.accept(softDeprecationDirective)

        // Then: 4 tabs shown (Home, Favorites, Library, Profile) — Explore skipped
        assertEquals(4, manager.tabs.size)
        val ids = manager.tabs.map { it.serverId }
        assertEquals(listOf("home", "favorites", "library", "profile"), ids)
        assertFalse("Deprecated Explore should not appear on fresh bootstrap", ids.contains("explore"))
    }

    // MARK: - Soft Deprecation

    @Test
    fun `Soft-deprecated tab kept when already visible`() {
        val manager = TabManager()

        // Given: Already showing 4 tabs including Explore
        upgradeToFourTabs(manager, "home")
        assertEquals(listOf("home", "explore", "library", "profile"), manager.tabs.map { it.serverId })
        val exploreId = manager.tabs.first { it.serverId == "explore" }.id

        // When: Receive directive with Explore soft-deprecated
        manager.accept(softDeprecationDirective)

        // Then: Explore still visible, Favorites hidden, ID preserved
        val ids = manager.tabs.map { it.serverId }
        assertEquals(listOf("home", "explore", "library", "profile"), ids)
        assertFalse("Replacement should be hidden while deprecated tab is visible", ids.contains("favorites"))
        assertEquals("ID preserved", exploreId, manager.tabs.first { it.serverId == "explore" }.id)
        assertNotNull("Deprecation info tracked", manager.deprecationInfo["explore"])
        assertEquals("soft", manager.deprecationInfo["explore"]?.level)
    }

    @Test
    fun `Soft-deprecated tab survives across repeated directives`() {
        val manager = TabManager()

        // Given: Already showing Explore
        upgradeToFourTabs(manager, "home")

        // When: Send soft-deprecation directive multiple times
        manager.accept(softDeprecationDirective)
        manager.accept(softDeprecationDirective)
        manager.accept(softDeprecationDirective)

        // Then: Explore still visible
        val ids = manager.tabs.map { it.serverId }
        assertTrue("Soft-deprecated tab should survive repeated directives", ids.contains("explore"))
        assertFalse(ids.contains("favorites"))
    }

    @Test
    fun `Soft-deprecated tab removed on next bootstrap-tabbed transition`() {
        val manager = TabManager()

        // Given: Explore is soft-deprecated but still visible
        upgradeToFourTabs(manager, "home")
        manager.accept(softDeprecationDirective)
        assertTrue(manager.tabs.map { it.serverId }.contains("explore"))

        // When: Go through bootstrap cycle (sign out → sign in)
        manager.accept(TabsDirective.Bootstrap)
        manager.accept(softDeprecationDirective)

        // Then: Explore removed, Favorites shown
        val ids = manager.tabs.map { it.serverId }
        assertFalse("Soft-deprecated tab removed after bootstrap cycle", ids.contains("explore"))
        assertTrue("Replacement shown after bootstrap cycle", ids.contains("favorites"))
        assertEquals(listOf("home", "favorites", "library", "profile"), ids)
    }

    // MARK: - Hard Deprecation

    @Test
    fun `Hard-deprecated tab removed immediately when user is NOT on it`() {
        val manager = TabManager()

        // Given: Showing 4 tabs, user on Home (not Explore)
        upgradeToFourTabs(manager, "home")

        // When: Receive directive with Explore hard-deprecated
        manager.accept(hardDeprecationDirective)

        // Then: Explore removed immediately, Favorites shown
        val ids = manager.tabs.map { it.serverId }
        assertFalse("Hard-deprecated tab removed when user is not on it", ids.contains("explore"))
        assertTrue("Replacement shown immediately", ids.contains("favorites"))
        assertEquals(listOf("home", "favorites", "library", "profile"), ids)
    }

    @Test
    fun `Hard-deprecated tab kept when user IS on it`() {
        val manager = TabManager()

        // Given: Showing 4 tabs, user on Explore
        upgradeToFourTabs(manager, "explore")
        manager.selectTab(serverId = "explore")

        // When: Receive directive with Explore hard-deprecated
        manager.accept(hardDeprecationDirective)

        // Then: Explore still visible (user is on it), Favorites hidden
        val ids = manager.tabs.map { it.serverId }
        assertTrue("Hard-deprecated tab kept while user is on it", ids.contains("explore"))
        assertFalse("Replacement hidden while deprecated tab is active", ids.contains("favorites"))
        assertEquals("hard", manager.deprecationInfo["explore"]?.level)
    }

    @Test
    fun `Hard-deprecated tab removed when user switches away`() {
        val manager = TabManager()

        // Given: User is on hard-deprecated Explore
        upgradeToFourTabs(manager, "explore")
        manager.selectTab(serverId = "explore")
        manager.accept(hardDeprecationDirective)
        assertTrue(manager.tabs.map { it.serverId }.contains("explore"))

        // When: User switches to Home
        manager.selectTab(serverId = "home")

        // Then: Explore removed, Favorites appears in its place
        val ids = manager.tabs.map { it.serverId }
        assertFalse("Hard-deprecated tab removed on switch", ids.contains("explore"))
        assertTrue("Replacement inserted at deprecated tab's position", ids.contains("favorites"))
        assertNull("Deprecation info cleared", manager.deprecationInfo["explore"])
    }

    // MARK: - Tab Count Stability

    @Test
    fun `Tab count stays stable through deprecation cycle`() {
        val manager = TabManager()

        // Start with 4 tabs
        upgradeToFourTabs(manager, "home")
        assertEquals(4, manager.tabs.size)

        // Soft-deprecate Explore: still 4 tabs (Explore kept, Favorites hidden)
        manager.accept(softDeprecationDirective)
        assertEquals("Count stable during soft deprecation", 4, manager.tabs.size)

        // Bootstrap cycle: still 4 tabs (Explore gone, Favorites shown)
        manager.accept(TabsDirective.Bootstrap)
        manager.accept(softDeprecationDirective)
        assertEquals("Count stable after deprecation resolved", 4, manager.tabs.size)
    }

    // MARK: - Deprecated Without Replacement

    @Test
    fun `Deprecated tab without replacement is handled correctly`() {
        val manager = TabManager()

        // Given: 4 tabs, user on Home
        upgradeToFourTabs(manager, "home")

        // When: Explore hard-deprecated with no replacement
        manager.accept(TabsDirective.Tabbed(
            active = "home",
            tabs = listOf(
                TabData(id = "home", title = "Home", icon = "house.fill", path = "/"),
                TabData(id = "explore", title = "Explore", icon = "magnifyingglass", path = "/explore", deprecated = "hard"),
                TabData(id = "library", title = "Library", icon = "books.vertical", path = "/library"),
                TabData(id = "profile", title = "Profile", icon = "person.crop.circle", path = "/profile")
            )
        ))

        // Then: Explore removed, 3 tabs remain
        val ids = manager.tabs.map { it.serverId }
        assertFalse(ids.contains("explore"))
        assertEquals(listOf("home", "library", "profile"), ids)
        assertEquals(3, manager.tabs.size)
    }

    // MARK: - Bootstrap Clears Deprecation State

    @Test
    fun `Bootstrap transition clears deprecation tracking`() {
        val manager = TabManager()

        // Given: Explore is soft-deprecated and tracked
        upgradeToFourTabs(manager, "home")
        manager.accept(softDeprecationDirective)
        assertTrue(manager.deprecationInfo.isNotEmpty())

        // When: Downgrade to bootstrap
        manager.accept(TabsDirective.Bootstrap)

        // Then: Deprecation state cleared
        assertTrue("Bootstrap should clear deprecation tracking", manager.deprecationInfo.isEmpty())
    }
}
