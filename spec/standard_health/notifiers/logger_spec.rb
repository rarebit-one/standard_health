# frozen_string_literal: true

require "spec_helper"

RSpec.describe StandardHealth::Notifiers::Logger do
  let(:lines) { [] }

  let(:fake_logger) do
    Class.new do
      def initialize(sink) = @sink = sink
      def warn(msg)  = @sink << [:warn, msg]
      def error(msg) = @sink << [:error, msg]
    end.new(lines)
  end

  subject(:notifier) { described_class.new(fake_logger) }

  def evaluate(status, failed: [], duration_ms: 12)
    notifier.call("standard_health.ready.evaluated",
                  { status: status, failed: failed, duration_ms: duration_ms })
  end

  # THE reason this diverges from standard_circuit's logger: at a 10s probe
  # period a line per evaluation is ~8,640/day/instance of "everything is
  # fine", which buries the one line that matters.
  it "logs NOTHING while healthy" do
    20.times { evaluate(:ok) }

    expect(lines).to be_empty
  end

  it "warns on degraded, naming the failing checks" do
    evaluate(:degraded, failed: [:cache, :audit_retention])

    level, message = lines.first
    expect(level).to eq(:warn)
    expect(message).to include("readiness degraded")
    expect(message).to include("cache, audit_retention")
    expect(message).to include("(12ms)")
  end

  it "errors on unavailable" do
    evaluate(:unavailable, failed: [:database])

    expect(lines.first.first).to eq(:error)
  end

  it "warns on a check timeout" do
    notifier.call("standard_health.check.timed_out", { name: :database, timeout_s: 2.0 })

    level, message = lines.first
    expect(level).to eq(:warn)
    expect(message).to include("database timed out after 2.0s")
  end

  it "ignores per-check completion events (that is the metrics notifier's job)" do
    notifier.call("standard_health.check.completed", { name: :db, status: :fail })

    expect(lines).to be_empty
  end

  it "survives a logger that raises" do
    exploding = Class.new { def warn(_) = raise("logger down") }.new

    expect {
      described_class.new(exploding)
        .call("standard_health.ready.evaluated", { status: :degraded, failed: [] })
    }.not_to raise_error
  end
end
