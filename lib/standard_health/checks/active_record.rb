# frozen_string_literal: true

require "standard_health/check"

module StandardHealth
  module Checks
    # Verifies the primary database connection by executing `SELECT 1`.
    # Critical by default — if the database is unreachable, the host app
    # cannot serve meaningful traffic.
    class ActiveRecord < Check
      def initialize(name: :active_record, critical: true)
        super
      end

      def run
        with_timing do
          ::ActiveRecord::Base.connection.execute("SELECT 1")
        end
      end
    end
  end
end
