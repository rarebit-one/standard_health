# frozen_string_literal: true

require "spec_helper"

RSpec.describe StandardHealth::Aggregator, "instrumentation, timeouts and budget" do
  let(:ok_check) do
    Class.new(StandardHealth::Check) do
      def run
        { status: :ok, latency_ms: 1 }
      end
    end
  end

  let(:slow_check) do
    Class.new(StandardHealth::Check) do
      def run
        sleep 0.3
        { status: :ok, latency_ms: 300 }
      end
    end
  end

  let(:raising_check) do
    Class.new(StandardHealth::Check) do
      def run
        raise ArgumentError, "connection to host=db.internal user=admin refused"
      end
    end
  end

  # Capture emitted events without depending on which bus is live.
  def captured_events
    events = []
    allow(StandardHealth::EventEmitter).to receive(:emit) do |name, payload|
      events << [name, payload]
    end
    events
  end

  describe "events" do
    it "emits a check.completed per check and one ready.evaluated per call" do
      events = captured_events
      StandardHealth.config.register_check(:a, ok_check)
      StandardHealth.config.register_check(:b, ok_check)

      described_class.call

      names = events.map(&:first)
      expect(names.count("standard_health.check.completed")).to eq(2)
      expect(names.count("standard_health.ready.evaluated")).to eq(1)
    end

    it "carries the latency that was previously computed and discarded" do
      events = captured_events
      StandardHealth.config.register_check(:a, ok_check)

      described_class.call

      payload = events.find { |n, _| n == "standard_health.check.completed" }.last
      expect(payload).to include(name: :a, status: :ok, latency_ms: 1, critical: false)
    end

    it "reports overall status, duration and the failing check names" do
      events = captured_events
      StandardHealth.config.register_check(:good, ok_check)
      StandardHealth.config.register_check(:bad, raising_check, critical: true)

      described_class.call

      payload = events.find { |n, _| n == "standard_health.ready.evaluated" }.last
      expect(payload[:status]).to eq(:unavailable)
      expect(payload[:failed]).to eq([:bad])
      expect(payload[:duration_ms]).to be_a(Integer)
    end

    it "carries error_class on a failure so a redacted body can still be grouped" do
      events = captured_events
      StandardHealth.config.register_check(:bad, raising_check)

      described_class.call

      payload = events.find { |n, p| n == "standard_health.check.completed" && p[:status] == :fail }.last
      expect(payload[:error_class]).to eq("ArgumentError")
      expect(payload[:error_message]).to match(/db\.internal/)
    end

    it "emits nothing when instrumentation is disabled" do
      events = captured_events
      StandardHealth.config.instrumentation_enabled = false
      StandardHealth.config.register_check(:a, ok_check)

      described_class.call

      expect(events).to be_empty
    end

    # The never-raise rule names this file. Instrumentation is the newest way
    # to violate it.
    it "still returns a result when the event bus itself blows up" do
      allow(StandardHealth::EventEmitter).to receive(:emit).and_raise("bus on fire")
      StandardHealth.config.register_check(:a, ok_check)

      expect { described_class.call }.not_to raise_error
      expect(described_class.call[:status]).to eq(:ok)
    end
  end

  describe "timeouts" do
    it "is OFF by default — a slow check still succeeds" do
      StandardHealth.config.register_check(:slow, slow_check)

      expect(described_class.call[:status]).to eq(:ok)
    end

    it "fails a check that exceeds its per-check timeout" do
      StandardHealth.config.register_check(:slow, slow_check, critical: false, timeout: 0.05)

      row = described_class.call[:checks].first

      expect(row[:status]).to eq(:fail)
      expect(row[:error]).to match(/timed out after 0.05s/)
      expect(row[:error_class]).to eq("StandardHealth::CheckTimeout")
    end

    it "falls back to default_check_timeout when no per-check value is set" do
      StandardHealth.config.default_check_timeout = 0.05
      StandardHealth.config.register_check(:slow, slow_check)

      expect(described_class.call[:checks].first[:status]).to eq(:fail)
    end

    it "lets a per-check timeout override the default" do
      StandardHealth.config.default_check_timeout = 0.05
      StandardHealth.config.register_check(:slow, slow_check, timeout: 5)

      expect(described_class.call[:checks].first[:status]).to eq(:ok)
    end

    it "emits check.timed_out" do
      events = captured_events
      StandardHealth.config.register_check(:slow, slow_check, timeout: 0.05)

      described_class.call

      timed_out = events.find { |n, _| n == "standard_health.check.timed_out" }
      expect(timed_out).not_to be_nil
      expect(timed_out.last).to include(name: :slow, timeout_s: 0.05)
    end

    # Timeout.timeout with the default class would also catch a Timeout::Error
    # the host raised for its own reasons and mislabel it as ours.
    it "does not swallow a Timeout::Error raised by the check itself" do
      host_timeout = Class.new(StandardHealth::Check) do
        def run
          raise Timeout::Error, "the host app's own timeout"
        end
      end
      StandardHealth.config.register_check(:host, host_timeout, timeout: 5)

      row = described_class.call[:checks].first

      expect(row[:error_class]).to eq("Timeout::Error")
      expect(row[:error]).to eq("the host app's own timeout")
    end
  end

  describe "total budget" do
    it "is OFF by default" do
      StandardHealth.config.register_check(:slow, slow_check)
      StandardHealth.config.register_check(:after, ok_check)

      expect(described_class.call[:checks].map { |c| c[:status] }).to eq([:ok, :ok])
    end

    it "marks checks the budget never reached as :skipped, not :ok" do
      StandardHealth.config.total_check_budget = 0.1
      StandardHealth.config.register_check(:slow, slow_check)
      StandardHealth.config.register_check(:after, ok_check)

      rows = described_class.call[:checks]

      expect(rows.last[:status]).to eq(:skipped)
      expect(rows.last[:error]).to match(/budget/)
    end

    # Pins the ACTUAL semantics: the budget gates before each check, so it
    # bounds how many checks run, not the probe's wall-clock time. Asserted
    # rather than merely documented, so a future "fix" has to be deliberate —
    # clamping to the remaining budget would apply Timeout.timeout to checks
    # that never opted into it.
    it "does NOT interrupt a check already in flight" do
      StandardHealth.config.total_check_budget = 0.05
      StandardHealth.config.register_check(:slow, slow_check)

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = described_class.call
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      # The check ran to completion despite a budget an order smaller.
      expect(result[:checks].first[:status]).to eq(:ok)
      expect(elapsed).to be >= 0.3
    end

    # THE self-inflicted-outage guard: a slow NON-critical check must not be
    # able to leave the database check unrun and pull the instance out of
    # rotation.
    it "floors a skipped CRITICAL check at :degraded, never :unavailable" do
      StandardHealth.config.total_check_budget = 0.1
      StandardHealth.config.register_check(:slow, slow_check, critical: false)
      StandardHealth.config.register_check(:database, ok_check, critical: true)

      result = described_class.call

      expect(result[:checks].last).to include(name: :database, status: :skipped, critical: true)
      expect(result[:status]).to eq(:degraded)
    end

    # Without this, a skip is invisible to the Metrics notifier — so once a
    # budget is enabled you could not answer "how often is check X skipped",
    # which is exactly the question a budget creates.
    it "emits check.completed for skipped checks so skip rate is chartable" do
      events = captured_events
      StandardHealth.config.total_check_budget = 0.1
      StandardHealth.config.register_check(:slow, slow_check)
      StandardHealth.config.register_check(:after, ok_check)

      described_class.call

      skipped = events.select { |n, p| n == "standard_health.check.completed" && p[:status] == :skipped }
      expect(skipped.length).to eq(1)
      expect(skipped.first.last).to include(name: :after)
    end

    it "still reports :unavailable for a real critical FAILURE alongside a skip" do
      StandardHealth.config.total_check_budget = 0.1
      StandardHealth.config.register_check(:bad, raising_check, critical: true)
      StandardHealth.config.register_check(:slow, slow_check)
      StandardHealth.config.register_check(:never, ok_check, critical: true)

      expect(described_class.call[:status]).to eq(:unavailable)
    end
  end
end
