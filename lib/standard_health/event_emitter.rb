# frozen_string_literal: true

module StandardHealth
  # Internal helper that emits StandardHealth events through whichever event
  # reporter is live in the host process.
  #
  # - On Rails 8.1+, `Rails.event.notify(name, **payload)` is the canonical bus.
  # - On older Rails (or any host without the structured reporter), we fall back
  #   to `ActiveSupport::Notifications.instrument(name, payload)`.
  #
  # Detection is performed at *call time* — the gem is required before Rails has
  # finished booting, so we cannot cache the decision at load time.
  #
  # This mirrors StandardCircuit::EventEmitter deliberately: one idiom for
  # observability across the standard_* gems.
  #
  # @api private
  module EventEmitter
    module_function

    # Emit a single event. Both backends are best-effort: any exception raised
    # by a subscriber is swallowed so health observability never takes down the
    # health path itself. See .claude/rules/never-raise.md — instrumentation
    # must not become a new way for /ready to 500.
    def emit(event_name, payload)
      if rails_event_available?
        ::Rails.event.notify(event_name, **payload)
      else
        ::ActiveSupport::Notifications.instrument(event_name, payload)
      end
    rescue => e
      warn "[StandardHealth] event emit for #{event_name.inspect} failed: #{e.class}: #{e.message}"
    end

    def rails_event_available?
      defined?(::Rails) &&
        ::Rails.respond_to?(:event) &&
        ::Rails.event.respond_to?(:notify)
    end
  end
end
