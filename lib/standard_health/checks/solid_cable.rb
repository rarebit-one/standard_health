# frozen_string_literal: true

require "standard_health/check"

module StandardHealth
  module Checks
    # Verifies the SolidCable / ActionCable backing store is reachable.
    #
    # SolidCable persists messages in `solid_cable_messages`. The probe is a
    # bounded read against that table, which confirms both that the cable
    # schema is migrated and that the connection it lives on is up.
    #
    # Promoted from sidekick-web's `SolidCableCheck`, which was one of four
    # host-local copies of a check the gem should have shipped.
    #
    # NOT REGISTERED AUTOMATICALLY. Registering it would be a behaviour change
    # on `bundle update`: every host without SolidCable installed — or with the
    # table not yet migrated — would start reporting a failing check, turning
    # the aggregate tier yellow across the estate for a check nobody asked for.
    # New checks in this gem are opt-in for that reason.
    #
    #   c.register_check :solid_cable, StandardHealth::Checks::SolidCable
    #
    # NON-CRITICAL BY DEFAULT, deliberately: cable is a degradable feature
    # dependency. A broken cable store should mark the app `degraded`, never
    # pull an instance out of rotation — so prefer this on the AGGREGATE tier
    # rather than in readiness.
    class SolidCable < Check
      def initialize(name: :solid_cable, critical: false)
        super
      end

      def run
        with_timing do
          connection.select_value("SELECT 1 FROM solid_cable_messages LIMIT 1")
        end
      end

      private

      # SolidCable may or may not be pointed at a separate database
      # (`SolidCable::Record.connects_to`). When it isn't configured, the table
      # lives on the primary connection, so fall back to it rather than failing
      # a host that simply didn't split the database out.
      def connection
        if defined?(::SolidCable::Record) && ::SolidCable::Record.respond_to?(:connection)
          ::SolidCable::Record.connection
        else
          ::ActiveRecord::Base.connection
        end
      end
    end
  end
end
