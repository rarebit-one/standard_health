# frozen_string_literal: true

require "rails_helper"

# The additive `status` field on /diagnostics/env.
#
# In 0.4.1 this is REPORTING ONLY — the endpoint still returns 200 either way.
# That is the migration window: monitors move onto the field now, and 0.5.0
# can make `:incomplete` a 503 without silently reddening every caller that
# asserts on the status code today.
RSpec.describe "/diagnostics/env status field", type: :request do
  def audit_body
    get "/health/diagnostics/env"
    JSON.parse(response.body)
  end

  context "when every required var is present" do
    before do
      StandardHealth.config.env_spec = StandardHealth::EnvSpec.define do
        required :PATH
      end
    end

    it "reports ok, with 200" do
      expect(response_status_and_field).to eq([200, "ok"])
    end
  end

  context "when a required var is missing" do
    before do
      StandardHealth.config.env_spec = StandardHealth::EnvSpec.define do
        required :DEFINITELY_NOT_SET_ANYWHERE_12345
      end
    end

    it "reports incomplete" do
      expect(audit_body["status"]).to eq("incomplete")
    end

    # The whole point of shipping the field a release early.
    it "STILL returns 200, so existing callers do not break" do
      get "/health/diagnostics/env"

      expect(response).to have_http_status(:ok)
    end
  end

  context "when only a recommended var is missing" do
    before do
      StandardHealth.config.env_spec = StandardHealth::EnvSpec.define do
        recommended :DEFINITELY_NOT_SET_ANYWHERE_12345
      end
    end

    it "is still ok — recommended is advisory, not required" do
      expect(audit_body["status"]).to eq("ok")
    end
  end

  context "with no env_spec configured" do
    it "is ok with an empty audit rather than 404" do
      body = audit_body
      expect(body["status"]).to eq("ok")
      expect(body["audit"]).to eq([])
    end
  end

  it "keeps mode, audit and generated_at" do
    body = audit_body
    expect(body.keys).to include("mode", "audit", "generated_at", "status")
  end

  private

  def response_status_and_field
    get "/health/diagnostics/env"
    [response.status, JSON.parse(response.body)["status"]]
  end
end
