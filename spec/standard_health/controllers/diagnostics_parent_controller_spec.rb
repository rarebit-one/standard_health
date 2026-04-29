# frozen_string_literal: true

require "rails_helper"

# Verifies the v0.2.0 `diagnostics_parent_controller` config: when set, only
# `DiagnosticsController` inherits from it, so a `before_action :auth, only:
# :env` declared on the diagnostics parent doesn't leak onto
# `HealthController` (which would otherwise trip Rails 7.1's
# `raise_on_missing_callback_actions` because `:env` isn't an action there).
#
# To rebuild the inheritance chain when config changes, we remove the engine
# controller constants and force Zeitwerk to reload them on next reference.
RSpec.describe "diagnostics_parent_controller", type: :request do
  def reset_engine_controllers!
    StandardHealth.reset_parent_controller!
    StandardHealth.reset_diagnostics_parent_controller!
    # Remove engine controller constants and reload Zeitwerk so the next
    # reference re-evaluates each class body against the current config
    # (`parent_controller` / `diagnostics_parent_controller`). Without
    # this, an earlier example's inheritance chain would survive into
    # the next one and break the superclass match check.
    %i[
      DiagnosticsController
      HealthController
      DiagnosticsApplicationController
      ApplicationController
    ].each do |const|
      next unless StandardHealth.const_defined?(const, false)
      StandardHealth.send(:remove_const, const)
    end
    Rails.application.reloader.reload!
  end

  before { reset_engine_controllers! }
  after  { reset_engine_controllers! }

  describe "controller-class resolution" do
    it "falls back to parent_controller when diagnostics_parent_controller is unset (v0.1.0 behavior)" do
      StandardHealth.configure do |c|
        c.parent_controller = "ActionController::API"
      end

      expect(StandardHealth.parent_controller).to eq(ActionController::API)
      expect(StandardHealth.diagnostics_parent_controller).to eq(ActionController::API)
    end

    it "uses the diagnostics-specific parent only when set" do
      StandardHealth.configure do |c|
        c.parent_controller = "ActionController::API"
        c.diagnostics_parent_controller = "DiagnosticsAuthController"
      end

      expect(StandardHealth.parent_controller).to eq(ActionController::API)
      expect(StandardHealth.diagnostics_parent_controller).to eq(DiagnosticsAuthController)
    end
  end

  describe "end-to-end with diagnostics auth" do
    before do
      StandardHealth.configure do |c|
        c.parent_controller = "ActionController::API"
        c.diagnostics_parent_controller = "DiagnosticsAuthController"
      end
    end

    it "applies the diagnostics-only auth to /diagnostics/env" do
      get "/health/diagnostics/env"
      expect(response).to have_http_status(:unauthorized)
    end

    it "does NOT apply the diagnostics auth to /alive (HealthController stays open)" do
      # The whole point of v0.2.0: a `before_action :auth, only: :env`
      # declared on the diagnostics parent does NOT cause Rails 7.1 to
      # raise on HealthController, because HealthController never
      # inherits the callback in the first place. /alive returns 200,
      # not 401 and not a missing-action error.
      expect { get "/health/alive" }.not_to raise_error
      expect(response).to have_http_status(:ok)
    end

    it "does NOT apply the diagnostics auth to /ready" do
      get "/health/ready"
      expect([200, 503]).to include(response.status)
    end
  end

  describe "v0.1.0 fallback end-to-end" do
    before do
      StandardHealth.configure do |c|
        c.parent_controller = "ActionController::API"
      end
    end

    it "serves /alive with no auth" do
      get "/health/alive"
      expect(response).to have_http_status(:ok)
    end

    it "serves /diagnostics/env with no auth" do
      get "/health/diagnostics/env"
      expect(response).to have_http_status(:ok)
    end
  end
end
