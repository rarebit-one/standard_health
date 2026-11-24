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
    attr_reader :env_spec

    # Validates the spec as it is assigned (`EnvSpec#validate!`), so an
    # `in:` alias with no `mode_alias` fails the initializer at boot rather
    # than raising on the first audit, which is a /diagnostics/env request
    # in production.
    def env_spec=(spec)
      spec.validate! if spec.respond_to?(:validate!)
      @env_spec = spec
    end

    # The spec that is actually audited, on `/diagnostics/env` and by
    # `Checks::EnvSpecAudit`: `env_spec` plus the env vars other gems
    # contributed (`Contributions#contribute_env_vars`), grouped per gem.
    # The app's own declaration of a var wins over a gem's.
    #
    # With no `env_spec` set, the contributions alone form the spec; with
    # neither, this is nil (the audit is empty, as before). `env_spec` itself
    # stays exactly what the app assigned.
    #
    # Rebuilt on each call rather than cached, so a contribution that arrives
    # after the initializer still shows up. Both are a handful of entries.
    #
    # @return [EnvSpec, nil]
    def effective_env_spec
      contributed = @contributions.env_spec
      return @env_spec unless contributed
      return contributed unless @env_spec

      @env_spec.reverse_merge(contributed)
    end

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
    # /health` for the usual mount — as { status, checks, dependencies,
    # circuits, generated_at }. OFF by default: with it off the engine draws no
    # matching route and a bare /health cascades to the host exactly as
    # before. See `StandardHealth::AggregateReport`.
    attr_accessor :aggregate_endpoint

    # Whether the aggregate tier re-runs the readiness checks (the
    # `register_check` registry). Default true. Set false for an aggregate
    # that reports only circuits + `register_aggregate_check` checks.
    attr_accessor :aggregate_readiness_checks

    # Whether to fold `StandardCircuit.health_report` into the aggregate tier
    # when StandardCircuit is loaded. Default true.
    #
    # DEPRECATED (0.10.0): the `circuits` section is superseded by
    # `dependencies` (see `aggregate_dependencies`) and is removed in 1.0.
    # Once a gem contributes dependency rows (standard_circuit >= 0.8), the
    # section is still rendered but no longer counts toward the status. Set
    # false once nothing reads `circuits`.
    attr_accessor :aggregate_circuits

    # Whether the aggregate tier renders the dependency rows other gems
    # contributed (`Contributions#contribute_dependencies`) as `dependencies`
    # and rolls its status up from them. Default true. Has no effect until a
    # gem contributes rows.
    attr_accessor :aggregate_dependencies

    # Whether /ready also renders contributed dependency rows (0.10.0). OFF
    # by default, and turning it on changes rotation: a `:critical`
    # dependency reporting :unavailable then makes /ready 503. No other row
    # changes the readiness status (a degraded or non-critical dependency is
    # rendered and nothing more), and /alive is never affected.
    #
    # Think before enabling it. Every instance sees the same upstream, so a
    # critical dependency's outage takes every instance out of rotation at
    # once, including for requests that never call that dependency.
    attr_accessor :ready_dependencies

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

    # Where the gem reports its own handled errors: a check that raises on
    # the aggregate tier, and a diagnostics assertion that raises. nil (the
    # default) keeps `Rails.error.report(error, handled: true, ...)`. Set a
    # callable taking `(error, context)` to route them elsewhere; `context`
    # is the Hash `Rails.error` would get (`{ health_check:, tier: }` or
    # `{ diagnostics_assertion: }`).
    #
    #   c.error_reporter = ->(error, context) { Sentry.capture_exception(error, extra: context) }
    attr_reader :error_reporter

    def error_reporter=(reporter)
      unless reporter.nil? || reporter.respond_to?(:call)
        raise ArgumentError, "error_reporter must respond to `call(error, context)`; got #{reporter.class}"
      end

      @error_reporter = reporter
    end

    # Reports a handled error through `error_reporter`, or `Rails.error` when
    # none is set (`rails_options` such as `severity:` go to `Rails.error`
    # only). Callers rescue: a broken reporter must not break a health tier.
    #
    # @api private
    def report_error(error, context:, **rails_options)
      if error_reporter
        error_reporter.call(error, context)
      elsif defined?(::Rails) && ::Rails.respond_to?(:error) && ::Rails.error
        ::Rails.error.report(error, handled: true, context: context, **rails_options)
      end
    end

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

    # `contributions` is the process-wide registry by default; a fresh one
    # isolates a test from whatever the loaded gems contributed.
    def initialize(contributions: StandardHealth.contributions)
      @contributions = contributions
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
      @aggregate_dependencies = true
      @ready_dependencies = false

      @instrumentation_enabled = true
      @logger = nil
      @sentry_enabled = true
      @metric_prefix = "health"
      @metrics_enabled = true
      @metric_events = nil
      @extra_notifiers = []
      @error_reporter = nil

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
    #
    # Re-registering a name replaces that registration in place (last writer
    # wins), so `configure` can safely re-run, e.g. from `to_prepare` on
    # reload, without running the check twice.
    def register_check(name, klass, critical: false, timeout: nil, **options)
      validate_check_options!(klass, options)
      registration = Registration.new(
        name: name.to_sym, klass: klass, critical: critical, timeout: timeout, options: options
      )
      upsert_registration(@checks, registration)
    end

    # The check set every consumer app registers by hand. Each entry: default
    # registration name, criticality, the check class (a String, resolved only
    # if the backing library is loaded), and the guard that decides whether
    # the backing library is present.
    #
    # Checks other gems contribute (`Contributions#contribute_check`) join this
    # set at `register_default_checks` time.
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
      # DEPRECATED: the one entry naming another gem's class. It stays until
      # standard_audit contributes `audit_retention` itself; once it does, its
      # contribution replaces this entry (same key, same position, never
      # registered twice) and this entry will be removed.
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
    # followed by every check another gem contributed
    # (`Contributions#contribute_check`), keyed by its contributed name and
    # non-critical unless the contributor said otherwise.
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
    # Each keyword (a built-in key or a contributed check's name) takes:
    #   true   — register with the defaults (the default)
    #   false  — don't register it
    #   Hash   — register with overrides: `name:`, `critical:`, `timeout:`,
    #            plus any constructor options (see #register_check)
    #
    #   c.register_default_checks solid_cache: false,
    #                             audit_retention: { critical: false, timeout: 1 },
    #                             standard_id_migrations: { critical: true }
    #
    # An unknown keyword raises ArgumentError listing the known ones.
    #
    # @return [Array<Symbol>] names actually registered by this call
    def register_default_checks(**settings)
      table = default_check_table
      settings = settings.transform_keys(&:to_sym)
      unknown = settings.keys - table.keys
      unless unknown.empty?
        raise ArgumentError,
              "unknown default check#{"s" if unknown.size > 1} #{unknown.map(&:inspect).join(", ")}; " \
              "known: #{table.keys.join(", ")}. A check from another gem is known only once that gem " \
              "has contributed it (when it is required)."
      end

      @contributions.defaults_applied!

      table.filter_map do |key, default|
        setting = settings.fetch(key, true)
        next unless setting
        next unless default[:available].call

        overrides = setting.is_a?(Hash) ? setting.transform_keys(&:to_sym) : {}
        name = (overrides.delete(:name) || default[:name]).to_sym
        next if @checks.any? { |reg| reg.name == name }

        critical = overrides.key?(:critical) ? overrides.delete(:critical) : default[:critical]
        timeout = overrides.key?(:timeout) ? overrides.delete(:timeout) : default[:timeout]
        klass = overrides.delete(:klass) || default_check_class(default)
        options = default.fetch(:options, {}).merge(overrides)

        register_check(name, klass, critical: critical, timeout: timeout, **options)
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
    #
    # Re-registering a name replaces it in place, as for #register_check.
    def register_aggregate_check(name, klass, critical: false, timeout: nil, **options)
      validate_check_options!(klass, options)
      registration = Registration.new(
        name: name.to_sym, klass: klass, critical: critical, timeout: timeout, options: options
      )
      upsert_registration(@aggregate_checks, registration)
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
    # status becomes an `:error` row (a raise is also reported, to
    # `error_reporter` or else `Rails.error` as handled). An `:error` row makes the endpoint's
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

    # DEFAULT_CHECKS plus contributed checks, keyed for register_default_checks.
    # A contribution under a built-in key (only `audit_retention` is allowed,
    # see Contributions::RESERVED_CHECK_NAMES) replaces that entry in place, so
    # the check keeps its position and is never registered twice.
    def default_check_table
      @contributions.checks.each_with_object(DEFAULT_CHECKS.dup) do |check, table|
        table[check.name] = {
          name: check.name, critical: check.critical, timeout: check.timeout,
          options: check.options, klass: check.klass, contributed: true,
          available: -> { true }
        }
      end
    end

    # Built-in defaults resolve their class now, so its constructor options
    # are validated at boot. A contributed class name stays a String and
    # resolves when the check runs (see Registration#check_class): the
    # contributing gem's constant may not be loadable yet.
    def default_check_class(default)
      return default[:klass] if default[:contributed]

      Object.const_get(default[:klass])
    end

    # Replaces the registration with the same name in place, or appends.
    def upsert_registration(registry, registration)
      index = registry.index { |existing| existing.name == registration.name }
      index ? registry[index] = registration : registry << registration
      registration
    end

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
