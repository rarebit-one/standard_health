# frozen_string_literal: true

Rails.application.configure do
  config.enable_reloading = false
  config.eager_load = ENV["CI"].present?
  config.consider_all_requests_local = true
  config.cache_store = :null_store
  config.action_dispatch.show_exceptions = :rescuable
  config.active_support.deprecation = :stderr
  config.hosts << "www.example.com"
  config.secret_key_base = "dummy_test_secret_key_base"
end
