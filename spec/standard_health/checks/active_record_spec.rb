# frozen_string_literal: true

require "spec_helper"

RSpec.describe StandardHealth::Checks::ActiveRecord do
  it "returns :ok with latency_ms against a live connection" do
    # Force a connection to the dummy app's sqlite DB.
    ::ActiveRecord::Base.establish_connection(
      adapter: "sqlite3",
      database: ":memory:"
    )

    result = described_class.new(name: :db).run

    expect(result[:status]).to eq(:ok)
    expect(result[:latency_ms]).to be_a(Integer)
  end

  it "returns :fail with the error message when the connection is broken" do
    check = described_class.new(name: :db)
    allow(::ActiveRecord::Base).to receive(:connection).and_raise(StandardError, "no db")

    result = check.run

    expect(result).to include(status: :fail, error: "no db")
  end

  it "is critical by default" do
    expect(described_class.new(name: :db).critical?).to be(true)
  end
end
