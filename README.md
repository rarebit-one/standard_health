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

Then `bundle install`, and run the install generator:

```bash
bin/rails generate standard_health:install
```

It writes `config/initializers/standard_health.rb` and mounts the engine in
`config/routes.rb` with the ordering requirement below noted inline. It is
idempotent — re-running skips what is already installed. Flags:
`--skip-initializer`, `--skip-routes`, `--force` (overwrite the initializer).

## Mounting

In `config/routes.rb`:

```ruby
mount StandardHealth::Engine => "/health"
```

This wires up:

- `GET /health/alive`
- `GET /health/ready`
- `GET /health/diagnostics/env`

### The aggregate `GET /health` is yours to draw — before the mount

**The engine draws sub-paths only.** There is no `GET /health` in
`config/routes.rb` here; the aggregate tier is the host's responsibility, and
the ordering is not optional:

```ruby
get "/health", to: "health_aggregate#show"          # aggregate — FIRST
mount StandardHealth::Engine => "/health", as: :standard_health
```

An app that mounts the engine **first** and relies on it to serve the aggregate
tier **silently has no aggregate tier at all** — no boot error, no 404 at boot,
and no failing route spec unless one exists. The failure surfaces as a
dashboard that has been reading nothing for months. Add a route spec asserting
`GET /health` resolves.

Why this way round: `mount` claims the `/health` prefix, so a bare `GET /health`
drawn *after* it still resolves (the engine has no route for the bare path) —
but nothing about that is obvious from reading the file, and getting it
backwards fails silently either way. Draw it first and the ordering question
never arises.

The four tiers, and what each is for:

| Route | Tier | Consumer |
|---|---|---|
| `GET /health/alive` | liveness — process is up | restart probes, CI reachability gates |
| `GET /health/ready` | readiness — **rotation gate** | load balancer / platform health check |
| `GET /health` | aggregate — full picture | dashboards, humans |
| `GET /health/diagnostics/env` | doctor (authed) | on-call, config audits |

Readiness gates **only** on hard infra the app owns. A soft upstream that
degrades must not pull an instance out of rotation — put those on the aggregate
tier instead.

## Configuration

Create `config/initializers/standard_health.rb` (or let the generator write it):

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

The DSL has three declarations:

- `required :NAME` — missing value reports `status: :missing`
- `recommended :NAME` — missing value reports `status: :should_set`
- `forbidden :NAME` — **present** value reports `status: :forbidden`; absent is `:ok`

All three accept:

- `in: %w[staging production]` — restricts the entry to those `APP_ENVIRONMENT` values; ignored otherwise. May also be a Symbol resolved via `mode_alias` (see below).
- `description: "..."` — surfaced verbatim in the audit JSON
- `consumed_by: "config/initializers/sentry.rb"` — pointer (or `Array<String>`) to where the value is read; surfaced verbatim
- `if: -> { ... }` / `unless: -> { ... }` — Proc predicates evaluated at audit time. When `unless:` returns truthy or `if:` returns falsy, the entry is reported with `status: :not_applicable`

`required` and `recommended` additionally accept `expected_value:` (see below). `forbidden` does not — its assertion *is* "absent" — and combining them raises an `ArgumentError` at `define` time rather than silently ignoring the option.

Audit output (one row per applicable entry):

```json
{
  "name": "SECRET_KEY_BASE",
  "level": "required",
  "status": "ok",
  "mode": "production"
}
```

Possible `status` values:

| status | meaning |
|---|---|
| `ok` | nothing to report |
| `missing` | `required` + absent |
| `should_set` | `recommended` + absent (advisory) |
| `forbidden` | `forbidden` + **present** |
| `mismatch` | present, but `expected_value:` says otherwise |
| `not_applicable` | suppressed by an `if:`/`unless:` predicate |

`missing`, `forbidden` and `mismatch` are the **violation** statuses — they drive the top-level `status: "incomplete"` and the optional `EnvSpecAudit` check. `should_set` is advisory and never counts as a violation.

### `forbidden`: vars that must NOT be set

