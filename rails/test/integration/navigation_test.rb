require "test_helper"

class NavigationTest < ActionDispatch::IntegrationTest
  test "unauthenticated requests redirect to sign_in" do
    [root_path, explore_path, library_path, favorites_path, premium_path, profile_path].each do |path|
      get path
      assert_redirected_to sign_in_path, "Expected #{path} to redirect when signed out"
    end
  end

  test "sign_in page renders for unauthenticated user" do
    get sign_in_path
    assert_response :success
    assert_select "form"
  end

  test "all tab pages render for signed-in user" do
    sign_in_as("regular")
    [root_path, explore_path, library_path, profile_path].each do |path|
      get path
      assert_response :success, "Expected #{path} to render"
    end
  end

  test "premium page renders" do
    sign_in_as("premium")
    get premium_path
    assert_response :success
  end

  test "favorites page renders" do
    sign_in_as("regular")
    post toggle_feature_path, params: { feature: "deprecated_explore_soft" }
    get favorites_path
    assert_response :success
  end

  test "explore detail page renders" do
    sign_in_as("regular")
    get explore_item_path(1)
    assert_response :success
  end

  test "explore detail with invalid ID redirects to index" do
    sign_in_as("regular")
    get explore_item_path(999)
    assert_redirected_to explore_path
  end

  test "sign out clears session and redirects to sign_in" do
    sign_in_as("regular")
    delete sign_out_path
    assert_redirected_to sign_in_path

    get root_path
    assert_redirected_to sign_in_path
  end

  test "new user is redirected to onboarding from home" do
    sign_in_as("new_user")
    get root_path
    assert_redirected_to onboarding_path
  end

  test "onboarding page renders" do
    sign_in_as("new_user")
    get onboarding_path
    assert_response :success
  end

  test "completing onboarding redirects to start" do
    sign_in_as("new_user")
    post onboarding_complete_path
    assert_redirected_to start_path

    follow_redirect!
    assert_response :success
  end

  test "toggling feature redirects back" do
    sign_in_as("regular")
    post toggle_feature_path, params: { feature: "premium_tab" }, headers: { "HTTP_REFERER" => root_url }
    assert_redirected_to root_url
  end

  test "path configuration endpoint returns JSON" do
    get configurations_navigation_path
    assert_response :success
    config = JSON.parse(response.body)
    assert config.key?("settings")
    assert config.key?("rules")
    assert config["rules"].any? { |r| r["patterns"].include?("/sign_in$") }
  end
end
