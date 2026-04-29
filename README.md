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

- `in: %w[staging production]` — restricts the entry to those `APP_ENVIRONMENT` values; ignored otherwise. May also be a Symbol resolved via `mode_alias` (see below).
- `description: "..."` — surfaced verbatim in the audit JSON
- `consumed_by: "config/initializers/sentry.rb"` — pointer (or `Array<String>`) to where the value is read; surfaced verbatim
- `if: -> { ... }` / `unless: -> { ... }` — Proc predicates evaluated at audit time. When `unless:` returns truthy or `if:` returns falsy, the entry is reported with `status: :not_applicable`

Audit output (one row per applicable entry):

```json
{
  "name": "SECRET_KEY_BASE",
  "level": "required",
  "status": "ok",
  "mode": "production"
}
```

Possible `status` values are `ok`, `missing` (required + absent), `should_set` (recommended + absent), and `not_applicable` (suppressed by an `if:`/`unless:` predicate).

### Predicates: `if:` and `unless:`

Use predicates when an env var is only meaningful under runtime conditions that aren't expressible as a fixed list of `APP_ENVIRONMENT` values — e.g. when a host app supports a "mock mode" toggle.

```ruby
required :MYINFO_PRIVATE_JWKS,
  in: %w[production],
  unless: -> { ENV["MYINFO_MOCK_MODE"].present? }

recommended :SENTRY_DSN,
  if: -> { ENV["SENTRY_DISABLED"].blank? }
```

A suppressed entry surfaces as:

```json
{
  "name": "MYINFO_PRIVATE_JWKS",
  "level": "required",
  "status": "not_applicable",
  "reason": "unless predicate matched",
  "mode": "production"
}
```

The `reason` is `"unless predicate matched"` or `"if predicate did not match"`. Both predicates may be combined; the entry only evaluates when `if:` is truthy and `unless:` is falsy.

### Mode aliases: `mode_alias`

Declare reusable groupings of `APP_ENVIRONMENT` values inside the `define` block, then reference them as Symbols in `in:`. Common patterns ship as conventions (not built-ins): `:deployed` for staging-and-up, `:live` for production-only.

```ruby
StandardHealth::EnvSpec.define do
  mode_alias :deployed, %w[staging preview production]
  mode_alias :live,     %w[production]

  required :APP_ENVIRONMENT
  required :SENTRY_DSN,       in: :deployed
  required :STRIPE_LIVE_KEY,  in: :live
end
```

`in:` accepts:

- `nil` (omitted) — entry always applies
- `Array<String>` — literal mode list (existing behaviour)
- `Symbol` — resolved against `mode_alias` at audit time. An undeclared Symbol raises `StandardHealth::EnvSpec::UnknownModeAlias`.

### `description:` and `consumed_by:`

Both flow through to audit rows verbatim. `description:` is a human hint; `consumed_by:` points at the file(s) that read the value, which makes "what does this env var actually do" much faster to answer in incident response.

```ruby
required :APP_HOST,
  in: :deployed,
  description: "Canonical web host",
  consumed_by: "config/initializers/sentry.rb"
```

```json
{
  "name": "APP_HOST",
  "level": "required",
  "status": "ok",
  "mode": "production",
  "description": "Canonical web host",
  "consumed_by": "config/initializers/sentry.rb"
}
```

`consumed_by:` may be a String or `Array<String>`; an Array is preserved as a JSON array.

### Groups

Wrap related declarations in a `group "Label" do ... end` block to tag them with a category. Groups are pure metadata — they don't affect applicability, status, or evaluation order.

```ruby
StandardHealth::EnvSpec.define do
  group "Singpass / MyInfo" do
    required :MYINFO_CLIENT_ID
    required :MYINFO_PRIVATE_JWKS, unless: -> { ENV["MYINFO_MOCK_MODE"].present? }
  end

  group "Database" do
    required :DATABASE_URL, in: :deployed
  end
end
```

Audit rows for entries declared inside a `group` block carry a `group` key:

```json
{ "name": "MYINFO_CLIENT_ID", "level": "required", "status": "ok", "mode": "production", "group": "Singpass / MyInfo" }
```

Entries declared outside any `group` block omit the `group` key entirely.

### Backward compatibility

All v0.2.0 specs continue to produce identical audit output in v0.3.0. The new fields (`description`, `consumed_by`, `group`, `reason`) appear only when the corresponding feature is used; the new `:not_applicable` status only appears when a predicate suppresses an entry.

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

> **Note (Rails 7.1+):** the `only: :env` filter above raises `AbstractController::ActionNotFound` because `HealthController` (alive/ready) shares this parent and has no `:env` action. Use [Splitting auth between health and diagnostics](#splitting-auth-between-health-and-diagnostics) instead — that's why v0.2.0 added `diagnostics_parent_controller`.

For a more granular setup, mount the engine inside an authenticated route block in your host app's `routes.rb`.

### Splitting auth between health and diagnostics

The pattern above hits a snag on Rails 7.1+ when you want to protect *only* `/diagnostics/env`. Both `HealthController` and `DiagnosticsController` inherit from `parent_controller`, so a `before_action :authenticate, only: :env` on that single parent applies to both — and Rails raises `AbstractController::ActionNotFound` because `:env` doesn't exist on `HealthController`.

Pre-v0.2.0 the workaround was to disable the check on the host controller:

```ruby
class StandardHealthHostController < ActionController::API
  self.raise_on_missing_callback_actions = false # workaround
  http_basic_authenticate_with(name: ..., password: ..., only: :env)
end
```

From v0.2.0 onwards, point `diagnostics_parent_controller` at a separate base class instead. Only `DiagnosticsController` inherits from it, so the `only: :env` callback no longer leaks onto `HealthController`:

```ruby
# app/controllers/health_base_controller.rb
class HealthBaseController < ActionController::API
end

# app/controllers/diagnostics_base_controller.rb
class DiagnosticsBaseController < ActionController::API
  http_basic_authenticate_with(
    name: ENV.fetch("HEALTH_USER"),
    password: ENV.fetch("HEALTH_PASS")
  )
end

# config/initializers/standard_health.rb
StandardHealth.configure do |c|
  c.parent_controller = "HealthBaseController"
  c.diagnostics_parent_controller = "DiagnosticsBaseController"
end
```

Now `/health/alive` and `/health/ready` are unauthenticated (probe-friendly) while `/health/diagnostics/env` requires HTTP Basic — no `raise_on_missing_callback_actions` flag needed.

When `diagnostics_parent_controller` is unset, `DiagnosticsController` falls back to `parent_controller`, matching v0.1.0 behavior exactly.

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
