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
    #
    # `timeout` is per-check seconds, or nil to fall back to
    # `default_check_timeout` (itself nil by default — see below).
    Registration = Struct.new(:name, :klass, :critical, :timeout, keyword_init: true) do
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

    # Optional class name of a controller that ONLY `DiagnosticsController`
    # should inherit from. When set, `HealthController` continues to use
    # `parent_controller` while `DiagnosticsController` uses this one. Lets
    # host apps put auth (e.g. HTTP Basic) on the diagnostics endpoint
    # without needing to set `raise_on_missing_callback_actions = false`
    # to suppress Rails 7.1's missing-action error caused by a single
    # parent declaring `before_action :auth, only: :env` for both controllers.
    #
    # When unset (the default), `DiagnosticsController` falls back to
    # `parent_controller` — fully backward-compatible with v0.1.0.
    attr_accessor :diagnostics_parent_controller

    # An optional `StandardHealth::EnvSpec` instance describing required and
    # recommended environment variables for the host app. Audited via the
    # /diagnostics/env endpoint.
    attr_accessor :env_spec

    # --- Instrumentation -----------------------------------------------
    #
    # Master switch for the Logger / Sentry / Metrics subscribers. On by
    # default: a health system nobody can see the history of is the gap this
    # release exists to close.
    attr_accessor :instrumentation_enabled

    # Logger for the Logger notifier. nil falls back to Rails.logger.
    attr_accessor :logger

    # Whether to register the Sentry notifier. Sentry itself stays a SOFT
    # dependency (guarded by `defined?`), so leaving this true costs nothing
    # in a host that doesn't use Sentry.
    attr_accessor :sentry_enabled

    # Prefix for emitted metric names, e.g. "health.check.duration".
    attr_accessor :metric_prefix

    # Extra `call(event_name, payload)` subscribers supplied by the host.
    attr_reader :extra_notifiers

    # --- Response redaction --------------------------------------------
    #
    # When false (the default) a failing check reports `error_class` +
    # `error_code` instead of the raw exception message. /ready is
    # unauthenticated, and raw driver errors leak hosts, ports and usernames.
    # The full message still reaches logs and Sentry via instrumentation.
    #
    # Set true to restore the pre-0.4.1 verbose bodies.
    attr_accessor :expose_check_errors

    # When set, a request carrying this value in `X-Health-Token` receives the
    # unredacted body. Break-glass for on-call without a redeploy. Compared
    # with a constant-time comparison.
    attr_accessor :detail_token

    # --- Timeouts (machinery only in 0.4.1) ----------------------------
    #
    # BOTH DEFAULT TO nil, meaning OFF — identical behaviour to v0.4.0.
    #
    # This is deliberate. Turning timeouts on is a semantic change: a check
    # that has always been slow-but-fine starts reporting :fail, and for a
    # critical check that pulls the instance out of rotation. Shipping that in
    # a patch release, to five apps at once, on a `bundle update`, is how you
    # cause the outage you were trying to prevent.
    #
    # The machinery ships now so apps can opt in per check and so the events
    # emitted in this release can tell us what the real p99 latencies are.
    # Sensible defaults get chosen from that data in a later release, once
    # enough p99 data has accumulated to pick them from evidence rather than
    # guesswork — deliberately NOT 0.5.0, which shipped without it.
    attr_accessor :default_check_timeout

    # Budget across all checks, evaluated BEFORE each check starts. Checks not
    # reached are reported :skipped, and a skip alone floors the roll-up at
    # :degraded — never :unavailable. Otherwise a slow NON-critical check could
    # exhaust the budget, leave a critical check unrun, and pull a healthy app
    # out of rotation. nil = no budget.
    #
    # IMPORTANT — this bounds HOW MANY CHECKS RUN, not how long the probe
    # takes. It is not enforced during an in-flight check: with a 1s budget and
    # a first check that blocks for 30s, /ready still takes 30s and only the
    # checks after it are skipped.
    #
    # Clamping each check to the remaining budget would fix that, and is
    # deliberately NOT done: it would apply Timeout.timeout to checks whose
    # author never asked for one, and that mechanism raises into the thread at
    # an arbitrary point (see the README's timeout caveat — it can return a
    # broken connection to the pool). Setting a budget must not silently opt
    # you into that.
    #
    # To bound wall-clock, put a `timeout:` on the checks that can safely take
    # one — or better, a driver-level timeout.
    attr_accessor :total_check_budget

    def initialize
      @parent_controller = "ActionController::API"
      @diagnostics_parent_controller = nil
      @env_spec = nil
      @checks = []

      @instrumentation_enabled = true
      @logger = nil
      @sentry_enabled = true
      @metric_prefix = "health"
      @extra_notifiers = []

      @expose_check_errors = false
      @detail_token = nil

      @default_check_timeout = nil
      @total_check_budget = nil
    end

    # Register an extra subscriber. Validated at add time so a bad entry
    # fails loudly at boot rather than silently at the first health probe.
    def add_notifier(notifier)
      unless notifier.respond_to?(:call)
        raise ArgumentError,
              "extra notifiers must respond to `call(event_name, payload)`; got #{notifier.class}"
      end

      @extra_notifiers << notifier
      notifier
    end

    # Register a health check class.
    #
    # @param name [Symbol] short identifier surfaced in /ready output
    # @param klass [Class] subclass of StandardHealth::Check
    # @param critical [Boolean] failure flips overall status to :unavailable
    # @param timeout [Numeric, nil] per-check seconds; nil falls back to
    #   `default_check_timeout` (nil = no timeout)
    def register_check(name, klass, critical: false, timeout: nil)
      @checks << Registration.new(
        name: name.to_sym, klass: klass, critical: critical, timeout: timeout
      )
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

    # Drop host-registered notifiers. Test hygiene, mirroring reset_checks!.
    def reset_notifiers!
      @extra_notifiers = []
    end
  end
end
