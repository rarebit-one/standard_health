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
  #     forbidden :DEMO_MODE_ENABLED, in: :live
  #     required :CSP_REPORT_ONLY, in: :live, expected_value: "false"
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
  #   - `level` (:required | :recommended | :forbidden)
  #   - `in:` (Array<String>, Symbol, or nil) — when an Array, the entry only
  #     applies while `APP_ENVIRONMENT` matches one of these modes. A Symbol
  #     is resolved against `mode_alias` declarations at audit time. When
  #     omitted, the entry applies to every mode.
  #   - `description:` (String, optional) — human-readable hint surfaced
  #     verbatim by `/diagnostics/env`.
  #   - `consumed_by:` (String or Array<String>, optional) — pointer(s) to
  #     where the value is read in the host app. Surfaced verbatim. When
  #     `audit` is called with `root:`, each path is checked for an
  #     `ENV[...]` / `ENV.fetch(...)` reference to the var; the result is
  #     reported as `consumer:` in the audit row
  #     (`:present`, `:file_missing`, or `:not_referenced`).
  #   - `if:` / `unless:` (Proc, optional) — predicates evaluated at audit
  #     time. When `unless:` returns truthy or `if:` returns falsy the entry
  #     is reported with `status: :not_applicable`.
  #   - `group` (String, optional) — set implicitly by enclosing `group`
  #     block; surfaced verbatim.
  #   - `deprecated:` (Boolean, optional) — flag for staged removal. When
  #     true, the audit row includes `deprecated: true`.
  #   - `sunset_on:` (String/Date, optional) — target removal date.
  #     Surfaced verbatim in audit rows.
  #   - `replacement:` (String, optional) — what to use instead. Surfaced
  #     in audit rows.
  #   - `expected_value:` (String/Symbol/Numeric/Regexp/Array, optional) —
  #     asserts the *value*, not just presence. A present value that does
  #     not match reports `status: :mismatch`. An Array means "any of".
  #     Surfaced in audit rows as `expected_value:` so an operator can see
  #     what was demanded; the actual value is deliberately NEVER surfaced
  #     (env values are frequently secrets).
  class EnvSpec
    # Raised when `in:` references a Symbol that hasn't been declared via
    # `mode_alias`.
    class UnknownModeAlias < ArgumentError; end

    # Levels whose absence is fine and whose *presence* is the failure.
    FORBIDDEN_LEVEL = :forbidden

    # Statuses that mean the environment is wrong, as opposed to merely
    # advisory (`:should_set`) or inapplicable (`:not_applicable`).
    #
    # Shared by `DiagnosticsController#audit_status` and the opt-in
    # `Checks::EnvSpecAudit`, so the doctor endpoint and the health check
    # cannot drift apart on what counts as a violation.
    VIOLATION_STATUSES = %i[missing forbidden mismatch].freeze

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
      :deprecated,
      :sunset_on,
      :replacement,
      :expected_value,
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
    # @param modes [Array<String>]
    def mode_alias(name, modes)
      @mode_aliases[name.to_sym] = Array(modes).map(&:to_s)
    end

    # Group subsequent declarations under a label. Pure metadata —
    # propagated to audit rows as `group:` and otherwise inert. Nested
    # `group` blocks are supported; the innermost label is the one that
    # propagates to enclosed entries.
    #
    # @param label [String]
    def group(label, &block)
      raise ArgumentError, "group requires a block" unless block

      @group_stack.push(label.to_s)
      block.call
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

    # Declare an env var that must NOT be set (in the applicable modes).
    # Inverts the presence rule: absent is `:ok`, present is `:forbidden`.
    #
    # This is the level for dangerous ops toggles — demo modes, auth
    # bypasses, bootstrap flags — that are legitimate on staging and must
    # never survive to production:
    #
    #   forbidden :DEMO_MODE_ENABLED, in: :live,
    #     description: "Demo surfaces; unset before promoting"
    #
    # `expected_value:` is meaningless here (the assertion is "absent"), so
    # combining them is a declaration error rather than a silently ignored
    # option. Raised at `define` time — i.e. host boot, well off the health
    # path — so it can never surface as a 500 from /ready.
    def forbidden(name, **opts)
      if opts.key?(:expected_value)
        raise ArgumentError,
              "`forbidden` asserts absence, so expected_value: is meaningless " \
              "(got #{opts[:expected_value].inspect} for #{name}). Use " \
              "`required ..., expected_value:` to assert a value instead."
      end

      add(FORBIDDEN_LEVEL, name, **opts)
    end

    # Run the audit against an env-like hash.
    #
    # @param env_hash [Hash{String, Symbol => String}] e.g. ENV.to_h
    # @param mode [String, Symbol] current APP_ENVIRONMENT value
    # @param root [String, Pathname, nil] host app root for resolving
    #   `consumed_by` paths. When given, each row gains a `consumer:` field:
    #   `:present` (file exists and references the var),
    #   `:file_missing` (path does not exist),
    #   `:not_referenced` (file exists but no `ENV[...]` / `ENV.fetch(...)`
    #   match for the var). When the entry has no `consumed_by` or `root`
    #   is nil, the field is omitted.
    # @return [Array<Hash>] one row per applicable entry. Each row has at
    #   least `name`, `level`, `status`, `mode`. When an entry is suppressed
    #   by an `if:`/`unless:` predicate, `status` is `:not_applicable` and a
    #   `reason` field explains why. `description`, `consumed_by`, `group`,
    #   `deprecated`, `sunset_on`, `replacement`, `expected_value`, and
    #   `consumer` are included when set on the entry / computed during audit.
    def audit(env_hash, mode:, root: nil)
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

        consumer_status = consumer_state(entry, root)
        row[:consumer] = consumer_status if consumer_status

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
        group: @group_stack.last,
        deprecated: opts[:deprecated] ? true : nil,
        sunset_on: opts[:sunset_on],
        replacement: opts[:replacement],
        expected_value: opts[:expected_value]
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

    # Builds the metadata-only portion of an audit row. The caller is
    # responsible for setting `:status` (and optionally `:reason`) — keeping
    # status off the base intentionally so a future code path that forgets
    # to set it produces a missing-key error instead of a silent `nil`.
    def base_row(entry, mode_str)
      row = { name: entry.name, level: entry.level, mode: mode_str }
      row[:description] = entry.description if entry.description
      row[:consumed_by] = serialize_consumed_by(entry.consumed_by) if entry.consumed_by
      row[:group] = entry.group if entry.group
      row[:deprecated] = true if entry.deprecated
      row[:sunset_on] = entry.sunset_on.to_s if entry.sunset_on
      row[:replacement] = entry.replacement if entry.replacement
      # The DECLARED expectation is safe to surface — it is config the host
      # wrote, not process state. The ACTUAL value is never surfaced: env
      # values are routinely secrets, and /diagnostics/env exists to report
      # that something is wrong, not to echo it back.
      row[:expected_value] = serialize_expected(entry.expected_value) unless entry.expected_value.nil?
      row
    end

    # Regexps have to become strings to survive JSON rendering; an Array of
    # candidates stays an Array so a caller can see every accepted value.
    def serialize_expected(expected)
      if expected.is_a?(Array)
        expected.map { |candidate| stringify_expected(candidate) }
      else
        stringify_expected(expected)
      end
    end

    def stringify_expected(candidate)
      candidate.is_a?(Regexp) ? candidate.inspect : candidate.to_s
    end

    # Resolve the consumer-presence state for an entry. Returns nil when
    # we have nothing to check (no root, no consumed_by). Otherwise:
    #
    #   :present        — at least one consumed_by path exists AND mentions
    #                     ENV["VAR"] or ENV.fetch("VAR", ...).
    #   :file_missing   — every consumed_by path is missing on disk.
    #   :not_referenced — at least one path exists, but none reference the
    #                     env var.
    def consumer_state(entry, root)
      return nil if root.nil? || entry.consumed_by.nil?

      pattern = env_reference_pattern(entry.name)
      any_file_present = false
      any_referenced = false

      entry.consumed_by.each do |relative|
        path = File.join(root.to_s, relative)
        next unless File.file?(path)

        any_file_present = true
        any_referenced = true if File.read(path).match?(pattern)
      end

      return :file_missing unless any_file_present
      any_referenced ? :present : :not_referenced
    end

    # Match ENV["VAR"], ENV['VAR'], ENV[:VAR], ENV.fetch("VAR", ...),
    # ENV.fetch('VAR', ...), ENV.fetch(:VAR, ...). Word-boundary on the
    # right so VAR_PREFIX doesn't accidentally match VAR.
    def env_reference_pattern(name)
      escaped = Regexp.escape(name.to_s)
      /ENV(?:\.fetch)?\s*[\[(]\s*[:'"]?#{escaped}\b/
    end

    def serialize_consumed_by(value)
      value.length == 1 ? value.first : value
    end

    # Resolve one entry against the value found in the env.
    #
    #   :forbidden  — a `forbidden` entry is set
    #   :missing    — a `required` entry is absent
    #   :should_set — a `recommended` entry is absent
    #   :mismatch   — present, but `expected_value:` says otherwise
    #   :ok         — everything else
    #
    # Presence is checked first for every level, because "absent" is
    # unambiguous: it satisfies `forbidden`, violates `required`, and there
    # is nothing for `expected_value:` to compare against.
    def classify(entry, value)
      present = !value.nil? && !value.to_s.empty?

      if entry.level == FORBIDDEN_LEVEL
        return present ? :forbidden : :ok
      end

      unless present
        return entry.level == :required ? :missing : :should_set
      end

      return :mismatch unless expected_value_satisfied?(entry, value)

      :ok
    end

    # Compare a present value against `expected_value:`. Comparison is on
    # the string form, since everything arriving from ENV is a String —
    # `expected_value: 5` matching `"5"` is the intuitive reading, and the
    # alternative (never matching) would be a silent trap.
    #
    # An Array means "any of". A Regexp is matched, not compared, which is
    # what makes value ranges and prefixes expressible.
    def expected_value_satisfied?(entry, value)
      expected = entry.expected_value
      return true if expected.nil?

      actual = value.to_s
      Array(expected).any? do |candidate|
        candidate.is_a?(Regexp) ? candidate.match?(actual) : candidate.to_s == actual
      end
    end

    def stringify(env_hash)
      env_hash.each_with_object({}) { |(k, v), h| h[k.to_s] = v }
    end
  end
end
