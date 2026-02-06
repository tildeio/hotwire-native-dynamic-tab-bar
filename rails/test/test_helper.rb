ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

module ActiveSupport
  class TestCase
    parallelize(workers: :number_of_processors)
    fixtures :all
  end
end

module SignInHelper
  def sign_in_as(persona)
    post sign_in_path, params: { persona: persona }
  end

  def sign_in_and_land(persona)
    sign_in_as(persona)
    follow_redirect! while response.redirect?
  end
end

class ActionDispatch::IntegrationTest
  include SignInHelper
end
