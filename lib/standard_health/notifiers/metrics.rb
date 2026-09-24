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
    #
    # Hosts that find the per-poll volume too expensive narrow it with
    # `config.metric_events` (an allow-list, passed here as `events:`) or drop
    # the notifier with `config.metrics_enabled = false` — both 0.6.0 — rather
    # than prepending a filter onto this class.
    class Metrics
      CHECK_COMPLETED = "standard_health.check.completed"
      READY_EVALUATED = "standard_health.ready.evaluated"
      CHECK_TIMED_OUT = "standard_health.check.timed_out"

      # Every event this notifier records.
      EVENTS = [CHECK_COMPLETED, READY_EVALUATED, CHECK_TIMED_OUT].freeze

      # The events that fire on every probe — the metric volume.
      PER_POLL_EVENTS = [CHECK_COMPLETED, READY_EVALUATED].freeze

      # @param metric_prefix [String]
      # @param events [Array<String>, nil] allow-list; nil records everything
      def initialize(metric_prefix: "health", events: nil)
        @prefix = metric_prefix
        @events = events&.map(&:to_s)&.freeze
      end

      # @return [Array<String>, nil] the allow-list, or nil for "all"
      attr_reader :events

      def call(event_name, payload)
        return if @events && !@events.include?(event_name)
        return unless metrics_available?

        case event_name
        when CHECK_COMPLETED then record_check(payload)
        when READY_EVALUATED then record_evaluation(payload)
        when CHECK_TIMED_OUT then record_timeout(payload)
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
        attributes = { check: name, status: status, critical: payload[:critical].to_s }
        # Only aggregate-tier (0.6.0, opt-in) evaluations carry a tier, so
        # readiness series keep exactly the attributes they always had.
        attributes[:tier] = payload[:tier].to_s if payload[:tier]
        ::Sentry::Metrics.count("#{@prefix}.check", value: 1, attributes: attributes)

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
