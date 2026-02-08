package io.tilde.dynamictabbar

import android.os.Bundle
import android.util.Log
import android.view.Menu
import android.view.View
import android.view.ViewGroup.LayoutParams.MATCH_PARENT
import android.widget.FrameLayout
import androidx.activity.enableEdgeToEdge
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.fragment.app.FragmentContainerView
import com.google.android.material.bottomnavigation.BottomNavigationView
import dev.hotwire.navigation.activities.HotwireActivity
import dev.hotwire.navigation.navigator.NavigatorConfiguration
import dev.hotwire.navigation.navigator.NavigatorHost

private const val TAG = "MainActivity"

class MainActivity : HotwireActivity() {
    private val tabManager = TabManager(
        generateId = View::generateViewId,
        log = { Log.d("TabManager", it) }
    )
    private lateinit var fragmentHost: FrameLayout
    private lateinit var bottomNav: BottomNavigationView

    companion object {
        private const val BASE_URL = "http://10.0.2.2:3000"
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(null) // null prevents restoring stale Fragments

        setContentView(R.layout.activity_main)
        fragmentHost = findViewById(R.id.fragment_host)
        bottomNav = findViewById(R.id.bottom_nav)

        // Handle insets manually (Compose Scaffold did this automatically)
        ViewCompat.setOnApplyWindowInsetsListener(fragmentHost) { view, insets ->
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars())
            view.setPadding(bars.left, bars.top, bars.right, 0) // bottom handled by nav bar
            insets
        }

        TabDirectiveRouter.listener = { directive -> acceptDirective(directive) }

        // Add bootstrap FragmentContainerView + NavigatorHost
        val bootstrapTab = tabManager.tabs[0]
        addFragmentContainer(bootstrapTab)
        supportFragmentManager.beginTransaction()
            .add(bootstrapTab.id, NavigatorHost::class.java, null, "tab-${bootstrapTab.id}")
            .commitNow()
        Log.d(TAG, "Added bootstrap NavigatorHost")

