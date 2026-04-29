# frozen_string_literal: true

module StandardHealth
  # Diagnostics endpoints. Output here is potentially sensitive (it
  # enumerates which env vars are missing), so host apps are responsible
  # for wrapping these routes with authentication.
  #
  # Inherits from `DiagnosticsApplicationController`, which resolves to
  # `config.diagnostics_parent_controller || config.parent_controller`.
  # This lets host apps put auth on diagnostics only — e.g. an HTTP Basic
  # `before_action :auth, only: :env` on a dedicated diagnostics parent —
  # without that callback leaking onto `HealthController` and tripping
  # Rails 7.1's `raise_on_missing_callback_actions`.
  class DiagnosticsController < DiagnosticsApplicationController
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
