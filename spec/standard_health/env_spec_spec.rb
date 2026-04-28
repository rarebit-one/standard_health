# frozen_string_literal: true

require "spec_helper"

RSpec.describe StandardHealth::EnvSpec do
  it "reports :ok when a required var is set" do
    spec = described_class.define do
      required :SECRET_KEY_BASE
    end

    audit = spec.audit({ "SECRET_KEY_BASE" => "abc" }, mode: "production")

    expect(audit).to contain_exactly(
      hash_including(name: :SECRET_KEY_BASE, level: :required, status: :ok, mode: "production")
    )
  end

  it "reports :missing when a required var is unset" do
    spec = described_class.define { required :SECRET_KEY_BASE }

    audit = spec.audit({}, mode: "production")

    expect(audit.first).to include(name: :SECRET_KEY_BASE, status: :missing)
  end

  it "skips entries whose mode does not apply" do
    spec = described_class.define do
      required :PROD_ONLY_KEY, in: %w[production]
    end

    expect(spec.audit({}, mode: "development")).to be_empty
    expect(spec.audit({}, mode: "production").first).to include(status: :missing)
  end

  it "reports recommended-but-missing as :should_set, not :missing" do
    spec = described_class.define { recommended :SENTRY_DSN }

    audit = spec.audit({}, mode: "production")

    expect(audit.first).to include(name: :SENTRY_DSN, level: :recommended, status: :should_set)
  end

  it "treats blank strings as missing" do
    spec = described_class.define { required :TOKEN }

    audit = spec.audit({ "TOKEN" => "" }, mode: "production")

    expect(audit.first).to include(status: :missing)
  end

  it "passes description through to audit rows" do
    spec = described_class.define do
      recommended :SENTRY_DSN, description: "Error tracking"
    end

    audit = spec.audit({}, mode: "production")

    expect(audit.first).to include(description: "Error tracking")
  end
end
