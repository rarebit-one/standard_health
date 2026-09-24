# frozen_string_literal: true

StandardHealth::Engine.routes.draw do
  # Probe routes are drawn from PROBE_ACTIONS (alive, ready) so
  # StandardHealth::PROBE_PATHS / probe_path? cannot drift from what the
  # engine serves.
  StandardHealth::PROBE_ACTIONS.each do |action|
    get "/#{action}", to: "health##{action}"
  end

  namespace :diagnostics do
    get :env
  end
end
