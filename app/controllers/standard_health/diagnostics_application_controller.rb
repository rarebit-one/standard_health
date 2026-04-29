# frozen_string_literal: true

module StandardHealth
  # Separate base class for `DiagnosticsController` so host apps can target
  # diagnostics-only auth at this class via `diagnostics_parent_controller`.
  # When `diagnostics_parent_controller` is unset, this resolves to the same
  # class as `parent_controller`, so the inheritance chain is behaviorally
  # identical to v0.1.0.
  class DiagnosticsApplicationController < diagnostics_parent_controller
  end
end
