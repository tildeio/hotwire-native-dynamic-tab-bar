class SessionsController < ApplicationController
  PERSONAS = {
    "regular" => {
      name: "Regular User",
      description: "Standard 4-tab layout. Toggle features to add tabs or deprecate existing ones.",
      features: { "onboarding_complete" => true }
    },
    "premium" => {
      name: "Premium User",
      description: "5 tabs with a Premium tab. Demonstrates adding a tab (Case 7).",
      features: { "onboarding_complete" => true, "premium_tab" => true }
    },
    "new_user" => {
      name: "New User",
      description: "Starts in bootstrap mode (no tabs). Complete onboarding to transition to tabbed (Cases 1, 2).",
      features: {}
    }
  }.freeze

  # Deprecation flags represent a deploy-level change, not a per-user preference.
  DEPLOY_FLAGS = %w[deprecated_explore].freeze

  def new
  end

  def create
    persona = PERSONAS[params[:persona]]
    if persona
      deploy_flags = features.slice(*DEPLOY_FLAGS)
      session[:user] = params[:persona]
      session[:features] = deploy_flags.merge(persona[:features])
      redirect_to bootstrap_mode? ? onboarding_path : start_path
    else
      redirect_to sign_in_path
    end
  end

  def destroy
    deploy_flags = features.slice(*DEPLOY_FLAGS)
    reset_session
    session[:features] = deploy_flags if deploy_flags.any?
    redirect_to sign_in_path
  end
end
