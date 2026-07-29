# frozen_string_literal: true

module StandardHealth
  module Notifiers
    # Logs health events.
    #
    # SILENT ON HEALTHY. This is the load-bearing difference from
    # StandardCircuit's logger notifier, and it is not a style preference.
    #
    # Circuit events are state TRANSITIONS — inherently rare, so logging every
    # one is fine. Health events are POLLS: DigitalOcean hits /health/ready
    # every 10s per instance, plus a liveness probe, plus any synthetic. A
    # line per evaluation is ~8,640 lines/day/instance of "everything is fine",
    # which buries the one line that matters and costs real money in log
    # ingest.
    #
    # So: nothing on :ok. `warn` on :degraded, `error` on :unavailable.
    class Logger
      def initialize(logger = nil)
        @logger = logger
      end

      def call(event_name, payload)
        case event_name
        when "standard_health.ready.evaluated" then log_evaluation(payload)
        when "standard_health.check.timed_out" then log_timeout(payload)
        end
      end

      private

      # THE log line has to carry the exception message, because redaction
      # strips it from the HTTP response. If it were only in the response we
      # just removed it from, it would be nowhere. Falls back to bare names
      # when a payload carries no detail.
      def detail(payload)
        failures = Array(payload[:failures])
        if failures.any?
          rendered = failures.map do |f|
            parts = [f[:name]].compact
            parts << f[:error_class] if f[:error_class]
            label = parts.join(" ")
            f[:error_message] ? "#{label}: #{f[:error_message]}" : label
          end
          return " — failing: #{rendered.join("; ")}"
        end

        failed = Array(payload[:failed])
        failed.empty? ? "" : " — failing: #{failed.join(", ")}"
      end

      def log_evaluation(payload)
        status = payload[:status]
        return if status.nil? || status.to_sym == :ok

        message = "[StandardHealth] readiness #{status}" \
                  "#{detail(payload)}" \
                  "#{payload[:duration_ms] ? " (#{payload[:duration_ms]}ms)" : ""}"

        case status.to_sym
        when :unavailable then emit_log(:error, message)
        else emit_log(:warn, message)
        end
        message
      end

      def log_timeout(payload)
        message = "[StandardHealth] check #{payload[:name]} timed out after #{payload[:timeout_s]}s"
        emit_log(:warn, message)
        message
      end

      def emit_log(level, message)
        target = @logger || default_logger
        target&.public_send(level, message)
      rescue StandardError
        # A broken logger must not break the health path.
        nil
      end

      def default_logger
        return ::Rails.logger if defined?(::Rails) && ::Rails.respond_to?(:logger) && ::Rails.logger

        nil
      end
    end
  end
end
