# frozen_string_literal: true

module StandardHealth
  # Registers internal and user-supplied subscribers against whichever event
  # bus is live (Rails.event on 8.1+, ActiveSupport::Notifications elsewhere).
  #
  # Each subscriber must respond to `call(event_name, payload)`. Internal
  # subscribers (Logger / Sentry / Metrics) are built from the live config so
  # changes to `metric_prefix` / `logger` propagate when `setup!` is re-run.
  #
  # Subscriptions cover the namespace prefix `standard_health.`, so a single
  # registration on each backend listens for every event the gem emits.
  #
  # @api private
  class Subscribers
    EVENT_PATTERN = "standard_health."
    EVENT_REGEXP = /\A#{Regexp.escape(EVENT_PATTERN)}/

    def initialize
      @rails_event_subscribers = []
      @as_subscribers = []
    end

    def setup!
      teardown!
      return unless StandardHealth.config.instrumentation_enabled

      register(internal_subscribers + extra_subscribers)
    end

    # Tear down both backends. Rails.event subscribers are unsubscribed
    # unconditionally — we recorded them at registration time, so we must
    # remove them even if Rails.event has since become unavailable (e.g. test
    # `hide_const("Rails")`). Otherwise the wrappers would remain live in the
    # bus while we believe they are gone.
    def teardown!
      @rails_event_subscribers.each do |subscriber|
        ::Rails.event.unsubscribe(subscriber) if EventEmitter.rails_event_available?
      rescue StandardError
        # If Rails.event is gone (test isolation), we can do nothing more —
        # clearing the array still releases our reference.
      end
      @rails_event_subscribers.clear

      @as_subscribers.each do |subscriber|
        ::ActiveSupport::Notifications.unsubscribe(subscriber)
      end
      @as_subscribers.clear
    end

    private

    def register(subscribers)
      subscribers.each { |subscriber| register_one(subscriber) }
    end

    # Register on whichever backend is live. We do not double-subscribe — if
    # `Rails.event` is present, every emit goes through it (see EventEmitter),
    # so the AS::Notifications side would never receive anything.
    def register_one(subscriber)
      if EventEmitter.rails_event_available?
        wrapper = RailsEventAdapter.new(subscriber)
        ::Rails.event.subscribe(wrapper)
        @rails_event_subscribers << wrapper
      else
        handle = ::ActiveSupport::Notifications.subscribe(EVENT_REGEXP) do |name, _start, _finish, _id, payload|
          subscriber.call(name, payload)
        end
        @as_subscribers << handle
      end
    end

    def internal_subscribers
      config = StandardHealth.config
      list = [Notifiers::Logger.new(config.logger)]
      list << Notifiers::Sentry.new if config.sentry_enabled
      list << Notifiers::Metrics.new(metric_prefix: config.metric_prefix)
      list
    end

    # Config#add_notifier already enforces that every entry responds to :call,
    # so we can hand the array straight through to register/1.
    def extra_subscribers
      StandardHealth.config.extra_notifiers
    end

    # Adapts a `call(name, payload)` subscriber to the Rails.event#subscribe
    # contract, which delivers a Hash event with :name / :payload / :context /
    # :tags / :source_location.
    class RailsEventAdapter
      def initialize(subscriber)
        @subscriber = subscriber
      end

      def emit(event)
        name = event[:name]
        return unless name&.start_with?(EVENT_PATTERN)

        @subscriber.call(name, event[:payload] || {})
      end
    end
  end
end
