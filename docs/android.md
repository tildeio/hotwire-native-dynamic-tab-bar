# Android Implementation Guide

This documents the Jetpack Compose + Hotwire Navigation implementation of the reconciliation algorithm defined in [reconciliation.md](reconciliation.md), using the wire protocol from [protocol.md](protocol.md).

The implementation is a 1:1 port of the [iOS implementation](ios.md). The algorithm, types, and structure are identical — only the platform mechanics differ (Fragments instead of SwiftUI views, View IDs instead of UUIDs, `FragmentContainerView` instead of `NavigatorStore`). This guide focuses on the Android-specific details; see the iOS guide for high-level design rationale that applies to both platforms.

A [XML Views (Fragments) appendix](#appendix-xml-views-fragments) covers the differences for Fragments-based apps — the shared files (`TabManager`, `NavigationComponent`, `TabDirectiveRouter`, `DynamicTabBarApplication`) are identical.

## How Android Differs from iOS

The reconciliation algorithm, types, and TabManager are identical across platforms. The differences are all in how the platform hosts web views and manages tab UI. Three things stand out:

### Container identity: View IDs, not UUIDs

On iOS, each tab container is keyed by a `UUID` — an opaque value with no framework meaning. The app maintains its own `NavigatorStore` that maps UUIDs to `Navigator` objects.

On Android, Hotwire Navigation uses `NavigatorHost` Fragments, and Fragments live inside views identified by `Int` View IDs. The container identity must be a View ID because that's how `FragmentManager` knows which `FragmentContainerView` a Fragment belongs to. So where iOS generates `UUID()`, Android generates `View.generateViewId()`. The reconciliation algorithm is unaffected — it just needs a stable, unique key per container.

### The tab bar is just a bar

iOS `TabView` is a combined container — it manages both the tab bar UI and the content views. Each `Tab` owns its content, and SwiftUI handles showing/hiding content when the selection changes. The tab bar and the content are one integrated system.

Android's Material `NavigationBar` is purely a row of buttons. It doesn't know about content views and doesn't manage them. The app must separately maintain a `FrameLayout` of `FragmentContainerView`s (one per tab) and toggle `VISIBLE`/`GONE` on them when the selection changes. This also means Fragment lifecycle — creating `NavigatorHost` Fragments when tabs are added, removing them when tabs are removed — is the app's responsibility. That's what `reconcileFragments` does; iOS has no equivalent because SwiftUI's `TabView` handles it automatically.

### Process death and Fragment restoration

When Android kills and restores a process, `FragmentManager` tries to restore saved Fragments into their original container View IDs. But our View IDs are generated dynamically at runtime — they won't match the saved IDs from the previous process. Restored Fragments would be orphaned, pointing at containers that don't exist.

The fix is `super.onCreate(null)` — passing `null` instead of `savedInstanceState` tells `FragmentManager` not to restore anything. The app starts fresh in bootstrap mode and the server sends the tab configuration again on the first page load. iOS doesn't have this problem because SwiftUI rebuilds the view hierarchy from scratch on launch.

## Prerequisites

- Android SDK 24+ (minSdk)
- Hotwire Native Android (`dev.hotwire:navigation`, `dev.hotwire:core`)
- Jetpack Compose (Material 3)

## Key Design Decision: Stable Scaffold

The same principle from the iOS guide applies: the implementation **always renders content inside a Scaffold**, even in bootstrap mode. Bootstrap mode is a Scaffold with one tab's content and a hidden bottom bar.

The alternative — switching between a plain view and a Scaffold with a `NavigationBar` — would tear down and recreate the Fragment hosting the web view, causing a flash of blank content.

By always using a Scaffold, the view structure never changes — only the tab count and bottom bar visibility do. The bootstrap tab's Fragment stays in place and gains siblings when tabs arrive.

## Architecture

The implementation splits into the same three concerns as iOS:

1. **Parsing:** `NavigationComponent` receives bridge messages and routes them to the Activity
2. **State:** `TabManager` implements the reconciliation algorithm (identical to iOS)
3. **Rendering:** `MainActivity` turns state into a Compose UI with Fragment-backed web views

The bridge component and the Activity communicate via `TabDirectiveRouter`, a singleton with a lambda listener. This is the Android equivalent of iOS's `NotificationCenter` — needed because the bridge component and the Activity are not in the same ownership tree.

## Types

All types live in `TabManager.kt`. They are identical to the iOS types with one platform difference: container identity is an `Int` (Android View ID) instead of a `UUID`.

### TabData (server representation)

Decoded from the bridge message via `kotlinx.serialization`. Matches the [protocol.md](protocol.md) wire format.

```kotlin
@Serializable
data class TabData(
    val id: String,                 // Server ID (e.g., "home", "explore")
    val title: String,
    val icon: String,
    val path: String,
    val deprecated: String? = null, // "soft" or "hard"
    val replaces: String? = null    // ID of deprecated tab this one replaces
)
```

### TabsDirective (parsed server intent)

```kotlin
sealed class TabsDirective {
    data object Bootstrap : TabsDirective()
    data class Tabbed(val active: String, val tabs: List<TabData>) : TabsDirective()
}
```

### TabItem (client container)

The client's internal model — the [container](reconciliation.md#client-side-uuid-identity) that holds tab state. The `id` is the container identity; the `serverId` is what it represents.

```kotlin
data class TabItem(
    val id: Int,          // Container identity (View ID, never changes)
    var serverId: String, // What it represents (empty for bootstrap)
    var title: String,
    var icon: String,
    var path: String
)
```

## Components

### NavigationComponent

Bridge component registered with Hotwire Native. Receives `configure` events from the Stimulus controller and routes them to the Activity.

```kotlin
class NavigationComponent(
    name: String,
    private val delegate: BridgeDelegate<HotwireDestination>
) : BridgeComponent<HotwireDestination>(name, delegate) {

    override fun onReceive(message: Message) {
        when (message.event) {
            "configure" -> handleConfigure(message)
            else -> Log.w(TAG, "Received unknown event: ${message.event}")
        }
    }

    private fun handleConfigure(message: Message) {
        val data = json.decodeFromString<MessageData>(message.jsonData)
        // ... build TabsDirective ...
        TabDirectiveRouter.send(directive)
    }
}
```

Communication is via `TabDirectiveRouter` — a singleton object with a `listener` lambda. The Activity sets the listener in `onCreate` and clears it in `onDestroy`. This is the simplest correct pattern for Android; iOS uses `NotificationCenter` for the same reason.

### TabManager

Pure Kotlin class that owns the tab state and implements the [reconciliation algorithm](reconciliation.md). **This is identical to the iOS `TabManager`**. The only difference is the container ID type (`Int` vs `UUID`).

```kotlin
class TabManager(
    private val generateId: () -> Int = { nextId.getAndIncrement() },
    private val log: (String) -> Unit = {}
) {
    var tabs: List<TabItem> // Current tab list
    var selectedId: Int     // Currently selected tab's View ID

    fun accept(directive: TabsDirective) { /* reconciliation */ }
    fun selectTab(id: Int) { /* user interaction */ }
}
```

The `generateId` and `log` parameters are injected for testability. Production passes `View::generateViewId` and `Log.d`; JVM tests use an `AtomicInteger` counter and a no-op logger. This makes `TabManager` testable as a plain JVM unit test with no Android dependencies.

### MainActivity

The main Activity, extending `HotwireActivity`. This is the most structurally different file from iOS because it bridges Compose UI with Fragment-based Hotwire Navigation.

```kotlin
class MainActivity : HotwireActivity() {
    private val tabManager = TabManager(
        generateId = View::generateViewId,
        log = { Log.d("TabManager", it) }
    )
    private lateinit var fragmentHost: FrameLayout

    // Compose state mirroring TabManager
    private var tabs by mutableStateOf(tabManager.tabs)
    private var selectedId by mutableStateOf(tabManager.selectedId)
}
```

Key details:

- **`fragmentHost`** is a `FrameLayout` that contains one `FragmentContainerView` per tab. Each `FragmentContainerView` hosts a `NavigatorHost` Fragment (Hotwire's equivalent of iOS's `Navigator`). Only the selected tab's container is `VISIBLE`; the rest are `GONE`.

- **`tabs` and `selectedId`** are Compose `mutableStateOf` properties that mirror `TabManager`'s state. When `TabManager` reconciles, `syncState()` copies the new values, triggering Compose recomposition.

- **`super.onCreate(null)`** — prevents stale Fragment restoration (see [Process death](#process-death-and-fragment-restoration) above).

- **`window.decorView.post { ... }`** — the bootstrap `NavigatorHost` Fragment is added in a `post` block because `setContent` must run first to attach `fragmentHost` to the view hierarchy. Fragments cannot be added to a container that isn't in the window yet.

#### Fragment Reconciliation

When `TabManager` changes the tab list, the Activity must reconcile the Fragment hierarchy to match. This is the Android-specific concern that has no iOS equivalent (SwiftUI handles view lifecycle automatically).

```kotlin
private fun reconcileFragments(oldTabs: List<TabItem>, newTabs: List<TabItem>) {
    val toRemove = oldIds - newIds
    val toAdd = newTabs.filter { it.id !in oldIds }

    // 1. Add FragmentContainerViews for new tabs (cheap, no loading)
    // 2. Remove old NavigatorHosts and their container views
}
```

`reconcileFragments` only adds container views for new tabs — `NavigatorHost` Fragments are created lazily via `ensureNavigatorHost()` the first time a tab is selected. This matches the iOS lazy-loading behavior, where UIKit only calls `navigator.start()` on the selected tab and SwiftUI only evaluates unselected tab bodies when first tapped.

This is called from both `acceptDirective` (server pushed a new configuration) and `onSelectTab` (user tapped a tab). The `onSelectTab` case is needed because `TabManager.selectTab()` can mutate the tab list when the user switches away from a hard-deprecated tab — the deprecated tab is removed and its replacement is inserted, and the new container view must be created for it. iOS doesn't need an explicit reconciliation call because SwiftUI observes `@Published` changes and reconciles views automatically (see [The tab bar is just a bar](#the-tab-bar-is-just-a-bar) above).

#### Navigator Configuration

`HotwireActivity` requires a `navigatorConfigurations()` override that maps tabs to `NavigatorConfiguration` objects. This tells Hotwire which `NavigatorHost` Fragment to use for each tab:

```kotlin
override fun navigatorConfigurations(): List<NavigatorConfiguration> {
    return tabManager.tabs.map { tab ->
        NavigatorConfiguration(
            name = "tab-${tab.id}",
            startLocation = java.net.URI(BASE_URL).resolve(tab.path).toString(),
            navigatorHostId = tab.id
        )
    }
}
```

The `navigatorHostId` links each configuration to the `FragmentContainerView` with the matching View ID. This is the Android equivalent of iOS's `NavigatorStore`, using `FragmentManager`'s built-in Fragment lifecycle instead of an explicit UUID-keyed cache.

### DynamicTabBarApplication

Standard Hotwire Native Android setup in the `Application` subclass:

```kotlin
class DynamicTabBarApplication : Application() {
    override fun onCreate() {
        super.onCreate()

        Hotwire.loadPathConfiguration(
            context = this,
            location = PathConfiguration.Location(
                assetFilePath = "json/path-configuration.json",
                remoteFileUrl = "$BASE_URL/configurations/navigation"
            )
        )

        Hotwire.defaultFragmentDestination = HotwireWebFragment::class
        Hotwire.registerFragmentDestinations(
            HotwireWebFragment::class,
            HotwireWebBottomSheetFragment::class
        )

        Hotwire.registerBridgeComponents(
            BridgeComponentFactory("navigation", ::NavigationComponent)
        )
    }
}
```

Path configuration is loaded from both a bundled asset (offline fallback) and a server URL (runtime overrides). This matches the iOS setup.

## Platform Differences from iOS

| Concern                   | iOS (SwiftUI)                          | Android (Compose)                                        |
| ------------------------- | -------------------------------------- | -------------------------------------------------------- |
| Container identity        | `UUID`                                 | `Int` (View ID)                                          |
| Tab rendering             | SwiftUI `TabView` with `Tab(value:)`   | Compose `Scaffold` + `NavigationBar`                     |
| Web view hosting          | `Navigator` cached in `NavigatorStore` | `NavigatorHost` Fragment in `FragmentContainerView`      |
| View lifecycle            | SwiftUI manages automatically          | Manual Fragment transactions (`reconcileFragments`)      |
| Bridge → UI communication | `NotificationCenter`                   | `TabDirectiveRouter` singleton                           |
| Tab bar visibility        | `.toolbar(.hidden, for: .tabBar)`      | Conditionally render `NavigationBar` in `bottomBar`      |
| Tab switching             | `TabView(selection:)` binding          | `View.VISIBLE` / `View.GONE` on container views          |
| State observation         | `@Published` + `@ObservedObject`       | `mutableStateOf` + Compose recomposition                 |
| Icon mapping              | SF Symbols (native)                    | SF Symbol names → Material Icons (mapped)                |
| Process death             | N/A (SwiftUI rebuilds)                 | `super.onCreate(null)` to prevent stale Fragment restore |

## What's Identical

- **TabManager** — same algorithm, same cases, same logging, same tests
- **NavigationComponent** — same bridge message parsing and routing
- **Types** — `TabData`, `TabsDirective`, `TabItem`, `DeprecationEntry` are structurally identical
- **Reconciliation cases** — all 11 cases from [reconciliation.md](reconciliation.md) behave the same
- **Morphing semantics** — container identity preserved, web view and navigation stack survive
- **Deprecation filtering** — soft/hard deprecation, replacement insertion, same two-pass algorithm

---

## Appendix: XML Views (Fragments)

The Compose version uses a declarative `NavigationBar` composable — stateless buttons rendered from `mutableStateOf` state, with Compose handling the diffing. The Fragments version replaces this with Material's `BottomNavigationView`, an imperative widget with its own internal state, selection tracking, and animation systems.

The tradeoff mirrors the iOS SwiftUI → UIKit split: in Compose, the runtime handles diffing for us — we write `syncState()` to copy values into `mutableStateOf`, and Compose decides what to recompose. In the Fragments version there is no diffing runtime, so we are the diffing runtime: `applyTabState()` compares the current menu item list by ID, only rebuilds on structural changes, and updates item properties in-place. This is the same role as UIKit's `applyTabState()`.

### What's identical

`TabManager`, `NavigationComponent`, `TabDirectiveRouter`, and `DynamicTabBarApplication` are verbatim copies. Nothing in these files references Compose or XML Views. The two Android implementations share them via identical source files, the same way the two iOS implementations share `TabManager`, `NavigationComponent`, and `Notifications`.

### What's different

| Concept            | Compose                                             | Fragments (XML Views)                                       |
| ------------------ | --------------------------------------------------- | ----------------------------------------------------------- |
| Layout             | `setContent { Scaffold { ... } }`                   | `setContentView(R.layout.activity_main)` (XML)              |
| Tab bar            | Compose `NavigationBar` (stateless)                 | `BottomNavigationView` (stateful, internal animation)       |
| State observation  | `mutableStateOf` + Compose recomposition            | Imperative `applyTabState()` calls                          |
| State sync         | `syncState()` (2 lines — copy values)               | `applyTabState()` (~50 lines — imperative UI update)        |
| Tab bar visibility | Conditionally render `NavigationBar` in `bottomBar` | `bottomNav.visibility = GONE / VISIBLE`                     |
| Selection          | `NavigationBarItem(selected, onClick)`              | `bottomNav.selectedItemId` + `setOnItemSelectedListener`    |
| Insets             | `Scaffold` handles automatically                    | Manual `ViewCompat.setOnApplyWindowInsetsListener`          |
| Bootstrap timing   | `window.decorView.post { }` (wait for Compose)      | Direct `commitNow()` in `onCreate` (XML attached instantly) |
| Icon mapping       | SF Symbol names → `ImageVector` (Material Icons)    | SF Symbol names → `Int` (drawable resource IDs)             |

### Why `mutableStateOf` isn't needed

In Compose, `tabs` and `selectedId` are `mutableStateOf` properties that mirror `TabManager`'s state. When `TabManager` reconciles, `syncState()` copies the new values, and Compose automatically recomposes only what changed. The Activity doesn't need to know what changed — Compose figures that out.

In the Fragments version, there is no reactive UI layer. The Activity calls `applyTabState()` directly, which reads `TabManager`'s state and imperatively updates `BottomNavigationView` and container visibility to match. This is the same imperative pattern as UIKit's `applyTabState()`, and the two methods have the same structure:

1. **Structural:** rebuild menu items / call `setViewControllers` (only when the set of tabs changed)
2. **Surgical:** update title and icon on existing items / `tabBarItem` properties
3. **Selection:** set `selectedItemId` / `selectedIndex`
4. **Visibility:** show/hide the tab bar and fragment containers / `tabBar.isHidden`

### BottomNavigationView animation suppression

This is the one concern unique to the Fragments version — it has no equivalent in Compose, SwiftUI, or UIKit. Their tab bar widgets either handle rebuilds silently (UIKit's `UITabBarController`) or are stateless (Compose's `NavigationBar`, SwiftUI's `TabView`).

`BottomNavigationView` has two internal animation systems that fire during menu rebuilds:

1. **`AutoTransition`** in `NavigationBarMenuView.updateMenuView()`: when the selected item changes, `beginDelayedTransition` queues an animated layout transition. During a rebuild, `menu.clear()` resets the internal `selectedItemId` to 0 (a quiet field write, not a public API call). The subsequent `setSelectedItemId()` sees a change from 0 to the correct ID and triggers the transition — icons visibly fly into position.

2. **`ValueAnimator`** on each `NavigationBarItemView`: each item has an `activeIndicatorAnimator` that animates the indicator pill's alpha and scale. `buildMenuView()` creates new item views at progress 0, then `setCheckedItem()` animates them to progress 1. This is the "expand from center" animation — appropriate for first load, but jarring on every rebuild.

The fix uses the presenter's own batching mechanism (the same pattern as `BottomNavigationView.inflateMenu()`):

```kotlin
@Suppress("RestrictedApi")
private fun applyTabState() {
    // ...
    if (structureChanged) {
        val presenter = bottomNav.getPresenter()
        val fromBootstrap = currentIds.size <= 1

        if (!fromBootstrap) bottomNav.isItemActiveIndicatorEnabled = false

        presenter.setUpdateSuspended(true)

        menu.clear()

        for ((i, tab) in tabs.withIndex()) {
            menu.add(Menu.NONE, tab.id, i, tab.title).setIcon(iconForTab(tab.icon))
        }

        presenter.setUpdateSuspended(false)
        presenter.updateMenuView(true)

        bottomNav.isItemActiveIndicatorEnabled = true
    }
    // ...
}
```

Three techniques, each addressing a specific animation system:

1. **Presenter suspension** (`setUpdateSuspended`): prevents `buildMenuView()` from running on the empty menu during `menu.clear()`, so `selectedItemId` is never reset to 0. The single flush via `updateMenuView(true)` calls `buildMenuView()` directly — the non-animated structural path. `setSelectedItemId()` after the rebuild finds the selection already correct and becomes a no-op, so `beginDelayedTransition` is never called.

2. **Disable indicator** (`isItemActiveIndicatorEnabled = false`): prevents the `ValueAnimator` in each item view from firing when `buildMenuView()` → `setCheckedItem()` → `setChecked(true)` runs on the newly created item views.

3. **Bootstrap exemption** (`fromBootstrap` check): skips indicator disabling for the bootstrap → tabbed transition, preserving the natural first-load animation feel.

`getPresenter()` is annotated `@RestrictTo(LIBRARY_GROUP)` — a lint warning, not a hard block. The `@Suppress("RestrictedApi")` annotation acknowledges this. `setUpdateSuspended()` and `updateMenuView()` are fully public.
