# frozen_string_literal: true

module StandardHealth
  # Diagnostics endpoints. Output here is potentially sensitive (it
  # enumerates which env vars are missing), so host apps are responsible
  # for wrapping these routes with authentication via `parent_controller`
  # — typically a basic-auth `before_action` on `ApplicationController`.
  class DiagnosticsController < ApplicationController
    # Audits the configured EnvSpec against the current process ENV and
    # returns the result as JSON. When no EnvSpec is configured the
    # endpoint returns an empty audit rather than a 404 so callers don't
    # have to special-case "feature not enabled".
    def env
      spec = StandardHealth.config.env_spec
      mode = ENV["APP_ENVIRONMENT"].to_s

      audit = spec ? spec.audit(ENV.to_h, mode: mode) : []

      render json: {
        mode: mode,
        audit: audit,
        generated_at: Time.now.utc.iso8601
      }
    end
  end
end
