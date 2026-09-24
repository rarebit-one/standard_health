# frozen_string_literal: true

require "timeout"

module StandardHealth
  # Raised internally when a check exceeds its timeout.
  #
  # A DEDICATED subclass, never bare `Timeout::Error`: `Timeout.timeout` with
  # the default class would also swallow a timeout the host app raised for its
  # own reasons and mislabel it as ours. Passing our own class means we only
  # ever catch the one we threw.
  class CheckTimeout < ::Timeout::Error; end

  # Runs all registered checks and rolls them up into a single status.
  #
  # Status semantics:
  #   :ok           — every check returned :ok
  #   :degraded     — at least one non-critical check failed, OR a check was
  #                   skipped because the total budget ran out
  #   :unavailable  — at least one critical check failed
  #
  # The aggregator never raises. Each check is invoked through `safe_run`
  # which catches `StandardError` so a buggy custom check cannot take down
  # /ready. Instrumentation is held to the same bar — every emit is wrapped
  # so a broken subscriber cannot become a new way for /ready to 500.
  class Aggregator
    # @param checks [Array<Configuration::Registration>]
    # @param now [Time]
    # @param tier [Symbol] which endpoint is evaluating. `:ready` (the default)
    #   emits `standard_health.ready.evaluated` exactly as before. Any other
    #   tier (0.6.0: `:aggregate`) emits only the per-check events — tagged
    #   with `tier:` — and leaves the evaluation event to its caller. That
    #   matters: the Sentry notifier is transition-gated on ready.evaluated
    #   with per-process state, so interleaving aggregate evaluations (which
    #   can include soft checks readiness doesn't run) would make it flap.
    def self.call(checks: StandardHealth.config.checks, now: Time.now.utc, tier: :ready)
      started = monotonic
      budget = StandardHealth.config.total_check_budget

      check_rows = checks.map do |reg|
        if budget_exhausted?(budget, started)
          row = skipped_row(reg, budget)
          # Skips emit too. Without this a skip is invisible to the Metrics
          # notifier — the only trace would be a name inside ready.evaluated's
          # `failed[]`, with no per-check counter — so once a budget is
          # enabled you could not answer "how often is check X getting
          # skipped", which is exactly the question a budget creates.
          emit_check(row, tier)
          row
        else
          safe_run(reg, tier)
        end
      end

      duration_ms = ((monotonic - started) * 1000).round
      status = overall_status(check_rows)

      failing = check_rows.reject { |r| r[:status] == :ok }

      return { status: status, checks: check_rows, generated_at: now.iso8601 } unless tier == :ready

      emit(
        "standard_health.ready.evaluated",
        status: status,
        duration_ms: duration_ms,
        failed: failing.map { |r| r[:name] },
        # The full failure detail rides on THIS event, not only on the
        # per-check one. Redaction removes the message from the HTTP body on
        # the promise that it still reaches logs and Sentry — but both of
        # those subscribers are driven by ready.evaluated (deliberately: it
        # is the transition-gated event, so they don't fire per poll). If the
        # message only existed on check.completed, redaction would delete the
        # last copy instead of relocating it.
        failures: failure_details(failing)
      )

      {
        status: status,
        checks: check_rows,
        generated_at: now.iso8601
      }
    end

    # Per-failure detail for an evaluation event. Public (but @api private) so
    # the aggregate tier's evaluation event carries the same shape.
    # @api private
    def self.failure_details(failing)
      failing.map do |r|
        {
          name: r[:name],
          critical: r[:critical],
          status: r[:status],
          error_class: r[:error_class],
          error_message: r[:error]
        }.compact
      end
    end

    def self.safe_run(reg, tier = :ready)
      timeout = reg.timeout || StandardHealth.config.default_check_timeout
      instance = reg.build

      result =
        if timeout
          Timeout.timeout(timeout, CheckTimeout) { instance.run }
        else
          instance.run
        end

      row = result.merge(name: reg.name, critical: reg.critical)
      emit_check(row, tier)
      row
    rescue CheckTimeout
      # Deliberately NOT sent to Rails.error (unlike the StandardError branch
      # below). A timeout is our own budget firing on a slow dependency, not a
      # bug in the check: it is already visible as `check.timed_out` and as a
      # failing row, and reporting it per poll would page on latency. The
      # pre-0.6 host aggregate controllers had no per-check timeouts, so
      # nothing reported there is lost.
      emit("standard_health.check.timed_out",
           name: reg.name, critical: reg.critical, timeout_s: timeout, **tier_attrs(tier))
      row = {
        name: reg.name,
        critical: reg.critical,
        status: :fail,
        error: "timed out after #{timeout}s",
        error_class: "StandardHealth::CheckTimeout"
      }
      emit_check(row, tier)
      row
    rescue StandardError => e
      row = {
        name: reg.name,
        critical: reg.critical,
        status: :fail,
        error: e.message,
        error_class: e.class.name
      }
      emit_check(row, tier)
      report_raised_check(e, reg, tier)
      row
    end
    private_class_method :safe_run

    # A check that RAISES (rather than returning a :fail row) on a
    # non-readiness tier goes to `Rails.error` as handled. Before 0.6.0 every
    # host's aggregate controller did exactly this; moving the tier into the
    # engine left the exception only in the Logger notifier's line, so a buggy
    # aggregate check stopped reaching the error tracker.
    #
    # Readiness is deliberately excluded: its failures already reach Sentry
    # through the transition-gated `ready.evaluated` notifier, and reporting
    # every raise from a ~6/min/instance probe would be exactly the noise that
    # notifier exists to prevent. Severity mirrors that notifier: a critical
    # check is an :error (it makes the tier :unavailable), otherwise :warning.
    def self.report_raised_check(error, reg, tier)
      return if tier == :ready
      return unless defined?(::Rails) && ::Rails.respond_to?(:error) && ::Rails.error

      ::Rails.error.report(
        error,
        handled: true,
        severity: reg.critical ? :error : :warning,
        context: { health_check: reg.name.to_s, tier: tier.to_s }
      )
    rescue StandardError
      # Never-raise: a broken error subscriber must not 500 the tier.
      nil
    end
    private_class_method :report_raised_check

    def self.budget_exhausted?(budget, started)
      return false unless budget

      (monotonic - started) >= budget
    end
    private_class_method :budget_exhausted?

    # A check the total budget never reached. `:skipped`, never silently
    # `:ok` — an unperformed check is not a healthy one.
    def self.skipped_row(reg, budget)
      {
        name: reg.name,
        critical: reg.critical,
        status: :skipped,
        error: "skipped — total check budget of #{budget}s exhausted"
      }
    end
    private_class_method :skipped_row

    def self.overall_status(rows)
      return :ok if rows.empty?

      failures = rows.reject { |r| r[:status] == :ok }
      return :ok if failures.empty?

      # A SKIP MUST NEVER PRODUCE :unavailable, even for a critical check.
      # Otherwise a slow *non-critical* check could exhaust the budget, leave
      # the database check unrun, and pull a perfectly healthy instance out of
      # rotation — a self-inflicted outage caused by the safety mechanism.
      # Skips floor the result at :degraded; only a real critical FAILURE
      # reaches :unavailable.
      return :unavailable if failures.any? { |r| r[:critical] && r[:status] != :skipped }

      :degraded
    end
    private_class_method :overall_status

    def self.emit_check(row, tier = :ready)
      emit(
        "standard_health.check.completed",
        name: row[:name],
        critical: row[:critical],
        status: row[:status],
        latency_ms: row[:latency_ms],
        error_class: row[:error_class],
        error_message: row[:error],
        **tier_attrs(tier)
      )
    end
    private_class_method :emit_check

    # Readiness payloads are left byte-for-byte as they were before tiers
    # existed; only non-readiness tiers are labelled.
    def self.tier_attrs(tier)
      tier == :ready ? {} : { tier: tier }
    end
    private_class_method :tier_attrs

    # Belt and braces on top of EventEmitter's own rescue. Honours
    # `instrumentation_enabled`. @api private (also used by AggregateReport). The never-raise
    # rule names this file, and instrumentation is the newest way to violate
    # it — so the call site guards too.
    def self.emit(event_name, **payload)
      return unless StandardHealth.config.instrumentation_enabled

      EventEmitter.emit(event_name, payload)
    rescue StandardError
      nil
    end

    def self.monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
    private_class_method :monotonic
  end
end
