# frozen_string_literal: true

require_relative "lib/standard_health/version"

Gem::Specification.new do |spec|
  spec.name        = "standard_health"
  spec.version     = StandardHealth::VERSION
  spec.authors     = ["Jaryl Sim"]
  spec.email       = ["code@jaryl.dev"]
  spec.homepage    = "https://github.com/rarebit-one/standard_health"
  spec.summary     = "A drop-in health check and environment-spec engine for Rails 8 host apps."
  spec.description = "StandardHealth is a mountable Rails engine providing /alive, /ready, " \
                     "and /diagnostics/env endpoints, with a configuration block for registering " \
                     "custom checks and a DSL for declaring required and recommended environment variables."
  spec.license     = "MIT"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/rarebit-one/standard_health"
  spec.metadata["changelog_uri"] = "https://github.com/rarebit-one/standard_health/blob/main/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"] = "https://github.com/rarebit-one/standard_health/issues"

  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    Dir["{app,config,lib}/**/*", "MIT-LICENSE", "Rakefile", "README.md", "CHANGELOG.md"]
  end

  spec.required_ruby_version = ">= 3.4"

  spec.add_dependency "rails", "~> 8.0"
end
