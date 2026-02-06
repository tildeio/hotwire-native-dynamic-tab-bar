class FeaturesController < ApplicationController
  before_action :require_sign_in

  def toggle
    case params[:feature]
    when "premium_tab"
      session[:features] = features.merge("premium_tab" => !features["premium_tab"])
    when /\Adeprecated_explore_(soft|hard)\z/
      level = $1
      session[:features] = if features["deprecated_explore"] == level
        features.except("deprecated_explore")
      else
        features.merge("deprecated_explore" => level)
      end
    end

    redirect_back fallback_location: root_path
  end
end
