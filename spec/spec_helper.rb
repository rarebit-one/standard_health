# frozen_string_literal: true

ENV["RAILS_ENV"] ||= "test"

require File.expand_path("dummy/config/environment", __dir__)
require "rspec/rails"

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand config.seed

  # Reset StandardHealth config between examples so registered checks /
  # env_specs don't leak.
  config.before(:each) do
    StandardHealth.reset_config!
  end
end
