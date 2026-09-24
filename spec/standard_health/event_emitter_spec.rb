# frozen_string_literal: true

require "rails_helper"

RSpec.describe StandardHealth::EventEmitter do
  describe ".emit" do
    context "when Rails.event is available" do
      before do
        skip "Rails.event not available" unless described_class.rails_event_available?
      end

      it "notifies through Rails.event with the payload as keywords" do
        allow(Rails.event).to receive(:notify)

        described_class.emit("standard_health.check.completed", { name: :db, status: :ok })

        expect(Rails.event).to have_received(:notify)
          .with("standard_health.check.completed", name: :db, status: :ok)
      end
    end

    context "when Rails.event is unavailable" do
      before { allow(described_class).to receive(:rails_event_available?).and_return(false) }

      it "falls back to ActiveSupport::Notifications" do
        seen = []
        sub = ActiveSupport::Notifications.subscribe("standard_health.test") { |*args| seen << args.last }

        described_class.emit("standard_health.test", { a: 1 })

        expect(seen).to eq([{ a: 1 }])
      ensure
        ActiveSupport::Notifications.unsubscribe(sub)
      end
    end

    it "swallows a raising subscriber — instrumentation must never break the health path" do
      allow(described_class).to receive(:rails_event_available?).and_return(false)
      sub = ActiveSupport::Notifications.subscribe("standard_health.boom") { raise "subscriber exploded" }

      expect { described_class.emit("standard_health.boom", {}) }
        .to output(/event emit for "standard_health.boom" failed: RuntimeError: subscriber exploded/).to_stderr
    ensure
      ActiveSupport::Notifications.unsubscribe(sub)
    end
  end

  describe ".rails_event_available?" do
    it "is falsy when Rails is not defined" do
      hide_const("Rails")

      expect(described_class.rails_event_available?).to be_falsy
    end

    it "is false when Rails has no event reporter" do
      rails = Module.new
      stub_const("Rails", rails)

      expect(described_class.rails_event_available?).to be(false)
    end

    it "is truthy when Rails.event responds to notify" do
      reporter = Object.new
      def reporter.notify(*, **); end
      rails = Module.new
      rails.define_singleton_method(:event) { reporter }
      stub_const("Rails", rails)

      expect(described_class.rails_event_available?).to be_truthy
    end
  end
end