For dangerous ops toggles — demo modes, auth bypasses, bootstrap flags — that are legitimate on staging and must never survive promotion to production:

```ruby
mode_alias :live, %w[production]

group "Production-forbidden toggles" do
  forbidden :DEMO_MODE_ENABLED, in: :live,
    description: "Demo/ops dashboard surfaces; unset before promoting"
  forbidden :STANDARD_ID_BYPASS_CODE, in: :live,
    description: "Fixed E2E OTP bypass code; staging only"
end
```

```json
{ "name": "DEMO_MODE_ENABLED", "level": "forbidden", "status": "forbidden", "mode": "production" }
```

Before this level existed, hosts expressed "forbidden" by declaring the var `recommended` with an `if: -> { ENV[...].present? }` predicate so that a set toggle at least produced a row — but the row was a green `:ok`, so the signal had to be carried by a hand-written custom check with its own duplicate list of toggle names. `forbidden` replaces both halves.

### `expected_value:`: assert the value, not just presence

Presence auditing misses the case where a var is set to the *wrong* thing — which for a security toggle is the failure mode that matters:

```ruby
# CSP is only enforced when this is exactly the string "false";
# "true" passes a presence audit while leaving the CSP report-only.
required :CONTENT_SECURITY_POLICY_REPORT_ONLY, in: :live,
  expected_value: "false",
  description: "Any other value leaves the CSP report-only"

required :LOG_LEVEL, expected_value: %w[info warn]   # any of
required :DATABASE_URL, expected_value: /\Apostgres:/ # matched, not compared
```

A present-but-wrong value reports `status: :mismatch`. An absent value still reports `:missing` / `:should_set` — there is nothing to compare. Comparison is on the string form, so `expected_value: 3000` matches `"3000"`.

**The actual value is never surfaced.** Env values are routinely secrets, and the endpoint exists to report *that* something is wrong, not to echo it back. The row carries the declared `expected_value` (host config, safe) and nothing else:

```json
{
  "name": "CONTENT_SECURITY_POLICY_REPORT_ONLY",
  "level": "required",
  "status": "mismatch",
  "expected_value": "false",
  "mode": "production"
}
```

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

Wrap related declarations in a `group "Label" do ... end` block to tag them with a category. Groups are pure metadata — they don't affect applicability, status, or evaluation order. Nested `group` blocks are supported; the innermost label propagates to enclosed entries. Calling `group` without a block raises `ArgumentError`.

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

### Top-level status

Since 0.4.1 the response carries a `status` alongside the audit, so a caller
can gate on one field instead of re-implementing the roll-up:

```json
{ "mode": "production", "status": "incomplete", "audit": [ ... ] }
```

`incomplete` means at least one row is a **violation** — `missing`,
`forbidden`, or `mismatch`. `should_set` is advisory and never affects it.

The level is deliberately not consulted for `mismatch`: a `recommended` var
declared with an `expected_value:` that does not hold is a failed assertion,
not advice.

**The endpoint still returns 200 either way.** Callers that already gate on
`status == "incomplete"` pick up the `forbidden` and `mismatch` assertions for
free — which is why they joined this roll-up rather than getting a verdict of
their own.

### Surfacing the audit on a health tier

`/diagnostics/env` is authed and polled by nobody, so config drift declared in
the spec is invisible until someone looks. Register the opt-in `EnvSpecAudit`
check to put the same verdict on a health tier:

```ruby
c.register_check :env_spec, StandardHealth::Checks::EnvSpecAudit
```

