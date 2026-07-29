# frozen_string_literal: true

module StandardHealth
  # Strips raw exception text out of the /ready response body.
  #
  # WHY THIS IS ON BY DEFAULT
  #
  # /ready is unauthenticated by design — probes must not need credentials —
  # and until now a failing check put the driver's raw message straight into
  # the body. `PG::ConnectionBad` alone will happily tell the internet the
  # database host, port, and username. On a public load balancer that is a
  # credential-adjacent leak triggered by exactly the incident you least want
  # to be leaking during.
  #
  # So the default body carries `error_class` (a class name, which carries no
  # host or credential) and a stable `error_code` symbol for dashboards to
  # group on. The full message is NOT lost — it goes to logs and Sentry via
  # the instrumentation added in the same release. That coupling is why
  # redaction and instrumentation ship together: shipping redaction alone
  # would delete the only copy of the message.
  #
  # Escape hatches, both off by default:
  #   config.expose_check_errors = true   # restore v0.4.0 verbose bodies
  #   config.detail_token = "..."         # X-Health-Token unlocks detail
  #
  # Everything else in the row (name, status, critical, latency_ms) is
  # untouched, so existing dashboards and specs keep working.
  module Redactor
    module_function

    # @param result [Hash] the aggregator result
    # @param expose [Boolean] true to pass the raw bodies through untouched
    # @return [Hash] a result safe to render to an anonymous caller
    def call(result, expose: false)
      return result if expose

      rows = Array(result[:checks]).map { |row| redact_row(row) }
      result.merge(checks: rows)
    end

    def redact_row(row)
      return row unless row.key?(:error) || row.key?(:error_class)

      # A :skipped row's `error` is NOT driver output — it is a sentence this
      # gem generated from a config value ("total check budget of 5.0s
      # exhausted"). It was never a leak vector, and it is the only thing that
      # explains a :degraded roll-up caused by budget exhaustion. Redacting it
      # would replace a useful explanation with a misleading
      # `error_class: StandardError`, as though something had raised.
      return row if row[:status] == :skipped

      redacted = row.dup
      message = redacted.delete(:error)
      klass = redacted[:error_class]

      return redacted if message.nil? && klass.nil?

      redacted[:error_class] = klass || "StandardError"
      redacted[:error_code] = error_code_for(redacted[:error_class])
      redacted
    end

    # A stable, lowercase, underscored token derived from the exception class.
    # Dashboards group on this; it must not vary with the message text.
    #
    #   "PG::ConnectionBad" -> "pg_connection_bad"
    def error_code_for(class_name)
      class_name.to_s
                .gsub("::", "_")
                .gsub(/([a-z\d])([A-Z])/, '\1_\2')
                .downcase
    end
  end
end
