# frozen_string_literal: true

require "rails_helper"

RSpec.describe StandardHealth::Checks::SolidCache do
  it "defaults to name :solid_cache and NON-critical — a degraded cache must not de-rotate" do
    check = described_class.new

    expect(check.name).to eq(:solid_cache)
    expect(check.critical?).to be(false)
  end

  it "returns :ok with latency_ms when the cache read succeeds" do
    allow(Rails.cache).to receive(:read).and_return(nil)

    result = described_class.new.run

    expect(result[:status]).to eq(:ok)
    expect(result[:latency_ms]).to be_a(Integer)
    expect(Rails.cache).to have_received(:read).with(described_class::PROBE_KEY)
  end

  it "is read-only — a flapping cache must not have host cache state written to it" do
    allow(Rails.cache).to receive(:read)
    allow(Rails.cache).to receive(:write)
    allow(Rails.cache).to receive(:fetch)

    described_class.new.run

    expect(Rails.cache).not_to have_received(:write)
    expect(Rails.cache).not_to have_received(:fetch)
  end

  it "returns :fail with the error class rather than raising when the store is unreachable" do
    allow(Rails.cache).to receive(:read).and_raise(IOError, "cache store unreachable")

    result = described_class.new.run

    expect(result).to include(status: :fail, error: "cache store unreachable", error_class: "IOError")
  end
end
