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
    #
    # `options` are extra keyword arguments forwarded to the check's
    # constructor alongside `name:`/`critical:` (e.g. `EnvSpecAudit`'s
    # `fail_on:`). Empty by default, in which case the check is built exactly
    # as it was before 0.6.0 — so a custom check whose `initialize` only takes
    # `name:`/`critical:` never sees an unexpected keyword.
    Registration = Struct.new(:name, :klass, :critical, :timeout, :options, keyword_init: true) do
      def initialize(**)
        super
        self.options ||= {}
      end

      def critical?
        !!critical
      end

      # Builds the check instance the aggregator runs. A String class name is
      # resolved here, at run time — so a host can register an autoloaded
      # app constant (`"AttestationRootsCheck"`) from an initializer, where it
      # is not yet resolvable, without a `to_prepare` dance; and a reloaded
      # class in development is picked up.
      def build
        check_class.new(name: name, critical: critical, **options)
      end

      def check_class
        klass.is_a?(String) ? Object.const_get(klass) : klass
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

    # Built-in HTTP Basic gate for `/diagnostics/env` (0.6.0). Replaces the
    # host-side `StandardHealthHostController` + `diagnostics_parent_controller`
    # pattern. OFF (nil) by default — nothing changes until a host opts in.
    #
    #   c.diagnostics_basic_auth = true   # ADMIN_BASIC_AUTH_USERNAME / _PASSWORD
    #   c.diagnostics_basic_auth = {
    #     username: -> { Rails.application.credentials.dig(:diagnostics, :username) },
    #     password: -> { Rails.application.credentials.dig(:diagnostics, :password) },
    #     realm: "Health Diagnostics",          # default
    #     allow_unconfigured: -> { Rails.env.local? } # default false: FAIL CLOSED
    #   }
    #
    # Reads back as a `StandardHealth::DiagnosticsBasicAuth` (or nil).
    attr_reader :diagnostics_basic_auth

    def diagnostics_basic_auth=(value)
      @diagnostics_basic_auth = DiagnosticsBasicAuth.build(value)
    end

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

    # --- Aggregate tier (0.6.0) ----------------------------------------
    #
    # When true, the engine serves the aggregate tier at its root — `GET
    # /health` for the usual mount — as { status, checks, circuits,
    # generated_at }. OFF by default: with it off the engine draws no
    # matching route and a bare /health cascades to the host exactly as
    # before. See `StandardHealth::AggregateReport`.
    attr_accessor :aggregate_endpoint

    # Whether the aggregate tier re-runs the readiness checks (the
    # `register_check` registry). Default true. Set false for an aggregate
    # that reports only circuits + `register_aggregate_check` checks.
    attr_accessor :aggregate_readiness_checks

    # Whether to fold `StandardCircuit.health_report` into the aggregate tier
    # when StandardCircuit is loaded. Default true.
    attr_accessor :aggregate_circuits

    # Prefix for emitted metric names, e.g. "health.check.duration".
    attr_accessor :metric_prefix

    # Whether to register the Metrics notifier at all (0.6.0). Unlike
    # `instrumentation_enabled`, turning this off keeps the Logger and Sentry
    # notifiers — which carry the actual health signal — running.
    attr_accessor :metrics_enabled

    # Allow-list of event names the Metrics notifier records (0.6.0). nil (the
    # default) records every event, as before. The per-poll events are the
    # volume — ~2 evaluations x N checks per probe interval per instance — so
    # a host paying for metric quota typically keeps only the rare, actionable
    # one:
    #
    #   c.metric_events = %w[standard_health.check.timed_out]
    #
    # See `Notifiers::Metrics::EVENTS` / `PER_POLL_EVENTS`.
    attr_reader :metric_events

    def metric_events=(events)
      if events.nil?
        @metric_events = nil
        return
      end

      names = Array(events).map(&:to_s)
      unknown = names - Notifiers::Metrics::EVENTS
      unless unknown.empty?
        raise ArgumentError,
              "unknown metric event(s) #{unknown.join(", ")}; known: #{Notifiers::Metrics::EVENTS.join(", ")}"
      end

      @metric_events = names.uniq.freeze
    end

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
    # reached are reported :skipped with `budget_exhausted: true` (unlike a
    # check that reports :skipped itself, which is neutral), and such a skip
    # alone floors the roll-up at
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
      @diagnostics_basic_auth = nil
      @env_spec = nil
      @checks = []
      @aggregate_checks = []
      @diagnostics_assertions = []
      @aggregate_endpoint = false
      @aggregate_readiness_checks = true
      @aggregate_circuits = true

      @instrumentation_enabled = true
      @logger = nil
      @sentry_enabled = true
      @metric_prefix = "health"
      @metrics_enabled = true
      @metric_events = nil
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
    # @param options [Hash] any other keywords are forwarded to the check's
    #   constructor, e.g.
    #
    #     c.register_check :env_spec, StandardHealth::Checks::EnvSpecAudit,
    #                      fail_on: %i[forbidden]
    #
    #   Validated against the constructor's signature HERE, so a typo fails
    #   at boot instead of turning into an ArgumentError on every probe (which
    #   the aggregator would dutifully report as a failing check forever).
    def register_check(name, klass, critical: false, timeout: nil, **options)
      validate_check_options!(klass, options)
      registration = Registration.new(
        name: name.to_sym, klass: klass, critical: critical, timeout: timeout, options: options
      )
      @checks << registration
      registration
    end

    # The check set every consumer app registers by hand. Each entry: default
    # registration name, criticality, the check class (a String, resolved only
    # if the backing library is loaded), and the guard that decides whether
    # the backing library is present.
    DEFAULT_CHECKS = {
      database: {
        name: :database, critical: true,
        klass: "StandardHealth::Checks::ActiveRecord",
        available: -> { defined?(::ActiveRecord::Base) }
      },
      solid_queue: {
        name: :solid_queue, critical: true,
        klass: "StandardHealth::Checks::SolidQueue",
        available: -> { defined?(::SolidQueue) }
      },
      solid_cache: {
        name: :solid_cache, critical: false,
        klass: "StandardHealth::Checks::SolidCache",
        available: -> { defined?(::SolidCache) }
      },
      audit_retention: {
        name: :audit_retention, critical: false,
        klass: "StandardAudit::Checks::Retention",
        available: -> { defined?(::StandardAudit::Checks::Retention) }
      }
    }.freeze

    # Registers the estate's common check set in one call:
    #
    #   :database         StandardHealth::Checks::ActiveRecord  critical
    #   :solid_queue      StandardHealth::Checks::SolidQueue    critical
    #   :solid_cache      StandardHealth::Checks::SolidCache    non-critical
    #   :audit_retention  StandardAudit::Checks::Retention      non-critical
    #
    # Note the database check registers as `:database`, not the class's own
    # `:active_record` default — every consumer renamed it, and dashboards key
    # on the name.
    #
    # A check whose backing library is not loaded (no `SolidQueue`, no
    # `SolidCache`, no `standard_audit`) is SKIPPED, not registered-and-
    # failing. A name that is already registered is also skipped, so calling
    # this after (or before) hand-registering one of them never duplicates it.
    #
    # Each keyword takes:
    #   true   — register with the defaults above (the default)
    #   false  — don't register it
    #   Hash   — register with overrides: `name:`, `critical:`, `timeout:`,
    #            plus any constructor options (see #register_check)
    #
    #   c.register_default_checks solid_cache: false,
    #                             audit_retention: { critical: false, timeout: 1 }
    #
    # @return [Array<Symbol>] names actually registered by this call
    def register_default_checks(database: true, solid_queue: true, solid_cache: true, audit_retention: true)
      requested = { database: database, solid_queue: solid_queue,
                    solid_cache: solid_cache, audit_retention: audit_retention }

      requested.filter_map do |key, setting|
        next unless setting

        overrides = setting.is_a?(Hash) ? setting.transform_keys(&:to_sym) : {}
        default = DEFAULT_CHECKS.fetch(key)
        next unless default[:available].call

        name = (overrides.delete(:name) || default[:name]).to_sym
        next if @checks.any? { |reg| reg.name == name }

        critical = overrides.key?(:critical) ? overrides.delete(:critical) : default[:critical]
        timeout = overrides.delete(:timeout)
        klass = overrides.delete(:klass) || Object.const_get(default[:klass])

        register_check(name, klass, critical: critical, timeout: timeout, **overrides)
        name
      end
    end

    # Register a check that runs ONLY on the aggregate tier — soft upstreams
    # and advisories that must never gate rotation (SolidCable, certificate
    # expiry, ...). Same signature as #register_check; `klass` may also be a
    # String class name, resolved at run time (as it may for #register_check).
    #
    #   c.register_aggregate_check :solid_cable, StandardHealth::Checks::SolidCable
    #   c.register_aggregate_check :attestation_roots, "AttestationRootsCheck"
    def register_aggregate_check(name, klass, critical: false, timeout: nil, **options)
      validate_check_options!(klass, options)
      registration = Registration.new(
        name: name.to_sym, klass: klass, critical: critical, timeout: timeout, options: options
      )
      @aggregate_checks << registration
      registration
    end

    DiagnosticsAssertion = Struct.new(:name, :callable)

    # Adds a runtime assertion to the doctor tier (`GET /diagnostics/env`),
    # rendered under `assertions:` next to the env audit. For facts env
    # presence can't prove: the live `statement_timeout`, the cache store a
    # rate limiter actually resolved to, a pinned root's expiry. Replaces a
    # host diagnostics controller that exists only to add these.
    #
    #   c.register_diagnostics_assertion(:statement_timeout) do
    #     value = ActiveRecord::Base.connection.select_value("SHOW statement_timeout").to_s
    #     { status: value == "0" ? :warn : :ok, value: value, expected: "non-zero" }
    #   end
    #
    # The callable takes no arguments and returns a Hash with `status:`
    # (`:ok`, `:warn` or `:error`) plus any detail keys. `name:` is set by
    # the gem. It runs per request, on the authenticated tier only, never on
    # /alive, /ready or the aggregate. A raise, a non-Hash, or an unknown
    # status becomes an `:error` row (a raise is also reported to
    # `Rails.error` as handled). An `:error` row makes the endpoint's
    # `status` `incomplete`; `:warn` does not.
    #
    # Re-registering a name replaces it, so `configure` can safely re-run
    # from `to_prepare` on reload.
    def register_diagnostics_assertion(name, callable = nil, &block)
      callable ||= block
      unless callable.respond_to?(:call)
        raise ArgumentError, "register_diagnostics_assertion(#{name.inspect}) needs a callable or a block"
      end

      assertion = DiagnosticsAssertion.new(name.to_sym, callable)
      @diagnostics_assertions.reject! { |existing| existing.name == assertion.name }
      @diagnostics_assertions << assertion
      assertion
    end

    # @return [Array<DiagnosticsAssertion>] in registration order
    def diagnostics_assertions
      @diagnostics_assertions.dup
    end

    # Drop registered diagnostics assertions. Test hygiene.
    def reset_diagnostics_assertions!
      @diagnostics_assertions = []
    end

    # @return [Array<Registration>] aggregate-only checks
    def aggregate_checks
      @aggregate_checks.dup
    end

    # @return [Array<Registration>] frozen view of registered checks
    def checks
      @checks.dup
    end

    # Remove all registered checks. Mainly useful in tests where the host
    # app and the engine share a process.
    def reset_checks!
      @checks = []
      @aggregate_checks = []
    end

    # Drop host-registered notifiers. Test hygiene, mirroring reset_checks!.
    def reset_notifiers!
      @extra_notifiers = []
    end

    private

    # Rejects option keys the check's constructor cannot accept. Only
    # inspects the signature — never instantiates — so a check with side
    # effects in `initialize` is not run at boot. A constructor taking
    # `**kwargs` accepts anything and is not second-guessed.
    def validate_check_options!(klass, options)
      return if options.empty?
      return unless klass.is_a?(Module) # a String name resolves at run time

      params = klass.instance_method(:initialize).parameters
      return if params.any? { |type, _| type == :keyrest }

      accepted = params.select { |type, _| %i[key keyreq].include?(type) }.map(&:last)
      unknown = options.keys.map(&:to_sym) - accepted
      return if unknown.empty?

      raise ArgumentError,
            "#{klass} does not accept #{unknown.map { |k| "`#{k}:`" }.join(", ")}; " \
            "its constructor takes #{accepted.map { |k| "`#{k}:`" }.join(", ")}"
    end
  end
end
