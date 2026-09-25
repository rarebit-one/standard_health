# frozen_string_literal: true

require "spec_helper"

RSpec.describe StandardHealth::AggregateReport do
  describe ".roll_up" do
    it "takes the worst of the check and circuit statuses" do
      expect(described_class.roll_up(:ok, nil)).to eq(:ok)
      expect(described_class.roll_up(:ok, :ok)).to eq(:ok)
      expect(described_class.roll_up(:degraded, :ok)).to eq(:degraded)
      expect(described_class.roll_up(:ok, :degraded)).to eq(:degraded)
      expect(described_class.roll_up(:degraded, :unavailable)).to eq(:unavailable)
      expect(described_class.roll_up(:unavailable, :ok)).to eq(:unavailable)
    end
  end

  it "maps an unknown circuit status to :degraded rather than :ok" do
    circuit = Module.new
    circuit.define_singleton_method(:health_report) { { status: :mystery, circuits: [] } }
    stub_const("StandardCircuit", circuit)

    expect(described_class.call[:status]).to eq(:degraded)
  end

  describe "a check that reports :skipped itself (0.7.1: neutral)" do
    let(:skipped_check) do
      Class.new(StandardHealth::Check) do
        def run
          { status: :skipped }
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

    before { hide_const("StandardCircuit") }

    it "leaves the aggregate :ok and the row visible as :skipped" do
      StandardHealth.config.register_aggregate_check(:attestation_roots, skipped_check)

      report = described_class.call

      expect(report[:status]).to eq(:ok)
      expect(report[:checks]).to contain_exactly(include(name: :attestation_roots, status: :skipped))
    end

    it "is left out of aggregate.evaluated's failed[] while a real failure still degrades" do
      events = []
      allow(StandardHealth::EventEmitter).to receive(:emit) { |name, payload| events << [name, payload] }
      StandardHealth.config.register_aggregate_check(:attestation_roots, skipped_check)
      StandardHealth.config.register_aggregate_check(:cache, fail_check)

      expect(described_class.call[:status]).to eq(:degraded)

      payload = events.find { |n, _| n == described_class::EVENT }.last
      expect(payload[:failed]).to eq([:cache])
    end
  end

  it "never raises when instrumentation blows up" do
    hide_const("StandardCircuit")
    allow(StandardHealth::EventEmitter).to receive(:emit).and_raise("bus down")

    expect { described_class.call }.not_to raise_error
  end

  describe "a check that raises" do
    let(:raising_check) do
      Class.new(StandardHealth::Check) do
        def run
          raise ArgumentError, "kaboom"
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

    before do
      hide_const("StandardCircuit")
      allow(Rails.error).to receive(:report)
    end

    it "is reported to Rails.error as handled, at :warning for a non-critical check" do
      StandardHealth.config.register_aggregate_check(:flaky, raising_check)

      described_class.call

      expect(Rails.error).to have_received(:report).with(
        an_instance_of(ArgumentError),
        handled: true,
        severity: :warning,
        context: { health_check: "flaky", tier: "aggregate" }
      )
    end

    it "is reported at :error when the check is critical" do
      StandardHealth.config.register_aggregate_check(:vital, raising_check, critical: true)

      expect(described_class.call[:status]).to eq(:unavailable)
      expect(Rails.error).to have_received(:report).with(
        an_instance_of(ArgumentError), hash_including(handled: true, severity: :error)
      )
    end

    it "is reported when it is a readiness check re-run by the aggregate tier" do
      StandardHealth.config.register_check(:database, raising_check, critical: true)

      described_class.call

      expect(Rails.error).to have_received(:report).with(
        an_instance_of(ArgumentError), hash_including(context: { health_check: "database", tier: "aggregate" })
      )
    end

    it "is not reported on the readiness tier, which reaches Sentry through ready.evaluated" do
      StandardHealth.config.register_check(:database, raising_check, critical: true)

      StandardHealth::Aggregator.call

      expect(Rails.error).not_to have_received(:report)
    end

    it "is not reported when the check times out (a latency signal, not a code error)" do
      slow_check = Class.new(StandardHealth::Check) do
        def run
          sleep 1
          { status: :ok }
        end
      end
      StandardHealth.config.register_aggregate_check(:slow, slow_check, timeout: 0.05)

      row = described_class.call[:checks].first

      expect(row).to include(name: :slow, status: :fail, error_class: "StandardHealth::CheckTimeout")
      expect(Rails.error).not_to have_received(:report)
    end

    it "is not reported when the check returns a :fail row instead of raising" do
      StandardHealth.config.register_aggregate_check(:soft, fail_check)

      described_class.call

      expect(Rails.error).not_to have_received(:report)
    end

    it "still answers when the error reporter itself raises" do
      allow(Rails.error).to receive(:report).and_raise("reporter down")
      StandardHealth.config.register_aggregate_check(:flaky, raising_check)

      result = nil
      expect { result = described_class.call }.not_to raise_error
      expect(result[:checks].first).to include(name: :flaky, status: :fail, error_class: "ArgumentError")
    end
  end
end
