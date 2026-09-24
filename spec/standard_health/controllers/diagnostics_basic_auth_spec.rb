# frozen_string_literal: true

require "rails_helper"

RSpec.describe "diagnostics_basic_auth", type: :request do
  def basic(user, pass)
    { "HTTP_AUTHORIZATION" => ActionController::HttpAuthentication::Basic.encode_credentials(user, pass) }
  end

  around do |example|
    saved = ENV.to_h.slice("ADMIN_BASIC_AUTH_USERNAME", "ADMIN_BASIC_AUTH_PASSWORD")
    ENV.delete("ADMIN_BASIC_AUTH_USERNAME")
    ENV.delete("ADMIN_BASIC_AUTH_PASSWORD")
    example.run
  ensure
    ENV.delete("ADMIN_BASIC_AUTH_USERNAME")
    ENV.delete("ADMIN_BASIC_AUTH_PASSWORD")
    saved.each { |k, v| ENV[k] = v }
  end

  context "when unset (the default)" do
    it "leaves /diagnostics/env exactly as before — no gate" do
      get "/health/diagnostics/env"

      expect(response).to have_http_status(:ok)
    end
  end

  context "with `true` (ADMIN_BASIC_AUTH_* defaults)" do
    before { StandardHealth.configure { |c| c.diagnostics_basic_auth = true } }

    context "when the credentials are set" do
      before do
        ENV["ADMIN_BASIC_AUTH_USERNAME"] = "ops"
        ENV["ADMIN_BASIC_AUTH_PASSWORD"] = "s3cret"
      end

      it "challenges an anonymous request with the Health Diagnostics realm" do
        get "/health/diagnostics/env"

        expect(response).to have_http_status(:unauthorized)
        expect(response.headers["WWW-Authenticate"]).to eq('Basic realm="Health Diagnostics"')
      end

      it "serves the audit to correct credentials" do
        get "/health/diagnostics/env", headers: basic("ops", "s3cret")

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body).to include("status", "audit")
      end

      it "rejects a wrong password" do
        get "/health/diagnostics/env", headers: basic("ops", "nope")

        expect(response).to have_http_status(:unauthorized)
      end

      it "rejects a wrong username with the right password" do
        get "/health/diagnostics/env", headers: basic("someone", "s3cret")

        expect(response).to have_http_status(:unauthorized)
      end

      it "rejects a prefix of the password (length-safe comparison)" do
        get "/health/diagnostics/env", headers: basic("ops", "s3c")

        expect(response).to have_http_status(:unauthorized)
      end

      it "never gates /alive or /ready" do
        get "/health/alive"
        expect(response).to have_http_status(:ok)

        get "/health/ready"
        expect(response).to have_http_status(:ok)
      end
    end

    context "when the credentials are unset — FAIL CLOSED" do
      it "refuses with 403 (not 401, not 5xx) and does not render the audit" do
        get "/health/diagnostics/env"

        expect(response).to have_http_status(:forbidden)
        expect(response.parsed_body).to include("error" => "diagnostics refused")
        expect(response.parsed_body).not_to have_key("audit")
      end

      it "refuses when only one half is set" do
        ENV["ADMIN_BASIC_AUTH_USERNAME"] = "ops"

        get "/health/diagnostics/env", headers: basic("ops", "")

        expect(response).to have_http_status(:forbidden)
      end
    end
  end

  context "with custom callables" do
    it "resolves credentials per request (rotation needs no restart)" do
      creds = { user: "a", pass: "b" }
      StandardHealth.configure do |c|
        c.diagnostics_basic_auth = { username: -> { creds[:user] }, password: -> { creds[:pass] }, realm: "Doctor" }
      end

      get "/health/diagnostics/env", headers: basic("a", "b")
      expect(response).to have_http_status(:ok)

      creds[:pass] = "rotated"
      get "/health/diagnostics/env", headers: basic("a", "b")
      expect(response).to have_http_status(:unauthorized)
      expect(response.headers["WWW-Authenticate"]).to eq('Basic realm="Doctor"')

      get "/health/diagnostics/env", headers: basic("a", "rotated")
      expect(response).to have_http_status(:ok)
    end

    it "accepts plain strings" do
      StandardHealth.configure { |c| c.diagnostics_basic_auth = { username: "u", password: "p" } }

      get "/health/diagnostics/env", headers: basic("u", "p")

      expect(response).to have_http_status(:ok)
    end

    it "fails closed (403) when the credential lookup raises" do
      StandardHealth.configure do |c|
        c.diagnostics_basic_auth = { username: -> { raise KeyError, "no creds" }, password: "p" }
      end

      get "/health/diagnostics/env", headers: basic("u", "p")

      expect(response).to have_http_status(:forbidden)
      expect(response.body).not_to include("no creds")
    end
  end

  context "with allow_unconfigured" do
    it "passes through when credentials are unset and the predicate is true" do
      StandardHealth.configure { |c| c.diagnostics_basic_auth = { allow_unconfigured: -> { true } } }

      get "/health/diagnostics/env"

      expect(response).to have_http_status(:ok)
    end

    it "still fails closed when the predicate is false" do
      StandardHealth.configure { |c| c.diagnostics_basic_auth = { allow_unconfigured: -> { false } } }

      get "/health/diagnostics/env"

      expect(response).to have_http_status(:forbidden)
    end

    it "still demands credentials once they ARE configured" do
      ENV["ADMIN_BASIC_AUTH_USERNAME"] = "ops"
      ENV["ADMIN_BASIC_AUTH_PASSWORD"] = "s3cret"
      StandardHealth.configure { |c| c.diagnostics_basic_auth = { allow_unconfigured: true } }

      get "/health/diagnostics/env"

      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "config validation" do
    it "rejects an unknown key at assignment" do
      expect { StandardHealth.config.diagnostics_basic_auth = { user: "x" } }
        .to raise_error(ArgumentError)
    end

    it "rejects a non-hash value" do
      expect { StandardHealth.config.diagnostics_basic_auth = "yes" }
        .to raise_error(ArgumentError, /diagnostics_basic_auth must be/)
    end

    it "reads back nil when turned off" do
      StandardHealth.config.diagnostics_basic_auth = true
      StandardHealth.config.diagnostics_basic_auth = false

      expect(StandardHealth.config.diagnostics_basic_auth).to be_nil
    end
  end
end
