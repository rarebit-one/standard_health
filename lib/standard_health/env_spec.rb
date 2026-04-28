# frozen_string_literal: true

module StandardHealth
  # DSL for declaring required and recommended environment variables.
  #
  # Example:
  #
  #   StandardHealth::EnvSpec.define do
  #     required :SECRET_KEY_BASE
  #     required :APP_ENVIRONMENT, in: %w[staging production]
  #     recommended :SENTRY_DSN, description: "Error tracking DSN"
  #   end
  #
  # Each entry has:
  #   - `name` (Symbol)
  #   - `level` (:required | :recommended)
  #   - `modes` (Array<String>, optional) — when set, the entry only applies
  #     while `APP_ENVIRONMENT` matches one of these modes. Otherwise it
  #     applies to every mode.
  #   - `description` (String, optional) — human-readable hint surfaced
  #     verbatim by `/diagnostics/env`.
  class EnvSpec
    Entry = Struct.new(:name, :level, :modes, :description, keyword_init: true) do
      # Whether this entry's audit applies under the given runtime mode.
      # Entries without a `modes:` constraint always apply.
      def applies_to?(mode)
        return true if modes.nil? || modes.empty?
        modes.include?(mode.to_s)
      end
    end

    # @return [Array<Entry>]
    attr_reader :entries

    # Build a spec via the DSL.
    def self.define(&block)
      new.tap { |spec| spec.instance_eval(&block) if block }
    end

    def initialize
      @entries = []
    end

    # Declare a required env var.
    #
    # @param name [Symbol, String]
    # @param in [Array<String>, nil] limit applicability to these modes
    # @param description [String, nil]
    def required(name, **opts)
      add(:required, name, **opts)
    end

    # Declare a recommended env var. A missing value never fails the audit;
    # it surfaces as `:should_set`.
    def recommended(name, **opts)
      add(:recommended, name, **opts)
    end

    # Run the audit against an env-like hash.
    #
    # @param env_hash [Hash{String, Symbol => String}] e.g. ENV.to_h
    # @param mode [String, Symbol] current APP_ENVIRONMENT value
    # @return [Array<Hash>] one row per applicable entry, each shaped like:
    #   { name:, level:, status: :ok | :missing | :should_set, mode: }
    def audit(env_hash, mode:)
      mode_str = mode.to_s
      env = stringify(env_hash)

      @entries.each_with_object([]) do |entry, out|
        next unless entry.applies_to?(mode_str)

        value = env[entry.name.to_s]
        status = classify(entry, value)

        row = {
          name: entry.name,
          level: entry.level,
          status: status,
          mode: mode_str
        }
        row[:description] = entry.description if entry.description
        out << row
      end
    end

    private

    def add(level, name, in: nil, description: nil)
      modes = binding.local_variable_get(:in)
      @entries << Entry.new(
        name: name.to_sym,
        level: level,
        modes: modes ? Array(modes).map(&:to_s) : nil,
        description: description
      )
    end

    def classify(entry, value)
      present = !value.nil? && !value.to_s.empty?
      return :ok if present

      entry.level == :required ? :missing : :should_set
    end

    def stringify(env_hash)
      env_hash.each_with_object({}) { |(k, v), h| h[k.to_s] = v }
    end
  end
end
