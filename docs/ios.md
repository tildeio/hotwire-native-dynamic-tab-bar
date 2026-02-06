# iOS Implementation Guide

This documents the SwiftUI implementation of the reconciliation algorithm defined in [reconciliation.md](reconciliation.md), using the wire protocol from [protocol.md](protocol.md).

A [UIKit appendix](#appendix-uikit) covers the differences for UIKit-based apps — the shared files (`TabManager`, `NavigationComponent`, `Notifications`) are identical.

## Prerequisites

- iOS 18.0+ (uses `Tab(value:)` API introduced in iOS 18)
- Hotwire Native iOS framework

## Key Design Decision: Stable TabView

The implementation **always renders a TabView**, even in bootstrap mode. Bootstrap mode is a TabView with one tab and a hidden tab bar. This is not obvious – the natural approach is to switch between two different view structures:

```swift
if tabs.isEmpty {
    BootstrapView(navigator: navigator)
} else {
    TabView { ... }
}
```

This fails. SwiftUI destroys the old view structure before creating the new one. UIKit view controllers receive `viewWillDisappear`/`viewDidDisappear` _after_ SwiftUI tries to show them in the new structure, resulting in a blank screen and race conditions.

By always using a TabView, the view structure never changes – only the tab count and tab bar visibility do. SwiftUI sees the bootstrap tab _staying in place_ and gaining siblings, rather than being torn down and rebuilt.

The [reconciliation algorithm](reconciliation.md) explains how the client decides which navigators to keep, create, and dispose. This guide covers the SwiftUI mechanics that make those operations work.

## Architecture

The implementation splits into three concerns:

1. **Parsing:** `NavigationComponent` receives bridge messages and posts a notification
2. **State:** `TabManager` implements the reconciliation algorithm
3. **Rendering:** `TabbedNavigator`, `NavigatorStore`, and `HotwireView` turn state into a TabView with live web views

The bridge component and the SwiftUI view hierarchy are in separate ownership trees, so they communicate via `NotificationCenter`.

## Types

### TabData (server representation)

Decoded directly from the bridge message. Matches the [protocol.md](protocol.md) wire format.

```swift
struct TabData: Codable, Hashable {
    let id: String // Server ID (e.g., "home", "explore")
    let title: String
    let icon: String
    let path: String
    var deprecated: String? = nil
    var replaces: String? = nil
}
```

### TabsDirective (parsed server intent)

```swift
enum TabsDirective: Equatable {
    case bootstrap                               // No tabs, hidden tab bar
    case tabbed(active: String, tabs: [TabData]) // Multiple tabs, visible tab bar
}
```

### TabItem (client container)

The client's internal model – the [container](reconciliation.md#client-side-uuid-identity) that holds tab state. The UUID is the container identity; the server ID is what it represents.

```swift
struct TabItem: Identifiable, Equatable {
    let uuid: UUID        // Container identity (never changes)
    var serverId: String  // What it represents (empty for bootstrap)
    var title: String
    var icon: String
    var path: String

    var id: UUID { uuid } // Alias for Identifiable conformance
}
```

## Components

### NavigationComponent

Bridge component registered with Hotwire Native. Receives `configure` events from the Stimulus controller and posts a notification.

```swift
final class NavigationComponent: BridgeComponent {
    nonisolated override class var name: String { "navigation" }

    override func onReceive(message: Message) {
        guard message.event == "configure" else { return }
        guard let data: MessageData = message.data() else { return }

        let directive: TabsDirective

        if data.tabs.isEmpty {
            directive = .bootstrap
        } else if let active = data.active {
            directive = .tabbed(active: active, tabs: data.tabs)
        } else {
            return // Protocol violation: non-empty tabs without active
        }

        NotificationCenter.default.post(
            name: .tabConfigurationDidChange,
            object: nil,
            userInfo: ["directive": directive]
        )
    }
}
```

Communication is via `NotificationCenter` because the bridge component and the SwiftUI view hierarchy are not in the same ownership tree.

### TabManager

`@MainActor` `ObservableObject` that owns the tab state and implements the [reconciliation algorithm](reconciliation.md).

```swift
@MainActor
final class TabManager: ObservableObject {
    @Published private(set) var tabs: [TabItem] = [/* initial: bootstrap tab */]
    @Published private(set) var selectedUuid: UUID = /* initial: bootstrap tab UUID */

    var isBootstrap: Bool { tabs.count == 1 }

    func accept(_ directive: TabsDirective) { /* reconciliation */ }
    func selectTab(uuid: UUID) { /* user interaction */ }
}
```

The `accept(_:)` method is the entry point for all server directives.

### TabbedNavigator

The main SwiftUI view. Always renders a `TabView`.

```swift
struct TabbedNavigator: View {
    @ObservedObject var tabManager: TabManager
    @StateObject private var store: NavigatorStore

    init(tabManager: TabManager, baseURL: URL) {
        // ...creates initial Navigator for bootstrap tab
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
        .onReceive(NotificationCenter.default.publisher(for: .tabConfigurationDidChange)) { notification in
            guard let directive = notification.userInfo?["directive"] as? TabsDirective else { return }
            tabManager.accept(directive)
        }
        .onChange(of: tabManager.tabs) { oldTabs, newTabs in
            let removedUuids = Set(oldTabs.map { $0.uuid }).subtracting(newTabs.map { $0.uuid })
            guard !removedUuids.isEmpty else { return }
            Task { @MainActor in
                store.remove(uuids: removedUuids)
            }
        }
    }
}
```

Key details:

- **Tab identity uses `tab.uuid`** (container identity), not `tab.serverId` – this is what makes the stable TabView work
- **Tab bar visibility** is controlled via `.toolbar(.hidden, for: .tabBar)` when in bootstrap mode
- **Navigator GC** happens in `.onChange(of: tabManager.tabs)`, actual removal deferred to the next run loop tick so SwiftUI can finish tearing down removed views before their navigators are disposed

### NavigatorStore

Maps container UUIDs to `Navigator` instances. Navigators are created lazily on first access and cached.

```swift
@MainActor
final class NavigatorStore: ObservableObject {
    private var navigators: [UUID: Navigator] = [:]
    private let baseURL: URL

    func navigator(for tab: TabItem) -> Navigator {
        if let existing = navigators[tab.uuid] { return existing }

        guard let url = URL(string: tab.path, relativeTo: baseURL) else {
            fatalError("Invalid tab path: \(tab.path)")
        }

        let navigator = Navigator(configuration: .init(name: "main", startLocation: url))
        navigators[tab.uuid] = navigator
        return navigator
    }

    func remove(uuids: Set<UUID>) { /* dispose navigators */ }
}
```

### HotwireView + NavigatorContainer

Bridges Hotwire Native into SwiftUI. Each tab's `Navigator` owns the WKWebView, navigation stack, and scroll position. `HotwireView` is a `UIViewControllerRepresentable` that wraps `navigator.rootViewController` in a `NavigatorContainer`:

```swift
struct HotwireView: UIViewControllerRepresentable {
    let navigator: Navigator

    func makeUIViewController(context: Context) -> NavigatorContainer {
        NavigatorContainer(navigator: navigator)
    }

    func updateUIViewController(_ container: NavigatorContainer, context: Context) {
        container.update(navigator: navigator)
    }
}
```

`NavigatorContainer` is a plain `UIViewController` that embeds `rootViewController` as a UIKit child via `addChild`/`didMove(toParent:)`.

Returning `rootViewController` directly from `makeUIViewController` causes a blank screen during the Case 9 morph (active tab removed, UUID reassigned to another tab). When tabs rearrange, SwiftUI may recreate the representable, calling `makeUIViewController` again. Without a container, both the old and new hosting controllers target the same `rootViewController` — the old one's `viewDidDisappear` fires after the new one's `viewWillAppear`, deactivating the WebView. Each `makeUIViewController` creates a fresh `NavigatorContainer`, so stale lifecycle events from the old hosting controller hit the old container, not `rootViewController`.

Same container UUID → same Navigator → all state preserved.

## Plumbing

### Register the bridge component

In your app initialization:

```swift
Hotwire.registerBridgeComponents([
    NavigationComponent.self,
    // ... other components
])
```

### Define the notification

```swift
extension Notification.Name {
    static let tabConfigurationDidChange = Notification.Name("tabConfigurationDidChange")
}
```

### View hierarchy

```swift
@main
struct MyApp: App {
    @StateObject private var tabManager = TabManager()
    let baseURL = URL(string: "http://localhost:3000")!

    var body: some Scene {
        WindowGroup {
            TabbedNavigator(tabManager: tabManager, baseURL: baseURL)
        }
    }
}
```

---

## Appendix: UIKit

Hotwire Native is a UIKit framework. The SwiftUI version bridges into it via `HotwireView` (`UIViewControllerRepresentable`) and `NavigatorContainer` — code that exists solely to protect against SwiftUI lifecycle quirks during morphs. The UIKit version doesn't need that bridging layer, using `navigator.rootViewController` directly as each tab's VC.

The tradeoff is the diffing engine: in SwiftUI, the runtime handles diffing for us — we provide identity via `tab.uuid` in `ForEach`, and SwiftUI decides what to create, update, and destroy. In UIKit there is no diffing runtime, so we are the diffing runtime: `applyTabState()` compares the current view controller list by identity, only calls `setViewControllers` on structural changes, and updates `tabBarItem` properties in-place.

### What's identical

`TabManager`, `NavigationComponent`, and `Notifications` are verbatim copies — they import Foundation, Combine, HotwireNative, and os.log, nothing SwiftUI-specific. `TabManager` uses `@Published`/`ObservableObject` (which are Combine, not SwiftUI), but nothing in the UIKit version subscribes to them reactively. They're inert but harmless, and keeping the files identical makes side-by-side comparison trivial.

### What's different

The SwiftUI version has 7 Swift files. The UIKit version has 6 — `HotwireView.swift` drops out.

| Concept            | SwiftUI                                                 | UIKit                                                    |
| ------------------ | ------------------------------------------------------- | -------------------------------------------------------- |
| Tab container      | `TabView(selection:)`                                   | `UITabBarController` subclass                            |
| Tab rendering      | `Tab(title, systemImage:, value:) { HotwireView(...) }` | `navigator.rootViewController` with `tabBarItem`         |
| Navigator bridge   | `HotwireView` + `NavigatorContainer` (76 lines)         | Not needed — direct child VC                             |
| Selection          | `Binding(get:set:)`                                     | `UITabBarControllerDelegate.didSelect` + `selectedIndex` |
| Notification       | `.onReceive(publisher)`                                 | `NotificationCenter.addObserver`                         |
| Tab GC             | `.onChange(of: tabs) { old, new in }`                   | Imperative `gcRemovedNavigators(previousUuids:)`         |
| Tab bar visibility | `.toolbar(.hidden, for: .tabBar)`                       | `tabBar.isHidden`                                        |
| Navigator cache    | `NavigatorStore: ObservableObject`                      | `NavigatorStore` (plain class)                           |

### Why HotwireView isn't needed

In SwiftUI, `Navigator.rootViewController` can't be returned directly from `makeUIViewController` because SwiftUI may recreate the `UIViewControllerRepresentable` during morphs. When that happens, both the old and new hosting controllers target the same `rootViewController` — the old one's `viewDidDisappear` fires after the new one's `viewWillAppear`, deactivating the WebView. `NavigatorContainer` wraps `rootViewController` as a UIKit child so stale lifecycle events hit the discarded container, not the navigator.

UIKit doesn't have this problem. `UITabBarController` manages child view controllers directly — there is no representable layer that gets recreated. `navigator.rootViewController` is used as the tab's VC, exactly like `HotwireTabBarController` does.

### TabbedNavigator (UIKit)

A `UITabBarController` subclass. The key method is `applyTabState()`, which runs after every tab manager mutation:

```swift
private func applyTabState() {
    let tabs = tabManager.tabs
    let currentVCs = viewControllers ?? []

    let desiredVCs: [UIViewController] = tabs.map { tab in
        store.navigator(for: tab).rootViewController
    }

    // Structural change only — skip when VC list is identical
    if !vcListsMatch(currentVCs, desiredVCs) {
        setViewControllers(desiredVCs, animated: false)
    }

    // Surgical property update (in-place, flicker-free)
    for (tab, vc) in zip(tabs, desiredVCs) {
        vc.tabBarItem.title = tab.title
        vc.tabBarItem.image = UIImage(systemName: tab.icon)
    }

    // Start selected navigator lazily (no-op if already started)
    if let selectedIndex = tabs.firstIndex(where: { $0.uuid == tabManager.selectedUuid }) {
        self.selectedIndex = selectedIndex
        store.navigator(for: tabs[selectedIndex]).start()
    }

    tabBar.isHidden = tabManager.isBootstrap
}
```

Three details matter:

1. **`setViewControllers` only runs on structural changes.** The identity check (`===` on each VC) skips the call when the VC list hasn't changed — the UIKit equivalent of SwiftUI's `ForEach` diffing by `tab.uuid`. Since `NavigationComponent` fires on every page load, most calls are no-ops and this avoids unnecessary work.

2. **Tab bar item properties update in-place.** The existing `UITabBarItem` object's `title` and `image` are modified directly, not replaced with a new `UITabBarItem(...)`. Replacing the object forces UIKit to re-render the tab bar; modifying properties on the existing object lets UIKit decide whether anything actually changed.

3. **`navigator.start()` is called on selection only.** Non-selected tabs start lazily when first tapped, matching `HotwireTabBarController`'s pattern. This avoids eagerly loading URLs for tabs the user hasn't visited.

### View hierarchy (UIKit)

```swift
// AppDelegate.swift — Hotwire setup
@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions ...) -> Bool {
        Hotwire.loadPathConfiguration(from: [
            .file(Bundle.main.url(forResource: "path-configuration", withExtension: "json")!),
            .server(URL(string: "http://localhost:3000/configurations/navigation.json")!),
        ])
        Hotwire.registerBridgeComponents([NavigationComponent.self])
        Hotwire.config.debugLoggingEnabled = true
        return true
    }
}

// SceneDelegate.swift — programmatic window
class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: ...) {
        guard let windowScene = (scene as? UIWindowScene) else { return }
        let tabManager = TabManager()
        let tabbedNavigator = TabbedNavigator(tabManager: tabManager, baseURL: URL(string: "http://localhost:3000")!)
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = tabbedNavigator
        window.makeKeyAndVisible()
        self.window = window
    }
}
```
