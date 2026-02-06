# Tab Reconciliation Algorithm

The server can send a new tab configuration at any time – typically on every page load, but the client must be prepared to reconcile whenever one arrives (see [protocol.md](protocol.md)).

The client is highly stateful. Each tab owns a web view, navigation stack, scroll position, and form state. These states are persistent – when switching between tabs, users expect to return to exactly where they left off. Disposing a tab means all of that is lost.

The client does not report its current state back to the server. There is no coordination. The server sends the full desired configuration every time, and it is entirely up to the client to reconcile the server's intent with its own realities. That is what this algorithm is about.

The abstract navigation state is:

```
NavigationState =
    | Bootstrap(Controller)   – single web view, no tab bar
    | Tabbed(Vec<Controller>) – multiple web views, visible tab bar
```

## Client-Side UUID Identity

There are two distinct things: the **container** and what it **represents**.

The container is the stateful thing – it holds the web view, navigation stack, and scroll position. It is keyed by a client-side **UUID** that never changes for its lifetime. Same UUID means same state preserved, new UUID means fresh state, removed UUID means state destroyed.

What a container represents – its server ID (`"home"`, `"explore"`), title, icon, and path – can change freely without affecting the container itself, and the UI states that it represents. This separation is what makes the algorithm work:

- **Morphing:** change what a container represents while preserving its UI states
- **Promotion:** a bootstrap container (representing nothing) becoming one of the tabs in the tabbed view
- **Demotion:** a named container clears its server identity, becoming the lone bootstrap tab

### Types

```swift
/// Server's representation of a tab
struct TabData: Codable, Hashable {
    let id: String    // Server ID (e.g., "home", "explore")
    let title: String
    let icon: String
    let path: String
}

/// Client's internal representation – the container
struct TabItem: Identifiable, Equatable {
    let uuid: UUID       // Container identity (never changes)
    var serverId: String // What it represents (empty for bootstrap)
    var title: String
    var icon: String
    var path: String
}
```

## Initial State

The client starts in bootstrap mode with one container:

```
tabs = [
    TabItem(uuid: <random>, serverId: "", title: "Bootstrap", icon: "", path: "/")
]
selectedUuid = tabs[0].uuid
```

The tab bar is hidden. The single container fills the screen.

## Transition Cases

### Case 1: Bootstrap → Bootstrap

```
bootstrap → bootstrap
```

**Example:** App launches, navigates to `/`, server redirects to `/sign-in` with bootstrap directive.

**Reconciliation:** No-op. Same container, history preserved.

### Case 2: Bootstrap → Tabbed

```
bootstrap → tabbed(A, *B*, C, D, E)
```

**Example:** User signs in. Server sends tabbed directive with `active: "explore"`.

**Reconciliation:**

1. **Promote** the bootstrap container to the server's active tab – assign it the active tab's server ID, title, icon, and path.
2. Create new containers (fresh UUIDs) for all other tabs in the directive.
3. **This is the only case where the server's `active` hint is respected** – because the bootstrap container has no server ID, there is no prior selection to conflict with.

The bootstrap container's UUID is preserved, so its web view, navigation history, and scroll position all survive the transition.

### Case 3: Tabbed → Bootstrap

```
tabbed(A, *B*, C, D, E) → bootstrap
```

**Example:** User signs out. Server sends bootstrap directive.

**Reconciliation:**

1. **Demote** the currently selected container – clear its server ID.
2. Dispose all other containers.

The selected container survives. Its web view is not reloaded.

### Case 4: Tabbed → Tabbed (No Change)

```
tabbed(A, *B*, C, D, E) → tabbed(A, *B*, C, D, E)
```

**Example:** Normal navigation within a tab. Most common case.

**Reconciliation:** No-op. Same containers, same order, same selection.

### Case 5: Tabbed → Tabbed (Active Hint Changed)

```
tabbed(A, *B*, C, D, E) → tabbed(A, B, *C*, D, E)
                                       ~~~
```

**Example:** User is on the Home tab and follows a link to `/explore/42`. The server's URL-matching heuristic says `active: "explore"`, but the user never tapped the Explore tab.

**Reconciliation:** **Ignore the server's active hint.** Keep the client's current selection.

The server's active detection is stateless URL prefix matching. On the web, this is probably just a visual indicator on the tab bar (which tab link is highlighted). But on native, each tab owns a navigation stack. It is [generally accepted](https://frankrausch.com/ios-navigation/) that tabs should not switch without the user interacting with the tab switcher UI – the user would find themselves on a different tab than the one they were browsing in.

**Rule:** After Case 2, the server's `active` field is advisory only. The client never programmatically switches tabs.

### Case 6: Tabbed → Tabbed (Ordering Changed)

```
tabbed(A, *B*, C, D, E) → tabbed(A, *B*, E, D, C)
                                         ~~~~~~~
```

**Example:** A deploy changed the tab order while the user was navigating.

**Reconciliation:** **Ignore ordering changes** when no tabs are added or removed. Reordering tabs mid-session is jarring with little benefit. The new order takes effect on next app restart or next bootstrap→tabbed transition.

**Exception:** When tabs are added or removed (Cases 7–9), the server's ordering is adopted since we are already making structural changes.

### Case 7: Tabbed → Tabbed (Tabs Added)

```
tabbed(A, *B*, C) → tabbed(A, *B*, C, D, E)
                                      ~~~~
```

**Example:** Feature flag enabled, user completed purchase, or deploy added new tabs.

**Reconciliation:**

