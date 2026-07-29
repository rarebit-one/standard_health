# frozen_string_literal: true

module StandardHealth
  module Notifiers
    # Forwards readiness degradation to Sentry.
    #
    # TRANSITION-ONLY, WITH A REPEAT FLOOR. This is the load-bearing difference
    # from StandardCircuit's Sentry notifier, and it is not a style preference.
    #
    # Circuit events are state transitions — rare, so capturing each one is
    # fine. Health events are POLLS at ~6/minute/instance. Capturing each
    # non-ok evaluation would turn a five-minute outage into ~30 duplicate
    # Sentry events per instance, which is how alerting gets muted.
    #
    # So we capture only when the status CHANGES, plus a floor (default 60s)
    # that re-reports a sustained bad state occasionally rather than never.
    # Recovery (back to :ok) is reported once, at :info, because "it came back"
    # is genuinely useful and happens exactly once per incident.
    #
    # State is per-process and mutex-guarded: Puma runs threaded, and several
    # threads can serve concurrent probes.
    #
    # Sentry is a SOFT dependency — guarded by `defined?`, never a gemspec
    # entry — so hosts that don't use Sentry pay nothing.
    class Sentry
      DEFAULT_REPEAT_FLOOR_SECONDS = 60

      def initialize(repeat_floor_seconds: DEFAULT_REPEAT_FLOOR_SECONDS)
        @repeat_floor_seconds = repeat_floor_seconds
        @mutex = Mutex.new
        @last_status = nil
        @last_reported_status = nil
        @last_reported_at = nil
      end

      def call(event_name, payload)
        return unless event_name == "standard_health.ready.evaluated"
        return unless sentry_available?

        status = payload[:status]&.to_sym
        return if status.nil?

        return unless should_report?(status)

        capture(status, payload)
      end

      private

      def sentry_available?
        defined?(::Sentry) && ::Sentry.respond_to?(:capture_message)
      end

      # Severity ordering. Only used to decide what counts as an escalation.
      SEVERITY = { ok: 0, degraded: 1, unavailable: 2 }.freeze

      # Decide whether this evaluation is worth a Sentry event.
      #
      # Three rules, in order:
      #
      # 1. ESCALATION always reports, immediately. Getting worse is urgent and
      #    must never sit behind a rate limit — a degraded app going
      #    unavailable during a floor window has to page now.
      #
      # 2. Otherwise the repeat floor applies, to EVERYTHING else. Reporting
      #    every transition unconditionally sounds right but reintroduces the
      #    exact noise the floor exists to stop: a check flapping
      #    ok → degraded → ok → degraded on a 10s poll is a "transition" six
      #    times a minute. Recoveries and re-degradations are therefore
      #    rate-limited; escalations are not.
      #
      # 3. A steady :ok never reports.
      #
      # The FIRST observation is special-cased. With no prior state every
      # comparison counts as a change, so a freshly booted process serving a
      # healthy first probe would emit "Health recovered" — once per process,
      # on every deploy and restart, for something that never broke. A first
      # observation is only worth reporting if it is already bad.
      def should_report?(status)
        now = monotonic_now
        @mutex.synchronize do
          first = @last_status.nil?
          stale = @last_reported_at.nil? || (now - @last_reported_at) >= @repeat_floor_seconds
          escalated = !first && severity(status) > severity(@last_reported_status || @last_status)

          report =
            if first
              status != :ok
            elsif escalated
              true
            elsif status == :ok
              # Recovery is worth saying once, but only if we actually
              # reported a problem — and it is rate-limited like everything
              # else, because a flapping check recovers as often as it breaks.
              # At the default 60s floor a genuine recovery lands within a
              # minute, which is fine for "it came back"; that small delay is
              # the price of not emitting six events a minute during a blip.
              stale && !(@last_reported_status.nil? || @last_reported_status == :ok)
            else
              stale
            end

          @last_status = status
          if report
            @last_reported_at = now
            @last_reported_status = status
          end
          report
        end
      end

      def severity(status)
        SEVERITY.fetch(status&.to_sym, 0)
      end

      def capture(status, payload)
        failed = Array(payload[:failed])
        level = status == :unavailable ? :error : (status == :ok ? :info : :warning)
        message =
          if status == :ok
            "Health recovered: readiness ok"
          else
            "Health #{status}#{failed.empty? ? "" : ": #{failed.join(", ")}"}"
          end

        # `failures` carries error_class + error_message. Redaction removed
        # those from the HTTP body on the promise they still reach Sentry —
        # so they have to be here, or that promise is false and the message
        # is gone entirely.
        failures = Array(payload[:failures])

        ::Sentry.capture_message(
          message,
          level: level,
          extra: {
            status: status.to_s,
            failed: (failed.empty? ? nil : failed),
            failures: (failures.empty? ? nil : failures),
            duration_ms: payload[:duration_ms]
          }.compact
        )
        message
      rescue StandardError
        # Observability must never break the health path.
        nil
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
