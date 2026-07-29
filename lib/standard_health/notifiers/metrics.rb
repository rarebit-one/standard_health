# frozen_string_literal: true

module StandardHealth
  module Notifiers
    # Emits per-check and per-evaluation metrics.
    #
    # Unlike the Logger and Sentry notifiers, this one fires on EVERY poll on
    # purpose. Counters and distributions are cheap, they aggregate, and the
    # poll rate is exactly what makes them useful: it is what lets you chart
    # p95 check latency and see "database check went from 3ms to 400ms an hour
    # before the outage".
    #
    # `latency_ms` has been computed on every check since v0.1.0 and thrown
    # away into the response body. This is where it finally goes somewhere.
    #
    # Sentry::Metrics is a SOFT dependency — guarded by `defined?`, never a
    # gemspec entry.
    class Metrics
      def initialize(metric_prefix: "health")
        @prefix = metric_prefix
      end

      def call(event_name, payload)
        return unless metrics_available?

        case event_name
        when "standard_health.check.completed" then record_check(payload)
        when "standard_health.ready.evaluated" then record_evaluation(payload)
        when "standard_health.check.timed_out" then record_timeout(payload)
        end
      rescue StandardError
        # Observability must never break the health path.
        nil
      end

      private

      def metrics_available?
        defined?(::Sentry::Metrics) && ::Sentry::Metrics.respond_to?(:count)
      end

      def record_check(payload)
        name = payload[:name].to_s
        status = payload[:status].to_s
        ::Sentry::Metrics.count(
          "#{@prefix}.check",
          value: 1,
          attributes: { check: name, status: status, critical: payload[:critical].to_s }
        )

        latency = payload[:latency_ms]
        return unless latency && ::Sentry::Metrics.respond_to?(:distribution)

        ::Sentry::Metrics.distribution(
          "#{@prefix}.check.duration",
          value: latency,
          unit: "millisecond",
          attributes: { check: name }
        )
      end

      def record_evaluation(payload)
        ::Sentry::Metrics.count(
          "#{@prefix}.ready",
          value: 1,
          attributes: { status: payload[:status].to_s }
        )

        duration = payload[:duration_ms]
        return unless duration && ::Sentry::Metrics.respond_to?(:distribution)

        ::Sentry::Metrics.distribution(
          "#{@prefix}.ready.duration",
          value: duration,
          unit: "millisecond"
        )
      end

      def record_timeout(payload)
        ::Sentry::Metrics.count(
          "#{@prefix}.check.timeout",
          value: 1,
          attributes: { check: payload[:name].to_s }
        )
      end
    end
  end
end
