class ApplicationController < ActionController::Base
  include Turbo::Native::Navigation

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  before_action :set_tab_config

  helper_method :signed_in?, :current_user, :features, :bootstrap_mode?, :active_tab_id, :tab_config, :web_tabs

  private

  def signed_in?
    session[:user].present?
  end

  def current_user
    session[:user]
  end

  def features
    (session[:features] || {}).with_indifferent_access
  end

  def bootstrap_mode?
    signed_in? && !features["onboarding_complete"]
  end

  def require_sign_in
    redirect_to sign_in_path unless signed_in?
  end

  BOOTSTRAP_CONFIG = { active: nil, tabs: [] }.freeze

  BASE_TABS = [
    { id: "home",    title: "Home",    icon: "house.fill",          path: "/"        },
    { id: "explore", title: "Explore", icon: "magnifyingglass",     path: "/explore" },
    { id: "library", title: "Library", icon: "books.vertical",      path: "/library" },
    { id: "profile", title: "Profile", icon: "person.crop.circle",  path: "/profile" }
  ].each(&:freeze).freeze

  def set_tab_config
    @tab_config = if !signed_in? || bootstrap_mode?
      BOOTSTRAP_CONFIG
    else
      { active: active_tab_id, tabs: build_tabs }
    end
  end

  def tab_config
    @tab_config
  end

  def build_tabs
    tabs = BASE_TABS.map(&:dup)

    # Apply deprecated extension to explore tab
    if features[:deprecated_explore].present?
      explore = tabs.find { |t| t[:id] == "explore" }
      explore[:deprecated] = features[:deprecated_explore] if explore

      # Favorites replaces the deprecated explore tab
      favorites_tab = { id: "favorites", title: "Favorites", icon: "heart.fill", path: "/favorites", replaces: "explore" }
      explore_index = tabs.index { |t| t[:id] == "explore" }
      tabs.insert(explore_index + 1, favorites_tab)
    end

    # Premium tab is independent — inserted before profile
    if features[:premium_tab]
      premium_tab = { id: "premium", title: "Premium", icon: "star.fill", path: "/premium" }
      profile_index = tabs.index { |t| t[:id] == "profile" }
      tabs.insert(profile_index, premium_tab)
    elsif active_tab_id == "premium"
      # User is on /premium but no longer has access — hard-deprecate so
      # the client removes the tab when the user switches away (deferred
      # Case 8) instead of forcing a Case 9 active-tab-removed morph.
      premium_tab = { id: "premium", title: "Premium", icon: "star.fill", path: "/premium", deprecated: "hard" }
      profile_index = tabs.index { |t| t[:id] == "profile" }
      tabs.insert(profile_index, premium_tab)
    end

    tabs
  end

  def active_tab_id
    case request.path
    when %r{^/explore}   then "explore"
    when %r{^/library}   then "library"
    when %r{^/favorites} then "favorites"
    when %r{^/premium}   then "premium"
    when %r{^/profile}   then "profile"
    else "home"
    end
  end

  def web_tabs
    tab_config[:tabs].reject do |t|
      if t[:deprecated]
        active_tab_id != t[:id]
      elsif t[:replaces]
        active_tab_id == t[:replaces]
      end
    end
  end
end
