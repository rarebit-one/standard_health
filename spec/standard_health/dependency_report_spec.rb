# frozen_string_literal: true

require "spec_helper"

RSpec.describe StandardHealth::DependencyReport do
  subject(:report) { described_class.call(contributions: registry) }

  let(:registry) { StandardHealth::Contributions.new }

  def contribute(rows = nil, source: :standard_circuit, &reader)
    reader ||= -> { rows }
    registry.contribute_dependencies(source, &reader)
  end

  it "is nil when no gem contributed dependency rows" do
    expect(report).to be_nil
  end

  it "is :ok with an empty section when the contributor has no dependencies" do
    contribute([])

    expect(report).to eq(status: :ok, dependencies: [])
  end

  it "renders a row in the design-doc shape" do
    row = {
      name: :stripe, status: :degraded, criticality: :critical,
      affected_purposes: ["checkout"], reasons: ["error_rate"], metrics_only: false,
      circuits: [{ name: :stripe, color: "green", locked: false, forced: nil }],
      measurements: { "stripe:errorRate" => 0.18, "stripe:p95Ms" => 2140,
                      "stripe:lastSuccessAt" => "2026-11-23T04:12:09Z", "stripe:fallbackRate" => 0.0 }
    }
    contribute([row])

    expect(report[:dependencies]).to eq([
      row.merge(name: "stripe", circuits: [{ name: :stripe, color: "green", locked: false }])
    ])
  end

  it "renders only the known keys, so a contributor cannot leak a message into the anonymous body" do
    contribute([dependency_row("stripe", error_message: "connect to 10.0.0.4:443 as admin", stats: {})])

    expect(report[:dependencies].first.keys).to contain_exactly(:name, :status, :criticality)
  end

  it "passes a probe result through (reserved for cached active probes)" do
    contribute([dependency_row("agent", probe: { status: "ok", checked_at: "2026-11-25T01:00:00Z" })])

    expect(report[:dependencies].first[:probe]).to eq(status: "ok", checked_at: "2026-11-25T01:00:00Z")
  end

  it "accepts string keys and string values" do
    contribute([{ "name" => "stripe", "status" => "unavailable", "criticality" => "critical" }])

    expect(report).to eq(status: :unavailable,
                         dependencies: [{ name: "stripe", status: :unavailable, criticality: :critical }])
  end

  describe "roll-up" do
    it "is :unavailable only for a critical row that is unavailable" do
      contribute([dependency_row("stripe", status: :unavailable, criticality: :critical),
                  dependency_row("maps", status: :degraded)])

      expect(report[:status]).to eq(:unavailable)
    end

    it "clamps an unavailable non-critical row to :degraded: only critical dependencies fail a tier" do
      contribute([dependency_row("sendgrid", status: :unavailable, criticality: :standard),
                  dependency_row("maps", status: :unavailable, criticality: :optional)])

      expect(report[:status]).to eq(:degraded)
      expect(report[:dependencies].map { |r| r[:status] }).to eq(%i[degraded degraded])
    end

    it "is :degraded for any degraded row, critical or not" do
      contribute([dependency_row("stripe", status: :degraded, criticality: :critical)])

      expect(report[:status]).to eq(:degraded)
    end

    it "reads an unknown status as :degraded and an unknown criticality as :standard" do
      contribute([dependency_row("x", status: :mystery, criticality: :vital)])

      expect(report[:dependencies]).to eq([{ name: "x", status: :degraded, criticality: :standard }])
      expect(report[:status]).to eq(:degraded)
    end

    it "concatenates the rows of several contributors" do
      contribute([dependency_row("stripe")])
      contribute([dependency_row("harness", status: :degraded)], source: :other_gem)

      expect(report[:dependencies].map { |r| r[:name] }).to eq(%w[stripe harness])
      expect(report[:status]).to eq(:degraded)
    end
  end

  describe "never raises" do
    it "degrades with an error class and code when a reader raises, keeping other contributors' rows" do
      contribute([dependency_row("harness")], source: :other_gem)
      contribute { raise IOError, "redis://10.0.0.9 refused" }

      expect(report).to include(
        status: :degraded,
        dependencies: [{ name: "harness", status: :ok, criticality: :standard }],
        error: { error_class: "IOError", error_code: "ioerror" },
        error_message: "redis://10.0.0.9 refused"
      )
    end

    it "keeps :unavailable from another contributor when one reader fails" do
      contribute([dependency_row("stripe", status: :unavailable, criticality: :critical)], source: :a)
      contribute(source: :b) { raise "boom" }

      expect(report[:status]).to eq(:unavailable)
    end

    it "degrades when a reader returns something other than an Array" do
      contribute({ name: "stripe" })

      expect(report).to include(status: :degraded, dependencies: [], error: include(error_class: "TypeError"))
    end

    it "degrades when a row is not a Hash or has no name" do
      contribute([dependency_row("")])

      expect(report).to include(status: :degraded, error: include(error_class: "ArgumentError"))
    end
  end

  describe ".failing_names" do
    it "names the rows that are not :ok" do
      rows = [dependency_row("a"), dependency_row("b", status: :degraded), dependency_row("c", status: :unavailable)]

      expect(described_class.failing_names(rows)).to eq(%w[b c])
    end
  end
end
