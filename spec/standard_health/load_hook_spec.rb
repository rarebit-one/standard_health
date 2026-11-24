# frozen_string_literal: true

require "spec_helper"
require "open3"
require "json"
require "rbconfig"

# `ActiveSupport.on_load(:standard_health)` must reach the registry whether
# the contributing gem is required before standard_health or after it.
#
# Run in a fresh process: this one loaded standard_health long ago, so it
# cannot show the "hook registered first" order, and a real hook here would
# contribute to the process-wide registry every other example reads.
RSpec.describe "ActiveSupport.on_load(:standard_health)" do
  let(:script) do
    <<~RUBY
      require "json"
      require "active_support"

      # A gem required BEFORE standard_health (block takes the registry).
      yielded = nil
      ActiveSupport.on_load(:standard_health) do |health|
        yielded = [health.class.name, health.respond_to?(:checks)]
        health.contribute_check :early_check, "EarlyCheck", critical: true
        health.contribute_env_vars("early_gem") { recommended :EARLY_VAR }
      end

      require "rails"
      require "standard_health"

      # A gem required AFTER standard_health (arity-0 block, instance_eval'd).
      ActiveSupport.on_load(:standard_health) do
        contribute_check :late_check, "LateCheck"
        contribute_env_vars("late_gem") { forbidden :LATE_VAR, in: %w[production] }
      end

      # A gem that contributes dependency rows, guarded the way one that also
      # supports standard_health < 0.10 must be (standard_circuit >= 0.8).
      ActiveSupport.on_load(:standard_health) do |health|
        next unless health.respond_to?(:contribute_dependencies)

        health.contribute_dependencies(:rows_gem) { [{ name: "stripe", status: :ok, criticality: :critical }] }
      end

      StandardHealth.reset_config! # contributions must survive this
      names = StandardHealth.config.register_default_checks
      checks = StandardHealth.config.checks.to_h { |r| [r.name, [r.klass, r.critical?]] }
      env = StandardHealth.config.effective_env_spec.entries.map { |e| [e.name, e.group] }

      dependencies = StandardHealth::DependencyReport.call[:dependencies]

      puts JSON.generate(names: names, checks: checks, env: env, yielded: yielded, dependencies: dependencies)
    RUBY
  end

  it "fires hooks registered both before and after standard_health loads" do
    out, err, status = Open3.capture3(
      RbConfig.ruby, "-I", File.expand_path("../../lib", __dir__), "-e", script
    )
    expect(status).to be_success, err

    result = JSON.parse(out.lines.last)

    # No ActiveRecord / SolidQueue / SolidCache / standard_audit loaded here,
    # so only the contributed checks register.
    expect(result["names"]).to eq(%w[early_check late_check])
    expect(result["checks"]).to eq("early_check" => ["EarlyCheck", true], "late_check" => ["LateCheck", false])
    expect(result["env"]).to eq([%w[EARLY_VAR early_gem], %w[LATE_VAR late_gem]])
    # The hook sees the narrow facade, not the registry and its readers.
    expect(result["yielded"]).to eq(["StandardHealth::Contributions::Facade", false])
    expect(result["dependencies"]).to eq([{ "name" => "stripe", "status" => "ok", "criticality" => "critical" }])
  end
end
