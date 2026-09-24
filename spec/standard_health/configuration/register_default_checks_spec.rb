# frozen_string_literal: true

require "spec_helper"

RSpec.describe "register_default_checks" do
  let(:config) { StandardHealth.config }

  let(:retention_class) do
    Class.new do
      def initialize(name: :audit_retention, critical: false)
        @name = name
        @critical = critical
      end

      def run
        { status: :ok }
      end
    end
  end

  def registrations
    config.checks.to_h { |reg| [reg.name, [reg.klass, reg.critical?]] }
  end

  context "when every backing library is loaded" do
    before do
      stub_const("SolidQueue", Module.new)
      stub_const("SolidCache", Module.new)
      stub_const("StandardAudit::Checks::Retention", retention_class)
    end

    it "registers the estate's common set with the names and criticality the apps use" do
      names = config.register_default_checks

      expect(names).to eq(%i[database solid_queue solid_cache audit_retention])
      expect(registrations).to eq(
        database: [StandardHealth::Checks::ActiveRecord, true],
        solid_queue: [StandardHealth::Checks::SolidQueue, true],
        solid_cache: [StandardHealth::Checks::SolidCache, false],
        audit_retention: [retention_class, false]
      )
    end

    it "skips a check set to false" do
      config.register_default_checks(solid_cache: false)

      expect(registrations.keys).to eq(%i[database solid_queue audit_retention])
    end

    it "applies overrides for name, criticality and timeout" do
      config.register_default_checks(
        database: { name: :primary_db, timeout: 2 },
        solid_queue: { critical: false }
      )

      db = config.checks.find { |r| r.name == :primary_db }
      queue = config.checks.find { |r| r.name == :solid_queue }

      expect(db).to have_attributes(klass: StandardHealth::Checks::ActiveRecord, critical: true, timeout: 2)
      expect(queue.critical?).to be(false)
    end

    it "does not duplicate a check the host already registered under the same name" do
      custom = Class.new(StandardHealth::Check)
      config.register_check(:database, custom, critical: true)

      names = config.register_default_checks

      expect(names).not_to include(:database)
      expect(config.checks.count { |r| r.name == :database }).to eq(1)
      expect(config.checks.find { |r| r.name == :database }.klass).to eq(custom)
    end

    it "is idempotent" do
      config.register_default_checks
      expect(config.register_default_checks).to eq([])
      expect(config.checks.size).to eq(4)
    end

    it "forwards constructor options through the override hash" do
      expect { config.register_default_checks(database: { bogus: 1 }) }
        .to raise_error(ArgumentError, /does not accept `bogus:`/)
    end
  end

  context "when optional backing libraries are absent" do
    before do
      hide_const("SolidQueue")
      hide_const("SolidCache")
      hide_const("StandardAudit")
    end

    it "registers only what is loaded rather than a check that can only fail" do
      expect(config.register_default_checks).to eq([:database])
      expect(registrations.keys).to eq([:database])
    end
  end

  it "rolls up through the aggregator like hand-registered checks" do
    hide_const("SolidQueue")
    hide_const("SolidCache")
    hide_const("StandardAudit")
    config.register_default_checks

    result = StandardHealth::Aggregator.call

    expect(result[:checks].map { |r| r[:name] }).to eq([:database])
  end
end
