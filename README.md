# Server-Driven Tab Bar Navigation for Hotwire Native

A reference implementation showing how a Rails server can control native iOS/Android tab bars dynamically via the Hotwire Native bridge. This is a working proof-of-concept extracted from a production hybrid app, intended to demonstrate the pattern and inform future extraction into reusable libraries.

## Problem

Hotwire Native gives the server control over _content_ – every page is a web view driven by Rails. The tab bar is the last piece of native UI that the server cannot drive.

Use cases:

- Show/hide the tab bar when the user is signed in/out
- Add/remove tabs based on feature flags or subscription tier
- Sunset features gracefully without stranding users mid-task
- Dynamic promotional content, A/B testing, etc

## Solution

Allow the server sends a tab configuration to the native app via the Hotwire Native bridge component. See [docs/protocol.md](docs/protocol.md) for details about these server-driven configuration messages.

### Why This Is Hard

Native tab bars are not merely a navigational element like a `<nav>` on the web. Each tab owns its own navigation stack, scroll position, form state, and web view instance. The mental model is that these states are persistent – when switching between tabs, users expect to return to exactly where they left off. It is also [generally accepted](https://frankrausch.com/ios-navigation/) that tabs should not switch without explicit user interaction; actions taken in one tab should not teleport the user to a different tab.

So the hard part is not _sending_ tab configuration from the server – that is straightforward. The hard part is **preserving tab state in the face of changes**. The server doesn't know the client's state – it sends the full desired configuration on every page load. The client must diff this against its current state and figure out what, if anything, actually changed and the best way to apply those changes while preserving as much useful state as possible.

Most of the time, nothing changed – the user just navigated within a tab. The client must recognize this and not touch anything. When something did change – say the server added a new tab – the client must figure out where to insert it without blowing away the navigation stacks, scroll positions, and web views of the existing tabs. And then there are the harder cases: what if the tab the user is currently looking at is gone from the new configuration?

That is what this entire project is about.

### Approach

We want this to work without preloading the app bundle with a list of known tabs that may drift from the server-side content. So we start in **bootstrap mode** – assume the server wants no tabs and load the initial `startLocation` in a single web view. In the course of rendering that page, the server will send a tab configuration, and chances are, we will need to show a tabbed view where the page we just loaded is one of the tabs.

The naive approach is to switch between a single view and a TabView:

```swift
if tabs.isEmpty {
    SingleView(controller: controller)  // no tab bar
} else {
    TabView { ... }                     // tab bar
}
```

But then we get a flash of the loaded page, only to unload it, tear down the entire view hierarchy, and wait for the same page to load again in a newly created TabView.

Instead, the client **always renders content inside a TabView**. When there are no tabs, it renders a single tab with the tab bar hidden. When there are tabs, it renders N tabs with the tab bar visible. The view structure never changes – only the tab count does.

Each tab is an abstract container keyed by a client-side **UUID**. When the server sends a 5-tab configuration, the bootstrap tab's UUID is assigned to whichever tab the server says is active (e.g. "Home"). The other 4 tabs get fresh UUIDs. From the native framework's perspective, the bootstrap tab was always there – it just got siblings and a new label. Its web view, navigation history, and scroll position are all preserved because the UUID never changed.

This is the core mechanism that makes everything else work. The UUID is how the client tracks tab state:

- **Same UUID** = same tab state (web view, navigation history, scroll position all preserved)
- **New UUID** = fresh tab with no history
- **Removed UUID** = tab state destroyed

The reconciliation algorithm's job is to map incoming server tab definitions onto these UUID-keyed containers – deciding which existing containers to keep, which to create, and which to deallocate – while preserving as much state as possible. See [docs/reconciliation.md](docs/reconciliation.md) for the full algorithm.

### Graceful Tab Removal

Reconciliation handles what happens when tabs change. But equally important is _when_ they change. In practice, tabs don't just change during big redesigns – features get sunset, A/B tests end, subscriptions lapse. If the user is on a tab that disappears, there's often no good recovery.

The protocol includes a graceful deprecation/replacement extension that lets the server signal a tab is going away, so the client removes it at the right moment – not while the user is mid-task. This is what makes dynamic tabs a practical tool teams can safely reach for and put to good use – not a big red button everyone is afraid to push. See [docs/protocol.md](docs/protocol.md) for details.

## Reference Implementations

- **[Rails server](rails/)** — Stimulus controller and ViewComponent that drives all four clients. See [docs/server.md](docs/server.md).
- **[iOS (SwiftUI)](ios-swiftui/)** — the original reference implementation. Defines the algorithm, types, and structure that all other implementations follow. See [docs/ios.md](docs/ios.md).
- **[iOS (UIKit)](ios-uikit/)** — direct port of the SwiftUI version. The shared files are identical; only the UI layer differs. See the [UIKit appendix](docs/ios.md#appendix-uikit).
- **[Android (Compose)](android-compose/)** — 1:1 port of the SwiftUI algorithm to Android with Jetpack Compose. See [docs/android.md](docs/android.md).
- **[Android (Fragments)](android-fragments/)** — same algorithm with XML (Fragments) Views. Shares identical common files with Compose version, just adapted for the different UI framework. See the [Fragments appendix](docs/android.md#appendix-xml-views-fragments).

## Documentation

| Document                                         | Description                                                                |
| ------------------------------------------------ | -------------------------------------------------------------------------- |
| [docs/protocol.md](docs/protocol.md)             | Wire protocol – message format, field semantics, delivery guarantees       |
| [docs/reconciliation.md](docs/reconciliation.md) | Reconciliation algorithm – transition types with design rationale          |
| [docs/server.md](docs/server.md)                 | Server implementation – Rails controllers/views, Stimulus bridge component |
| [docs/ios.md](docs/ios.md)                       | iOS implementation – SwiftUI and UIKit                                     |
| [docs/android.md](docs/android.md)               | Android implementation – Compose and Fragments                             |
