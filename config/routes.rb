# frozen_string_literal: true

StandardHealth::Engine.routes.draw do
  # Probe routes are drawn from PROBE_ACTIONS (alive, ready) so
  # StandardHealth::PROBE_PATHS / probe_path? cannot drift from what the
  # engine serves.
  StandardHealth::PROBE_ACTIONS.each do |action|
    get "/#{action}", to: "health##{action}"
  end

  # Aggregate tier at the engine root (GET /health for the usual mount).
  # OPT-IN: the constraint is evaluated per request, so with
  # `aggregate_endpoint` off this route never matches and a bare /health
  # cascades to the host's own route exactly as it did before 0.6.0.
  get "/", to: "health#aggregate", as: :aggregate,
           constraints: ->(_request) { StandardHealth.config.aggregate_endpoint }

  namespace :diagnostics do
    get :env
  end
end
