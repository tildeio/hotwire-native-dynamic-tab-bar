# Wire Protocol

This document specifies the message format exchanged between the server-side Stimulus bridge controller and the native bridge component.

## Message Format

Every `configure` message is a JSON object:

```ts
{
  active: string | null;
  tabs: TabData[];
}
```

`tabs` is always empty or has 2+ elements (never exactly 1). When non-empty, `active` is guaranteed to reference a valid `id` in the array. See [Server Invariants](#server-invariants).

Where `TabData` is:

```ts
{
  id: string;    // stable identifier, unique within the array
  title: string; // display label
  icon: string;  // canonical icon name
  path: string;  // relative URL, resolved against the app's start URL
}
```

## Bootstrap Mode

An empty `tabs` array means the client should show a single full-screen web view with no tab bar. This is also the client's assumed initial state before the server has sent any configuration.

```json
{ "active": null, "tabs": [] }
```

## Tabbed Mode

A non-empty `tabs` array means the client should show a tab bar. The `active` field identifies which tab the current page belongs to.

```json
{
  "active": "home",
  "tabs": [
    {
      "id": "home",
      "title": "Home",
      "icon": "house.fill",
      "path": "/"
    },
    {
      "id": "explore",
      "title": "Explore",
      "icon": "magnifyingglass",
      "path": "/explore"
    },
    {
      "id": "library",
      "title": "Library",
      "icon": "books.vertical",
      "path": "/library"
    },
    {
      "id": "profile",
      "title": "Profile",
      "icon": "person.crop.circle",
      "path": "/profile"
    }
  ]
}
```

The client maintains its own tab selection state and does not report it back to the server. The server's `active` field is its best guess based on URL matching, but the client treats it as a **hint**, not a command.

Typically, the only time the client uses it is during the bootstrap-to-tabbed transition, where there is no prior selection to preserve. Once the app is in tabbed mode, the client [generally should not switch tabs programmatically](https://frankrausch.com/ios-navigation/) – the user's current tab selection is authoritative.

Similarly, the array order reflects the server's intended tab order, but the client may choose to defer applying ordering changes to avoid jarring mid-session reorders.

See [reconciliation.md](reconciliation.md) for the full rules.

## Idempotency

The server may sends a `configure` message at any time, typically on every Turbo page load. Most of the time the configuration has not changed. Clients **must** diff incoming config against current state and no-op when nothing changed.

## Server Invariants

1. **`tabs` is always 0 or 2+.** The server never sends exactly 1 tab.

2. **If `tabs` is non-empty, `active` references a valid tab ID.**

3. **Tab IDs are stable across navigation.** The same conceptual tab always uses the same `id` value.

4. **`path` is a relative URL.** Clients resolve it against the app's start URL using standard [RFC 3986](https://www.rfc-editor.org/rfc/rfc3986#section-5) resolution.

## Icon Mapping

The `icon` field is an opaque string. It is up to the application to define the set of possible names and how they map to each platform's native icons or custom design assets.

## Extensions

Clients should ignore unrecognized fields on `TabData`, allowing the protocol to be extended over time. For example, a future extension may introduce a `badge` field.

### Graceful Tab Removal (`deprecated`, `replaces`)

Tabs can disappear for many reasons: a feature is sunset, seasonal content expires, an A/B test ends, a user's subscription lapses.

If the user happens to be on a tab that was removed when the next configuration arrives, the client is in a difficult position – the page they are viewing belongs to a tab that no longer exists, and there is no good way to recover without losing something (see [reconciliation.md](reconciliation.md), Case 9).

`deprecated` and `replaces` give the server a way to signal that a tab is going away, so the client can remove it at a less disruptive moment instead of immediately.

This extension introduces two new optional fields on `TabData`:

```ts
{
  // ...
  deprecated?: "soft" | "hard";
  replaces: string;
}
```

**`deprecated`** signals that the tab is being phased out. The value controls urgency:

- **`"soft"`** – Remove at the next natural opportunity: app restart, or the next bootstrap-to-tabbed transition. Until then, the tab remains visible and functional. The server should ensure the path it points to remain valid (either keep the feature working, or maintain a catch-all notice page explaining why it went away).
- **`"hard"`** – Remove at all soft opportunities, plus also when the user switches away from the tab. The user can finish what they are doing, but the tab does not survive a tab switch.

**`replaces`** contains the `id` of a deprecated tab that this tab is replacing. While the deprecated tab is still visible, the replacement is hidden. Once the deprecated tab is finally removed, the replacement appears in its place. This is primarily a tool for visual balance – apps often want a stable tab count, and `replaces` lets you swap one tab for another across a deprecation cycle and keep the total tab count the same.

#### Example: Sunsetting a Tab

Suppose the app has four tabs (Home, Explore, Library, Profile) and the Explore feature is being retired in favor of a new Favorites tab. The server would send:

```json
{
  "active": "home",
  "tabs": [
    {
      "id": "home",
      "title": "Home",
      "icon": "house.fill",
      "path": "/"
    },
    {
      "id": "explore",
      "title": "Explore",
      "icon": "magnifyingglass",
      "path": "/explore",
      "deprecated": "soft",
    },
    {
      "id": "favorites",
      "title": "Favorites",
      "icon": "heart.fill",
      "path": "/favorites",
      "replaces": "explore",
    },
    {
      "id": "library",
      "title": "Library",
      "icon": "books.vertical",
      "path": "/library"
    },
    {
      "id": "profile",
      "title": "Profile",
      "icon": "person.crop.circle",
      "path": "/profile"
    }
  ]
}
```

If a client is bootstrapping for the first time, it'd simply show the new `Home | Favorites | Library | Profile` configuration.

Otherwise, if it's already showing `Home | Explore | Library | Profile`, it will _keep_ showing that to avoid a jarring tab disappearance mid-session, regardless of whether the user is on the deprecated Explore tab or not.

On the other hand, if the server sent `"deprecated": "hard"`, it signals a more urgent request to kill the tab at the soonest opportunity.

If the user is not _currently_ on the deprecated Explore tab when the message arrive, the client will switch it out right away.

If the user _is_ on the Explore tab, it'll remain so long as the user is still actively browsing within that section, but as soon as they switch away to a different tab, the Explore tab will be replaced by the new Favorites tab instead.

In all cases, the tab count remained at 4 throughout.
