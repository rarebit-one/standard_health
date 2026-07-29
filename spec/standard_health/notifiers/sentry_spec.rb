# frozen_string_literal: true

require "spec_helper"

RSpec.describe StandardHealth::Notifiers::Sentry do
  let(:captures) { [] }

  # Minimal Sentry stand-in — the gem treats Sentry as a soft dependency and
  # must never require it.
  before do
    sentry = Module.new do
      class << self
        attr_accessor :sink

        def capture_message(message, level: nil, extra: nil)
          sink << { message: message, level: level, extra: extra }
          message
        end
      end
    end
    sentry.sink = captures
    stub_const("Sentry", sentry)
  end

  def evaluate(notifier, status, failed: [])
    notifier.call("standard_health.ready.evaluated",
                  { status: status, failed: failed, duration_ms: 5 })
  end

  it "does nothing at all while healthy" do
    notifier = described_class.new
    5.times { evaluate(notifier, :ok) }

    expect(captures).to be_empty
  end

  # THE reason this diverges from standard_circuit's notifier: health events
  # are polls (~6/min/instance), not transitions. Capturing each one turns a
  # five-minute outage into ~30 duplicate issues.
  it "captures a sustained failure ONCE, not once per poll" do
    notifier = described_class.new(repeat_floor_seconds: 3600)
    10.times { evaluate(notifier, :unavailable, failed: [:database]) }

    expect(captures.length).to eq(1)
    expect(captures.first[:message]).to eq("Health unavailable: database")
    expect(captures.first[:level]).to eq(:error)
  end

  it "re-reports a sustained failure once the repeat floor elapses" do
    notifier = described_class.new(repeat_floor_seconds: 0)
    3.times { evaluate(notifier, :unavailable, failed: [:database]) }

    expect(captures.length).to eq(3)
  end

  it "captures each escalation immediately, even inside the floor window" do
    notifier = described_class.new(repeat_floor_seconds: 3600)
    evaluate(notifier, :ok)
    evaluate(notifier, :degraded, failed: [:cache])
    evaluate(notifier, :unavailable, failed: [:database])

    expect(captures.map { |c| c[:message] }).to eq([
      "Health degraded: cache",
      "Health unavailable: database"
    ])
  end

  # Reporting every transition unconditionally reintroduces the exact noise
  # the floor exists to stop: a check flapping on a 10s poll "transitions"
  # six times a minute.
  it "rate-limits a FLAPPING check instead of capturing every toggle" do
    notifier = described_class.new(repeat_floor_seconds: 3600)
    6.times do
      evaluate(notifier, :degraded, failed: [:cache])
      evaluate(notifier, :ok)
    end

    expect(captures.length).to eq(1)
    expect(captures.first[:message]).to eq("Health degraded: cache")
  end

  # Rate-limiting must never delay bad news getting worse.
  it "still escalates to unavailable during the floor window while flapping" do
    notifier = described_class.new(repeat_floor_seconds: 3600)
    evaluate(notifier, :degraded, failed: [:cache])
    evaluate(notifier, :ok)
    evaluate(notifier, :unavailable, failed: [:database])

    expect(captures.map { |c| c[:message] }).to eq([
      "Health degraded: cache",
      "Health unavailable: database"
    ])
  end

  it "reports recovery once, at info, once the floor has elapsed" do
    notifier = described_class.new(repeat_floor_seconds: 0)
    evaluate(notifier, :unavailable, failed: [:database])
    captures.clear
    evaluate(notifier, :ok)
    evaluate(notifier, :ok)
    evaluate(notifier, :ok)

    expect(captures.length).to eq(1)
    expect(captures.first).to include(message: "Health recovered: readiness ok", level: :info)
  end

  # Recovery is rate-limited like everything else — a flapping check recovers
  # as often as it breaks. At the default 60s floor a real recovery still
  # lands within a minute.
  it "does not report recovery inside the floor window" do
    notifier = described_class.new(repeat_floor_seconds: 3600)
    evaluate(notifier, :unavailable, failed: [:database])
    captures.clear
    evaluate(notifier, :ok)

    expect(captures).to be_empty
  end

  it "never reports recovery for a process that was never unhealthy" do
    notifier = described_class.new(repeat_floor_seconds: 0)
    5.times { evaluate(notifier, :ok) }

    expect(captures).to be_empty
  end

  it "uses warning for degraded and error for unavailable" do
    notifier = described_class.new(repeat_floor_seconds: 3600)
    evaluate(notifier, :degraded, failed: [:cache])
    evaluate(notifier, :unavailable, failed: [:db])

    expect(captures.map { |c| c[:level] }).to eq([:warning, :error])
  end

  it "ignores events other than ready.evaluated" do
    notifier = described_class.new
    notifier.call("standard_health.check.completed", { name: :db, status: :fail })

    expect(captures).to be_empty
  end

  it "is inert when Sentry is not loaded" do
    hide_const("Sentry")
    notifier = described_class.new

    expect { evaluate(notifier, :unavailable, failed: [:db]) }.not_to raise_error
  end

  it "swallows a Sentry that raises" do
    allow(Sentry).to receive(:capture_message).and_raise("sentry down")
    notifier = described_class.new

    expect { evaluate(notifier, :unavailable, failed: [:db]) }.not_to raise_error
  end
end
