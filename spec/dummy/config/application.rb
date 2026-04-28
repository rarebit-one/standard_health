# frozen_string_literal: true

require_relative "boot"

require "rails"
require "active_model/railtie"
require "active_record/railtie"
require "action_controller/railtie"

Bundler.require(*Rails.groups)
require "standard_health"

module Dummy
  class Application < Rails::Application
    config.load_defaults Rails::VERSION::STRING.to_f

    config.autoload_lib(ignore: %w[assets tasks])

    # API-only — StandardHealth's default parent_controller is
    # ActionController::API, so we don't need ActionView or sessions.
    config.api_only = true
  end
end
