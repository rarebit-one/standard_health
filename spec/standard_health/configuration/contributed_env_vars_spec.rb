# frozen_string_literal: true

require "rails_helper"

# Env vars another gem contributes (`Contributions#contribute_env_vars`) join
# the app's env_spec wherever it is audited: `effective_env_spec`, the
# /diagnostics/env view and `Checks::EnvSpecAudit`.
RSpec.describe "contributed env vars", type: :request do
  let(:contributions) { StandardHealth::Contributions.new }

  around do |example|
    original = ENV.fetch("APP_ENVIRONMENT", nil)
    ENV["APP_ENVIRONMENT"] = "production"
    example.run
  ensure
    ENV["APP_ENVIRONMENT"] = original
    ENV.delete("SH_TEST_BYPASS_CODE")
  end

  before do
    allow(StandardHealth).to receive(:contributions).and_return(contributions)
    StandardHealth.reset_config!

    contributions.contribute_env_vars "standard_id" do
      recommended :SH_TEST_SIGNING_KEY, description: "gem's view"
      forbidden :SH_TEST_BYPASS_CODE, in: %w[production]
    end
  end

  def rows
    StandardHealth.config.effective_env_spec.audit({ "SH_TEST_BYPASS_CODE" => "1" }, mode: "production")
                  .to_h { |row| [row[:name], row.slice(:level, :status, :group, :description)] }
  end

  describe "Configuration#effective_env_spec" do
    it "is nil with neither an app spec nor contributions, as before" do
      expect(StandardHealth::Configuration.new(contributions: StandardHealth::Contributions.new).effective_env_spec)
        .to be_nil
    end

    it "is the app spec unchanged when nothing was contributed" do
      config = StandardHealth::Configuration.new(contributions: StandardHealth::Contributions.new)
      config.env_spec = StandardHealth::EnvSpec.define { required :PATH }

      expect(config.effective_env_spec).to be(config.env_spec)
    end

    it "is the contributions alone when the app set no env_spec" do
      expect(rows).to eq(
        SH_TEST_SIGNING_KEY: { level: :recommended, status: :should_set, group: "standard_id", description: "gem's view" },
        SH_TEST_BYPASS_CODE: { level: :forbidden, status: :forbidden, group: "standard_id" }
      )
    end

    it "merges contributions after the app's entries, the app's own declaration of a var winning" do
      StandardHealth.config.env_spec = StandardHealth::EnvSpec.define do
        mode_alias :live, %w[production]
        required :SH_TEST_SIGNING_KEY, in: :live, description: "app's view"
        required :SH_TEST_APP_ONLY
      end

      expect(rows.keys).to eq(%i[SH_TEST_SIGNING_KEY SH_TEST_APP_ONLY SH_TEST_BYPASS_CODE])
      expect(rows[:SH_TEST_SIGNING_KEY]).to eq(level: :required, status: :missing, description: "app's view")
      expect(StandardHealth.config.env_spec.entries.size).to eq(2) # the app's spec is untouched
    end

    it "picks up a contribution made after the app configured its spec" do
      StandardHealth.config.env_spec = StandardHealth::EnvSpec.define { required :PATH }
      contributions.contribute_env_vars("standard_audit") { recommended :SH_TEST_RETENTION_DAYS }

      expect(StandardHealth.config.effective_env_spec.entries.map(&:name)).to include(:SH_TEST_RETENTION_DAYS)
    end
  end

  describe "GET /health/diagnostics/env" do
    it "lists contributed vars grouped by contributor and counts their violations" do
      ENV["SH_TEST_BYPASS_CODE"] = "1"
      StandardHealth.config.env_spec = StandardHealth::EnvSpec.define { required :PATH }

      get "/health/diagnostics/env"
      body = JSON.parse(response.body)

      bypass = body["audit"].find { |row| row["name"] == "SH_TEST_BYPASS_CODE" }
      expect(bypass).to include("group" => "standard_id", "status" => "forbidden")
      expect(body["audit"].map { |row| row["name"] }).to include("PATH", "SH_TEST_SIGNING_KEY")
      expect(body["status"]).to eq("incomplete")
    end
  end

  describe "Checks::EnvSpecAudit" do
    it "fails on a contributed var's violation even with no app env_spec" do
      ENV["SH_TEST_BYPASS_CODE"] = "1"

      result = StandardHealth::Checks::EnvSpecAudit.new.run

      expect(result).to include(status: :fail, error: "forbidden: SH_TEST_BYPASS_CODE")
    end
  end
end
