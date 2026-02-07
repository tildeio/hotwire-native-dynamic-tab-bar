package io.tilde.dynamictabbar

import android.os.Bundle
import android.util.Log
import android.view.View
import android.view.ViewGroup
import android.view.ViewGroup.LayoutParams.MATCH_PARENT
import android.widget.FrameLayout
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AccountCircle
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.automirrored.filled.LibraryBooks
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Star
import androidx.compose.material3.Icon
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.viewinterop.AndroidView
import androidx.fragment.app.FragmentContainerView
import dev.hotwire.navigation.activities.HotwireActivity
import dev.hotwire.navigation.navigator.NavigatorConfiguration
import dev.hotwire.navigation.navigator.NavigatorHost
import io.tilde.dynamictabbar.ui.theme.DynamicTabBarTheme

private const val TAG = "MainActivity"

class MainActivity : HotwireActivity() {
    private val tabManager = TabManager(
        generateId = View::generateViewId,
        log = { Log.d("TabManager", it) }
    )
    private lateinit var fragmentHost: FrameLayout

    // Compose state mirroring TabManager
    private var tabs by mutableStateOf(tabManager.tabs)
    private var selectedId by mutableStateOf(tabManager.selectedId)

    companion object {
        private const val BASE_URL = "http://10.0.2.2:3000"
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(null) // null prevents restoring stale Fragments

        TabDirectiveRouter.listener = { directive -> acceptDirective(directive) }

        fragmentHost = FrameLayout(this).apply {
            layoutParams = ViewGroup.LayoutParams(MATCH_PARENT, MATCH_PARENT)
        }
        fragmentHost.addView(FragmentContainerView(this).apply {
            id = tabManager.tabs[0].id
            layoutParams = FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT)
            visibility = View.GONE
        })

        setContent {
            DynamicTabBarTheme {
                val isBootstrap = tabs.size <= 1
                Scaffold(
                    modifier = Modifier.fillMaxSize(),
                    bottomBar = {
                        if (!isBootstrap) {
                            NavigationBar {
                                tabs.forEach { tab ->
                                    NavigationBarItem(
                                        selected = tab.id == selectedId,
                                        onClick = { onSelectTab(tab.id) },
                                        icon = {
                                            Icon(
                                                iconForTab(tab.icon),
                                                contentDescription = tab.title
                                            )
                                        },
                                        label = { Text(tab.title) }
                                    )
                                }
                            }
                        }
                    }
                ) { innerPadding ->
                    AndroidView(
                        factory = { fragmentHost },
                        update = { container ->
                            for (i in 0 until container.childCount) {
                                val child = container.getChildAt(i)
                                child.visibility =
                                    if (child.id == selectedId) View.VISIBLE else View.GONE
                            }
                        },
                        modifier = Modifier
                            .fillMaxSize()
                            .padding(innerPadding)
                    )
                }
            }
        }

        // Add bootstrap NavigatorHost AFTER Compose puts fragmentHost in the hierarchy
        window.decorView.post {
            val tab = tabManager.tabs[0]
            supportFragmentManager.beginTransaction()
                .add(tab.id, NavigatorHost::class.java, null, "tab-${tab.id}")
                .commitNow()
            Log.d(TAG, "Added bootstrap NavigatorHost")
        }
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
        syncState()
        updateCurrentNavigator()
    }

    private fun onSelectTab(id: Int) {
        val oldTabs = tabManager.tabs.toList()
        tabManager.selectTab(id = id)
        reconcileFragments(oldTabs, tabManager.tabs)
        syncState()
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
            fragmentHost.addView(FragmentContainerView(this).apply {
                id = tab.id
                layoutParams = FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT)
                visibility = View.GONE
            })
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

    private fun syncState() {
        tabs = tabManager.tabs.toList()
        selectedId = tabManager.selectedId
    }

    override fun onDestroy() {
        TabDirectiveRouter.listener = null
        super.onDestroy()
    }
}

/** Map protocol icon strings (SF Symbol names) to Material Icons */
private fun iconForTab(icon: String): ImageVector = when (icon) {
    "house", "house.fill" -> Icons.Default.Home
    "magnifyingglass" -> Icons.Default.Search
    "books.vertical", "books.vertical.fill" -> Icons.AutoMirrored.Filled.LibraryBooks
    "person.crop.circle", "person.crop.circle.fill" -> Icons.Default.AccountCircle
    "heart", "heart.fill" -> Icons.Default.Favorite
    "star", "star.fill" -> Icons.Default.Star
    else -> Icons.Default.Home
}
