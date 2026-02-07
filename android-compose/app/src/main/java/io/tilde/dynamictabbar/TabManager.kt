package io.tilde.dynamictabbar

import kotlinx.serialization.Serializable
import java.util.concurrent.atomic.AtomicInteger

// MARK: - Types

/**
 * Server's representation of a tab.
 */
@Serializable
data class TabData(
    val id: String,       // Server ID (e.g., "home", "explore")
    val title: String,
    val icon: String,
    val path: String,
    val deprecated: String? = null,  // "soft" or "hard" (null = not deprecated)
    val replaces: String? = null     // ID of deprecated tab this one replaces
) {
    fun toTabItem(id: Int): TabItem {
        return TabItem(id = id, serverId = this.id, title = title, icon = icon, path = path)
    }
}

/**
 * Server directive for tab configuration.
 */
sealed class TabsDirective {
    /** No tabs, hidden tab bar */
    data object Bootstrap : TabsDirective()

    /** Multiple tabs, visible tab bar */
    data class Tabbed(val active: String, val tabs: List<TabData>) : TabsDirective()

    val tabsList: List<TabData>
        get() = when (this) {
            is Bootstrap -> emptyList()
            is Tabbed -> tabs
        }
}

/**
 * Client's internal representation of a tab — the container.
 *
 * The id is the container identity (an Android View ID, never changes for its lifetime).
 * The serverId, title, icon, and path describe what it represents and can change
 * (e.g., during morphing or promotion).
 */
data class TabItem(
    val id: Int,               // Container identity (View ID, never changes)
    var serverId: String,      // Server's ID (empty for bootstrap)
    var title: String,
    var icon: String,
    var path: String
)

/**
 * Tracks deprecated tabs that are still visible, keyed by server ID.
 */
data class DeprecationEntry(
    val level: String,            // "soft" or "hard"
    val replacement: TabData?     // Tab to show when this one is removed
)

// MARK: - TabManager

/**
 * Manages tab state and reconciliation with server directives.
 *
 * Core principle: The active navigator must survive all transitions.
 * Everything else is just bookkeeping.
 *
 * Implements all 11 reconciliation cases from reconciliation.md,
 * plus graceful tab removal via deprecated/replaces extensions.
 *
 * This class is pure Kotlin — no Android or coroutines dependencies —
 * so it can be tested as a JVM unit test. The [generateId] parameter
 * defaults to an AtomicInteger counter for JVM tests. Production code
 * passes View::generateViewId so tab IDs are valid Android View IDs.
 */
