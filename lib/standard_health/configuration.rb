# frozen_string_literal: true

module StandardHealth
  # Holds engine-wide configuration.
  #
  # Host apps configure the engine via:
  #
  #   StandardHealth.configure do |c|
  #     c.parent_controller = "ApplicationController"
  #     c.register_check :custom, MyCheck, critical: true
  #     c.env_spec = StandardHealth::EnvSpec.define { ... }
  #   end
  class Configuration
    # A registered health check entry.
    Registration = Struct.new(:name, :klass, :critical, keyword_init: true) do
      def critical?
        !!critical
      end
    end

    # Class name of the controller that StandardHealth's controllers should
    # inherit from. Resolved lazily via `constantize` at request time so the
    # host app's controller (which may pull in auth concerns) is fully
    # loaded before we touch it. Defaults to `ActionController::API` so the
    # engine works in API-only host apps without configuration.
    attr_accessor :parent_controller

    # An optional `StandardHealth::EnvSpec` instance describing required and
    # recommended environment variables for the host app. Audited via the
    # /diagnostics/env endpoint.
    attr_accessor :env_spec

    def initialize
      @parent_controller = "ActionController::API"
      @env_spec = nil
      @checks = []
    end

    # Register a health check class.
    #
    # @param name [Symbol] short identifier surfaced in /ready output
    # @param klass [Class] subclass of StandardHealth::Check
    # @param critical [Boolean] failure flips overall status to :unavailable
    def register_check(name, klass, critical: false)
      @checks << Registration.new(name: name.to_sym, klass: klass, critical: critical)
    end

    # @return [Array<Registration>] frozen view of registered checks
    def checks
      @checks.dup
    end

    # Remove all registered checks. Mainly useful in tests where the host
    # app and the engine share a process.
    def reset_checks!
      @checks = []
    end
  end
end
