# frozen_string_literal: true

module StandardHealth
  # Runs the host's `register_diagnostics_assertion` callables for the doctor
  # tier (`/diagnostics/env`, behind `diagnostics_basic_auth`).
  #
  # An assertion is a runtime fact that env presence cannot express: the live
  # `statement_timeout`, which cache store a limiter actually resolved to, how
  # close a pinned certificate is to expiry. Each callable returns a Hash with
  # at least `status:` (`:ok`, `:warn` or `:error`); any other keys (`value:`,
  # `expected:`, ...) are rendered as-is. The gem sets `name:`.
  #
  # Public: a host with its own diagnostics controller can render
  # `StandardHealth::DiagnosticsAssertions.run` itself.
  module DiagnosticsAssertions
    STATUSES = %i[ok warn error].freeze

    module_function

    # @return [Array<Hash>] one row per registered assertion, in registration
    #   order. Never raises: an assertion that raises, returns a non-Hash, or
    #   returns an unknown status becomes an `:error` row.
    def run(config = StandardHealth.config)
      config.diagnostics_assertions.map { |assertion| evaluate(assertion) }
    end

    # True when any row is `:error`. `:warn` is advisory.
    def failing?(rows)
      Array(rows).any? { |row| row[:status] == :error }
    end

    def evaluate(assertion)
      result = assertion.callable.call
      return invalid(assertion.name, "returned #{result.class}, expected a Hash") unless result.is_a?(Hash)

      row = result.to_h.transform_keys(&:to_sym)
      status = row[:status].respond_to?(:to_sym) ? row[:status].to_sym : nil
      return invalid(assertion.name, "returned status #{row[:status].inspect}, expected one of #{STATUSES.inspect}") unless STATUSES.include?(status)

      { name: assertion.name }.merge(row.except(:name)).merge(status: status)
    rescue StandardError => e
      report(e, assertion.name)
      # The doctor tier is authenticated, so the message is shown (the /ready
      # redaction rationale does not apply); the class is kept separately
      # for grouping.
      { name: assertion.name, status: :error, error_class: e.class.name, error: e.message }
    end

    def invalid(name, detail)
      { name: name, status: :error, error: "diagnostics assertion #{name} #{detail}" }
    end

    def report(error, name)
      return unless defined?(::Rails) && ::Rails.respond_to?(:error) && ::Rails.error

      ::Rails.error.report(error, handled: true, severity: :warning,
        context: { diagnostics_assertion: name }, source: "standard_health")
    rescue StandardError
      nil
    end
  end
end
