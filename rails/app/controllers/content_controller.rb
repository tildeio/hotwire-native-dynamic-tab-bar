class ContentController < ApplicationController
  before_action :require_sign_in

  EXPLORE_ITEMS = (1..20).map { |i|
    { id: i, title: "Explore Item #{i}", description: "Description for item #{i}. This is a sample explore item to demonstrate in-tab navigation." }
  }.freeze

  def home
    redirect_to onboarding_path if bootstrap_mode?
  end

  def explore
    @items = EXPLORE_ITEMS
  end

  def explore_item
    @item = EXPLORE_ITEMS.find { |item| item[:id] == params[:id].to_i }
    redirect_to explore_path unless @item
  end

  def onboarding; end

  def onboarding_complete
    session[:features] = features.merge("onboarding_complete" => true)
    redirect_to start_path
  end

  def library; end
  def favorites; end
  def premium; end

  def profile
    @persona = SessionsController::PERSONAS[current_user]
  end
end
