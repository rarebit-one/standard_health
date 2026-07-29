# frozen_string_literal: true

require "spec_helper"

# Redaction removes the exception message from the HTTP body on the explicit
# promise that it still reaches logs and Sentry. These specs exist because
# that promise was NOT true when first written: `error_message` rode only on
# `check.completed`, which neither built-in subscriber listens to, so the
# message was being deleted rather than relocated.
#
# They trace a realistic driver failure the whole way through:
#   a check using with_timing  ->  aggregator  ->  ready.evaluated  ->  Logger/Sentry
RSpec.describe "failure detail survives redaction" do
  # Mimics a real driver error: raised inside with_timing, exactly as all
  # three built-in checks do.
  let(:driver_failure) do
    Class.new(StandardHealth::Check) do
      def run
        with_timing do
          raise ArgumentError, 'connection refused host="db-prod.internal" user="app_admin"'
        end
      end
    end
  end

  before { StandardHealth.config.register_check(:database, driver_failure, critical: true) }

  # Finding #1: with_timing swallowed the class, so every built-in check
  # failure rendered as the generic "StandardError" the redaction feature
  # exists to avoid.
  it "captures the real exception class from a with_timing check" do
    row = StandardHealth::Aggregator.call[:checks].first

    expect(row[:error_class]).to eq("ArgumentError")
  end

  it "produces a specific error_code after redaction, not standard_error" do
    result = StandardHealth::Redactor.call(StandardHealth::Aggregator.call)

    expect(result[:checks].first[:error_code]).to eq("argument_error")
  end

  # Finding #2: the message has to be on the event the subscribers actually
  # consume, which is ready.evaluated.
  it "puts error_class and error_message on ready.evaluated" do
    events = []
    allow(StandardHealth::EventEmitter).to receive(:emit) { |n, p| events << [n, p] }

    StandardHealth::Aggregator.call

    payload = events.find { |n, _| n == "standard_health.ready.evaluated" }.last
    failure = payload[:failures].first
    expect(failure[:error_class]).to eq("ArgumentError")
    expect(failure[:error_message]).to match(/db-prod\.internal/)
  end

  it "reaches the log line, with the message redaction removed from the body" do
    lines = []
    logger = Class.new do
      def initialize(sink) = @sink = sink
      def warn(m) = @sink << m
      def error(m) = @sink << m
    end.new(lines)

    events = []
    allow(StandardHealth::EventEmitter).to receive(:emit) { |n, p| events << [n, p] }
    StandardHealth::Aggregator.call
    payload = events.find { |n, _| n == "standard_health.ready.evaluated" }.last

    StandardHealth::Notifiers::Logger.new(logger)
                                     .call("standard_health.ready.evaluated", payload)

    expect(lines.first).to include("ArgumentError")
    expect(lines.first).to include("db-prod.internal")
  end

  it "reaches Sentry extras" do
    captures = []
    sentry = Module.new do
      class << self
        attr_accessor :sink
        def capture_message(message, level: nil, extra: nil)
          sink << { message: message, extra: extra }
        end
      end
    end
    sentry.sink = captures
    stub_const("Sentry", sentry)

    events = []
    allow(StandardHealth::EventEmitter).to receive(:emit) { |n, p| events << [n, p] }
    StandardHealth::Aggregator.call
    payload = events.find { |n, _| n == "standard_health.ready.evaluated" }.last

    StandardHealth::Notifiers::Sentry.new
                                     .call("standard_health.ready.evaluated", payload)

    failure = captures.first[:extra][:failures].first
    expect(failure[:error_class]).to eq("ArgumentError")
    expect(failure[:error_message]).to match(/db-prod\.internal/)
  end

  # The whole point: gone from the public body, present in the operator path.
  it "is absent from the redacted response but present in the event" do
    events = []
    allow(StandardHealth::EventEmitter).to receive(:emit) { |n, p| events << [n, p] }
    body = StandardHealth::Redactor.call(StandardHealth::Aggregator.call)
    payload = events.find { |n, _| n == "standard_health.ready.evaluated" }.last

    expect(body.to_s).not_to include("db-prod.internal")
    expect(payload.to_s).to include("db-prod.internal")
  end
end
