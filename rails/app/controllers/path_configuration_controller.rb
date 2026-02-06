class PathConfigurationController < ApplicationController
  skip_before_action :set_tab_config

  def show
    render json: {
      settings: {},
      rules: [
        {
          patterns: [".*"],
          properties: {
            context: "default",
            uri: "hotwire://fragment/web",
            pull_to_refresh_enabled: true
          }
        },
        {
          patterns: ["/sign_in$"],
          properties: {
            presentation: "replace_root",
            pull_to_refresh_enabled: false
          }
        },
        {
          patterns: ["/start$"],
          properties: {
            presentation: "replace_root"
          }
        },
        {
          patterns: ["/onboarding$"],
          properties: {
            presentation: "replace_root",
            pull_to_refresh_enabled: false
          }
        }
      ]
    }
  end
end
