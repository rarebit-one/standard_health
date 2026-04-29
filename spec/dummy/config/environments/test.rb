# frozen_string_literal: true

Rails.application.configure do
  # Reloading is enabled so the diagnostics-parent-controller spec can
  # rebuild the engine controller inheritance chain mid-suite when
  # exercising different `parent_controller` / `diagnostics_parent_controller`
  # combinations. Eager loading and reloading are mutually exclusive in
  # Rails, so we keep eager_load off in tests (it's only useful in CI to
  # surface autoload issues, which our explicit specs cover anyway).
  config.enable_reloading = true
  config.eager_load = false
  config.consider_all_requests_local = true
  config.cache_store = :null_store
  config.action_dispatch.show_exceptions = :rescuable
  config.active_support.deprecation = :stderr
  config.hosts << "www.example.com"
  config.secret_key_base = "dummy_test_secret_key_base"
end
