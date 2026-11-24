# frozen_string_literal: true

require "spec_helper"

RSpec.describe StandardHealth::Contributions do
  subject(:registry) { described_class.new }

  describe "#contribute_check" do
    it "records the check non-critical by default, keeping a String class name unresolved" do
      registry.contribute_check :standard_id_migrations, "StandardId::Checks::Migrations"

      expect(registry.checks.map(&:to_h)).to eq([
        { name: :standard_id_migrations, klass: "StandardId::Checks::Migrations",
          critical: false, timeout: nil, options: {} }
      ])
    end

    it "keeps criticality, timeout and constructor options" do
      registry.contribute_check "audit_schema", "StandardAudit::Checks::Schema", critical: true, timeout: 2, foo: 1

      expect(registry.checks.first).to have_attributes(name: :audit_schema, critical: true, timeout: 2, options: { foo: 1 })
    end

    it "replaces a re-contributed name in place" do
      registry.contribute_check :a, "A"
      registry.contribute_check :b, "B"
      registry.contribute_check :a, "A2", critical: true

      expect(registry.checks.map { |c| [c.name, c.klass] }).to eq([[:a, "A2"], [:b, "B"]])
    end

    it "refuses the names standard_health owns" do
      %i[database solid_queue solid_cache].each do |name|
        expect { registry.contribute_check name, "X" }
          .to raise_error(ArgumentError, /#{name.inspect} is a standard_health default check/)
      end
    end

    it "allows audit_retention, which standard_audit is expected to take over" do
      expect { registry.contribute_check :audit_retention, "StandardAudit::Checks::Retention" }.not_to raise_error
    end

    it "rejects something that is neither a class nor a class name" do
      expect { registry.contribute_check :x, 42 }.to raise_error(ArgumentError, /class name String/)
    end

    it "warns, and still records, a check contributed after register_default_checks ran" do
      registry.defaults_applied!

      expect { registry.contribute_check :late, "Late" }
        .to output(/check :late was contributed after register_default_checks ran/).to_stderr
      expect(registry.checks.map(&:name)).to eq([:late])
    end

    it "does not warn before register_default_checks ran" do
      expect { registry.contribute_check :early, "Early" }.not_to output.to_stderr
    end
  end

  describe "#contribute_env_vars" do
    it "groups every declaration under the contributor" do
      registry.contribute_env_vars "standard_id" do
        recommended :STANDARD_ID_OAUTH_SIGNING_KEY, description: "signing key"
        forbidden :STANDARD_ID_BYPASS_CODE, in: %w[production]
      end

      entries = registry.env_spec.entries
      expect(entries.map { |e| [e.name, e.level, e.modes, e.group] }).to eq([
        [:STANDARD_ID_OAUTH_SIGNING_KEY, :recommended, nil, "standard_id"],
        [:STANDARD_ID_BYPASS_CODE, :forbidden, ["production"], "standard_id"]
      ])
    end

    it "prefixes a nested group label with the contributor" do
      registry.contribute_env_vars(:standard_singpass) do
        required :SINGPASS_CLIENT_ID
        group("MyInfo") { required :MYINFO_CLIENT_ID }
      end

      expect(registry.env_spec.entries.map { |e| [e.name, e.group] }).to eq([
        [:SINGPASS_CLIENT_ID, "standard_singpass"],
        [:MYINFO_CLIENT_ID, "standard_singpass / MyInfo"]
      ])
    end

    it "rejects a mode alias in `in:`, because aliases belong to the app" do
      expect do
        registry.contribute_env_vars("standard_id") { forbidden :STANDARD_ID_BYPASS_CODE, in: :live }
      end.to raise_error(ArgumentError, /STANDARD_ID_BYPASS_CODE \(:live\).*plain environment names/)
    end

    it "rejects a mode_alias declaration" do
      expect do
        registry.contribute_env_vars("standard_id") do
          mode_alias :live, %w[production]
          forbidden :STANDARD_ID_BYPASS_CODE, in: %w[production]
        end
      end.to raise_error(ArgumentError, /declares mode_alias :live/)
    end

    it "needs a block" do
      expect { registry.contribute_env_vars("standard_id") }.to raise_error(ArgumentError, /needs a block/)
    end

    it "replaces a re-contribution from the same contributor" do
      registry.contribute_env_vars("standard_id") { required :OLD }
      registry.contribute_env_vars("standard_id") { required :NEW }

      expect(registry.env_spec.entries.map(&:name)).to eq([:NEW])
    end
  end

  describe "#env_spec" do
    it "is nil with no contributions" do
      expect(registry.env_spec).to be_nil
    end

    it "lists each var once, the first contributor winning" do
      registry.contribute_env_vars("standard_id") { required :SHARED, description: "first" }
      expect do
        registry.contribute_env_vars("standard_singpass") do
          recommended :SHARED, description: "second"
          required :MYINFO_CLIENT_ID
        end
      end.to output.to_stderr

      expect(registry.env_spec.entries.map { |e| [e.name, e.group, e.description] }).to eq([
        [:SHARED, "standard_id", "first"],
        [:MYINFO_CLIENT_ID, "standard_singpass", nil]
      ])
    end
  end

  describe "the same env var from two contributors" do
    before { registry.contribute_env_vars("standard_id") { required :SHARED } }

    it "warns, naming the var and both contributors" do
      expect { registry.contribute_env_vars("standard_singpass") { recommended :SHARED } }
        .to output(/env var SHARED is contributed by both "standard_id" and "standard_singpass"; "standard_id" contributed first/)
        .to_stderr
    end

    it "names the earlier contributor as the winner when it re-contributes the var" do
      fresh = described_class.new
      fresh.contribute_env_vars("standard_id") { required :OTHER }
      fresh.contribute_env_vars("standard_singpass") { recommended :SHARED }

      expect { fresh.contribute_env_vars("standard_id") { required :SHARED } }
        .to output(/both "standard_id" and "standard_singpass"; "standard_id" contributed first/).to_stderr
      expect(fresh.env_spec.entries.find { |e| e.name == :SHARED }.group).to eq("standard_id")
    end

    it "warns once per process, not again on a re-contribution or an audit" do
      expect { registry.contribute_env_vars("standard_singpass") { recommended :SHARED } }.to output.to_stderr

      expect do
        registry.contribute_env_vars("standard_singpass") { recommended :SHARED }
        registry.env_spec.audit({}, mode: "production")
      end.not_to output.to_stderr
    end

    it "does not warn when the vars differ" do
      expect { registry.contribute_env_vars("standard_singpass") { required :MYINFO_CLIENT_ID } }
        .not_to output.to_stderr
    end
  end

  describe "#contribute_dependencies" do
    it "records a reader per source, called only when the rows are read" do
      calls = 0
      registry.contribute_dependencies(:standard_circuit) { calls += 1; [] }

      expect(calls).to eq(0)
      expect(registry.dependency_readers.keys).to eq([:standard_circuit])
      expect(registry.dependency_readers[:standard_circuit].call).to eq([])
      expect(calls).to eq(1)
    end

    it "replaces a re-contributed source" do
      registry.contribute_dependencies("standard_circuit") { [{ name: "old" }] }
      registry.contribute_dependencies(:standard_circuit) { [{ name: "new" }] }

      expect(registry.dependency_readers.transform_values(&:call)).to eq(standard_circuit: [{ name: "new" }])
    end

    it "needs a block" do
      expect { registry.contribute_dependencies(:standard_circuit) }.to raise_error(ArgumentError, /needs a block/)
    end

    it "hands out a copy, so a reader of the registry cannot change it" do
      registry.dependency_readers[:intruder] = -> { [] }

      expect(registry.dependency_readers).to be_empty
    end
  end

  describe "#facade" do
    subject(:facade) { registry.facade }

    it "exposes only the contributor methods" do
      expect(facade.public_methods(false)).to contain_exactly(:contribute_check, :contribute_env_vars,
                                                              :contribute_dependencies)
      expect(facade).not_to respond_to(:dependency_readers)
      expect(facade).not_to respond_to(:checks)
      expect(facade).not_to respond_to(:env_spec)
      expect(facade).not_to respond_to(:defaults_applied!)
    end

    it "contributes to the registry" do
      facade.contribute_check :standard_id_migrations, "StandardId::Checks::Migrations", critical: true
      facade.contribute_env_vars("standard_id") { recommended :STANDARD_ID_OAUTH_SIGNING_KEY }
      facade.contribute_dependencies(:standard_circuit) { [] }

      expect(registry.dependency_readers.keys).to eq([:standard_circuit])
      expect(registry.checks.map { |c| [c.name, c.critical] }).to eq([[:standard_id_migrations, true]])
      expect(registry.env_spec.entries.map(&:name)).to eq([:STANDARD_ID_OAUTH_SIGNING_KEY])
    end

    it "keeps the readers out of reach of an instance_eval'd (arity-0) hook block" do
      expect { facade.instance_eval { checks } }.to raise_error(NameError, /checks/)
    end

    it "is what the load hook yields" do
      expect(StandardHealth.contributions.facade).to be_a(described_class::Facade)
    end
  end

  describe "StandardHealth.contributions" do
    it "survives reset_config!, which builds the new config over the same registry" do
      registry.contribute_check :standard_id_migrations, "StandardId::Checks::Migrations"
      allow(StandardHealth).to receive(:contributions).and_return(registry)

      StandardHealth.reset_config!
      hide_const("SolidQueue")
      hide_const("SolidCache")
      hide_const("StandardAudit")

      expect(StandardHealth.config.register_default_checks).to eq(%i[database standard_id_migrations])
    end
  end
end
