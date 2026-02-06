Rails.application.routes.draw do
  root "content#home"
  get "start", to: "content#home"

  get  "sign_in",  to: "sessions#new"
  post "sign_in",  to: "sessions#create"
  delete "sign_out", to: "sessions#destroy"

  get  "onboarding",          to: "content#onboarding"
  post "onboarding/complete", to: "content#onboarding_complete"

  get "explore",     to: "content#explore"
  get "explore/:id", to: "content#explore_item", as: :explore_item

  get "library",   to: "content#library"
  get "favorites", to: "content#favorites"
  get "premium",   to: "content#premium"
  get "profile",   to: "content#profile"

  post "toggle_feature", to: "features#toggle"

  get "configurations/navigation", to: "path_configuration#show"

  get "up" => "rails/health#show", as: :rails_health_check
end