class TabManager(
    private val generateId: () -> Int = { nextId.getAndIncrement() },
    private val log: (String) -> Unit = {}
) {

    companion object {
        private val nextId = AtomicInteger(1)
    }

    var tabs: List<TabItem> = emptyList()
        private set

    var selectedId: Int = 0
        private set

    /** Tracks deprecated tabs that are still visible, keyed by server ID. */
    private val _deprecationInfo = mutableMapOf<String, DeprecationEntry>()
    val deprecationInfo: Map<String, DeprecationEntry> get() = _deprecationInfo.toMap()

    /** Whether currently in bootstrap mode (single tab, no tab bar) */
    val isBootstrap: Boolean get() = tabs.size == 1

    /** Active tab (always exists — tabs is never empty) */
    val activeTab: TabItem get() = tabs.first { it.id == selectedId }

    init {
        val id = generateId()
        tabs = listOf(
            TabItem(id = id, serverId = "", title = "Bootstrap", icon = "", path = "/")
        )
        selectedId = id
        log("Initialized in bootstrap mode")
    }

    // MARK: - Public API

    /** Select a tab by server ID (user interaction) */
    fun selectTab(serverId: String) {
        val tab = tabs.firstOrNull { it.serverId == serverId } ?: return
        val previousTab = activeTab
        selectedId = tab.id
        log("User selected tab: $serverId")

        if (tab.id != previousTab.id) {
            handleHardDeprecationOnSwitch(previousTab.serverId)
        }
    }

    /** Select a tab by ID */
    fun selectTab(id: Int) {
        if (tabs.none { it.id == id }) return
        val previousTab = activeTab
        selectedId = id

        if (id != previousTab.id) {
            handleHardDeprecationOnSwitch(previousTab.serverId)
        }
    }

    /** Accept a directive from the server and reconcile tabs */
    fun accept(directive: TabsDirective) {
        val wantsBootstrap = directive.tabsList.isEmpty()
        val isCurrentlyBootstrap = isBootstrap

        log("Received directive: ${if (wantsBootstrap) "Bootstrap" else "Tabbed(${directive.tabsList.size})"}")

        // Case 1: Bootstrap → Bootstrap
        if (isCurrentlyBootstrap && wantsBootstrap) {
            _deprecationInfo.clear()
            log("  Case 1: Bootstrap → Bootstrap (no-op)")
            return
        }

        // Case 2: Bootstrap → Tabbed
        if (isCurrentlyBootstrap && !wantsBootstrap) {
            log("  Case 2: Bootstrap → Tabbed")
            val tabbed = directive as TabsDirective.Tabbed
            val (filtered, effectiveActive) = filterForDeprecation(tabbed.tabs, tabbed.active)
            upgradeToTabs(effectiveActive, filtered)
            return
        }

        // Case 3: Tabbed → Bootstrap
        if (!isCurrentlyBootstrap && wantsBootstrap) {
            log("  Case 3: Tabbed → Bootstrap")
            _deprecationInfo.clear()
            downgradeToBootstrap()
            return
        }

        // Both tabbed — filter for deprecation, then reconcile (Cases 4-11)
        val tabbed = directive as TabsDirective.Tabbed
        val (filtered, effectiveActive) = filterForDeprecation(tabbed.tabs, tabbed.active)

        if (filtered.isEmpty()) {
            downgradeToBootstrap()
            return
        }

        reconcileTabs(effectiveActive, filtered)
    }

    // MARK: - Deprecation Filtering

    /**
     * Filters the server's tab list for deprecation, deciding which deprecated tabs
     * to keep visible and which replacements to show.
     *
     * A deprecated tab is kept if it's already visible and either:
     * - It's "soft" deprecated (always kept while visible), or
     * - It's "hard" deprecated AND the user is currently on it.
     *
     * A replacement tab is shown only when its deprecated counterpart is filtered out.
     * Returns the filtered tab list and an adjusted active tab ID.
     */
    private fun filterForDeprecation(
        allTabs: List<TabData>,
        serverActive: String
    ): Pair<List<TabData>, String> {
        val currentIds = tabs.map { it.serverId }.toSet()

        // Build replacement map: deprecatedId → replacement TabData
        val replacementsByDeprecated = allTabs
            .filter { it.replaces != null }
            .associateBy { it.replaces!! }

        // Pass 1: Decide which deprecated tabs to keep
        val keptDeprecatedIds = mutableSetOf<String>()

        for (tab in allTabs) {
            val deprecation = tab.deprecated ?: continue

            if (currentIds.contains(tab.id)) {
                // Tab is already visible
                when (deprecation) {
                    "soft" -> keptDeprecatedIds.add(tab.id)
                    "hard" -> {
                        if (activeTab.serverId == tab.id) {
                            // User is currently on this tab — keep it
                            keptDeprecatedIds.add(tab.id)
                        }
                        // else: user is not on it — don't keep, remove immediately
                    }
                }
            }
            // else: tab not currently visible — don't add deprecated tabs
        }

        // Pass 2: Build filtered list + update deprecation tracking
        val result = mutableListOf<TabData>()
        _deprecationInfo.clear()

        for (tab in allTabs) {
            if (tab.deprecated != null) {
                if (keptDeprecatedIds.contains(tab.id)) {
                    result.add(tab)
                    _deprecationInfo[tab.id] = DeprecationEntry(
                        level = tab.deprecated,
                        replacement = replacementsByDeprecated[tab.id]
                    )
                }
                // else: deprecated tab filtered out
            } else if (tab.replaces != null) {
                if (keptDeprecatedIds.contains(tab.replaces)) {
                    // Deprecated tab still visible — hide its replacement
                } else {
                    // Deprecated tab gone — show replacement
                    result.add(tab)
                }
            } else {
                // Normal tab
                result.add(tab)
            }
        }

        // Adjust active if the server's active was filtered out
        val effectiveActive = if (result.any { it.id == serverActive }) {
            serverActive
        } else {
            result.firstOrNull()?.id ?: serverActive
        }

        return Pair(result, effectiveActive)
    }

    /**
     * When the user switches away from a hard-deprecated tab, remove it
     * and insert its replacement (if any) at the same position.
     */
    private fun handleHardDeprecationOnSwitch(previousServerId: String) {
        val info = _deprecationInfo[previousServerId] ?: return
        if (info.level != "hard") return

        val mutableTabs = tabs.toMutableList()
        val deprecatedIndex = mutableTabs.indexOfFirst { it.serverId == previousServerId }
        if (deprecatedIndex == -1) return

        mutableTabs.removeAt(deprecatedIndex)

        val replacement = info.replacement
        if (replacement != null) {
            mutableTabs.add(minOf(deprecatedIndex, mutableTabs.size), replacement.toTabItem(generateId()))
        }

        tabs = mutableTabs
        _deprecationInfo.remove(previousServerId)
        log("Hard-deprecated tab '$previousServerId' removed on tab switch")
    }

    // MARK: - Private Implementation

    /** Case 2: Bootstrap → Tabbed */
    private fun upgradeToTabs(active: String, tabsData: List<TabData>) {
        val bootstrapId = tabs[0].id

        tabs = tabsData.map { data ->
            data.toTabItem(id = if (data.id == active) bootstrapId else generateId())
        }
        selectedId = bootstrapId
        log("Upgraded to ${tabs.size} tabs, active: $active, preserved bootstrap ID")
    }

    /** Case 3: Tabbed → Bootstrap */
    private fun downgradeToBootstrap() {
        val active = activeTab

        tabs = listOf(
            TabItem(id = active.id, serverId = "", title = "Bootstrap", icon = "", path = active.path)
        )
        log("Downgraded to bootstrap, preserved ID from: ${active.serverId}")
    }

    /** Cases 4-11: Tabbed → Tabbed reconciliation */
    private fun reconcileTabs(active: String, tabsData: List<TabData>) {
        val currentIds = tabs.map { it.serverId }.toSet()
        val targetIds = tabsData.map { it.id }.toSet()

        // Quick check for changes
        val added = tabsData.any { !currentIds.contains(it.id) }
        val removed = tabs.any { !targetIds.contains(it.serverId) }

        // Case 4 & 6: No change or ordering change (both ignored)
        if (!added && !removed) {
            val sameOrder = tabs.indices.all { i -> tabs[i].serverId == tabsData[i].id }
            log(if (sameOrder) "  Case 4: No change (no-op)" else "  Case 6: Ordering changed (ignored)")
            return
        }

        // Check if active tab needs morphing (Case 9)
        val activeStillExists = targetIds.contains(activeTab.serverId)

        if (!activeStillExists) {
            log("  Case 9: Active tab removed (morphing)")
            morphAndReconcile(active, tabsData)
        } else {
            if (added && !removed) {
                log("  Case 7: Tabs added (adopt server ordering)")
            } else if (removed && !added) {
                log("  Case 8: Tabs removed (adopt server ordering)")
            } else {
                log("  Case 10/11: Tabs replaced (adopt server ordering)")
            }
            simpleReconcile(tabsData)
        }
    }

    /** Case 9: Active tab removed — morph it into server's active tab */
    private fun morphAndReconcile(active: String, tabsData: List<TabData>) {
        val currentActive = activeTab

        // Build map of existing tabs (excluding the active one — its ID will be reassigned)
        val existingByServerId = tabs
            .filter { it.id != currentActive.id }
            .associateBy { it.serverId }

        tabs = tabsData.map { data ->
            if (data.id == active) {
                data.toTabItem(id = currentActive.id)
            } else {
                data.toTabItem(id = existingByServerId[data.id]?.id ?: generateId())
            }
        }
        log("Morphed '${currentActive.serverId}' → '$active', ID preserved")
    }

    /** Cases 7, 8, 10: Simple reconciliation (active tab still exists) */
    private fun simpleReconcile(tabsData: List<TabData>) {
        val existingByServerId = tabs.associateBy { it.serverId }

        tabs = tabsData.map { data ->
            data.toTabItem(id = existingByServerId[data.id]?.id ?: generateId())
        }
        log("Reconciled to ${tabs.size} tabs, active preserved")
    }
}
