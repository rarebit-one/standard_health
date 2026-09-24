# frozen_string_literal: true

require "digest"

module StandardHealth
  # Request-time half of `config.diagnostics_basic_auth`. Included into
  # `DiagnosticsController` only — never `HealthController` — so /alive and
  # /ready stay anonymous for orchestrator probes.
  #
  # A NO-OP when `diagnostics_basic_auth` is unset, so hosts that gate
  # diagnostics through `diagnostics_parent_controller` see no change. Both
  # can be used together; the parent's callbacks run first.
  module DiagnosticsAuthentication
    extend ActiveSupport::Concern

    included do
      # ActionController::API does not include this; ActionController::Base
      # does, and including it twice is harmless.
      include ActionController::HttpAuthentication::Basic::ControllerMethods

      before_action :standard_health_diagnostics_basic_auth!
    end

    private

    def standard_health_diagnostics_basic_auth!
      settings = StandardHealth.config.diagnostics_basic_auth
      return unless settings

      user = settings.expected_username
      pass = settings.expected_password

      if user.empty? || pass.empty?
        return if settings.allow_unconfigured?

        return refuse_unconfigured_diagnostics!
      end

      authenticate_or_request_with_http_basic(settings.realm) do |given_user, given_pass|
        settings.authenticate(given_user, given_pass)
      end
    rescue StandardError => e
      # A credential lookup that raises (missing credentials key, Current not
      # set, ...) must fail CLOSED — never fall through to the audit, and
      # never 500 (see below). The class name is logged, not rendered.
      Rails.logger&.warn("[StandardHealth] diagnostics auth lookup failed: #{e.class}")
      refuse_unconfigured_diagnostics!
    end

    # 403, NOT 5xx — a platform constraint, not a preference. DigitalOcean
    # App Platform's edge replaces an app 5xx with its own generic error page,
    # so a 503 here is indistinguishable from the app being down and the
    # explanation is thrown away. 403 passes through and is honest: access is
    # refused. Not 401, because a challenge invites retrying with credentials
    # that cannot work — none are configured to match.
    def refuse_unconfigured_diagnostics!
      render json: {
        error: "diagnostics refused",
        detail: "diagnostics basic-auth credentials are not configured, so this endpoint " \
                "cannot be authenticated. Refusing rather than exposing env state."
      }, status: :forbidden
    end
  end
end
