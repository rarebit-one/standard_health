# frozen_string_literal: true

require "spec_helper"

RSpec.describe StandardHealth::Checks::EnvSpecAudit do
  around do |example|
    StandardHealth.reset_config!
    original = ENV.fetch("APP_ENVIRONMENT", nil)
    ENV["APP_ENVIRONMENT"] = "production"
    example.run
    ENV["APP_ENVIRONMENT"] = original
    StandardHealth.reset_config!
  end

  def configure_spec(&block)
    StandardHealth.config.env_spec = StandardHealth::EnvSpec.define(&block)
  end

  it "is non-critical by default — config drift must not pull an instance from rotation" do
    expect(described_class.new(name: :env_spec).critical?).to be(false)
  end

  it "is :ok when no env_spec is configured at all" do
    result = described_class.new(name: :env_spec).run

    expect(result[:status]).to eq(:ok)
    expect(result[:latency_ms]).to be_a(Integer)
  end

  it "is :ok when the spec has no violations" do
    configure_spec { required :PATH }

    expect(described_class.new(name: :env_spec).run).to include(status: :ok)
  end

  it "fails when a forbidden var is set, naming it" do
    ENV["SH_TEST_DEMO_MODE"] = "1"
    configure_spec { forbidden :SH_TEST_DEMO_MODE }

    result = described_class.new(name: :env_spec).run

    expect(result[:status]).to eq(:fail)
    expect(result[:error]).to include("forbidden: SH_TEST_DEMO_MODE")
  ensure
    ENV.delete("SH_TEST_DEMO_MODE")
  end

  it "fails on an expected_value mismatch" do
    ENV["SH_TEST_CSP"] = "true"
    configure_spec { required :SH_TEST_CSP, expected_value: "false" }

    result = described_class.new(name: :env_spec).run

    expect(result[:status]).to eq(:fail)
    expect(result[:error]).to include("mismatch: SH_TEST_CSP")
  ensure
    ENV.delete("SH_TEST_CSP")
  end

  it "fails on a missing required var" do
    configure_spec { required :SH_TEST_DEFINITELY_UNSET }

    result = described_class.new(name: :env_spec).run

    expect(result[:error]).to include("missing: SH_TEST_DEFINITELY_UNSET")
  end

  it "does NOT fail on a merely recommended-but-absent var" do
    configure_spec { recommended :SH_TEST_DEFINITELY_UNSET }

    expect(described_class.new(name: :env_spec).run).to include(status: :ok)
  end

  it "groups multiple violation kinds into one message" do
    ENV["SH_TEST_DEMO_MODE"] = "1"
    configure_spec do
      forbidden :SH_TEST_DEMO_MODE
      required :SH_TEST_DEFINITELY_UNSET
    end

    error = described_class.new(name: :env_spec).run[:error]

    expect(error).to include("forbidden: SH_TEST_DEMO_MODE")
    expect(error).to include("missing: SH_TEST_DEFINITELY_UNSET")
  ensure
    ENV.delete("SH_TEST_DEMO_MODE")
  end

  it "never surfaces the offending VALUE, only the name" do
    ENV["SH_TEST_TOKEN"] = "sup3rs3cret"
    configure_spec { forbidden :SH_TEST_TOKEN }

    result = described_class.new(name: :env_spec).run

    expect(result.to_s).not_to include("sup3rs3cret")
  ensure
    ENV.delete("SH_TEST_TOKEN")
  end

  it "reports a stable error_class so the redacted body carries a useful error_code" do
    configure_spec { required :SH_TEST_DEFINITELY_UNSET }

    result = described_class.new(name: :env_spec).run

    expect(result[:error_class]).to eq("StandardHealth::EnvSpecViolation")
    expect(StandardHealth::Redactor.error_code_for(result[:error_class]))
      .to eq("standard_health_env_spec_violation")
  end

  it "respects a narrowed fail_on via subclassing" do
    strict = Class.new(described_class) do
      def initialize(name: :env_spec, critical: false)
        super(name: name, critical: critical, fail_on: %i[forbidden])
      end
    end
    configure_spec { required :SH_TEST_DEFINITELY_UNSET }

    expect(strict.new(name: :env_spec).run).to include(status: :ok)
  end

  it "does not resolve consumed_by paths — no file IO on a polled tier" do
    configure_spec { required :SH_TEST_DEFINITELY_UNSET, consumed_by: "config/whatever.rb" }
    # `consumer:` is only computed when `audit` is given a `root:`. Its absence
    # is the observable proof the check omitted it.
    spec = StandardHealth.config.env_spec
    allow(spec).to receive(:audit).and_call_original

    described_class.new(name: :env_spec).run

    expect(spec).to have_received(:audit).with(anything, hash_excluding(:root))
  end

  describe "never-raise invariant" do
    it "degrades to :fail when the spec's audit raises (bad mode alias)" do
      configure_spec { required :ANYTHING, in: :never_declared }

      result = described_class.new(name: :env_spec).run

      expect(result[:status]).to eq(:fail)
      expect(result[:error_class]).to eq("StandardHealth::EnvSpec::UnknownModeAlias")
    end

    it "degrades to :fail when a host-supplied predicate raises" do
      configure_spec do
        required :ANYTHING, if: -> { raise "predicate blew up" }
      end

      result = described_class.new(name: :env_spec).run

      expect(result).to include(status: :fail, error: "predicate blew up")
    end
  end
end
