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

    it "keeps a nested group label (innermost wins, as in EnvSpec)" do
      registry.contribute_env_vars(:standard_singpass) do
        group("MyInfo") { required :MYINFO_CLIENT_ID }
      end

      expect(registry.env_spec.entries.first.group).to eq("MyInfo")
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
      registry.contribute_env_vars("standard_singpass") do
        recommended :SHARED, description: "second"
        required :MYINFO_CLIENT_ID
      end

      expect(registry.env_spec.entries.map { |e| [e.name, e.group, e.description] }).to eq([
        [:SHARED, "standard_id", "first"],
        [:MYINFO_CLIENT_ID, "standard_singpass", nil]
      ])
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
