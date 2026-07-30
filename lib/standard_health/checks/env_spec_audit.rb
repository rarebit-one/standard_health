# frozen_string_literal: true

require "standard_health/check"
require "standard_health/env_spec"

module StandardHealth
  module Checks
    # Surfaces EnvSpec violations as a health check.
    #
    # WHY THIS EXISTS
    #
    # The env-spec audit is otherwise only visible on `/diagnostics/env`,
    # which is authed and polled by nobody. So hosts that wanted config drift
    # to show up on a health tier wrote their own check to re-derive it —
    # fundbright-web carried two (`ForbiddenToggles`, `CspEnforcement`) built
    # from hand-maintained constant lists that had to be kept in sync with the
    # env spec by comment. This check reads the spec directly, so there is one
    # declaration and no list to drift.
    #
    # NOT REGISTERED AUTOMATICALLY. See `Checks::SolidCable` for the reasoning
    # — briefly: auto-registering would fail existing hosts on a `bundle
    # update` the moment their spec had any pre-existing violation.
    #
    # Register it yourself:
    #
    #   c.register_check :env_spec, StandardHealth::Checks::EnvSpecAudit
    #
    # NON-CRITICAL BY DEFAULT, and that default is load-bearing. Config drift
    # is *visibility*, not a rotation signal: an instance with a stale toggle
    # set is still serving traffic correctly, and pulling it out of rotation
    # would convert a warning into an outage. It rolls the aggregate up to
    # `:degraded` (HTTP 200). Registering it `critical: true` means "this app
    # must not serve at all with a bad env", which is a real but rare posture
    # — and on the readiness tier it will pull instances. Know which you want.
    #
    # To narrow what counts as a failure, or to make it critical, subclass —
    # the aggregator instantiates checks with `name:`/`critical:` only, so
    # per-registration options are not available:
    #
    #   class StrictEnvSpec < StandardHealth::Checks::EnvSpecAudit
    #     def initialize(name: :env_spec, critical: false)
    #       super(name: name, critical: critical, fail_on: %i[forbidden])
    #     end
    #   end
    class EnvSpecAudit < Check
      # Reported as `error_class` so the redacted body carries a groupable
      # `error_code` (`standard_health_env_spec_violation`) instead of a
      # meaningless "StandardError". Not an exception class — nothing here
      # raises — just a stable label.
      VIOLATION_LABEL = "StandardHealth::EnvSpecViolation"

      def initialize(name: :env_spec, critical: false, fail_on: EnvSpec::VIOLATION_STATUSES)
        super(name: name, critical: critical)
        @fail_on = Array(fail_on).map(&:to_sym)
      end

      # @return [Array<Symbol>] audit statuses this check treats as failures
      attr_reader :fail_on

      def run
        violations = nil

        # `with_timing` is what keeps the never-raise invariant: `audit` runs
        # host-supplied `if:`/`unless:` procs and can raise `UnknownModeAlias`,
        # and neither may reach the aggregator as an exception.
        timing = with_timing { violations = violating_rows }

        return timing unless timing[:status] == :ok
        return timing if violations.empty?

        timing.merge(
          status: :fail,
          error: describe(violations),
          error_class: VIOLATION_LABEL
        )
      end

      private

      def violating_rows
        spec = ::StandardHealth.config.env_spec
        return [] unless spec

        # No `root:`. Resolving `consumed_by` paths does file IO per entry,
        # which is fine for an on-demand doctor endpoint and not fine on a
        # health tier that gets polled every few seconds. Consumer presence is
        # a code-review question anyway, not a runtime health signal.
        spec.audit(ENV.to_h, mode: ENV["APP_ENVIRONMENT"].to_s)
            .select { |row| @fail_on.include?(row[:status]) }
      end

      # Names only, grouped by status. Env var NAMES are not secrets and are
      # the whole point of the message; VALUES never appear. This message is
      # redacted out of an unauthenticated /ready body anyway and reaches
      # operators via the instrumentation events.
      def describe(violations)
        violations
          .group_by { |row| row[:status] }
          .sort_by { |status, _| status.to_s }
          .map { |status, rows| "#{status}: #{rows.map { |r| r[:name] }.sort.join(', ')}" }
          .join("; ")
      end
    end
  end
end
