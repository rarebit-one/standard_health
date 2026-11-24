# frozen_string_literal: true

# Stand-ins for the two StandardCircuit shapes standard_health must serve:
#
#   * 0.7.x — `health_report` only, and no dependency rows contributed.
#   * 0.8+  — `health_report` still there (the deprecated circuits fold-in),
#             plus rows contributed through `contribute_dependencies`.
#
# Rows go to a fresh Contributions registry that `StandardHealth.contributions`
# returns for the example, so nothing leaks into the process-wide registry.
module DependencyRowsHelpers
  def circuit_report(status: :ok, circuits: [])
    { status: status, circuits: circuits }
  end

  def stub_standard_circuit_07(report = circuit_report)
    circuit = Module.new
    circuit.define_singleton_method(:health_report) { report }
    stub_const("StandardCircuit", circuit)
  end

  def stub_standard_circuit_08(rows, report = circuit_report)
    stub_standard_circuit_07(report)
    contribute_rows(rows)
  end

  def contribute_rows(rows = nil, source: :standard_circuit, &reader)
    reader ||= -> { rows }
    isolated_contributions.contribute_dependencies(source, &reader)
  end

  def isolated_contributions
    @isolated_contributions ||= StandardHealth::Contributions.new.tap do |registry|
      allow(StandardHealth).to receive(:contributions).and_return(registry)
    end
  end

  def dependency_row(name, status: :ok, criticality: :standard, **extra)
    { name: name, status: status, criticality: criticality, **extra }
  end
end

RSpec.configure do |config|
  config.include DependencyRowsHelpers
end
