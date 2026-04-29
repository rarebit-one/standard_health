# frozen_string_literal: true

# Dummy host-app controller used by the diagnostics-parent-controller specs.
# Stands in for what a real host app would write: HTTP Basic (or any other)
# auth scoped to the `:env` action only. The point of pinning `only: :env`
# is to prove that v0.2.0's `diagnostics_parent_controller` wiring keeps
# this callback isolated to `DiagnosticsController` — i.e. HealthController
# does *not* inherit it, so Rails 7.1's missing-callback-action check
# doesn't trip.
class DiagnosticsAuthController < ActionController::API
  before_action :authenticate, only: :env

  private

  def authenticate
    head :unauthorized
  end
end
