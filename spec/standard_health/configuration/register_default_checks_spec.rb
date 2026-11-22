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

  it "rejects an unknown key, listing the known ones" do
    expect { config.register_default_checks(solid_cash: false) }
      .to raise_error(ArgumentError, /unknown default check :solid_cash; known: database, solid_queue, solid_cache, audit_retention/)
  end

  context "with checks contributed by other gems" do
    let(:contributions) { StandardHealth::Contributions.new }
    let(:config) { StandardHealth::Configuration.new(contributions: contributions) }

    let(:migrations_class) do
      Class.new do
        def initialize(name: :standard_id_migrations, critical: false)
          @name = name
          @critical = critical
        end

        def run
          { status: :ok }
        end
      end
    end

    before do
      hide_const("SolidQueue")
      hide_const("SolidCache")
      hide_const("StandardAudit")
      stub_const("StandardId::Checks::Migrations", migrations_class)
      contributions.contribute_check :standard_id_migrations, "StandardId::Checks::Migrations"
    end

    it "registers them after the built-ins, non-critical, with the class name left to resolve at run time" do
      expect(config.register_default_checks).to eq(%i[database standard_id_migrations])

      reg = config.checks.last
      expect(reg).to have_attributes(name: :standard_id_migrations, klass: "StandardId::Checks::Migrations")
      expect(reg.critical?).to be(false)
      expect(reg.check_class).to eq(migrations_class)
    end

    it "honours a contributor's criticality, timeout and constructor options" do
      contributions.contribute_check :strict, "StandardId::Checks::Migrations", critical: true, timeout: 3

      config.register_default_checks

      expect(config.checks.find { |r| r.name == :strict }).to have_attributes(critical: true, timeout: 3)
    end

    it "lets the app opt out per name" do
      expect(config.register_default_checks(standard_id_migrations: false)).to eq([:database])
    end

    it "lets the app override per name" do
      config.register_default_checks(standard_id_migrations: { critical: true, name: :idp_migrations, timeout: 1 })

      expect(config.checks.last).to have_attributes(name: :idp_migrations, critical: true, timeout: 1)
    end

    it "skips one the app already registered under that name" do
      custom = Class.new(StandardHealth::Check)
      config.register_check(:standard_id_migrations, custom)

      expect(config.register_default_checks).to eq([:database])
      expect(config.checks.map(&:klass)).to eq([custom, StandardHealth::Checks::ActiveRecord])
    end

    it "accepts a contributed name as a keyword, and lists it among the known ones" do
      expect { config.register_default_checks(standard_id_migration: false) }
        .to raise_error(ArgumentError, /known: database, solid_queue, solid_cache, audit_retention, standard_id_migrations/)
    end

    it "builds and runs through the aggregator" do
      config.register_default_checks
      allow(StandardHealth).to receive(:config).and_return(config)

      rows = StandardHealth::Aggregator.call[:checks]

      expect(rows.map { |r| [r[:name], r[:status]] }).to include([:standard_id_migrations, :ok])
    end

    it "does not retroactively register a check contributed after the call, and warns" do
      config.register_default_checks

      expect { contributions.contribute_check :late, "Late" }.to output(/:late was contributed after/).to_stderr
      expect(config.checks.map(&:name)).not_to include(:late)
    end
  end

  # The hardcoded `audit_retention` entry stays until standard_audit
  # contributes it; the contribution must then take over, not double up.
  context "when standard_audit contributes audit_retention" do
    let(:contributions) { StandardHealth::Contributions.new }
    let(:config) { StandardHealth::Configuration.new(contributions: contributions) }

    before do
      stub_const("SolidQueue", Module.new)
      stub_const("SolidCache", Module.new)
      stub_const("StandardAudit::Checks::Retention", retention_class)
      contributions.contribute_check :standard_id_migrations, "StandardId::Checks::Migrations"
      contributions.contribute_check :audit_retention, "StandardAudit::Checks::Retention", timeout: 5
    end

    it "registers it once, from the contribution, in the built-in position" do
      expect(config.register_default_checks)
        .to eq(%i[database solid_queue solid_cache audit_retention standard_id_migrations])

      retention = config.checks.select { |r| r.name == :audit_retention }
      expect(retention.size).to eq(1)
      expect(retention.first).to have_attributes(klass: "StandardAudit::Checks::Retention", timeout: 5)
    end

    it "still honours the existing audit_retention keyword" do
      config.register_default_checks(audit_retention: false)

      expect(config.checks.map(&:name)).not_to include(:audit_retention)
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
