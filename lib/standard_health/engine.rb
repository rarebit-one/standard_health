# frozen_string_literal: true

module StandardHealth
  class Engine < ::Rails::Engine
    isolate_namespace StandardHealth

    # Boot hook: register the internal Logger / Sentry / Metrics subscribers
    # (and any `extra_notifiers` the host configured) against whichever event
    # bus is live in this Rails version.
    #
    # `after: :load_config_initializers` is load-bearing — every host's
    # StandardHealth config lives in `config/initializers/standard_health.rb`,
    # and the internal subscribers are built FROM that config (logger,
    # metric_prefix, sentry_enabled, instrumentation_enabled). Registering
    # earlier would capture defaults and silently ignore the host's settings.
    initializer "standard_health.subscribers", after: :load_config_initializers do
      StandardHealth.subscribers.setup!
    end
  end
end
