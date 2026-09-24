# frozen_string_literal: true

require "rails_helper"

RSpec.describe "aggregate endpoint (config.aggregate_endpoint)", type: :request do
  let(:ok_check) do
    Class.new(StandardHealth::Check) do
      def run
        { status: :ok, latency_ms: 1 }
      end
    end
  end

  let(:leaky_failure) do
    Class.new(StandardHealth::Check) do
      def run
        { status: :fail, error: "could not connect to host=10.0.0.5 user=admin", error_class: "PG::ConnectionBad" }
      end
    end
  end

  def stub_circuits(status:, circuits: [])
    circuit = Module.new
    circuit.define_singleton_method(:health_report) { { status: status, circuits: circuits } }
    stub_const("StandardCircuit", circuit)
  end

  def enable!(&block)
    StandardHealth.configure do |c|
      c.aggregate_endpoint = true
      block&.call(c)
    end
  end

  def body
    response.parsed_body
  end

  context "when off (the default)" do
    it "draws no aggregate route — a bare /health 404s exactly as before" do
      StandardHealth.config.register_check(:database, ok_check, critical: true)

      get "/health"

      expect(response).to have_http_status(:not_found)
    end

    it "still lets a host route drawn AFTER the mount serve /health (cascade intact)" do
      host_app = ->(_env) { [200, { "Content-Type" => "text/plain" }, ["HOST"]] }
      Rails.application.routes.draw do
        mount StandardHealth::Engine => "/health", as: :standard_health
        get "/health", to: host_app
      end

      get "/health"

      expect(response.body).to eq("HOST")
    ensure
      load Rails.root.join("config/routes.rb")
    end
  end

  context "when on" do
    it "serves readiness checks in the shared envelope, omitting circuits when StandardCircuit is absent" do
      hide_const("StandardCircuit")
      enable! { |c| c.register_check(:database, ok_check, critical: true) }

      get "/health"

      expect(response).to have_http_status(:ok)
      expect(body.keys).to eq(%w[status checks generated_at])
      expect(body["status"]).to eq("ok")
      expect(body["checks"].map { |r| r["name"] }).to eq(["database"])
    end

    it "is also reachable with a trailing slash" do
      hide_const("StandardCircuit")
      enable!

      get "/health/"

      expect(response).to have_http_status(:ok)
    end

    it "does not change /alive or /ready" do
      enable! { |c| c.register_aggregate_check(:soft, leaky_failure) }

      get "/health/ready"

      expect(response).to have_http_status(:ok)
      expect(body["status"]).to eq("ok")
      expect(body["checks"]).to eq([])
    end

    describe "circuit folding" do
      it "includes StandardCircuit.health_report circuits" do
        stub_circuits(status: :ok, circuits: [{ name: :s3, color: "green", locked: false, criticality: :standard }])
        enable!

        get "/health"

        expect(body["status"]).to eq("ok")
        expect(body["circuits"]).to eq([{ "name" => "s3", "color" => "green", "locked" => false, "criticality" => "standard" }])
      end

      it "503s as :unavailable (never StandardCircuit's :critical) when a critical circuit is red" do
        stub_circuits(status: :critical, circuits: [{ name: :oauth, color: "red", criticality: :critical }])
        enable!

        get "/health"

        expect(response).to have_http_status(:service_unavailable)
        expect(body["status"]).to eq("unavailable")
      end

      it "degrades (200) on a degraded circuit roll-up" do
        stub_circuits(status: :degraded)
        enable!

        get "/health"

        expect(response).to have_http_status(:ok)
        expect(body["status"]).to eq("degraded")
      end

      it "degrades rather than 500s when the circuit report raises, without leaking the message" do
        circuit = Module.new
        circuit.define_singleton_method(:health_report) { raise Errno::ECONNREFUSED, "redis://secret-host:6379" }
        stub_const("StandardCircuit", circuit)
        enable!

        get "/health"

        expect(response).to have_http_status(:ok)
        expect(body["status"]).to eq("degraded")
        expect(body["circuits"]).to eq([])
        expect(body["circuits_error"]).to eq("error_class" => "Errno::ECONNREFUSED",
                                             "error_code" => "errno_econnrefused")
        expect(response.body).not_to include("secret-host")
      end

      it "can be turned off with aggregate_circuits = false" do
        stub_circuits(status: :critical)
        enable! { |c| c.aggregate_circuits = false }

        get "/health"

        expect(response).to have_http_status(:ok)
        expect(body).not_to have_key("circuits")
      end
    end

    describe "check roll-up" do
      before { hide_const("StandardCircuit") }

      it "503s when a critical readiness check fails" do
        enable! { |c| c.register_check(:database, leaky_failure, critical: true) }

        get "/health"

        expect(response).to have_http_status(:service_unavailable)
        expect(body["status"]).to eq("unavailable")
      end

      it "runs aggregate-only checks and lets a soft failure degrade, never gate" do
        enable! do |c|
          c.register_check(:database, ok_check, critical: true)
          c.register_aggregate_check(:solid_cable, leaky_failure)
        end

        get "/health"

        expect(response).to have_http_status(:ok)
        expect(body["status"]).to eq("degraded")
        expect(body["checks"].map { |r| r["name"] }).to eq(%w[database solid_cable])
      end

      it "reports only aggregate-only checks when aggregate_readiness_checks is false (sidekick's shape)" do
        enable! do |c|
          c.aggregate_readiness_checks = false
          c.register_check(:database, leaky_failure, critical: true)
          c.register_aggregate_check(:solid_cable, ok_check)
        end

        get "/health"

        expect(response).to have_http_status(:ok)
        expect(body["checks"].map { |r| r["name"] }).to eq(["solid_cable"])
      end

      it "resolves a String class name at request time" do
        stub_const("LateBoundCheck", ok_check)
        enable! { |c| c.register_aggregate_check(:late, "LateBoundCheck") }

        get "/health"

        expect(body["checks"].first).to include("name" => "late", "status" => "ok")
      end

      it "reports an unresolvable String class as a failing row rather than raising" do
        enable! { |c| c.register_aggregate_check(:missing, "NoSuchCheckClass") }

        get "/health"

        expect(response).to have_http_status(:ok)
        expect(body["checks"].first).to include("status" => "fail", "error_class" => "NameError")
      end
    end

    describe "redaction" do
      before { hide_const("StandardCircuit") }

      it "redacts driver messages exactly like /ready" do
        enable! { |c| c.register_aggregate_check(:db2, leaky_failure) }

        get "/health"

        row = body["checks"].first
        expect(row).to include("error_class" => "PG::ConnectionBad", "error_code" => "pg_connection_bad")
        expect(row).not_to have_key("error")
        expect(response.body).not_to include("10.0.0.5")
      end

      it "honours the X-Health-Token break-glass" do
        enable! do |c|
          c.detail_token = "let-me-in"
          c.register_aggregate_check(:db2, leaky_failure)
        end

        get "/health", headers: { "X-Health-Token" => "let-me-in" }

        expect(body["checks"].first["error"]).to include("10.0.0.5")
      end
    end

    describe "instrumentation" do
      before { hide_const("StandardCircuit") }

      def captured_events
        events = []
        allow(StandardHealth::EventEmitter).to receive(:emit) { |name, payload| events << [name, payload] }
        events
      end

      it "emits aggregate.evaluated — never ready.evaluated, which drives the transition-gated Sentry notifier" do
        events = captured_events
        enable! { |c| c.register_aggregate_check(:soft, leaky_failure) }

        get "/health"

        names = events.map(&:first)
        expect(names).to include("standard_health.aggregate.evaluated")
        expect(names).not_to include("standard_health.ready.evaluated")

        payload = events.find { |n, _| n == "standard_health.aggregate.evaluated" }.last
        expect(payload).to include(status: :degraded, failed: [:soft])
        expect(payload[:failures].first).to include(error_message: a_string_including("10.0.0.5"))
      end

      it "tags aggregate check events with tier: :aggregate and leaves /ready's payload untouched" do
        events = captured_events
        enable! { |c| c.register_check(:database, ok_check) }

        get "/health"
        get "/health/ready"

        completed = events.select { |n, _| n == "standard_health.check.completed" }.map(&:last)
        expect(completed.first).to include(tier: :aggregate)
        expect(completed.last).not_to have_key(:tier)
      end
    end

    it "is honoured even when a host route for /health is drawn after the mount (engine wins once opted in)" do
      hide_const("StandardCircuit")
      enable!
      host_app = ->(_env) { [200, { "Content-Type" => "text/plain" }, ["HOST"]] }
      Rails.application.routes.draw do
        mount StandardHealth::Engine => "/health", as: :standard_health
        get "/health", to: host_app
      end

      get "/health"

      expect(response.body).not_to eq("HOST")
      expect(body).to include("status" => "ok")
    ensure
      load Rails.root.join("config/routes.rb")
    end
  end
end
