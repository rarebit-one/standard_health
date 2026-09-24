# frozen_string_literal: true

require "rails_helper"

RSpec.describe "StandardHealth probe paths" do
  describe "StandardHealth::PROBE_PATHS" do
    it "matches every orchestrator-polled path under the default /health mount" do
      %w[/up /health /health/alive /health/ready /health/ready/ /up/].each do |path|
        expect(path).to match(StandardHealth::PROBE_PATHS), path
      end
    end

    it "is a superset of the regex the host apps copy-paste" do
      legacy = %r{\A/(up|health/(alive|ready))\z}
      %w[/up /health/alive /health/ready].each do |path|
        expect(path).to match(legacy)
        expect(path).to match(StandardHealth::PROBE_PATHS)
      end
    end

    it "keeps the doctor tier OUT (authed, on-call traffic, belongs in APM)" do
      expect("/health/diagnostics/env").not_to match(StandardHealth::PROBE_PATHS)
    end

    it "is anchored on segment boundaries" do
      %w[/healthy-habits /health/alive/extra /health/readyz /api/up /upload /health/alive?x=1].each do |path|
        expect(path).not_to match(StandardHealth::PROBE_PATHS), path
      end
    end
  end

  describe ".probe_path?" do
    it "uses the default pattern" do
      expect(StandardHealth.probe_path?("/health/ready")).to be(true)
      expect(StandardHealth.probe_path?("/users")).to be(false)
      expect(StandardHealth.probe_path?(nil)).to be(false)
    end

    it "honours a custom mount prefix" do
      expect(StandardHealth.probe_path?("/_status/alive", mount: "/_status")).to be(true)
      expect(StandardHealth.probe_path?("/_status", mount: "_status/")).to be(true)
      expect(StandardHealth.probe_path?("/health/alive", mount: "/_status")).to be(false)
    end

    it "can reproduce the legacy exact set (no aggregate)" do
      expect(StandardHealth.probe_path?("/health", aggregate: false)).to be(false)
      expect(StandardHealth.probe_path?("/health/ready", aggregate: false)).to be(true)
    end

    it "can drop /up and add extra paths" do
      expect(StandardHealth.probe_path?("/up", up: false)).to be(false)
      expect(StandardHealth.probe_path?("/circuits", extra: ["/circuits"])).to be(true)
    end

    it "escapes the mount path" do
      expect(StandardHealth.probe_path?("/hXalth/alive", mount: "/h.alth")).to be(false)
      expect(StandardHealth.probe_path?("/h.alth/alive", mount: "/h.alth")).to be(true)
    end
  end

  describe "derived from the engine's actual routes" do
    it "covers exactly the engine's non-diagnostics GET routes" do
      engine_paths = StandardHealth::Engine.routes.routes
                                            .map { |r| r.path.spec.to_s.delete_suffix("(.:format)") }
                                            .reject { |p| p.start_with?("/diagnostics") || p == "/" }

      expect(engine_paths).to match_array(StandardHealth::PROBE_ACTIONS.map { |a| "/#{a}" })
    end

    it "serves every probe path it matches", type: :request do
      StandardHealth::PROBE_ACTIONS.each do |action|
        get "/health/#{action}"
        expect(response).to have_http_status(:ok)
      end
    end
  end
end
