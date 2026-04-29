# frozen_string_literal: true

module StandardHealth
  # Base controller for all StandardHealth endpoints.
  #
  # Lazily inherits from `StandardHealth.config.parent_controller` (resolved
  # by `StandardHealth.parent_controller` in lib/standard_health.rb) so host
  # apps can wire their own auth/rate-limiting/before_actions in once and
  # have them apply to /alive and /ready. The default is
  # `ActionController::API` so the engine works in API-only host apps
  # without configuration.
  #
  # `DiagnosticsController` has its own base class
  # (`DiagnosticsApplicationController`) with its own resolver — see
  # `config.diagnostics_parent_controller`.
  class ApplicationController < parent_controller
  end
end
