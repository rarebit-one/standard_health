# frozen_string_literal: true

module StandardHealth
  # Base class for health checks.
  #
  # Subclasses implement `#run`, returning a hash like:
  #
  #   { status: :ok, latency_ms: 3 }
  #
  # or
  #
  #   { status: :fail, error: "connection refused" }
  #
  # The `with_timing` helper wraps a block, captures latency, and converts
  # any unhandled `StandardError` into a `:fail` row so subclasses don't
  # have to repeat the pattern.
  class Check
    attr_reader :name, :critical

    def initialize(name:, critical: false)
      @name = name
      @critical = critical
    end

    def critical?
      !!@critical
    end

    # Subclasses override this. Default implementation reports an
    # unimplemented check rather than raising, so a misconfigured custom
    # check degrades gracefully instead of taking down /ready.
    def run
      { status: :fail, error: "not implemented" }
    end

    # Wrap a block: time it, return :ok with latency_ms on success, or
    # :fail with the error message on any StandardError. Useful for
    # check implementations that boil down to "run this query, swallow
    # exceptions, report status".
    def with_timing
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      yield
      latency_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000).round
      { status: :ok, latency_ms: latency_ms }
    rescue StandardError => e
      { status: :fail, error: e.message }
    end
  end
end
