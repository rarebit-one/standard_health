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
    def ready
      result = StandardHealth::Aggregator.call
      http_status = result[:status] == :unavailable ? :service_unavailable : :ok
      render json: result, status: http_status
    end
  end
end
