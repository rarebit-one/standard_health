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
    #   :ok         — no violations
    #   :incomplete — at least one row is `:missing`, `:forbidden`, or
    #                 `:mismatch` (`EnvSpec::VIOLATION_STATUSES`)
    #
    # The `forbidden`/`mismatch` statuses join the roll-up rather than
    # getting a verdict of their own, so callers that already gate on
    # `status == "incomplete"` pick up the new assertions for free. Note the
    # level is deliberately NOT consulted: a `recommended` var declared with
    # an `expected_value:` that does not hold is a failed assertion, not
    # advice. The advisory status stays `:should_set`, which is not a
    # violation.
    #
    # The endpoint still returns 200 either way, so nothing that asserts on
    # the status code breaks.
    def audit_status(audit)
      violated = Array(audit).any? do |row|
        EnvSpec::VIOLATION_STATUSES.include?(row[:status])
      end
      violated ? :incomplete : :ok
    end
  end
end