It fails on `:missing` / `:forbidden` / `:mismatch` rows and reports the
offending **names** (never values). Non-critical by default — see
[Opt-in checks](#opt-in-checks).

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

**A check must never raise.** `Aggregator` rescues `StandardError` per check, so a buggy check degrades to `:fail` rather than 500ing the endpoint — but don't rely on that as the only line of defence. Route fallible work through `with_timing`.

## Opt-in checks

Every check in this gem must be registered explicitly; **none are registered
automatically**, including the ones below. That is a deliberate constraint on
the gem: auto-registering a check turns it on for every host on a `bundle
update`, and a host that has never had SolidCable installed — or whose env spec
has a pre-existing violation — would go from green to yellow across its estate
for a check nobody asked for. New checks are additive only when they are opt-in.

| Check | Probes | `critical:` default |
|---|---|---|
| `Checks::ActiveRecord` | `SELECT 1` on the primary connection | `true` |
| `Checks::SolidQueue` | SolidQueue's tables | `true` |
| `Checks::SolidCache` | read-only `Rails.cache` probe | `false` |
| `Checks::SolidCable` | `solid_cable_messages` store | `false` |
| `Checks::EnvSpecAudit` | the configured `env_spec` | `false` |

The `critical:` default is only a default — `register_check` overrides it, and
what belongs on the rotation gate is a per-app decision.

```ruby
StandardHealth.configure do |c|
  c.register_check :solid_cable, StandardHealth::Checks::SolidCable
  c.register_check :env_spec, StandardHealth::Checks::EnvSpecAudit
end
```

### `Checks::SolidCable`

Bounded read against `solid_cable_messages`, confirming both that the cable
schema is migrated and that its connection is up. Uses
`SolidCable::Record.connection` when SolidCable is pointed at a separate
database, falling back to the primary connection when it isn't.

Cable is a **degradable feature dependency** — prefer this on the aggregate
tier. A broken cable store should mark the app `degraded`, never de-rotate it.

### `Checks::EnvSpecAudit`

Runs the configured `env_spec` and fails on the violation statuses
(`:missing`, `:forbidden`, `:mismatch`), reporting the offending variable
**names** grouped by status. Values never appear.

It reads the spec directly, so there is one declaration and no second list to
keep in sync — which is the whole reason it exists. It skips `consumed_by`
resolution (that does file IO per entry, fine for an on-demand doctor endpoint
and not fine on a tier polled every few seconds), and it is `:ok` when no
`env_spec` is configured.

Non-critical by default, and that default is load-bearing: config drift is
*visibility*, not a rotation signal. An instance with a stale toggle set is
still serving traffic correctly, and de-rotating it converts a warning into an
outage. Registering it `critical: true` asserts "this app must not serve at all
with a bad env" — a real but rare posture. Know which you want.

The aggregator instantiates checks with `name:`/`critical:` only, so to narrow
what counts as a failure, subclass:

```ruby
class ForbiddenTogglesOnly < StandardHealth::Checks::EnvSpecAudit
  def initialize(name: :forbidden_toggles, critical: false)
    super(name: name, critical: critical, fail_on: %i[forbidden])
  end
end
```

Note the failure message is subject to [redaction](#failure-detail-is-redacted)
on `/ready` like any other check; the detail reaches you through logs and
Sentry. The row carries a stable `error_class` of
`StandardHealth::EnvSpecViolation`, so the redacted body still groups on
`error_code: "standard_health_env_spec_violation"` rather than a useless
`standard_error`.

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

`skipped` also exists, for a check the total budget never reached (see
Timeouts). A skip floors the roll-up at `degraded` and **never** produces
`unavailable`, even for a critical check.

## Failure detail is redacted

Since 0.4.1, a failing check reports the exception **class** rather than its
message:

```json
{ "name": "database", "critical": true, "status": "fail",
  "error_class": "PG::ConnectionBad", "error_code": "pg_connection_bad" }
```

`/ready` is unauthenticated by design — probes carry no credentials — and a
raw driver message will happily tell an anonymous caller the database host,
port and username. The full message still reaches your logs and Sentry through
the instrumentation below; it just isn't in the public body.

```ruby
c.expose_check_errors = true       # restore pre-0.4.1 verbose bodies
c.detail_token = ENV["HEALTH_DETAIL_TOKEN"]   # X-Health-Token unlocks detail
```

`status`, `name`, `critical`, `latency_ms` and `generated_at` are unchanged.

## Instrumentation

The gem emits events on whichever bus is live — `Rails.event` on Rails 8.1+,
`ActiveSupport::Notifications` otherwise:

| Event | Payload |
|---|---|
| `standard_health.check.completed` | `name`, `critical`, `status`, `latency_ms`, `error_class`, `error_message` |
| `standard_health.check.timed_out` | `name`, `critical`, `timeout_s` |
| `standard_health.ready.evaluated` | `status`, `duration_ms`, `failed[]` |

Three subscribers are registered automatically. Their noise profiles differ on
purpose, because health events are **polls**, not state transitions — a 10s
probe period means ~6 evaluations/minute/instance:

- **Logger** — silent while healthy. `warn` on degraded, `error` on
  unavailable. A line per evaluation would be ~8,640/day/instance of
  "everything is fine".
- **Sentry** — only on status **change**, plus a 60s repeat floor for a
  sustained bad state, plus one `info` on recovery. Capturing every non-ok
  poll would turn a five-minute outage into ~30 duplicate issues. Sentry is a
  soft dependency; no gemspec entry.
- **Metrics** — every poll, deliberately. Counters plus latency
  distributions are what make `latency_ms` chartable.

```ruby
StandardHealth.configure do |c|
  c.instrumentation_enabled = true    # default
  c.logger        = Rails.logger      # default: Rails.logger
  c.sentry_enabled = true             # default
  c.metric_prefix  = "health"         # default

  c.add_notifier(MyNotifier.new)      # must respond to call(event_name, payload)
end
```

## Timeouts

**Off by default.** Both settings are `nil`, which is byte-identical to 0.4.0.

```ruby
c.default_check_timeout = 2.0        # seconds, per check
c.total_check_budget    = 5.0        # checked BEFORE each check starts
c.register_check :db, MyCheck, critical: true, timeout: 1.0   # per-check override
```

**`total_check_budget` bounds how many checks RUN, not how long the probe
takes.** It is evaluated before each check starts, not during one. With a 1s
budget and a first check that blocks for 30s, `/ready` still takes 30s — only
the checks *after* it are skipped.

Clamping each check to the remaining budget would close that gap, and is
deliberately not done: it would apply `Timeout.timeout` to checks whose author
never asked for one, and that mechanism raises into the thread at an arbitrary
point (see below). Setting a budget must not silently opt you into that. To
bound wall-clock, put a `timeout:` on the checks that can safely take one.

Enabling them is a semantic change — a check that has always been
slow-but-fine starts reporting `:fail`, and for a critical check that pulls
the instance out of rotation. Pick values from observed `latency_ms` rather
than intuition; that is what the `check.completed` events are for.

Checks the total budget never reaches report `:skipped`, never silently `:ok`.
A skip alone floors the roll-up at `degraded` — otherwise a slow *non-critical*
check could exhaust the budget, leave the database check unrun, and pull a
healthy instance out of rotation.

Checks run **sequentially**. They are not parallelised on purpose: running
them in threads would mean connection checkouts from the health path, and a
health endpoint that can exhaust the connection pool is a worse problem than
the one it was added to solve.

### ⚠ Know what `Timeout.timeout` actually does before enabling this

Ruby's `Timeout.timeout` interrupts by raising **into the running thread at an
arbitrary point**. It cannot wait for a safe boundary. If a timeout fires
while a check is mid-way through a non-atomic operation — say a connection
checkout in the `ActiveRecord` check — the connection can be returned to the
pool in a broken state. You would have traded a slow check for a corrupted
pool, on the health path, during an incident.

The dedicated `CheckTimeout` class solves the *mislabelling* problem (a host's
own `Timeout::Error` is never mistaken for ours). **It does not solve this
one.** Nothing can, at this layer.

So, before turning timeouts on:

- Prefer a driver-level timeout where one exists — `connect_timeout` /
  `statement_timeout` on the database, a client timeout on an HTTP dependency.
  Those abort at a safe point because the driver owns the operation.
- Reserve `timeout:` here for checks whose `run` is genuinely interruptible —
  typically your own custom checks — rather than the built-in datastore ones.
- Set the value comfortably above observed p99 (see the `latency_ms` in
  `check.completed`), so it fires on a hang rather than on a slow day.

This is why the defaults ship as `nil` and why choosing them is deferred: the
right answer is usually a driver timeout, not this.

## License

MIT.
