# frozen_string_literal: true

require "rails_helper"

# End-to-end: what an ANONYMOUS caller actually receives from /ready when a
# check is failing. /ready is unauthenticated by design (probes carry no
# credentials), so whatever lands in this body is public.
RSpec.describe "/ready response redaction", type: :request do
  let(:leaky_check) do
    Class.new(StandardHealth::Check) do
      def run
        raise ArgumentError,
              'could not connect: host="db-prod.internal" port=5432 user="app_admin"'
      end
    end
  end

  before { StandardHealth.config.register_check(:database, leaky_check, critical: true) }

  it "does not leak the host, port or username to an anonymous caller" do
    get "/health/ready"

    expect(response).to have_http_status(:service_unavailable)
    expect(response.body).not_to include("db-prod.internal")
    expect(response.body).not_to include("app_admin")
    expect(response.body).not_to include("5432")
  end

  it "still says WHAT broke, via class and code" do
    get "/health/ready"

    row = JSON.parse(response.body)["checks"].first
    expect(row["error_class"]).to eq("ArgumentError")
    expect(row["error_code"]).to eq("argument_error")
    expect(row).not_to have_key("error")
  end

  # The envelope other tooling reads must not move in a patch release.
  it "leaves status, name, critical and the top-level shape unchanged" do
    get "/health/ready"

    body = JSON.parse(response.body)
    expect(body["status"]).to eq("unavailable")
    expect(body).to have_key("generated_at")
    expect(body["checks"].first).to include("name" => "database", "critical" => true, "status" => "fail")
  end

  context "when the host opts back in to verbose bodies" do
    before { StandardHealth.config.expose_check_errors = true }

    it "restores the pre-0.4.1 message" do
      get "/health/ready"

      expect(response.body).to include("db-prod.internal")
    end
  end

  context "break-glass detail token" do
    before { StandardHealth.config.detail_token = "s3cret-token" }

    it "exposes detail to a caller presenting the token" do
      get "/health/ready", headers: { "X-Health-Token" => "s3cret-token" }

      expect(response.body).to include("db-prod.internal")
    end

    it "keeps redacting for a wrong token" do
      get "/health/ready", headers: { "X-Health-Token" => "nope" }

      expect(response.body).not_to include("db-prod.internal")
    end

    it "keeps redacting when no token is presented" do
      get "/health/ready"

      expect(response.body).not_to include("db-prod.internal")
    end
  end

  it "leaves /alive untouched" do
    get "/health/alive"

    expect(response).to have_http_status(:ok)
    expect(response.body).to be_empty
  end
end
