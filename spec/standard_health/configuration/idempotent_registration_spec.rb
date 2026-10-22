# frozen_string_literal: true

require "spec_helper"

RSpec.describe "re-registering a check" do
  let(:config) { StandardHealth.config }

  let(:check_class) do
    Class.new do
      def initialize(name:, critical: false)
        @name = name
        @critical = critical
      end

      def run
        { status: :ok }
      end
    end
  end

  let(:other_class) { Class.new(check_class) }

  it "replaces a readiness check of the same name in place" do
    config.register_check(:first, check_class)
    config.register_check(:database, check_class)
    config.register_check(:last, check_class)
    config.register_check("database", other_class, critical: true)

    expect(config.checks.map(&:name)).to eq(%i[first database last])
    expect(config.checks[1]).to have_attributes(klass: other_class, critical?: true)
  end

  it "replaces an aggregate check of the same name in place" do
    config.register_aggregate_check(:solid_cable, check_class)
    config.register_aggregate_check(:solid_cable, other_class)

    expect(config.aggregate_checks.map(&:klass)).to eq([other_class])
  end
end

RSpec.describe "assigning env_spec" do
  it "rejects a spec that uses an undeclared mode alias" do
    spec = StandardHealth::EnvSpec.define { required :APP_HOST, in: :deployed }

    expect { StandardHealth.config.env_spec = spec }
      .to raise_error(StandardHealth::EnvSpec::UnknownModeAlias, /:deployed/)
  end

  it "accepts a valid spec, and nil" do
    spec = StandardHealth::EnvSpec.define do
      mode_alias :deployed, %w[production]
      required :APP_HOST, in: :deployed
    end

    StandardHealth.config.env_spec = spec
    expect(StandardHealth.config.env_spec).to be(spec)

    StandardHealth.config.env_spec = nil
    expect(StandardHealth.config.env_spec).to be_nil
  end
end
