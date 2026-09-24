# frozen_string_literal: true

require "spec_helper"

RSpec.describe StandardHealth::Notifiers::Metrics do
  let(:calls) { [] }

  # Minimal Sentry::Metrics stand-in — Sentry is a soft dependency and the gem
  # must never require it.
  def stub_sentry_metrics(distribution: true)
    sink = calls
    metrics = Module.new
    metrics.define_singleton_method(:count) { |name, **kw| sink << [:count, name, kw] }
    if distribution
      metrics.define_singleton_method(:distribution) { |name, **kw| sink << [:distribution, name, kw] }
    end
    stub_const("Sentry", Module.new)
    stub_const("Sentry::Metrics", metrics)
  end

  let(:check_completed) do
    ["standard_health.check.completed", { name: :database, status: :ok, critical: true, latency_ms: 3 }]
  end
  let(:ready_evaluated) { ["standard_health.ready.evaluated", { status: :degraded, duration_ms: 12 }] }
  let(:timed_out) { ["standard_health.check.timed_out", { name: :solid_queue, timeout_s: 1 }] }

  describe "with Sentry::Metrics available" do
    before { stub_sentry_metrics }

    it "counts each check and records its latency distribution" do
      described_class.new.call(*check_completed)

      expect(calls).to eq([
        [:count, "health.check", { value: 1, attributes: { check: "database", status: "ok", critical: "true" } }],
        [:distribution, "health.check.duration", { value: 3, unit: "millisecond", attributes: { check: "database" } }]
      ])
    end

    it "skips the latency distribution when a check carried no latency (e.g. a skip)" do
      described_class.new.call("standard_health.check.completed", { name: :x, status: :skipped, critical: false })

      expect(calls.map(&:first)).to eq([:count])
    end

    it "counts each readiness evaluation by status and records its duration" do
      described_class.new.call(*ready_evaluated)

      expect(calls).to eq([
        [:count, "health.ready", { value: 1, attributes: { status: "degraded" } }],
        [:distribution, "health.ready.duration", { value: 12, unit: "millisecond" }]
      ])
    end

    it "counts timeouts" do
      described_class.new.call(*timed_out)

      expect(calls).to eq([[:count, "health.check.timeout", { value: 1, attributes: { check: "solid_queue" } }]])
    end

    it "honours the metric prefix" do
      described_class.new(metric_prefix: "app.health").call(*timed_out)

      expect(calls.first[1]).to eq("app.health.check.timeout")
    end

    it "ignores events it does not know" do
      described_class.new.call("standard_health.something_else", {})
      described_class.new.call("standard_circuit.run.completed", {})

      expect(calls).to be_empty
    end

    describe "events: allow-list (config.metric_events)" do
      it "records everything when nil (the default)" do
        notifier = described_class.new
        [check_completed, ready_evaluated, timed_out].each { |e| notifier.call(*e) }

        expect(calls.map { |c| c[1] }).to include("health.check", "health.ready", "health.check.timeout")
      end

      it "drops the per-poll events and keeps timeouts — sidekick's quota fix, without a prepend" do
        notifier = described_class.new(events: %w[standard_health.check.timed_out])
        [check_completed, ready_evaluated, timed_out].each { |e| notifier.call(*e) }

        expect(calls).to eq([[:count, "health.check.timeout", { value: 1, attributes: { check: "solid_queue" } }]])
      end

      it "exposes the per-poll set as a constant" do
        expect(described_class::PER_POLL_EVENTS)
          .to contain_exactly("standard_health.check.completed", "standard_health.ready.evaluated")
        expect(described_class::EVENTS - described_class::PER_POLL_EVENTS)
          .to eq(["standard_health.check.timed_out"])
      end
    end

    it "never raises when the metrics backend does" do
      allow(Sentry::Metrics).to receive(:count).and_raise(RuntimeError, "quota")

      expect { described_class.new.call(*check_completed) }.not_to raise_error
    end
  end

  it "counts but skips distributions on a Sentry::Metrics without #distribution" do
    stub_sentry_metrics(distribution: false)

    described_class.new.call(*check_completed)

    expect(calls.map(&:first)).to eq([:count])
  end

  it "is a no-op when Sentry::Metrics is absent" do
    hide_const("Sentry")

    expect(described_class.new.call(*check_completed)).to be_nil
  end
end
