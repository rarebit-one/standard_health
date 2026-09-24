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

  it "never raises when instrumentation blows up" do
    hide_const("StandardCircuit")
    allow(StandardHealth::EventEmitter).to receive(:emit).and_raise("bus down")

    expect { described_class.call }.not_to raise_error
  end
end
