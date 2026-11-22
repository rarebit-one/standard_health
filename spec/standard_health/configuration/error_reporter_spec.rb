# frozen_string_literal: true

require "spec_helper"

RSpec.describe "error_reporter configuration" do
  let(:config) { StandardHealth.config }
  let(:error) { ArgumentError.new("boom") }

  it "defaults to nil, which keeps Rails.error" do
    expect(config.error_reporter).to be_nil
  end

  it "rejects something that is not callable, at boot" do
    expect { config.error_reporter = "Sentry" }
      .to raise_error(ArgumentError, /error_reporter must respond to `call\(error, context\)`/)
  end

  it "accepts nil to restore the default" do
    config.error_reporter = ->(_error, _context) { }
    config.error_reporter = nil

    expect(config.error_reporter).to be_nil
  end

  describe "#report_error" do
    before { allow(Rails.error).to receive(:report) }

    it "reports to Rails.error as handled when no error_reporter is set" do
      config.report_error(error, severity: :warning, context: { health_check: "x" }, source: "standard_health")

      expect(Rails.error).to have_received(:report).with(
        error, handled: true, severity: :warning, context: { health_check: "x" }, source: "standard_health"
      )
    end

    it "calls error_reporter with the error and the context alone when one is set" do
      reported = []
      config.error_reporter = ->(err, context) { reported << [err, context] }

      config.report_error(error, severity: :warning, context: { health_check: "x" })

      expect(reported).to eq([[error, { health_check: "x" }]])
      expect(Rails.error).not_to have_received(:report)
    end
  end
end
