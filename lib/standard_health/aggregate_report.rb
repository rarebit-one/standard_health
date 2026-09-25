# frozen_string_literal: true

module StandardHealth
  # Builds the aggregate tier served at the engine root when
  # `config.aggregate_endpoint` is on:
  #
  #   {
  #     status:       :ok | :degraded | :unavailable,
  #     checks:       [...],   # readiness checks (optional) + aggregate-only checks
  #     circuits:     [...],   # StandardCircuit.health_report[:circuits], when loaded
  #     generated_at: "..."
  #   }
  #
  # WHY IN THE ENGINE. Every consumer drew `get "/health"` BEFORE the engine
  # mount (a route-ordering trap both gems warn about) and two of them
  # hand-merged circuits and checks in a host controller. This is that
  # controller, owned once, so the host route and the controller can go.
  #
  # Status roll-up, in the estate's readiness vocabulary:
  #   :unavailable (503) — a critical check failed, or a :critical circuit is RED
  #   :degraded    (200) — a non-critical check failed, a check was skipped
  #                        by the total budget, or the circuit roll-up is
  #                        :degraded. A check that reports :skipped itself
  #                        (not applicable) is neutral — see Aggregator.
  #   :ok          (200) — otherwise
  #
  # StandardCircuit's own word for its worst state is `:critical`; it is
  # translated to `:unavailable` here and never reaches the response.
  #
  # Never raises (see .claude/rules/never-raise.md): checks run through the
  # Aggregator's safe_run, and a StandardCircuit that raises degrades the
  # tier rather than 500ing it.
  module AggregateReport
    EVENT = "standard_health.aggregate.evaluated"

    CIRCUIT_STATUS = { ok: :ok, degraded: :degraded, critical: :unavailable }.freeze

    module_function

    # @return [Hash] unredacted report; the controller redacts before render
    def call(config: StandardHealth.config, now: Time.now.utc)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      registrations = config.aggregate_checks
      registrations = config.checks + registrations if config.aggregate_readiness_checks
      checks_result = Aggregator.call(checks: registrations, now: now, tier: :aggregate)

      circuits = circuit_report(config)
      status = roll_up(checks_result[:status], circuits && circuits[:status])

      report = { status: status, checks: checks_result[:checks] }
      if circuits
        report[:circuits] = circuits[:circuits]
        report[:circuits_error] = circuits[:error] if circuits[:error]
      end
      report[:generated_at] = checks_result[:generated_at]

      emit_evaluation(report, checks_result[:checks], circuits, started)
      report
    end

    # nil when circuits are off or StandardCircuit is not loaded — the key is
    # then omitted from the body rather than rendered empty, so an app with no
    # circuits doesn't look like one whose circuits all vanished.
    def circuit_report(config)
      return nil unless config.aggregate_circuits
      return nil unless defined?(::StandardCircuit) && ::StandardCircuit.respond_to?(:health_report)

      report = ::StandardCircuit.health_report
      { status: CIRCUIT_STATUS.fetch(report[:status]&.to_sym, :degraded), circuits: Array(report[:circuits]) }
    rescue StandardError => e
      # A circuit data store that is down (Redis gone) must not 500 the
      # aggregate tier. Degrade, and say so with a class — never a message,
      # this body is anonymous.
      {
        status: :degraded,
        circuits: [],
        error: { error_class: e.class.name, error_code: Redactor.error_code_for(e.class.name) },
        error_message: e.message
      }
    end

    def roll_up(check_status, circuit_status)
      statuses = [check_status, circuit_status].compact
      return :unavailable if statuses.include?(:unavailable)
      return :degraded if statuses.include?(:degraded)

      :ok
    end

    # A dedicated event, NOT ready.evaluated: the Sentry notifier is
    # transition-gated on ready.evaluated with per-process state, and an
    # aggregate that includes soft checks would make it flap. The Logger
    # notifier logs this one (so redacted messages still reach logs); Sentry
    # and Metrics ignore it.
    def emit_evaluation(report, rows, circuits, started)
      failing = Aggregator.failing_rows(rows)
      payload = {
        status: report[:status],
        duration_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round,
        failed: failing.map { |r| r[:name] },
        failures: Aggregator.failure_details(failing)
      }
      if circuits
        payload[:circuits_status] = circuits[:status]
        payload[:red_circuits] = circuits[:circuits].select { |c| c[:color].to_s == "red" }.map { |c| c[:name] }
        if circuits[:error]
          payload[:circuits_error_class] = circuits[:error][:error_class]
          payload[:circuits_error_message] = circuits[:error_message]
        end
      end
      Aggregator.emit(EVENT, **payload)
    rescue StandardError
      # Instrumentation must never become a way for the tier to 500.
      nil
    end
  end
end
