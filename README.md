# StandardHealth

A drop-in health check and environment-spec engine for Rails 8 host apps.

Mount it once and you get:

- `GET /health/alive` — liveness probe (always 200 if Rails is up)
- `GET /health/ready` — readiness probe; runs every registered check and rolls them up into an overall status
- `GET /health/diagnostics/env` — audits the host app's `ENV` against a declarative spec

Built-in checks cover ActiveRecord, SolidQueue, and SolidCache. Host apps can register additional checks via the configuration block.

## Installation

Add to your Gemfile:

```ruby
gem "standard_health"
```

Then `bundle install`.

## Mounting

In `config/routes.rb`:

```ruby
mount StandardHealth::Engine => "/health"
```

This wires up:

- `GET /health/alive`
- `GET /health/ready`
- `GET /health/diagnostics/env`

## Configuration

Create `config/initializers/standard_health.rb`:

```ruby
StandardHealth.configure do |c|
  # Controllers under StandardHealth inherit from this class. Use a host
  # app controller to apply auth before_actions to every endpoint.
  c.parent_controller = "ApplicationController"

  # Register checks. The first argument is a short name surfaced in JSON;
  # `critical: true` means a failure flips overall status to :unavailable.
  c.register_check :database, StandardHealth::Checks::ActiveRecord, critical: true
  c.register_check :solid_queue, StandardHealth::Checks::SolidQueue, critical: true
  c.register_check :solid_cache, StandardHealth::Checks::SolidCache, critical: false

  # Declare the env vars your app expects.
  c.env_spec = StandardHealth::EnvSpec.define do
    required :SECRET_KEY_BASE
    required :APP_ENVIRONMENT, in: %w[staging production]
    required :DATABASE_URL,    in: %w[production]
    recommended :SENTRY_DSN, description: "Error tracking DSN"
  end
end
```

## EnvSpec

The DSL has two declarations:

- `required :NAME` — missing value reports `status: :missing`
- `recommended :NAME` — missing value reports `status: :should_set`

Both accept:

- `in: %w[staging production]` — restricts the entry to those `APP_ENVIRONMENT` values; ignored otherwise
- `description: "..."` — surfaced verbatim in the audit JSON

Audit output (one row per applicable entry):

```json
{
  "name": "SECRET_KEY_BASE",
  "level": "required",
  "status": "ok",
  "mode": "production"
}
```

Possible `status` values are `ok`, `missing` (required + absent), and `should_set` (recommended + absent).

## Custom checks

Inherit from `StandardHealth::Check` and implement `#run`:

```ruby
class RedisCheck < StandardHealth::Check
  def run
    with_timing { Redis.current.ping }
  end
end

StandardHealth.configure do |c|
  c.register_check :redis, RedisCheck, critical: false
end
```

`with_timing` captures `latency_ms` on success and converts any `StandardError` into `{ status: :fail, error: <message> }`.

## Auth

`/alive` and `/ready` are typically left open for orchestrator probes. `/diagnostics/env` enumerates which env vars are missing — that's potentially sensitive, so the host app is responsible for protecting it.

The recommended pattern is to point `parent_controller` at a host app controller that enforces auth:

```ruby
# app/controllers/internal_health_controller.rb
class InternalHealthController < ActionController::API
  http_basic_authenticate_with(
    name: ENV.fetch("HEALTH_USER"),
    password: ENV.fetch("HEALTH_PASS"),
    only: :env # only protect diagnostics
  )
end

# config/initializers/standard_health.rb
StandardHealth.configure do |c|
  c.parent_controller = "InternalHealthController"
end
```

For a more granular setup, mount the engine inside an authenticated route block in your host app's `routes.rb`.

## Status semantics

`/ready` returns:

| Overall status | HTTP code | Meaning |
|---|---|---|
| `ok` | 200 | All checks passed |
| `degraded` | 200 | A non-critical check failed |
| `unavailable` | 503 | A critical check failed |

The orchestrator should pull the instance out of rotation only on 503; degraded means "still serving, page someone."

## License

MIT.
