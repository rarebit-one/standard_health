# frozen_string_literal: true

require "spec_helper"

RSpec.describe "metrics configuration" do
  let(:config) { StandardHealth.config }

  it "defaults to metrics on, every event" do
    expect(config.metrics_enabled).to be(true)
    expect(config.metric_events).to be_nil
  end

  it "normalizes metric_events to frozen strings" do
    config.metric_events = [:"standard_health.check.timed_out"]

    expect(config.metric_events).to eq(["standard_health.check.timed_out"])
    expect(config.metric_events).to be_frozen
  end

  it "rejects an unknown event name at boot rather than silently recording nothing" do
    expect { config.metric_events = %w[standard_health.check.timeout] }
      .to raise_error(ArgumentError, /unknown metric event/)
  end

  it "accepts nil to restore the default" do
    config.metric_events = %w[standard_health.check.timed_out]
    config.metric_events = nil

    expect(config.metric_events).to be_nil
  end
end
