# frozen_string_literal: true

require "rails_helper"

# Pins the routing behaviour the README's ordering guidance rests on.
#
# The engine draws SUB-paths only, so it has no route for a bare `/health`.
# The claim "draw the aggregate route first, but drawing it after still
# resolves" is a statement about Rails route cascading — when a mounted app's
# router matches nothing it returns `X-Cascade: pass` and the parent route set
# keeps matching. That is load-bearing documentation, so it gets a spec rather
# than a comment: if a future Rails release stopped cascading, an app that drew
# its aggregate route after the mount would silently lose the tier, and the
# README would be actively wrong.
RSpec.describe "aggregate GET /health route ordering", type: :request do
  AGGREGATE_APP = ->(_env) { [200, { "Content-Type" => "text/plain" }, ["AGGREGATE"]] }

  after do
    # Restore the dummy app's own routes for the rest of the suite.
    load Rails.root.join("config/routes.rb")
  end

  it "resolves the aggregate route when drawn BEFORE the mount (documented order)" do
    Rails.application.routes.draw do
      get "/health", to: AGGREGATE_APP
      mount StandardHealth::Engine => "/health", as: :standard_health
    end

    get "/health"

    expect(response.body).to eq("AGGREGATE")
  end

  it "ALSO resolves when drawn after the mount — the engine cascades past a bare /health" do
    Rails.application.routes.draw do
      mount StandardHealth::Engine => "/health", as: :standard_health
      get "/health", to: AGGREGATE_APP
    end

    get "/health"

    expect(response.body).to eq("AGGREGATE")
  end

  it "leaves the engine's own sub-paths reachable in either order" do
    Rails.application.routes.draw do
      get "/health", to: AGGREGATE_APP
      mount StandardHealth::Engine => "/health", as: :standard_health
    end

    get "/health/alive"

    expect(response).to have_http_status(:ok)
    expect(response.body).not_to eq("AGGREGATE")
  end

  # The actual failure the README warns about: mount the engine and draw NO
  # aggregate route. There is no boot error and no 500 — just a 404 nobody
  # notices, which is why it survives for months.
  it "404s the aggregate tier when the host never draws it — silently" do
    Rails.application.routes.draw do
      mount StandardHealth::Engine => "/health", as: :standard_health
    end

    get "/health"

    expect(response).to have_http_status(:not_found)
  end
end
