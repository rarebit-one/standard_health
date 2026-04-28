# frozen_string_literal: true

require "standard_health/check"

module StandardHealth
  module Checks
    # Verifies the SolidQueue backing store is reachable.
    #
    # SolidQueue can be configured to live on a dedicated database connection
    # (`config.solid_queue.connects_to`). When that's the case we run the
    # probe against `SolidQueue::Record.connection`. Otherwise we fall back
    # to the primary AR connection — which is exactly where the queue tables
    # live in single-DB setups.
    class SolidQueue < Check
      def initialize(name: :solid_queue, critical: true)
        super
      end

      def run
        with_timing do
          connection.execute("SELECT 1")
        end
      end

      private

      def connection
        if defined?(::SolidQueue::Record) && ::SolidQueue::Record.respond_to?(:connection)
          ::SolidQueue::Record.connection
        else
          ::ActiveRecord::Base.connection
        end
      end
    end
  end
end
