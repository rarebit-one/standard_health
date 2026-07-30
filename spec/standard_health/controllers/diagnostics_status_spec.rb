# frozen_string_literal: true

require "rails_helper"

# The additive `status` field on /diagnostics/env.
#
# REPORTING ONLY — the endpoint still returns 200 either way, so callers that
# assert on the status code keep working. `incomplete` covers all three
# violation statuses (`missing`, `forbidden`, `mismatch`); the newer two joined
# this roll-up rather than getting a verdict of their own precisely so callers
# already gating on this field pick them up for free.
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

  context "when a forbidden var is set" do
    before do
      ENV["SH_TEST_FORBIDDEN_TOGGLE"] = "1"
      StandardHealth.config.env_spec = StandardHealth::EnvSpec.define do
        forbidden :SH_TEST_FORBIDDEN_TOGGLE
      end
    end

    after { ENV.delete("SH_TEST_FORBIDDEN_TOGGLE") }

    it "rolls up to incomplete" do
      expect(audit_body["status"]).to eq("incomplete")
    end

    it "reports the forbidden status on the row, still with 200" do
      body = audit_body

      expect(response).to have_http_status(:ok)
      expect(body["audit"].first).to include("status" => "forbidden", "level" => "forbidden")
    end

    it "does not echo the offending value" do
      expect(audit_body.to_s).not_to include('"1"')
    end
  end

  context "when a var is present but violates expected_value" do
    before do
      ENV["SH_TEST_CSP_TOGGLE"] = "true"
      StandardHealth.config.env_spec = StandardHealth::EnvSpec.define do
        required :SH_TEST_CSP_TOGGLE, expected_value: "false"
      end
    end

    after { ENV.delete("SH_TEST_CSP_TOGGLE") }

    it "rolls up to incomplete even though the var is present" do
      expect(audit_body["status"]).to eq("incomplete")
    end

    it "surfaces the declared expectation but not the actual value" do
      row = audit_body["audit"].first

      expect(row).to include("status" => "mismatch", "expected_value" => "false")
      expect(row.values).not_to include("true")
    end
  end

  context "when a recommended var mismatches its expected_value" do
    before do
      ENV["SH_TEST_LOG_LEVEL"] = "debug"
      StandardHealth.config.env_spec = StandardHealth::EnvSpec.define do
        recommended :SH_TEST_LOG_LEVEL, expected_value: "info"
      end
    end

    after { ENV.delete("SH_TEST_LOG_LEVEL") }

    # A declared assertion that does not hold is a failure, not advice —
    # unlike a merely absent recommended var.
    it "rolls up to incomplete despite the advisory level" do
      expect(audit_body["status"]).to eq("incomplete")
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
