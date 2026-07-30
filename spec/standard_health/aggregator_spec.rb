# frozen_string_literal: true

require "spec_helper"

RSpec.describe StandardHealth::Aggregator do
  let(:ok_check) do
    Class.new(StandardHealth::Check) do
      def run
        { status: :ok, latency_ms: 1 }
      end
    end
  end

  let(:fail_check) do
    Class.new(StandardHealth::Check) do
      def run
        { status: :fail, error: "boom" }
      end
    end
  end

  let(:raising_check) do
    Class.new(StandardHealth::Check) do
      def run
        raise "kaboom"
      end
    end
  end

  it "rolls up to :ok when every check is ok" do
    StandardHealth.config.register_check(:a, ok_check)
    StandardHealth.config.register_check(:b, ok_check)

    result = described_class.call

    expect(result[:status]).to eq(:ok)
    expect(result[:checks].map { |c| c[:name] }).to contain_exactly(:a, :b)
    expect(result[:generated_at]).to match(/\A\d{4}-\d{2}-\d{2}T/)
  end

  it "is :degraded when a non-critical check fails" do
    StandardHealth.config.register_check(:a, ok_check, critical: true)
    StandardHealth.config.register_check(:b, fail_check, critical: false)

    result = described_class.call

    expect(result[:status]).to eq(:degraded)
  end

  it "is :unavailable when a critical check fails" do
    StandardHealth.config.register_check(:a, fail_check, critical: true)

    result = described_class.call

    expect(result[:status]).to eq(:unavailable)
  end

  it "treats raised exceptions as :fail without crashing" do
    StandardHealth.config.register_check(:a, raising_check, critical: false)

    result = described_class.call

    expect(result[:status]).to eq(:degraded)
    expect(result[:checks].first).to include(status: :fail, error: "kaboom")
  end

  it "is :ok with no registered checks" do
    expect(described_class.call[:status]).to eq(:ok)
  end

  # The opt-in checks added in 0.5.0 are host-registered, and the never-raise
  # rule has to hold for them the same as for the built-ins. These assert it
  # END-TO-END through the aggregator, not just at the check's own `run`.
  describe "never-raise holds for the opt-in 0.5.0 checks" do
    around do |example|
      StandardHealth.reset_config!
      example.run
      StandardHealth.reset_config!
    end

    it "still answers when EnvSpecAudit's underlying audit raises" do
      StandardHealth.config.env_spec = StandardHealth::EnvSpec.define do
        required :ANYTHING, if: -> { raise "predicate blew up" }
      end
      StandardHealth.config.register_check(
        :env_spec, StandardHealth::Checks::EnvSpecAudit
      )

      result = nil
      expect { result = described_class.call }.not_to raise_error

      expect(result[:status]).to eq(:degraded)
      expect(result[:checks].first).to include(name: :env_spec, status: :fail)
    end

    it "still answers when SolidCable's connection raises" do
      allow(::ActiveRecord::Base).to receive(:connection).and_raise(StandardError, "no db")
      StandardHealth.config.register_check(
        :solid_cable, StandardHealth::Checks::SolidCable
      )

      result = nil
      expect { result = described_class.call }.not_to raise_error

      expect(result[:status]).to eq(:degraded)
      expect(result[:checks].first).to include(name: :solid_cable, status: :fail)
    end

    it "reaches :unavailable, not an exception, when a raising opt-in check is critical" do
      allow(::ActiveRecord::Base).to receive(:connection).and_raise(StandardError, "no db")
      StandardHealth.config.register_check(
        :solid_cable, StandardHealth::Checks::SolidCable, critical: true
      )

      result = nil
      expect { result = described_class.call }.not_to raise_error

      expect(result[:status]).to eq(:unavailable)
    end
  end
end
