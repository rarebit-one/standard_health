# frozen_string_literal: true

require "spec_helper"

RSpec.describe StandardHealth::Aggregator do
  let(:ok_check) do
    Class.new(StandardHealth::Check) do
      def run
        { status: :ok, latency_ms: 1 }
      end
    end
  end

  let(:fail_check) do
    Class.new(StandardHealth::Check) do
      def run
        { status: :fail, error: "boom" }
      end
    end
  end

  let(:raising_check) do
    Class.new(StandardHealth::Check) do
      def run
        raise "kaboom"
      end
    end
  end

  it "rolls up to :ok when every check is ok" do
    StandardHealth.config.register_check(:a, ok_check)
    StandardHealth.config.register_check(:b, ok_check)

    result = described_class.call

    expect(result[:status]).to eq(:ok)
    expect(result[:checks].map { |c| c[:name] }).to contain_exactly(:a, :b)
    expect(result[:generated_at]).to match(/\A\d{4}-\d{2}-\d{2}T/)
  end

  it "is :degraded when a non-critical check fails" do
    StandardHealth.config.register_check(:a, ok_check, critical: true)
    StandardHealth.config.register_check(:b, fail_check, critical: false)

    result = described_class.call

    expect(result[:status]).to eq(:degraded)
  end

  it "is :unavailable when a critical check fails" do
    StandardHealth.config.register_check(:a, fail_check, critical: true)

    result = described_class.call

    expect(result[:status]).to eq(:unavailable)
  end

  it "treats raised exceptions as :fail without crashing" do
    StandardHealth.config.register_check(:a, raising_check, critical: false)

    result = described_class.call

    expect(result[:status]).to eq(:degraded)
    expect(result[:checks].first).to include(status: :fail, error: "kaboom")
  end

  it "is :ok with no registered checks" do
    expect(described_class.call[:status]).to eq(:ok)
  end

  # 0.7.1: a check that REPORTS :skipped is saying "not applicable here", and
  # that is neutral in the roll-up. sidekick-web's non-critical attestation
  # check held /health at "degraded" permanently while attestation simply was
  # not configured. (A BUDGET skip is different — see the instrumentation spec.)
  describe "a check that reports :skipped itself" do
    let(:skipped_check) do
      Class.new(StandardHealth::Check) do
        def run
          { status: :skipped, latency_ms: 0 }
        end
      end
    end

    it "does not degrade the roll-up when non-critical, and stays visible in checks" do
      StandardHealth.config.register_check(:database, ok_check, critical: true)
      StandardHealth.config.register_check(:attestation, skipped_check, critical: false)

      result = described_class.call

      expect(result[:status]).to eq(:ok)
      expect(result[:checks].last).to include(name: :attestation, status: :skipped, critical: false)
      expect(result[:checks].last).not_to have_key(:budget_exhausted)
    end

    # Deliberate: "not applicable" says nothing about whether the instance can
    # serve, so a critical skip must not pull it out of rotation either.
    it "is neutral when critical too — neither :unavailable nor :degraded" do
      StandardHealth.config.register_check(:replica, skipped_check, critical: true)

      expect(described_class.call[:status]).to eq(:ok)
    end

    it "is :ok when every check is skipped" do
      StandardHealth.config.register_check(:a, skipped_check)
      StandardHealth.config.register_check(:b, skipped_check, critical: true)

      expect(described_class.call[:status]).to eq(:ok)
    end

    it "still degrades on a real non-critical failure alongside it" do
      StandardHealth.config.register_check(:attestation, skipped_check, critical: true)
      StandardHealth.config.register_check(:cache, fail_check, critical: false)

      expect(described_class.call[:status]).to eq(:degraded)
    end

    it "still reaches :unavailable on a real critical failure alongside it" do
      StandardHealth.config.register_check(:attestation, skipped_check, critical: false)
      StandardHealth.config.register_check(:database, fail_check, critical: true)

      expect(described_class.call[:status]).to eq(:unavailable)
    end
  end

  # The opt-in checks added in 0.5.0 are host-registered, and the never-raise
  # rule has to hold for them the same as for the built-ins. These assert it
  # END-TO-END through the aggregator, not just at the check's own `run`.
  describe "never-raise holds for the opt-in 0.5.0 checks" do
    around do |example|
      StandardHealth.reset_config!
      example.run
      StandardHealth.reset_config!
    end

    it "still answers when EnvSpecAudit's underlying audit raises" do
      StandardHealth.config.env_spec = StandardHealth::EnvSpec.define do
        required :ANYTHING, if: -> { raise "predicate blew up" }
      end
      StandardHealth.config.register_check(
        :env_spec, StandardHealth::Checks::EnvSpecAudit
      )

      result = nil
      expect { result = described_class.call }.not_to raise_error

      expect(result[:status]).to eq(:degraded)
      expect(result[:checks].first).to include(name: :env_spec, status: :fail)
    end

    it "still answers when SolidCable's connection raises" do
      allow(::ActiveRecord::Base).to receive(:connection).and_raise(StandardError, "no db")
      StandardHealth.config.register_check(
        :solid_cable, StandardHealth::Checks::SolidCable
      )

      result = nil
      expect { result = described_class.call }.not_to raise_error

      expect(result[:status]).to eq(:degraded)
      expect(result[:checks].first).to include(name: :solid_cable, status: :fail)
    end

    it "reaches :unavailable, not an exception, when a raising opt-in check is critical" do
      allow(::ActiveRecord::Base).to receive(:connection).and_raise(StandardError, "no db")
      StandardHealth.config.register_check(
        :solid_cable, StandardHealth::Checks::SolidCable, critical: true
      )

      result = nil
      expect { result = described_class.call }.not_to raise_error

      expect(result[:status]).to eq(:unavailable)
    end
  end
end
