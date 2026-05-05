# frozen_string_literal: true

require "spec_helper"

RSpec.describe StandardHealth::EnvSpec do
  describe "basic audit semantics" do
    it "reports :ok when a required var is set" do
      spec = described_class.define do
        required :SECRET_KEY_BASE
      end

      audit = spec.audit({ "SECRET_KEY_BASE" => "abc" }, mode: "production")

      expect(audit).to contain_exactly(
        hash_including(name: :SECRET_KEY_BASE, level: :required, status: :ok, mode: "production")
      )
    end

    it "reports :missing when a required var is unset" do
      spec = described_class.define { required :SECRET_KEY_BASE }

      audit = spec.audit({}, mode: "production")

      expect(audit.first).to include(name: :SECRET_KEY_BASE, status: :missing)
    end

    it "skips entries whose mode does not apply" do
      spec = described_class.define do
        required :PROD_ONLY_KEY, in: %w[production]
      end

      expect(spec.audit({}, mode: "development")).to be_empty
      expect(spec.audit({}, mode: "production").first).to include(status: :missing)
    end

    it "reports recommended-but-missing as :should_set, not :missing" do
      spec = described_class.define { recommended :SENTRY_DSN }

      audit = spec.audit({}, mode: "production")

      expect(audit.first).to include(name: :SENTRY_DSN, level: :recommended, status: :should_set)
    end

    it "treats blank strings as missing" do
      spec = described_class.define { required :TOKEN }

      audit = spec.audit({ "TOKEN" => "" }, mode: "production")

      expect(audit.first).to include(status: :missing)
    end

    it "passes description through to audit rows" do
      spec = described_class.define do
        recommended :SENTRY_DSN, description: "Error tracking"
      end

      audit = spec.audit({}, mode: "production")

      expect(audit.first).to include(description: "Error tracking")
    end
  end

  describe "if:/unless: predicates" do
    it "reports :not_applicable when unless: predicate is truthy" do
      spec = described_class.define do
        required :MYINFO_PRIVATE_JWKS, unless: -> { true }
      end

      audit = spec.audit({}, mode: "production")

      expect(audit.first).to include(
        name: :MYINFO_PRIVATE_JWKS,
        status: :not_applicable,
        reason: a_string_matching(/unless/)
      )
    end

    it "evaluates the entry normally when unless: predicate is falsy" do
      spec = described_class.define do
        required :MYINFO_PRIVATE_JWKS, unless: -> { false }
      end

      audit = spec.audit({}, mode: "production")

      expect(audit.first).to include(name: :MYINFO_PRIVATE_JWKS, status: :missing)
    end

    it "reports :not_applicable when if: predicate is falsy" do
      spec = described_class.define do
        recommended :SENTRY_DSN, if: -> { false }
      end

      audit = spec.audit({}, mode: "production")

      expect(audit.first).to include(
        name: :SENTRY_DSN,
        status: :not_applicable,
        reason: a_string_matching(/if/)
      )
    end

    it "evaluates the entry normally when if: predicate is truthy" do
      spec = described_class.define do
        recommended :SENTRY_DSN, if: -> { true }
      end

      audit = spec.audit({}, mode: "production")

      expect(audit.first).to include(name: :SENTRY_DSN, status: :should_set)
    end

    it "requires both if: (truthy) and unless: (falsy) for entry to evaluate" do
      spec = described_class.define do
        required :BOTH_OK, if: -> { true }, unless: -> { false }
        required :IF_FAILS, if: -> { false }, unless: -> { false }
        required :UNLESS_FAILS, if: -> { true }, unless: -> { true }
      end

      audit = spec.audit({}, mode: "production")
      by_name = audit.each_with_object({}) { |row, h| h[row[:name]] = row }

      expect(by_name[:BOTH_OK]).to include(status: :missing)
      expect(by_name[:IF_FAILS]).to include(status: :not_applicable, reason: a_string_matching(/if/))
      expect(by_name[:UNLESS_FAILS]).to include(status: :not_applicable, reason: a_string_matching(/unless/))
    end
  end

  describe "mode_alias" do
    it "resolves a Symbol passed to in: against declared aliases" do
      spec = described_class.define do
        mode_alias :deployed, %w[staging production]
        required :APP_HOST, in: :deployed
      end

      expect(spec.audit({}, mode: "development")).to be_empty
      expect(spec.audit({}, mode: "staging").first).to include(name: :APP_HOST, status: :missing)
      expect(spec.audit({ "APP_HOST" => "x" }, mode: "production").first).to include(status: :ok)
    end

    it "raises UnknownModeAlias when in: references an undefined Symbol" do
      spec = described_class.define do
        required :APP_HOST, in: :nonexistent
      end

      expect { spec.audit({}, mode: "production") }
        .to raise_error(StandardHealth::EnvSpec::UnknownModeAlias, /nonexistent/)
    end

    it "still accepts Array<String> for in:" do
      spec = described_class.define do
        required :APP_HOST, in: %w[production]
      end

      expect(spec.audit({}, mode: "production").first).to include(status: :missing)
    end

    it "lets a later mode_alias declaration override an earlier one (last writer wins)" do
      spec = described_class.define do
        mode_alias :deployed, %w[staging]
        mode_alias :deployed, %w[staging production]
        required :APP_HOST, in: :deployed
      end

      expect(spec.audit({}, mode: "staging").first).to include(name: :APP_HOST, status: :missing)
      expect(spec.audit({}, mode: "production").first).to include(name: :APP_HOST, status: :missing)
    end
  end

  describe "consumed_by:" do
    it "passes a String consumed_by through to audit rows verbatim" do
      spec = described_class.define do
        required :APP_HOST, consumed_by: "config/initializers/sentry.rb"
      end

      audit = spec.audit({ "APP_HOST" => "x" }, mode: "production")

      expect(audit.first).to include(consumed_by: "config/initializers/sentry.rb")
    end

    it "passes an Array<String> consumed_by through to audit rows verbatim" do
      spec = described_class.define do
        required :APP_HOST, consumed_by: %w[a.rb b.rb]
      end

      audit = spec.audit({ "APP_HOST" => "x" }, mode: "production")

      expect(audit.first).to include(consumed_by: %w[a.rb b.rb])
    end

    it "omits consumed_by from the row when not declared" do
      spec = described_class.define { required :APP_HOST }

      audit = spec.audit({}, mode: "production")

      expect(audit.first).not_to have_key(:consumed_by)
    end
  end

  describe "group blocks" do
    it "propagates the group label to enclosed entries" do
      spec = described_class.define do
        group "Singpass / MyInfo" do
          required :MYINFO_CLIENT_ID
        end
      end

      audit = spec.audit({}, mode: "production")

      expect(audit.first).to include(name: :MYINFO_CLIENT_ID, group: "Singpass / MyInfo")
    end

    it "omits the group key for entries declared outside any block" do
      spec = described_class.define do
        required :OUTSIDE
      end

      audit = spec.audit({}, mode: "production")

      expect(audit.first).not_to have_key(:group)
    end

    it "scopes the group label to the block boundary" do
      spec = described_class.define do
        group "A" do
          required :IN_A
        end
        required :OUTSIDE
      end

      by_name = spec.audit({}, mode: "production").each_with_object({}) { |row, h| h[row[:name]] = row }

      expect(by_name[:IN_A]).to include(group: "A")
      expect(by_name[:OUTSIDE]).not_to have_key(:group)
    end

    it "uses the innermost label when group blocks are nested" do
      spec = described_class.define do
        group "Outer" do
          group "Inner" do
            required :NESTED
          end
        end
      end

      audit = spec.audit({}, mode: "production")

      expect(audit.first).to include(name: :NESTED, group: "Inner")
    end

    it "raises ArgumentError when group is called without a block" do
      expect do
        described_class.define { group "Naked" }
      end.to raise_error(ArgumentError, /group requires a block/)
    end
  end

  describe "consumer presence (root:)" do
    let(:tmpdir) { Dir.mktmpdir }
    after { FileUtils.remove_entry(tmpdir) }

    def write_consumer(relative, body)
      path = File.join(tmpdir, relative)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, body)
    end

    it "reports :present when the consumed_by file references the var via ENV.fetch" do
      write_consumer("config/initializers/truemail.rb", %(ENV.fetch("TRUEMAIL_VERIFIER_EMAIL", "x")))
      spec = described_class.define do
        required :TRUEMAIL_VERIFIER_EMAIL, consumed_by: "config/initializers/truemail.rb"
      end

      audit = spec.audit({ "TRUEMAIL_VERIFIER_EMAIL" => "x" }, mode: "production", root: tmpdir)

      expect(audit.first).to include(consumer: :present)
    end

    it "reports :present when the file uses ENV[\"VAR\"] subscript syntax" do
      write_consumer("a.rb", 'ENV["MY_VAR"]')
      spec = described_class.define { required :MY_VAR, consumed_by: "a.rb" }

      audit = spec.audit({ "MY_VAR" => "x" }, mode: "production", root: tmpdir)

      expect(audit.first).to include(consumer: :present)
    end

    it "reports :present when the file uses ENV[:VAR] symbol subscript syntax" do
      write_consumer("a.rb", "ENV[:MY_VAR]")
      spec = described_class.define { required :MY_VAR, consumed_by: "a.rb" }

      audit = spec.audit({ "MY_VAR" => "x" }, mode: "production", root: tmpdir)

      expect(audit.first).to include(consumer: :present)
    end

    it "reports :not_referenced when the file exists but does not mention the var" do
      write_consumer("a.rb", '# nothing about ENV["OTHER_VAR"] here')
      spec = described_class.define { required :MY_VAR, consumed_by: "a.rb" }

      audit = spec.audit({ "MY_VAR" => "x" }, mode: "production", root: tmpdir)

      expect(audit.first).to include(consumer: :not_referenced)
    end

    it "reports :file_missing when the consumed_by path does not exist on disk" do
      spec = described_class.define { required :MY_VAR, consumed_by: "config/missing.rb" }

      audit = spec.audit({ "MY_VAR" => "x" }, mode: "production", root: tmpdir)

      expect(audit.first).to include(consumer: :file_missing)
    end

    it "reports :present when at least one of multiple consumed_by paths matches" do
      write_consumer("a.rb", "# nothing")
      write_consumer("b.rb", 'ENV.fetch("MY_VAR")')
      spec = described_class.define { required :MY_VAR, consumed_by: %w[a.rb b.rb] }

      audit = spec.audit({ "MY_VAR" => "x" }, mode: "production", root: tmpdir)

      expect(audit.first).to include(consumer: :present)
    end

    it "does not match a longer-named var that shares a prefix" do
      write_consumer("a.rb", 'ENV.fetch("MY_VAR_PREFIX")')
      spec = described_class.define { required :MY_VAR, consumed_by: "a.rb" }

      audit = spec.audit({ "MY_VAR" => "x" }, mode: "production", root: tmpdir)

      expect(audit.first).to include(consumer: :not_referenced)
    end

    it "omits the consumer field when root: is not provided" do
      spec = described_class.define { required :MY_VAR, consumed_by: "a.rb" }

      audit = spec.audit({ "MY_VAR" => "x" }, mode: "production")

      expect(audit.first).not_to have_key(:consumer)
    end

    it "omits the consumer field when consumed_by is not declared" do
      spec = described_class.define { required :MY_VAR }

      audit = spec.audit({ "MY_VAR" => "x" }, mode: "production", root: tmpdir)

      expect(audit.first).not_to have_key(:consumer)
    end
  end

  describe "deprecation metadata" do
    it "surfaces deprecated: true in the audit row" do
      spec = described_class.define { required :LEGACY_VAR, deprecated: true }

      audit = spec.audit({ "LEGACY_VAR" => "x" }, mode: "production")

      expect(audit.first).to include(deprecated: true)
    end

    it "omits deprecated key when not declared" do
      spec = described_class.define { required :NORMAL_VAR }

      audit = spec.audit({ "NORMAL_VAR" => "x" }, mode: "production")

      expect(audit.first).not_to have_key(:deprecated)
    end

    it "surfaces sunset_on as a string in the audit row" do
      spec = described_class.define do
        required :LEGACY_VAR, deprecated: true, sunset_on: "2026-12-31"
      end

      audit = spec.audit({ "LEGACY_VAR" => "x" }, mode: "production")

      expect(audit.first).to include(sunset_on: "2026-12-31")
    end

    it "surfaces replacement in the audit row" do
      spec = described_class.define do
        required :LEGACY_VAR, deprecated: true, replacement: "Use NEW_VAR instead"
      end

      audit = spec.audit({ "LEGACY_VAR" => "x" }, mode: "production")

      expect(audit.first).to include(replacement: "Use NEW_VAR instead")
    end

    it "treats deprecated: false / nil as undeclared" do
      spec = described_class.define do
        required :A, deprecated: false
        required :B, deprecated: nil
      end

      audit = spec.audit({ "A" => "x", "B" => "x" }, mode: "production")

      expect(audit[0]).not_to have_key(:deprecated)
      expect(audit[1]).not_to have_key(:deprecated)
    end
  end
end
