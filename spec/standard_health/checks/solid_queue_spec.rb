# frozen_string_literal: true

require "spec_helper"

RSpec.describe StandardHealth::Checks::SolidQueue do
  before do
    ::ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
  end

  it "defaults to name :solid_queue and CRITICAL — jobs are hard infra the app owns" do
    check = described_class.new

    expect(check.name).to eq(:solid_queue)
    expect(check.critical?).to be(true)
  end

  it "honours an explicit name and criticality" do
    check = described_class.new(name: :queue, critical: false)

    expect(check.name).to eq(:queue)
    expect(check.critical?).to be(false)
  end

  it "falls back to the primary connection when SolidQueue::Record is absent (single-DB setup)" do
    hide_const("SolidQueue")

    result = described_class.new.run

    expect(result[:status]).to eq(:ok)
    expect(result[:latency_ms]).to be_a(Integer)
  end

  it "probes SolidQueue::Record's connection when the queue has its own database" do
    queue_connection = instance_double(ActiveRecord::ConnectionAdapters::AbstractAdapter, execute: [[1]])
    record = Class.new { define_singleton_method(:connection) { queue_connection } }
    stub_const("SolidQueue::Record", record)
    allow(::ActiveRecord::Base).to receive(:connection).and_raise("primary must not be touched")

    expect(described_class.new.run).to include(status: :ok)
    expect(queue_connection).to have_received(:execute).with("SELECT 1")
  end

  it "returns :fail with the error class rather than raising when the queue database is down" do
    record = Class.new { define_singleton_method(:connection) { raise ActiveRecord::ConnectionNotEstablished, "queue db down" } }
    stub_const("SolidQueue::Record", record)

    result = described_class.new.run

    expect(result).to include(status: :fail, error: "queue db down", error_class: "ActiveRecord::ConnectionNotEstablished")
  end
end
