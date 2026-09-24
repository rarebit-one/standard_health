# frozen_string_literal: true

module StandardHealth
  class HealthController < ApplicationController
    # Liveness probe. Returns 200 unconditionally — its only job is to
    # confirm the Rails process is up and routing requests. Anything
    # heavier belongs in /ready.
    def alive
      head :ok
    end

    # Readiness probe. Runs every registered check and returns:
    #   200 if the rolled-up status is :ok or :degraded
    #   503 if any critical check failed (:unavailable)
    #
    # Failure detail is REDACTED by default — see StandardHealth::Redactor.
    # This endpoint is unauthenticated so probes need no credentials, and a
    # raw driver error will happily tell an anonymous caller the database
    # host, port and username. The full message goes to logs and Sentry
    # instead. Status codes and every other field are unchanged.
    def ready
      result = StandardHealth::Aggregator.call
      http_status = result[:status] == :unavailable ? :service_unavailable : :ok
      render json: StandardHealth::Redactor.call(result, expose: expose_errors?),
             status: http_status
    end

    # Aggregate tier (0.6.0, opt-in via `config.aggregate_endpoint`; the route
    # does not match otherwise). Checks + StandardCircuit state in one body —
    # see StandardHealth::AggregateReport. 503 only on :unavailable, i.e. a
    # critical check failure or a :critical circuit RED. Redacted exactly like
    # /ready, with the same break-glass.
    def aggregate
      report = StandardHealth::AggregateReport.call
      http_status = report[:status] == :unavailable ? :service_unavailable : :ok
      render json: StandardHealth::Redactor.call(report, expose: expose_errors?),
             status: http_status
    end

    private

    # Detail is exposed when the host opted in globally, or when the caller
    # presents the break-glass token. Compared in constant time: the token is
    # a secret, and a naive == leaks its length and prefix to a patient
    # attacker on an endpoint that is public by design.
    def expose_errors?
      config = StandardHealth.config
      return true if config.expose_check_errors

      token = config.detail_token
      return false if token.nil? || token.empty?

      presented = request.headers["X-Health-Token"].to_s
      return false if presented.empty?

      ActiveSupport::SecurityUtils.secure_compare(presented, token)
    rescue StandardError
      false
    end
  end
end
