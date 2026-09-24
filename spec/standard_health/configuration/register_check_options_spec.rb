# frozen_string_literal: true

require "spec_helper"

# 0.6.0: `register_check` forwards extra keywords to the check constructor.
# Before this, `EnvSpecAudit`'s `fail_on:` (or any per-registration knob) was
# only reachable by subclassing, because the aggregator built every check with
# `name:`/`critical:` alone.
RSpec.describe "register_check option passthrough" do
  let(:config) { StandardHealth.config }

  let(:configurable_check) do
    Class.new(StandardHealth::Check) do
      def initialize(name:, critical: false, threshold: 1)
        super(name: name, critical: critical)
        @threshold = threshold
      end

      def run
        { status: :ok, threshold: @threshold }
      end
    end
  end

  let(:plain_check) do
    Class.new(StandardHealth::Check) do
      def run
        { status: :ok }
      end
    end
  end

  it "forwards extra keywords to the check's constructor" do
    config.register_check(:tuned, configurable_check, threshold: 42)

    row = StandardHealth::Aggregator.call[:checks].first

    expect(row).to include(name: :tuned, status: :ok, threshold: 42)
  end

  it "builds a check with no extra options exactly as before (no unexpected keywords)" do
    legacy = Class.new do
      def initialize(name:, critical:)
        @name = name
        @critical = critical
      end

      def run
        { status: :ok }
      end
    end
    config.register_check(:legacy, legacy)

    expect(StandardHealth::Aggregator.call[:checks].first).to include(status: :ok)
    expect(config.checks.first.options).to eq({})
  end

  it "rejects an unknown option at registration time, naming it" do
    expect { config.register_check(:bad, plain_check, fail_on: %i[forbidden]) }
      .to raise_error(ArgumentError, /does not accept `fail_on:`/)
  end

  it "does not second-guess a constructor that takes **kwargs" do
    splat = Class.new(StandardHealth::Check) do
      def initialize(name:, critical: false, **rest)
        super(name: name, critical: critical)
        @rest = rest
      end

      def run
        { status: :ok, rest: @rest }
      end
    end
    config.register_check(:splat, splat, anything: 1)

    expect(StandardHealth::Aggregator.call[:checks].first).to include(rest: { anything: 1 })
  end

  it "keeps timeout/critical as registration concerns, not constructor options" do
    reg = config.register_check(:tuned, configurable_check, critical: true, timeout: 2, threshold: 3)

    expect(reg).to have_attributes(critical: true, timeout: 2, options: { threshold: 3 })
  end

  describe "EnvSpecAudit fail_on: without subclassing" do
    around do |example|
      original = ENV.fetch("APP_ENVIRONMENT", nil)
      ENV["APP_ENVIRONMENT"] = "production"
      example.run
    ensure
      ENV["APP_ENVIRONMENT"] = original
    end

    it "narrows what counts as a failure" do
      config.env_spec = StandardHealth::EnvSpec.define { required :SH_TEST_DEFINITELY_UNSET }
      config.register_check(:env_spec, StandardHealth::Checks::EnvSpecAudit, fail_on: %i[forbidden])

      expect(StandardHealth::Aggregator.call[:checks].first).to include(status: :ok)
    end

    it "still fails on the default statuses when fail_on: is omitted" do
      config.env_spec = StandardHealth::EnvSpec.define { required :SH_TEST_DEFINITELY_UNSET }
      config.register_check(:env_spec, StandardHealth::Checks::EnvSpecAudit)

      expect(StandardHealth::Aggregator.call[:checks].first).to include(status: :fail)
    end
  end
end
