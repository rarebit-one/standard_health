# frozen_string_literal: true

require "rails_helper"

RSpec.describe StandardHealth::Subscribers do
  subject(:subscribers) { StandardHealth::Subscribers.new }

  let(:received) { [] }
  let(:recorder) do
    sink = received
    ->(name, payload) { sink << [name, payload] }
  end

  after { subscribers.teardown! }

  def internal_classes
    subscribers.send(:internal_subscribers).map(&:class)
  end

  describe "internal subscribers built from config" do
    it "registers Logger, Sentry and Metrics by default" do
      expect(internal_classes).to eq([
        StandardHealth::Notifiers::Logger,
        StandardHealth::Notifiers::Sentry,
        StandardHealth::Notifiers::Metrics
      ])
    end

    it "omits Sentry when sentry_enabled is false" do
      StandardHealth.config.sentry_enabled = false

      expect(internal_classes).not_to include(StandardHealth::Notifiers::Sentry)
    end

    it "omits Metrics — and only Metrics — when metrics_enabled is false" do
      StandardHealth.config.metrics_enabled = false

      expect(internal_classes).to eq([StandardHealth::Notifiers::Logger, StandardHealth::Notifiers::Sentry])
    end

    it "passes metric_prefix and metric_events through to the Metrics notifier" do
      StandardHealth.config.metric_prefix = "svc.health"
      StandardHealth.config.metric_events = %w[standard_health.check.timed_out]

      metrics = subscribers.send(:internal_subscribers).grep(StandardHealth::Notifiers::Metrics).first

      expect(metrics.instance_variable_get(:@prefix)).to eq("svc.health")
      expect(metrics.events).to eq(%w[standard_health.check.timed_out])
    end
  end

  shared_examples "an event bus registration" do
    it "delivers standard_health.* events to host notifiers after setup!" do
      StandardHealth.config.add_notifier(recorder)
      subscribers.setup!

      StandardHealth::EventEmitter.emit("standard_health.check.completed", { name: :db, status: :ok })

      expect(received).to include(["standard_health.check.completed", hash_including(name: :db, status: :ok)])
    end

    it "does not deliver other namespaces" do
      StandardHealth.config.add_notifier(recorder)
      subscribers.setup!

      StandardHealth::EventEmitter.emit("standard_circuit.run.completed", { name: :x })

      expect(received).to be_empty
    end

    it "stops delivering after teardown!" do
      StandardHealth.config.add_notifier(recorder)
      subscribers.setup!
      subscribers.teardown!

      StandardHealth::EventEmitter.emit("standard_health.check.completed", { name: :db })

      expect(received).to be_empty
    end

    it "does not double-register when setup! is re-run" do
      StandardHealth.config.add_notifier(recorder)
      subscribers.setup!
      subscribers.setup!

      StandardHealth::EventEmitter.emit("standard_health.check.completed", { name: :db })

      expect(received.size).to eq(1)
    end

    it "registers nothing when instrumentation is disabled" do
      StandardHealth.config.add_notifier(recorder)
      StandardHealth.config.instrumentation_enabled = false
      subscribers.setup!

      StandardHealth::EventEmitter.emit("standard_health.check.completed", { name: :db })

      expect(received).to be_empty
    end
  end

  context "on Rails.event (8.1+)" do
    before do
      skip "Rails.event not available" unless StandardHealth::EventEmitter.rails_event_available?
    end

    it_behaves_like "an event bus registration"
  end

  context "on ActiveSupport::Notifications (pre-8.1 fallback)" do
    before { allow(StandardHealth::EventEmitter).to receive(:rails_event_available?).and_return(false) }

    it_behaves_like "an event bus registration"
  end

  describe StandardHealth::Subscribers::RailsEventAdapter do
    it "forwards only standard_health.* events, with their payload" do
      adapter = described_class.new(recorder)

      adapter.emit(name: "standard_health.ready.evaluated", payload: { status: :ok })
      adapter.emit(name: "other.event", payload: {})
      adapter.emit(name: nil)

      expect(received).to eq([["standard_health.ready.evaluated", { status: :ok }]])
    end

    it "substitutes an empty payload when none is given" do
      described_class.new(recorder).emit(name: "standard_health.check.timed_out")

      expect(received).to eq([["standard_health.check.timed_out", {}]])
    end
  end
end
