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
      root = defined?(Rails) ? Rails.root : nil

      audit = spec ? spec.audit(ENV.to_h, mode: mode, root: root) : []

      render json: {
        mode: mode,
        status: audit_status(audit),
        audit: audit,
        generated_at: Time.now.utc.iso8601
      }
    end

    private

    # Top-level verdict so a caller can gate on ONE field instead of
    # re-implementing the roll-up over `audit`.
    #
    #   :ok         — nothing required is missing
    #   :incomplete — at least one `required` var is missing
    #
    # ADDITIVE ONLY in 0.4.1: the endpoint still returns 200 either way, so
    # nothing that asserts on the status code breaks. That is the point —
    # it gives monitors a release in which to migrate onto this field before
    # 0.5.0 makes `:incomplete` a 503. Without the migration window, turning
    # the code non-200 would silently redden every existing caller.
    def audit_status(audit)
      incomplete = Array(audit).any? do |row|
        row[:level].to_s == "required" && row[:status].to_s == "missing"
      end
      incomplete ? :incomplete : :ok
    end
  end
end