1. Keep all existing containers (UUIDs preserved).
2. Create new containers for added tabs (fresh UUIDs).
3. **Adopt server ordering** (since we are adding tabs anyway, the reorder is not the most jarring part).
4. Active tab unchanged.

### Case 8: Tabbed → Tabbed (Tabs Removed)

```
tabbed(A, *B*, C, D, E) → tabbed(A, *B*, C)
                                         ~ (D, E removed)
```

**Example:** Feature flag disabled, subscription downgraded, or deploy removed tabs.

**Reconciliation:**

1. Remove containers whose server IDs are absent from the new directive.
2. Dispose removed containers and their state.
3. **Adopt server ordering** (since we are adding tabs anyway, the reorder is not the most jarring part).
4. Active tab unchanged.

When the server marks tabs as `deprecated` (see [protocol.md](protocol.md#graceful-tab-removal-deprecated-replaces)), removal can be deferred until a less disruptive moment – converting an immediate removal into a graceful phase-out.

### Case 9: Tabbed → Tabbed (Active Tab Removed)

```
tabbed(A, B, *C*, D, E) → tabbed(A, *B*,    D, E)
                                         ~ (C removed, was active)
```

**Example:** User is on a tab that loses its feature flag, or a deploy removes the tab the user is currently viewing.

**The problem:** The page that sent this directive was just rendered in a container whose server identity no longer exists in the directive. We cannot simply dispose the container and reopen the same URL in another tab – the page may contain form state, flash messages, or other ephemeral content that would be lost if we navigated to the same URL again.

**Reconciliation (least bad option):**

1. The active container (C) **morphs** into the server's suggested active tab (B) – it adopts B's server ID, title, and icon, but keeps its own UUID.
2. The container previously representing B is disposed.
3. All other surviving containers preserve their UUIDs.
4. Adopt server ordering.

This means the user's current page is now displayed under a differently-named tab. The container that was previously B loses its navigation history. This is not great UX, but it preserves the most important thing: the content the user is currently looking at.

**Avoiding this case:**

This is terrible UX and should be actively avoided. Better tools:

- **Major redesign:** Bump a version number to trigger a full-app refresh modal.
- **Subscription expired:** Trigger a modal asking the user to refresh the app rather than silently removing their current tab.
- **Feature sunset:** Use the `deprecated` and `replaces` extensions (see [protocol.md](protocol.md#graceful-tab-removal-deprecated-replaces)) to defer removal until the user navigates away. This converts Case 9 into a deferred Case 8, giving the user time to finish what they are doing. The server should keep the old URL prefix working while the tab is still visible – either maintain the feature, or serve a catch-all page explaining why it went away.

### Case 10: Tabbed → Tabbed (Tab Replaced)

```
tabbed(A, *B*, C, D, E) → tabbed(A, *F*, C, D, E)
                                     ~ (B replaced by F)
```

**Example:** Either an intentional replacement (feature renamed/merged) or two unrelated changes (B removed, F added) that happen to coincide.

**Reconciliation:**

Without an explicit `replaces` signal from the server, the client cannot distinguish intentional replacement from coincidence. The algorithm handles it as a combination of removal + addition:

**If the replaced tab is not active:** Remove old container, add new container (Cases 8 + 7). State lost.

**If the replaced tab is active:** Morph the container into the new tab (Case 9 logic). The container survives, but now represents F. State preserved by necessity – there is no good alternative.

**With explicit signals:** When the server uses `deprecated` + `replaces` (see [protocol.md](protocol.md#graceful-tab-removal-deprecated-replaces)), the client can handle the transition gracefully – deferring removal of the old tab and swapping in the replacement at the right moment.

### Case 11: Tabbed → Tabbed (All Tabs Replaced)

```
tabbed(A, *B*, C) → tabbed(X, *Y*, Z)
                           ~~~~~~~~~ (all tabs replaced)
```

**Example:** Major app redesign deployed, or user switches accounts (though account switching should typically go through a bootstrap phase).

**Reconciliation:** This is a special case of Case 10 where all tabs happen to change. The active container morphs into the server's active tab. All other containers are new.

In practice, this scenario should be handled by a version bump triggering a full-app refresh rather than attempting in-place reconciliation.

## Summary Table

| Case | Transition                | Server `active` | Action                                      |
| ---- | ------------------------- | --------------- | ------------------------------------------- |
| 1    | Bootstrap → Bootstrap     | –               | No-op                                       |
| 2    | Bootstrap → Tabbed        | **Respected**   | Promote bootstrap container to active       |
| 3    | Tabbed → Bootstrap        | –               | Demote selected container, dispose others   |
| 4    | Tabbed → Tabbed (same)    | Ignored         | No-op                                       |
| 5    | Tabbed → Tabbed (active)  | **Ignored**     | Keep client selection                       |
| 6    | Tabbed → Tabbed (order)   | Ignored         | Ignore reorder (wait for restart)           |
| 7    | Tabbed → Tabbed (+tabs)   | Ignored         | Add containers, adopt server order          |
| 8    | Tabbed → Tabbed (-tabs)   | Ignored         | Remove containers, adopt server order       |
| 9    | Tabbed → Tabbed (-active) | Used for morph  | Morph active container into server's active |
| 10   | Tabbed → Tabbed (replace) | Depends         | Remove + add, or morph if active            |
| 11   | Tabbed → Tabbed (all new) | Used for morph  | Special case of 10                          |

## Implementation Reference

See [ios.md](ios.md) for the full SwiftUI implementation guide.
