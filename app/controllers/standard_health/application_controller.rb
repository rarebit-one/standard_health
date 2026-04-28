# frozen_string_literal: true

module StandardHealth
  # Base controller for all StandardHealth endpoints.
  #
  # Lazily inherits from `StandardHealth.config.parent_controller` so host
  # apps can wire their own auth/rate-limiting/before_actions in once and
  # have them apply to /alive, /ready, and /diagnostics/env. The default
  # is `ActionController::API` so the engine works in API-only host apps
  # without configuration.
  #
  # Resolution happens at the moment this class is first referenced, which
  # is request time — by then the host app's controllers are loaded and
  # the constant resolves cleanly. Caching the resolved class on the
  # singleton avoids re-running `constantize` per request.
  def self.parent_controller
    @parent_controller ||= config.parent_controller.constantize
  end

  # Allow tests/host apps to bust the cached parent controller (e.g. when
  # toggling config between examples).
  def self.reset_parent_controller!
    @parent_controller = nil
  end

  class ApplicationController < parent_controller
  end
end
