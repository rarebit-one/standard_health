# frozen_string_literal: true

module StandardHealth
  # Runs all registered checks and rolls them up into a single status.
  #
  # Status semantics:
  #   :ok           — every check returned :ok
  #   :degraded     — at least one non-critical check failed
  #   :unavailable  — at least one critical check failed
  #
  # The aggregator never raises. Each check is invoked through
  # `safe_run` which catches `StandardError` so a buggy custom check
  # cannot take down /ready.
  class Aggregator
    def self.call(checks: StandardHealth.config.checks, now: Time.now.utc)
      check_rows = checks.map { |reg| safe_run(reg) }
      {
        status: overall_status(check_rows),
        checks: check_rows,
        generated_at: now.iso8601
      }
    end

    def self.safe_run(reg)
      result = reg.klass.new(name: reg.name, critical: reg.critical).run
      result.merge(name: reg.name, critical: reg.critical)
    rescue StandardError => e
      {
        name: reg.name,
        critical: reg.critical,
        status: :fail,
        error: e.message
      }
    end
    private_class_method :safe_run

    def self.overall_status(rows)
      return :ok if rows.empty?

      failures = rows.reject { |r| r[:status] == :ok }
      return :ok if failures.empty?
      return :unavailable if failures.any? { |r| r[:critical] }

      :degraded
    end
    private_class_method :overall_status
  end
end
