# frozen_string_literal: true

require "rails_helper"

# Dependency rows (0.10.0) across the probe tiers, for both StandardCircuit
# shapes an app can be on: 0.7.x (circuits fold-in only, no rows) and 0.8+
# (rows contributed, circuits still rendered but deprecated).
RSpec.describe "dependency rows", type: :request do
  let(:ok_check) do
    Class.new(StandardHealth::Check) do
      def run
        { status: :ok, latency_ms: 1 }
      end
    end
  end

  let(:red_critical_circuit) { { name: :stripe, color: "red", locked: false, criticality: :critical } }

  let(:stripe_row) do
    {
      name: "stripe", status: :ok, criticality: :critical, affected_purposes: [], reasons: [],
      metrics_only: false,
      circuits: [{ name: :stripe, color: "green", locked: false }],
      measurements: { "stripe:errorRate" => 0.0, "stripe:p95Ms" => 120.5,
                      "stripe:lastSuccessAt" => "2026-11-25T01:00:00Z", "stripe:fallbackRate" => 0.0 }
    }
  end

  def configure!(&block)
    StandardHealth.configure do |c|
      c.aggregate_endpoint = true
      c.register_check :database, ok_check, critical: true
      block&.call(c)
    end
  end

  def body
    response.parsed_body
  end

  describe "GET /health (aggregate)" do
    context "with StandardCircuit 0.7.x (no rows contributed)" do
      it "renders the pre-0.10 body: circuits, and no dependencies key" do
        stub_standard_circuit_07(circuit_report(status: :ok, circuits: [{ name: :stripe, color: "green" }]))
        configure!

        get "/health"

        expect(body.keys).to eq(%w[status checks circuits generated_at])
        expect(body["circuits"]).to eq([{ "name" => "stripe", "color" => "green" }])
      end

      it "still 503s on a red critical circuit, from the circuit roll-up" do
        stub_standard_circuit_07(circuit_report(status: :critical, circuits: [red_critical_circuit]))
        configure!

        get "/health"

        expect(response).to have_http_status(:service_unavailable)
        expect(body["status"]).to eq("unavailable")
      end
    end

    context "with StandardCircuit 0.8 (rows contributed)" do
      it "renders dependencies next to the deprecated circuits section" do
        stub_standard_circuit_08([stripe_row], circuit_report(circuits: [{ name: :stripe, color: "green" }]))
        configure!

        get "/health"

        expect(body.keys).to eq(%w[status checks dependencies circuits generated_at])
        expect(body["dependencies"]).to eq([JSON.parse(stripe_row.to_json)])
        expect(body["circuits"]).to eq([{ "name" => "stripe", "color" => "green" }])
      end

      it "503s when a critical dependency is unavailable" do
        stub_standard_circuit_08([stripe_row.merge(status: :unavailable, affected_purposes: ["default"])],
                                 circuit_report(status: :critical, circuits: [red_critical_circuit]))
        configure!

        get "/health"

        expect(response).to have_http_status(:service_unavailable)
        expect(body["dependencies"].first).to include("status" => "unavailable", "affected_purposes" => ["default"])
      end

      it "rolls up from the rows alone: the circuit section no longer counts, so nothing is reported twice" do
        # The rows say ok (say, the breaker just went half-open and the row
        # rules judged it fine); the fold-in alone would have said 503.
        stub_standard_circuit_08([stripe_row], circuit_report(status: :critical, circuits: [red_critical_circuit]))
        configure!

        get "/health"

        expect(response).to have_http_status(:ok)
        expect(body["status"]).to eq("ok")
      end

      it "counts the circuit roll-up again when the rows cannot be read" do
        stub_standard_circuit_07(circuit_report(status: :critical, circuits: [red_critical_circuit]))
        contribute_rows { raise Errno::ECONNREFUSED, "redis://secret-host:6379" }
        configure!

        get "/health"

        expect(response).to have_http_status(:service_unavailable)
        expect(body["dependencies"]).to eq([])
        expect(body["dependencies_error"]).to eq("error_class" => "Errno::ECONNREFUSED",
                                                 "error_code" => "errno_econnrefused")
        expect(response.body).not_to include("secret-host")
      end

      it "degrades but stays 200 for a degraded or non-critical dependency" do
        stub_standard_circuit_08([stripe_row.merge(status: :degraded),
                                  stripe_row.merge(name: "sendgrid", status: :unavailable, criticality: :standard)])
        configure!

        get "/health"

        expect(response).to have_http_status(:ok)
        expect(body["status"]).to eq("degraded")
        expect(body["dependencies"].map { |r| r["status"] }).to eq(%w[degraded degraded])
      end

      it "drops the deprecated section with aggregate_circuits = false" do
        stub_standard_circuit_08([stripe_row])
        configure! { |c| c.aggregate_circuits = false }

        get "/health"

        expect(body.keys).to eq(%w[status checks dependencies generated_at])
      end

      it "falls back to the circuit roll-up with aggregate_dependencies = false" do
        stub_standard_circuit_08([stripe_row], circuit_report(status: :critical, circuits: [red_critical_circuit]))
        configure! { |c| c.aggregate_dependencies = false }

        get "/health"

        expect(response).to have_http_status(:service_unavailable)
        expect(body).not_to have_key("dependencies")
      end

      it "still fails the tier on a critical check, whatever the rows say" do
        failing = Class.new(StandardHealth::Check) { def run = { status: :fail, error: "down" } }
        stub_standard_circuit_08([stripe_row])
        configure! { |c| c.register_check :database, failing, critical: true }

        get "/health"

        expect(response).to have_http_status(:service_unavailable)
      end
    end
  end

  describe "GET /health/ready" do
    let(:unavailable_rows) { [stripe_row.merge(status: :unavailable)] }

    it "ignores dependency rows by default: the body and the status are unchanged" do
      stub_standard_circuit_08(unavailable_rows)
      configure!

      get "/health/ready"

      expect(response).to have_http_status(:ok)
      expect(body.keys).to eq(%w[status checks generated_at])
    end

    context "with ready_dependencies on" do
      it "503s on a critical dependency that is unavailable, and renders the rows" do
        stub_standard_circuit_08(unavailable_rows)
        configure! { |c| c.ready_dependencies = true }

        get "/health/ready"

        expect(response).to have_http_status(:service_unavailable)
        expect(body["status"]).to eq("unavailable")
        expect(body.keys).to eq(%w[status checks dependencies generated_at])
      end

      it "does not change the status for degraded or non-critical rows" do
        stub_standard_circuit_08([stripe_row.merge(status: :degraded),
                                  stripe_row.merge(name: "maps", status: :unavailable, criticality: :optional)])
        configure! { |c| c.ready_dependencies = true }

        get "/health/ready"

        expect(response).to have_http_status(:ok)
        expect(body["status"]).to eq("ok")
        expect(body["dependencies"].map { |r| r["status"] }).to eq(%w[degraded degraded])
      end

      it "does not leave rotation when the rows cannot be read" do
        contribute_rows { raise IOError, "redis down" }
        configure! { |c| c.ready_dependencies = true }

        get "/health/ready"

        expect(response).to have_http_status(:ok)
        expect(body["status"]).to eq("ok")
        expect(body["dependencies_error"]).to eq("error_class" => "IOError", "error_code" => "ioerror")
      end

      it "renders nothing extra when StandardCircuit 0.7.x contributes no rows" do
        stub_standard_circuit_07(circuit_report(status: :critical, circuits: [red_critical_circuit]))
        configure! { |c| c.ready_dependencies = true }

        get "/health/ready"

        expect(response).to have_http_status(:ok)
        expect(body.keys).to eq(%w[status checks generated_at])
      end

      it "names the dependency in ready.evaluated" do
        events = []
        allow(StandardHealth::EventEmitter).to receive(:emit) { |name, payload| events << [name, payload] }
        stub_standard_circuit_08(unavailable_rows)
        configure! { |c| c.ready_dependencies = true }

        get "/health/ready"

        payload = events.find { |name, _| name == "standard_health.ready.evaluated" }.last
        expect(payload).to include(status: :unavailable, failed: [], failing_dependencies: ["stripe"])
      end
    end
  end

  describe "GET /health/alive" do
    it "is 200 whatever the dependencies say, even with ready_dependencies on" do
      stub_standard_circuit_08([stripe_row.merge(status: :unavailable)])
      configure! { |c| c.ready_dependencies = true }

      get "/health/alive"

      expect(response).to have_http_status(:ok)
    end
  end
end