        applyTabState()
    }

    override fun navigatorConfigurations(): List<NavigatorConfiguration> {
        return tabManager.tabs.map { tab ->
            val url = java.net.URI(BASE_URL).resolve(tab.path).toString()
            NavigatorConfiguration(
                name = "tab-${tab.id}",
                startLocation = url,
                navigatorHostId = tab.id
            )
        }
    }

    private fun acceptDirective(directive: TabsDirective) {
        val oldTabs = tabManager.tabs.toList()
        tabManager.accept(directive)
        reconcileFragments(oldTabs, tabManager.tabs)
        applyTabState()
        updateCurrentNavigator()
    }

    private fun onSelectTab(id: Int) {
        val oldTabs = tabManager.tabs.toList()
        tabManager.selectTab(id = id)
        reconcileFragments(oldTabs, tabManager.tabs)
        applyTabState()
        updateCurrentNavigator()
    }

    private fun updateCurrentNavigator() {
        val tab = tabManager.activeTab
        ensureNavigatorHost(tab)
        val url = java.net.URI(BASE_URL).resolve(tab.path).toString()
        delegate.setCurrentNavigator(
            NavigatorConfiguration(
                name = "tab-${tab.id}",
                startLocation = url,
                navigatorHostId = tab.id
            )
        )
    }

    private fun ensureNavigatorHost(tab: TabItem) {
        if (supportFragmentManager.findFragmentByTag("tab-${tab.id}") == null) {
            supportFragmentManager.beginTransaction()
                .add(tab.id, NavigatorHost::class.java, null, "tab-${tab.id}")
                .commitNow()
            Log.d(TAG, "Added NavigatorHost for tab: ${tab.serverId}")
        }
    }

    private fun reconcileFragments(oldTabs: List<TabItem>, newTabs: List<TabItem>) {
        val oldIds = oldTabs.map { it.id }.toSet()
        val newIds = newTabs.map { it.id }.toSet()
        val toRemove = oldIds - newIds
        val toAdd = newTabs.filter { it.id !in oldIds }

        if (toRemove.isEmpty() && toAdd.isEmpty()) return

        Log.d(TAG, "Reconciling: removing ${toRemove.size}, adding ${toAdd.size}")

        // Add container views first (new fragments need somewhere to go)
        for (tab in toAdd) {
            addFragmentContainer(tab)
        }

        // Remove old NavigatorHosts. Don't add new ones here — they are
        // created lazily in ensureNavigatorHost() as needed.
        supportFragmentManager.beginTransaction().apply {
            for (id in toRemove) {
                supportFragmentManager.findFragmentById(id)?.let { remove(it) }
            }
        }.commitNow()

        // Clean up old container views (fragments are gone now)
        for (id in toRemove) {
            fragmentHost.findViewById<View>(id)?.let { fragmentHost.removeView(it) }
        }
    }

    /**
     * Reads TabManager state and updates BottomNavigationView + fragment
     * container visibility to match. Mirrors UIKit's applyTabState().
     *
     * Menu rebuilds use presenter suspension to batch mutations into a single
     * buildMenuView() call. Without this, menu.clear() resets the internal
     * selectedItemId to 0, and the subsequent setSelectedItemId triggers
     * BottomNavigationView's AutoTransition (layout animation) and each
     * item's ValueAnimator (indicator pill animation). Presenter suspension
     * prevents buildMenuView from running on the empty menu, preserving the
     * correct selectedItemId so no transition is triggered. The indicator is
     * also disabled during rebuild to suppress the pill's expand animation
     * on newly created item views.
     */
    @Suppress("RestrictedApi")
    private fun applyTabState() {
        val tabs = tabManager.tabs
        val selectedId = tabManager.selectedId
        val isBootstrap = tabs.size <= 1

        bottomNav.setOnItemSelectedListener(null)

        val menu = bottomNav.menu
        val currentIds = (0 until menu.size()).map { menu.getItem(it).itemId }
        val desiredIds = tabs.map { it.id }
        val structureChanged = currentIds != desiredIds

        if (structureChanged) {
            val presenter = bottomNav.getPresenter()
            val fromBootstrap = currentIds.size <= 1

            // Disable indicator during rebuild — unless coming from bootstrap,
            // where the "expand from center" animation is the natural first-load feel.
            if (!fromBootstrap) bottomNav.isItemActiveIndicatorEnabled = false

            // Suspend — mutations won't trigger buildMenuView/updateMenuView.
            presenter.setUpdateSuspended(true)

            menu.clear()

            for ((i, tab) in tabs.withIndex()) {
                menu.add(Menu.NONE, tab.id, i, tab.title).setIcon(iconForTab(tab.icon))
            }

            // Resume and flush — single buildMenuView() with all items present.
            presenter.setUpdateSuspended(false)
            presenter.updateMenuView(true)

            bottomNav.isItemActiveIndicatorEnabled = true
        }

        // Sync title and icon on all items
        for (tab in tabs) {
            menu.findItem(tab.id)?.apply {
                title = tab.title
                setIcon(iconForTab(tab.icon))
            }
        }

        // Set selection — should be a no-op if buildMenuView already selected correctly.
        if (!isBootstrap) bottomNav.selectedItemId = selectedId

        // Show/hide
        bottomNav.visibility = if (isBootstrap) View.GONE else View.VISIBLE

        syncContainerVisibility()

        bottomNav.setOnItemSelectedListener { item ->
            onSelectTab(item.itemId)
            true
        }
    }

    /** Update which FragmentContainerView is visible */
    private fun syncContainerVisibility() {
        val selectedId = tabManager.selectedId
        for (i in 0 until fragmentHost.childCount) {
            val child = fragmentHost.getChildAt(i)
            child.visibility = if (child.id == selectedId) View.VISIBLE else View.GONE
        }
    }

    private fun addFragmentContainer(tab: TabItem) {
        fragmentHost.addView(FragmentContainerView(this).apply {
            id = tab.id
            layoutParams = FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT)
            visibility = View.GONE
        })
    }

    override fun onDestroy() {
        TabDirectiveRouter.listener = null
        super.onDestroy()
    }
}

/** Map protocol icon strings (SF Symbol names) to drawable resource IDs */
private fun iconForTab(icon: String): Int = when (icon) {
    "house", "house.fill" -> R.drawable.ic_home
    "magnifyingglass" -> R.drawable.ic_search
    "books.vertical", "books.vertical.fill" -> R.drawable.ic_library
    "person.crop.circle", "person.crop.circle.fill" -> R.drawable.ic_account
    "heart", "heart.fill" -> R.drawable.ic_favorite
    "star", "star.fill" -> R.drawable.ic_star
    else -> R.drawable.ic_home
}
