# frozen_string_literal: true

require "standard_health/check"

module StandardHealth
  module Checks
    # Verifies the Rails cache is reachable via a read-only probe.
    #
    # We deliberately don't write — a flapping cache shouldn't corrupt host
    # app cache state. If the read raises (connection refused, decoding
    # error, etc.), the check fails. Non-critical by default: a degraded
    # cache shouldn't pull the app out of rotation.
    class SolidCache < Check
      PROBE_KEY = "standard_health_probe"

      def initialize(name: :solid_cache, critical: false)
        super
      end

      def run
        with_timing do
          ::Rails.cache.read(PROBE_KEY)
        end
      end
    end
  end
end
