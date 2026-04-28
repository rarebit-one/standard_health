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
end
