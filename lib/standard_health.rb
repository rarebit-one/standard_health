# frozen_string_literal: true

require "standard_health/version"
require "standard_health/engine"
require "standard_health/configuration"
require "standard_health/env_spec"
require "standard_health/check"
require "standard_health/checks/active_record"
require "standard_health/checks/solid_queue"
require "standard_health/checks/solid_cache"
require "standard_health/aggregator"

module StandardHealth
  class << self
    # Yields the configuration to a block.
    #
    #   StandardHealth.configure do |c|
    #     c.parent_controller = "ApplicationController"
    #     c.register_check :db, StandardHealth::Checks::ActiveRecord, critical: true
    #   end
    def configure
      yield config if block_given?
      config
    end

    def config
      @config ||= Configuration.new
    end

    # Mostly useful in tests — wipes the singleton config so each example
    # gets a clean slate.
    def reset_config!
      @config = Configuration.new
    end
  end
end
