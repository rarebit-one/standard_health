# frozen_string_literal: true

module StandardHealth
  # Reads the dependency rows other gems contributed
  # (`Contributions#contribute_dependencies`) and rolls them up, for the
  # aggregate tier and, when `config.ready_dependencies` is on, for /ready.
  #
  # A row, as rendered (string keys in JSON):
  #
  #   { name: "stripe", status: :degraded, criticality: :critical,
  #     affected_purposes: ["checkout"], reasons: ["error_rate"],
  #     metrics_only: false,
  #     circuits: [{ name: "stripe", color: "green", locked: false }],
  #     measurements: { "stripe:errorRate" => 0.18, "stripe:p95Ms" => 2140, ... } }
  #
  # Only the keys in ROW_KEYS are rendered. The body is anonymous, so a
  # contributor cannot put an exception message or anything else into it by
  # adding a key. `probe` is reserved for a cached active-probe result.
  #
  # Roll-up:
  #   :unavailable — a :critical row reports :unavailable
  #   :degraded    — any row reports :degraded, or a non-critical row reports
  #                  :unavailable (clamped: only critical rows can fail a tier)
  #   :ok          — otherwise, including no rows
  #
  # An unknown status reads as :degraded, never :ok. Never raises (see
  # .claude/rules/never-raise.md): a reader that raises, or returns something
  # that is not an Array of Hashes with a name, degrades the section and
  # reports `error: { error_class, error_code }`.
  module DependencyReport
    STATUSES = %i[ok degraded unavailable].freeze
    CRITICALITIES = %i[critical standard optional].freeze
    ROW_KEYS = %i[name status criticality affected_purposes reasons metrics_only circuits measurements probe].freeze
    CIRCUIT_KEYS = %i[name color locked].freeze

    module_function

    # @return [Hash, nil] `{ status:, dependencies: [...] }`, plus `error:` and
    #   `error_message:` when a reader failed; nil when no gem contributed
    #   dependency rows (the caller then omits the section).
    def call(contributions: StandardHealth.contributions)
      readers = contributions.dependency_readers
      return nil if readers.empty?

      rows = []
      error = nil
      readers.each do |source, reader|
        rows.concat(read(source, reader))
      rescue StandardError => e
        error ||= e
      end

      report = { status: roll_up(rows), dependencies: rows }
      return report unless error

      report[:status] = worse(report[:status], :degraded)
      report[:error] = { error_class: error.class.name, error_code: Redactor.error_code_for(error.class.name) }
      report[:error_message] = error.message
      report
    end

    def read(source, reader)
      result = reader.call
      raise TypeError, "#{source} dependency rows must be an Array; got #{result.class}" unless result.is_a?(Array)

      result.map { |row| normalize(source, row) }
    end

    def normalize(source, row)
      raise TypeError, "#{source} dependency row must be a Hash; got #{row.class}" unless row.is_a?(Hash)

      row = row.transform_keys(&:to_sym)
      raise ArgumentError, "#{source} dependency row has no name" if row[:name].to_s.empty?

      normalized = row.slice(*ROW_KEYS)
      normalized[:name] = row[:name].to_s
      normalized[:criticality] = symbol_in(row[:criticality], CRITICALITIES, :standard)
      normalized[:status] = clamp(symbol_in(row[:status], STATUSES, :degraded), normalized[:criticality])
      normalized[:circuits] = Array(row[:circuits]).map { |c| c.to_h.transform_keys(&:to_sym).slice(*CIRCUIT_KEYS) } if row.key?(:circuits)
      normalized
    end

    # Only a critical dependency can fail a tier.
    def clamp(status, criticality)
      status == :unavailable && criticality != :critical ? :degraded : status
    end

    def symbol_in(value, allowed, fallback)
      symbol = value.respond_to?(:to_sym) ? value.to_sym : nil
      allowed.include?(symbol) ? symbol : fallback
    end

    def roll_up(rows)
      rows.map { |row| row[:status] }.reduce(:ok) { |worst, status| worse(worst, status) }
    end

    def worse(left, right)
      STATUSES.index(right) > STATUSES.index(left) ? right : left
    end

    # Names of the rows that are not :ok, for evaluation events.
    def failing_names(rows)
      rows.reject { |row| row[:status] == :ok }.map { |row| row[:name] }
    end
  end
end
