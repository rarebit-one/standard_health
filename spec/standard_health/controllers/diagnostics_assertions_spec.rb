# frozen_string_literal: true

require "rails_helper"

# `register_diagnostics_assertion` (0.7.0): host runtime assertions rendered on
# the doctor tier next to the env audit, so a host no longer needs its own
# diagnostics controller just to add them.
RSpec.describe "/diagnostics/env assertions", type: :request do
  def body
    get "/health/diagnostics/env"
    JSON.parse(response.body)
  end

  it "renders an empty assertions list when none are registered" do
    expect(body).to include("status" => "ok", "assertions" => [])
  end

  it "renders each assertion with its name, status and detail keys, in registration order" do
    StandardHealth.configure do |c|
      c.register_diagnostics_assertion(:statement_timeout) { { status: :ok, value: "15s", expected: "non-zero" } }
      c.register_diagnostics_assertion(:rate_limit_store, -> { { "status" => "warn", "value" => "SolidCache::Store" } })
    end

    expect(body["assertions"]).to eq([
      { "name" => "statement_timeout", "status" => "ok", "value" => "15s", "expected" => "non-zero" },
      { "name" => "rate_limit_store", "status" => "warn", "value" => "SolidCache::Store" }
    ])
  end

  it "keeps status ok for :warn but reports incomplete for :error" do
    StandardHealth.config.register_diagnostics_assertion(:advisory) { { status: :warn } }
    expect(body["status"]).to eq("ok")

    StandardHealth.config.register_diagnostics_assertion(:broken) { { status: :error } }
    expect(body["status"]).to eq("incomplete")
    expect(response).to have_http_status(:ok)
  end

  it "turns a raising assertion into an :error row, reports it, and still renders the rest" do
    allow(Rails.error).to receive(:report)
    StandardHealth.configure do |c|
      c.register_diagnostics_assertion(:db) { raise ArgumentError, "connection refused" }
      c.register_diagnostics_assertion(:fine) { { status: :ok } }
    end

    rows = body["assertions"]
    expect(rows.first).to eq("name" => "db", "status" => "error", "error_class" => "ArgumentError", "error" => "connection refused")
    expect(rows.last).to eq("name" => "fine", "status" => "ok")
    expect(Rails.error).to have_received(:report).with(
      an_instance_of(ArgumentError), hash_including(handled: true, context: { diagnostics_assertion: :db })
    )
  end

  it "turns a non-Hash result or an unknown status into an :error row" do
    StandardHealth.configure do |c|
      c.register_diagnostics_assertion(:nil_result) { nil }
      c.register_diagnostics_assertion(:bad_status) { { status: :fine } }
    end

    expect(body["assertions"]).to match([
      { "name" => "nil_result", "status" => "error", "error" => a_string_including("returned NilClass, expected a Hash") },
      { "name" => "bad_status", "status" => "error", "error" => a_string_including("returned status :fine") }
    ])
  end

  it "does not let the callable override the registered name" do
    StandardHealth.config.register_diagnostics_assertion(:real) { { name: :spoofed, status: :ok } }

    expect(body["assertions"]).to eq([{ "name" => "real", "status" => "ok" }])
  end

  it "never runs on the probe tiers" do
    calls = 0
    StandardHealth.config.register_diagnostics_assertion(:counted) { calls += 1; { status: :ok } }

    get "/health/alive"
    get "/health/ready"

    expect(calls).to eq(0)
  end

  it "stays behind diagnostics_basic_auth" do
    calls = 0
    StandardHealth.configure do |c|
      c.diagnostics_basic_auth = { username: "u", password: "p" }
      c.register_diagnostics_assertion(:counted) { calls += 1; { status: :ok } }
    end

    get "/health/diagnostics/env"

    expect(response).to have_http_status(:unauthorized)
    expect(calls).to eq(0)
  end
end

RSpec.describe StandardHealth::Configuration, "#register_diagnostics_assertion" do
  subject(:config) { described_class.new }

  it "requires a callable or a block" do
    expect { config.register_diagnostics_assertion(:x) }.to raise_error(ArgumentError, /needs a callable/)
    expect { config.register_diagnostics_assertion(:x, "nope") }.to raise_error(ArgumentError)
  end

  it "replaces an assertion re-registered under the same name (reload-safe)" do
    config.register_diagnostics_assertion(:x) { { status: :ok } }
    config.register_diagnostics_assertion("x") { { status: :warn } }

    expect(config.diagnostics_assertions.map(&:name)).to eq([:x])
    expect(config.diagnostics_assertions.first.callable.call).to eq(status: :warn)
  end

  it "is cleared by reset_diagnostics_assertions!" do
    config.register_diagnostics_assertion(:x) { { status: :ok } }
    config.reset_diagnostics_assertions!

    expect(config.diagnostics_assertions).to be_empty
  end
end
