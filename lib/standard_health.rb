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

    # Resolves `config.parent_controller` to an actual class lazily — at
    # the moment the engine's `ApplicationController` is first referenced
    # (request time), by which point the host app's controllers are
    # loaded. Caching avoids re-running `constantize` per request, and
    # the name-mismatch reset lets tests swap config between examples.
    def parent_controller
      expected = config.parent_controller
      if @parent_controller && @parent_controller.name != expected
        @parent_controller = nil
      end
      @parent_controller ||= expected.constantize
    end

    def reset_parent_controller!
      @parent_controller = nil
    end

    # Resolves the parent class for `DiagnosticsController` only. Falls
    # back to `config.parent_controller` when no diagnostics-specific
    # parent is configured, preserving v0.1.0 behavior. When set, lets
    # host apps apply `before_action :auth, only: :env` to the diagnostics
    # endpoint without that callback leaking onto `HealthController`
    # (which would otherwise trip Rails 7.1's
    # `raise_on_missing_callback_actions`).
    def diagnostics_parent_controller
      expected = config.diagnostics_parent_controller || config.parent_controller
      if @diagnostics_parent_controller && @diagnostics_parent_controller.name != expected
        @diagnostics_parent_controller = nil
      end
      @diagnostics_parent_controller ||= expected.constantize
    end

    def reset_diagnostics_parent_controller!
      @diagnostics_parent_controller = nil
    end
  end
end
