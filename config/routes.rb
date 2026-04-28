# frozen_string_literal: true

StandardHealth::Engine.routes.draw do
  get "/alive", to: "health#alive"
  get "/ready", to: "health#ready"

  namespace :diagnostics do
    get :env
  end
end
