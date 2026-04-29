# frozen_string_literal: true

module StandardHealth
  # DSL for declaring required and recommended environment variables.
  #
  # Example:
  #
  #   StandardHealth::EnvSpec.define do
  #     mode_alias :deployed, %w[staging preview production]
  #     mode_alias :live, %w[production]
  #
  #     required :SECRET_KEY_BASE
  #     required :APP_ENVIRONMENT, in: %w[staging production]
  #     recommended :SENTRY_DSN, description: "Error tracking DSN"
  #
  #     group "Singpass / MyInfo" do
  #       required :MYINFO_CLIENT_ID
  #       required :MYINFO_PRIVATE_JWKS,
  #         in: :live,
  #         unless: -> { ENV["MYINFO_MOCK_MODE"].present? }
  #     end
  #   end
  #
  # Each entry has:
  #   - `name` (Symbol)
  #   - `level` (:required | :recommended)
  #   - `in:` (Array<String>, Symbol, or nil) — when an Array, the entry only
  #     applies while `APP_ENVIRONMENT` matches one of these modes. A Symbol
  #     is resolved against `mode_alias` declarations at audit time. When
  #     omitted, the entry applies to every mode.
  #   - `description:` (String, optional) — human-readable hint surfaced
  #     verbatim by `/diagnostics/env`.
  #   - `consumed_by:` (String or Array<String>, optional) — pointer(s) to
  #     where the value is read in the host app. Surfaced verbatim.
  #   - `if:` / `unless:` (Proc, optional) — predicates evaluated at audit
  #     time. When `unless:` returns truthy or `if:` returns falsy the entry
  #     is reported with `status: :not_applicable`.
  #   - `group` (String, optional) — set implicitly by enclosing `group`
  #     block; surfaced verbatim.
  class EnvSpec
    # Raised when `in:` references a Symbol that hasn't been declared via
    # `mode_alias`.
    class UnknownModeAlias < ArgumentError; end

    # Internal entry record. `modes` may be an Array<String> or a Symbol
    # alias that gets resolved at audit time.
    Entry = Struct.new(
      :name,
      :level,
      :modes,
      :description,
      :consumed_by,
      :if_predicate,
      :unless_predicate,
      :group,
      keyword_init: true
    )

    # @return [Array<Entry>]
    attr_reader :entries

    # @return [Hash{Symbol => Array<String>}]
    attr_reader :mode_aliases

    # Build a spec via the DSL.
    def self.define(&block)
      new.tap { |spec| spec.instance_eval(&block) if block }
    end

    def initialize
      @entries = []
      @mode_aliases = {}
      @group_stack = []
    end

    # Declare a mode alias usable in `in:`. Re-declaring overrides the
    # previous value (last writer wins) so layered specs are easy to compose.
    #
    # @param name [Symbol]
    # @param modes [Array<String, Symbol>]
    def mode_alias(name, modes)
      @mode_aliases[name.to_sym] = Array(modes).map(&:to_s)
    end

    # Group subsequent declarations under a label. Pure metadata —
    # propagated to audit rows as `group:` and otherwise inert.
    #
    # @param label [String]
    def group(label)
      @group_stack.push(label.to_s)
      yield
    ensure
      @group_stack.pop
    end

    # Declare a required env var.
    #
    # @param name [Symbol, String]
    # @param in [Array<String>, Symbol, nil] limit applicability to these modes
    # @param description [String, nil]
    # @param consumed_by [String, Array<String>, nil]
    # @param if [Proc, nil]
    # @param unless [Proc, nil]
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
    # @return [Array<Hash>] one row per applicable entry. Each row has at
    #   least `name`, `level`, `status`, `mode`. When an entry is suppressed
    #   by an `if:`/`unless:` predicate, `status` is `:not_applicable` and a
    #   `reason` field explains why. `description`, `consumed_by`, and
    #   `group` are included when set on the entry.
    def audit(env_hash, mode:)
      mode_str = mode.to_s
      env = stringify(env_hash)

      @entries.each_with_object([]) do |entry, out|
        next unless mode_applies?(entry, mode_str)

        row = base_row(entry, mode_str)

        suppression = predicate_suppression(entry)
        if suppression
          row[:status] = :not_applicable
          row[:reason] = suppression
        else
          value = env[entry.name.to_s]
          row[:status] = classify(entry, value)
        end

        out << row
      end
    end

    private

    def add(level, name, **opts)
      modes_opt = opts[:in]
      @entries << Entry.new(
        name: name.to_sym,
        level: level,
        modes: normalize_modes(modes_opt),
        description: opts[:description],
        consumed_by: normalize_consumed_by(opts[:consumed_by]),
        if_predicate: opts[:if],
        unless_predicate: opts[:unless],
        group: @group_stack.last
      )
    end

    def normalize_modes(modes_opt)
      return nil if modes_opt.nil?
      return modes_opt if modes_opt.is_a?(Symbol)
      Array(modes_opt).map(&:to_s)
    end

    def normalize_consumed_by(value)
      return nil if value.nil?
      array = Array(value).map(&:to_s)
      array.empty? ? nil : array
    end

    def mode_applies?(entry, mode_str)
      modes = resolve_modes(entry.modes)
      return true if modes.nil? || modes.empty?
      modes.include?(mode_str)
    end

    def resolve_modes(modes)
      return nil if modes.nil?
      if modes.is_a?(Symbol)
        unless @mode_aliases.key?(modes)
          raise UnknownModeAlias, "Unknown mode alias: #{modes.inspect}"
        end
        @mode_aliases[modes]
      else
        modes
      end
    end

    def predicate_suppression(entry)
      if entry.unless_predicate && entry.unless_predicate.call
        return "unless predicate matched"
      end
      if entry.if_predicate && !entry.if_predicate.call
        return "if predicate did not match"
      end
      nil
    end

    def base_row(entry, mode_str)
      row = {
        name: entry.name,
        level: entry.level,
        status: nil,
        mode: mode_str
      }
      row[:description] = entry.description if entry.description
      row[:consumed_by] = serialize_consumed_by(entry.consumed_by) if entry.consumed_by
      row[:group] = entry.group if entry.group
      row
    end

    def serialize_consumed_by(value)
      value.length == 1 ? value.first : value
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
