# Server Implementation Guide

This documents the Rails side of server-driven tab navigation – generating the tab configuration and delivering it to native apps via the Hotwire Native bridge. For the message format, see [protocol.md](protocol.md). For how the native app reconciles incoming config with its current state, see [reconciliation.md](reconciliation.md).

## Stimulus Bridge Controller

`app/javascript/controllers/bridge/navigation_controller.js`:

```javascript
import { BridgeComponent } from "@hotwired/hotwire-native-bridge";

export default class extends BridgeComponent {
  static component = "navigation";
  static values = { config: String };

  connect() {
    super.connect();
    this.#sendTabConfiguration();
  }

  configValueChanged() {
    this.#sendTabConfiguration();
  }

  #sendTabConfiguration() {
    this.send("configure", JSON.parse(this.configValue));
  }
}
```

## Tab Configuration

The application controller builds the tab config hash on every request. The layout serializes it to JSON for the bridge data attribute.

```ruby
class ApplicationController < ActionController::Base
  BOOTSTRAP_CONFIG = {
    active: nil,
    tabs: []
  }.freeze

  TABS = [
    {
      id: "home",
      title: "Home",
      icon: "house.fill",
      path: "/",
    },
    {
      id: "explore",
      title: "Explore",
      icon: "magnifyingglass",
      path: "/explore",
    },
    {
      id: "library",
      title: "Library",
      icon: "books.vertical",
      path: "/library",
    },
    {
      id: "profile",
      title: "Profile",
      icon: "person.crop.circle",
      path: "/profile",
    }
  ].each(&:freeze).freeze

  before_action :set_tab_config
  helper_method :tab_config, :active_tab_id

  private

  def set_tab_config
    @tab_config = if signed_in?
      { active: active_tab_id, tabs: TABS }
    else
      BOOTSTRAP_CONFIG
    end
  end

  def tab_config = @tab_config

  def active_tab_id
    case request.path
    when %r{^/explore} then "explore"
    when %r{^/library} then "library"
    when %r{^/profile} then "profile"
    else "home"
    end
  end
end
```

**`active_tab_id` is a stateless URL heuristic.** It does not know which tab the user tapped – it guesses based on the current path. The native client treats this as advisory (see [reconciliation.md](reconciliation.md), Case 5).

This is a simplified illustrative example. In practice, `TABS` and `set_tab_config` would be more dynamic – the demo generates the configuration at runtime to exercise the various reconciliation edge cases.

## Layout

In the shared layout:

```erb
<nav
  data-controller="bridge--navigation"
  data-bridge--navigation-config-value="<%= tab_config.to_json %>"
  class="<%= "hidden" if hotwire_native_app? %>"
>
  <%= link_to "Home", root_path, class: active_tab_id == "home" ? "active" : "" %>
  <%= link_to "Explore", explore_path, class: active_tab_id == "explore" ? "active" : "" %>
  <%= link_to "Library", library_path, class: active_tab_id == "library" ? "active" : "" %>
  <%= link_to "Profile", profile_path, class: active_tab_id == "profile" ? "active" : "" %>
</nav>
```

The `<nav>` tag serves double duty – it is the web tab bar for browsers, and it carries the bridge controller's data attributes for native apps. The Stimulus controller reads the JSON config and forwards it to the native bridge.

## Example User Flows

### Sign in (bootstrap → tabbed)

1. User opens app. No session. Server renders sign-in page.
2. `signed_in?` is false → returns `{ active: null, tabs: [] }`.
3. Native app is in bootstrap mode (one container, no tab bar).
4. User signs in. Turbo navigates to home page.
5. `signed_in?` is true, `request.path` is `"/"` → `@tab_config` has 4 tabs with `active: "home"`.
6. Stimulus controller sends `configure` with tabbed config.
7. Native app promotes bootstrap container to "home", creates 3 new containers, shows tab bar (Case 2).

### Sign out (tabbed → bootstrap)

1. User is on Explore tab, viewing `/explore/42`.
2. User taps sign out. Turbo navigates to sign-in page.
3. `signed_in?` is false → returns bootstrap config.
4. Native app demotes current container to bootstrap, disposes other 3, hides tab bar (Case 3).
5. User's current page is preserved – no reload.

### Normal navigation (no-op)

1. User is on Home tab, taps a link to `/explore/42`.
2. Turbo loads the page.
3. `@tab_config` has same 4 tabs with `active: "explore"`.
4. Native app sees same tab set, ignores the active hint change (Case 5).
