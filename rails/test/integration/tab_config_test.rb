require "test_helper"

class TabConfigTest < ActionDispatch::IntegrationTest
  def tab_config
    assert_response :success
    doc = Nokogiri::HTML5(response.body)
    nav = doc.at_css("[data-controller='bridge--navigation']")
    assert nav, "Expected a bridge--navigation controller element in the page"
    JSON.parse(nav["data-bridge--navigation-config-value"])
  end

  test "signed out returns bootstrap config" do
    get sign_in_path
    config = tab_config
    assert_nil config["active"]
    assert_equal [], config["tabs"]
  end

  test "new user starts in bootstrap mode" do
    sign_in_and_land("new_user")
    config = tab_config
    assert_nil config["active"]
    assert_equal [], config["tabs"]
  end

  test "new user gets tabbed config after completing onboarding" do
    sign_in_and_land("new_user")
    post onboarding_complete_path
    follow_redirect!
    config = tab_config
    assert_equal 4, config["tabs"].length
    assert_equal "home", config["active"]
  end

  test "regular user gets 4 tabs" do
    sign_in_and_land("regular")
    config = tab_config
    ids = config["tabs"].map { |t| t["id"] }
    assert_equal %w[home explore library profile], ids
  end

  test "regular user tabs have correct paths" do
    sign_in_and_land("regular")
    config = tab_config
    paths = config["tabs"].to_h { |t| [t["id"], t["path"]] }
    assert_equal({ "home" => "/", "explore" => "/explore", "library" => "/library", "profile" => "/profile" }, paths)
  end

  test "regular user tabs have correct icons" do
    sign_in_and_land("regular")
    config = tab_config
    icons = config["tabs"].to_h { |t| [t["id"], t["icon"]] }
    assert_equal({ "home" => "house.fill", "explore" => "magnifyingglass", "library" => "books.vertical", "profile" => "person.crop.circle" }, icons)
  end

  test "premium user gets 5 tabs including premium" do
    sign_in_and_land("premium")
    config = tab_config
    ids = config["tabs"].map { |t| t["id"] }
    assert_equal %w[home explore library premium profile], ids
  end

  test "premium tab has correct fields" do
    sign_in_and_land("premium")
    config = tab_config
    tab = config["tabs"].find { |t| t["id"] == "premium" }
    assert_equal "Premium", tab["title"]
    assert_equal "star.fill", tab["icon"]
    assert_equal "/premium", tab["path"]
  end

  test "deprecated explore includes favorites with replaces" do
    sign_in_as("regular")
    post toggle_feature_path, params: { feature: "deprecated_explore_soft" }
    follow_redirect!
    config = tab_config

    explore = config["tabs"].find { |t| t["id"] == "explore" }
    assert_equal "soft", explore["deprecated"]

    favorites = config["tabs"].find { |t| t["id"] == "favorites" }
    assert_equal "explore", favorites["replaces"]
  end

  test "toggling premium_tab adds premium tab" do
    sign_in_as("regular")
    post toggle_feature_path, params: { feature: "premium_tab" }
    follow_redirect!
    config = tab_config
    assert_includes config["tabs"].map { |t| t["id"] }, "premium"
    assert_equal 5, config["tabs"].length
  end

  test "toggling deprecated_explore_soft marks explore deprecated" do
    sign_in_as("regular")
    post toggle_feature_path, params: { feature: "deprecated_explore_soft" }
    follow_redirect!
    config = tab_config
    explore = config["tabs"].find { |t| t["id"] == "explore" }
    assert_equal "soft", explore["deprecated"]
  end

  test "toggling deprecated_explore_hard marks explore hard-deprecated" do
    sign_in_as("regular")
    post toggle_feature_path, params: { feature: "deprecated_explore_hard" }
    follow_redirect!
    config = tab_config
    explore = config["tabs"].find { |t| t["id"] == "explore" }
    assert_equal "hard", explore["deprecated"]
  end

  test "active tab detection" do
    sign_in_as("regular")

    { root_path => "home", explore_path => "explore", explore_item_path(1) => "explore",
      library_path => "library", profile_path => "profile" }.each do |path, expected|
      get path
      config = tab_config
      assert_equal expected, config["active"], "Expected active=#{expected} for #{path}"
    end
  end

  test "active tab is favorites for favorites path" do
    sign_in_as("regular")
    post toggle_feature_path, params: { feature: "deprecated_explore_soft" }
    get favorites_path
    assert_equal "favorites", tab_config["active"]
  end

  test "active tab is premium for premium path" do
    sign_in_and_land("premium")
    get premium_path
    assert_equal "premium", tab_config["active"]
  end

  test "tabs length is never 1" do
    get sign_in_path
    assert_not_equal 1, tab_config["tabs"].length

    sign_in_and_land("regular")
    assert tab_config["tabs"].length >= 2

    sign_in_and_land("new_user")
    assert_not_equal 1, tab_config["tabs"].length
  end

  test "when tabs non-empty, active references a valid tab ID" do
    sign_in_and_land("regular")
    config = tab_config
    assert_includes config["tabs"].map { |t| t["id"] }, config["active"]
  end

  test "tab IDs are stable across navigation" do
    sign_in_and_land("regular")
    ids1 = tab_config["tabs"].map { |t| t["id"] }

    get explore_path
    ids2 = tab_config["tabs"].map { |t| t["id"] }

    assert_equal ids1, ids2
  end

  test "tab paths are relative URLs" do
    sign_in_and_land("regular")
    tab_config["tabs"].each do |tab|
      assert tab["path"].start_with?("/"), "#{tab['id']} path should be relative"
      assert_not tab["path"].start_with?("http"), "#{tab['id']} path should not be absolute"
    end
  end

  test "deprecated is soft or hard when present" do
    sign_in_as("regular")
    post toggle_feature_path, params: { feature: "deprecated_explore_soft" }
    follow_redirect!
    tab_config["tabs"].each do |tab|
      next unless tab.key?("deprecated")
      assert_includes %w[soft hard], tab["deprecated"]
    end
  end

  test "premium tab is hard-deprecated when user is on /premium without access" do
    sign_in_and_land("premium")
    post toggle_feature_path, params: { feature: "premium_tab" }

    # User is on /premium but no longer has the feature
    get premium_path
    config = tab_config

    premium = config["tabs"].find { |t| t["id"] == "premium" }
    assert premium, "Premium tab should still be in config when user is on /premium"
    assert_equal "hard", premium["deprecated"]
    assert_equal "premium", config["active"]
  end

  test "premium tab is omitted when user is not on /premium and has no access" do
    sign_in_and_land("premium")
    post toggle_feature_path, params: { feature: "premium_tab" }

    get root_path
    config = tab_config

    assert_nil config["tabs"].find { |t| t["id"] == "premium" }
  end

  test "premium page shows subscription required when feature is off" do
    sign_in_and_land("premium")
    post toggle_feature_path, params: { feature: "premium_tab" }

    get premium_path
    assert_match /Subscription Required/, response.body
  end

  test "replaces references the ID of a deprecated tab" do
    sign_in_as("regular")
    post toggle_feature_path, params: { feature: "deprecated_explore_soft" }
    follow_redirect!
    config = tab_config
    deprecated_ids = config["tabs"].select { |t| t["deprecated"] }.map { |t| t["id"] }
    config["tabs"].each do |tab|
      next unless tab.key?("replaces")
      assert_includes deprecated_ids, tab["replaces"]
    end
  end
end
