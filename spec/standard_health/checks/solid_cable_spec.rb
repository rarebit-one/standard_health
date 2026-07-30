# frozen_string_literal: true

require "spec_helper"

RSpec.describe StandardHealth::Checks::SolidCable do
  before do
    ::ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
  end

  it "is non-critical by default — cable is a degradable feature dependency" do
    expect(described_class.new(name: :solid_cable).critical?).to be(false)
  end

  it "returns :ok with latency_ms when the cable table is reachable" do
    ::ActiveRecord::Base.connection.create_table(:solid_cable_messages, force: true)

    result = described_class.new(name: :solid_cable).run

    expect(result[:status]).to eq(:ok)
    expect(result[:latency_ms]).to be_a(Integer)
  end

  it "returns :fail when the cable table is missing (unmigrated store)" do
    connection = ::ActiveRecord::Base.connection
    connection.drop_table(:solid_cable_messages, if_exists: true)

    result = described_class.new(name: :solid_cable).run

    expect(result[:status]).to eq(:fail)
    expect(result[:error_class]).to match(/StatementInvalid/)
  end

  it "falls back to the primary connection when SolidCable::Record is absent" do
    ::ActiveRecord::Base.connection.create_table(:solid_cable_messages, force: true)

    expect(described_class.new(name: :solid_cable).run).to include(status: :ok)
  end

  it "returns :fail rather than raising when the connection itself is broken" do
    check = described_class.new(name: :solid_cable)
    allow(::ActiveRecord::Base).to receive(:connection).and_raise(StandardError, "no db")

    expect { check.run }.not_to raise_error
    expect(check.run).to include(status: :fail, error: "no db")
  end
end
