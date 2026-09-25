# StandardHealth

A drop-in health check and environment-spec engine for Rails 8 host apps.

Mount it once and you get:

- `GET /health/alive` — liveness probe (always 200 if Rails is up)
- `GET /health/ready` — readiness probe; runs every registered check and rolls them up into an overall status
- `GET /health/diagnostics/env` — audits the host app's `ENV` against a declarative spec
- `GET /health` — *opt-in* aggregate tier: checks plus StandardCircuit state (see [below](#let-the-engine-serve-the-aggregate-tier-060))

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

**Unless you opt into [`aggregate_endpoint`](#let-the-engine-serve-the-aggregate-tier-060)
(0.6.0), the engine serves no bare `GET /health`.** The aggregate tier is then
the host's responsibility, and the ordering is not optional:

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

### Let the engine serve the aggregate tier (0.6.0)

Instead of drawing the aggregate route yourself, opt in and the engine serves
it at its root:

```ruby
StandardHealth.configure do |c|
  c.aggregate_endpoint = true
  # c.aggregate_readiness_checks = true    # default: re-run the register_check registry
  # c.aggregate_circuits = true            # default: fold StandardCircuit.health_report in, when loaded
  c.register_aggregate_check :solid_cable, StandardHealth::Checks::SolidCable  # aggregate-ONLY
end
```

```json
{ "status": "degraded",
  "checks":   [{ "name": "database", "critical": true, "status": "ok", "latency_ms": 2 },
               { "name": "solid_cable", "critical": false, "status": "fail",
                 "error_class": "PG::ConnectionBad", "error_code": "pg_connection_bad" }],
  "circuits": [{ "name": "google_oauth", "color": "green", "locked": false, "criticality": "critical" }],
  "generated_at": "2026-09-24T00:00:00Z" }
```

| Status | HTTP | When |
|---|---|---|
| `unavailable` | 503 | a critical check failed, or a `:critical` circuit is red |
| `degraded` | 200 | a non-critical check failed, a check was skipped by the total budget, or the circuit roll-up is `:degraded` |
| `ok` | 200 | otherwise |

**The aggregate tier re-runs your readiness checks by default.** With
`aggregate_readiness_checks` on (the default), every `register_check`
registration runs here as well as on `/ready`. A failing critical check, such
as `:database` or `:solid_queue` from `register_default_checks`, therefore turns
`/health` into a **503 `unavailable`**, not just `/ready`. Point an uptime
monitor at `/health` and a database outage pages as a 503. If your aggregate
tier should only report soft signals (sidekick), set
`aggregate_readiness_checks = false`.

StandardCircuit's own word `critical` is translated to `unavailable`, so both
tiers speak one vocabulary. The aggregate body never says `"critical"`. `circuits` is omitted when StandardCircuit isn't
loaded (or `aggregate_circuits = false`); if `health_report` raises (circuit
store down) the tier degrades and reports `circuits_error: { error_class,
error_code }` instead of 500ing. Check rows are redacted exactly like `/ready`,
with the same `detail_token` break-glass. `register_aggregate_check` checks
run **only** here — never on `/ready` — and default to `critical: false`.

A check that **raises** on this tier, rather than returning a `:fail` row, is
also reported to `Rails.error` as handled (since 0.6.1), with context
`{ health_check:, tier: "aggregate" }` and severity `:error` for a critical
check or `:warning` otherwise. That matches what the pre-0.6 host controllers
did. Per-check timeouts are not reported; they surface as
`standard_health.check.timed_out`. `/ready` does not do this: its failures reach Sentry through the
transition-gated `ready.evaluated` notifier.

With `aggregate_endpoint` off (the default) the engine's root route carries a
per-request constraint that never matches, so a bare `/health` cascades to your
own route exactly as before. Once on, the engine answers `/health` regardless
of where your own route is drawn relative to the mount.

**Migration** — replace your host code with the flag:

- **fundbright / nutripod / jumpdrive** (`get "/health", to: "standard_circuit/health#show"`):
  set `c.aggregate_endpoint = true`, delete that route (and the
  `require "standard_circuit/health_controller"` if nothing else uses it —
  fundbright's `/circuits` alias still does). The body gains `checks[]`, and
  a red critical circuit reports `"unavailable"` rather than `"critical"`
  (still 503). Update any dashboard or monitor matching on `"critical"`.
- **luminality** (`HealthAggregateController` merging `Aggregator` + circuits):
  set the flag, delete the route and the controller. Same envelope and status
  words — it is this controller.
- **sidekick** (`HealthAggregateController` with soft checks only):

  ```ruby
  c.aggregate_endpoint = true
  c.aggregate_readiness_checks = false   # sidekick's aggregate never re-ran readiness
  c.register_aggregate_check :solid_cable, StandardHealth::Checks::SolidCable
  c.register_aggregate_check :attestation_roots, "AttestationRootsCheck"  # String: resolved per request
  ```

  then delete the route and the controller. Status words move from
  `critical` to `unavailable`, as above.

Aggregate evaluations emit `standard_health.aggregate.evaluated`, **not**
`ready.evaluated` — see [Instrumentation](#instrumentation).

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

### `register_default_checks` (0.6.0)

Every consumer registers the same set by hand. One call does it:

```ruby
# replaces:
#   c.register_check :database,        StandardHealth::Checks::ActiveRecord, critical: true
#   c.register_check :solid_queue,     StandardHealth::Checks::SolidQueue,   critical: true
#   c.register_check :solid_cache,     StandardHealth::Checks::SolidCache,   critical: false
#   c.register_check :audit_retention, StandardAudit::Checks::Retention,     critical: false
c.register_default_checks
```

| Key | Registered as | Class | `critical` | Skipped unless |
|---|---|---|---|---|
| `database` | `:database` | `Checks::ActiveRecord` | `true` | `ActiveRecord::Base` is loaded |
| `solid_queue` | `:solid_queue` | `Checks::SolidQueue` | `true` | `SolidQueue` is loaded |
| `solid_cache` | `:solid_cache` | `Checks::SolidCache` | `false` | `SolidCache` is loaded |
| `audit_retention` | `:audit_retention` | `StandardAudit::Checks::Retention` | `false` | `standard_audit` is loaded |

A check whose backing library isn't loaded is skipped rather than registered
to fail forever. A name that's already registered is skipped too, so it's safe
to mix with hand-registered checks (in either order) and to call twice. Each
key takes `true` (defaults), `false` (skip), or a Hash of overrides —
`name:`, `critical:`, `timeout:`, plus any [constructor options](#custom-checks):

```ruby
c.register_default_checks solid_cache: false,                 # jumpdrive: has SolidCache, doesn't check it
                          solid_queue: { timeout: 2 }
```

Returns the names it registered. Check order in the response follows
registration order.

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
{ "mode": "production", "status": "incomplete", "audit": [ ... ], "assertions": [ ... ] }
```

`incomplete` means at least one row is a **violation** — `missing`,
`forbidden`, or `mismatch` — or (since 0.7.0) a registered diagnostics
assertion reported `error`. `should_set` and an assertion's `warn` are
advisory and never affect it.

The level is deliberately not consulted for `mismatch`: a `recommended` var
declared with an `expected_value:` that does not hold is a failed assertion,
not advice.

**The endpoint still returns 200 either way.** Callers that already gate on
`status == "incomplete"` pick up the `forbidden` and `mismatch` assertions for
free — which is why they joined this roll-up rather than getting a verdict of
their own.

### Runtime assertions: `register_diagnostics_assertion` (0.7.0)

Env presence can't prove that a setting took effect. For example, the live
`statement_timeout` may still be `0`, a rate limiter may have fallen back to
Solid Cache, or a pinned certificate may be about to expire. Register those
checks as assertions and the engine renders them on `/diagnostics/env` under
`assertions:`, behind the same `diagnostics_basic_auth` gate:

```ruby
StandardHealth.configure do |c|
  c.register_diagnostics_assertion(:statement_timeout) do
    value = ActiveRecord::Base.connection.select_value("SHOW statement_timeout").to_s
    { status: value.strip == "0" ? :warn : :ok, value: value, expected: "non-zero" }
  end

  # Any callable works; reference app constants inside it, not at boot.
  c.register_diagnostics_assertion(:rate_limit_store, -> { RateLimitAssertion.call })
end
```

```json
{ "mode": "production", "status": "ok", "audit": [ ... ],
  "assertions": [ { "name": "statement_timeout", "status": "ok", "value": "15s", "expected": "non-zero" } ] }
```

- The callable takes no arguments and returns a Hash with `status:` set to
  `:ok`, `:warn` or `:error`. Other keys are rendered as-is. The gem sets
  `name:`, and the callable can't override it.
- An assertion that raises becomes `{ status: "error", error_class:, error: }`
  and is reported to `Rails.error` as handled. The tier is authenticated, so
  the message is shown. A non-Hash result or an unknown status also becomes an
  `:error` row. One broken assertion never takes the endpoint down.
- An `:error` row makes the top-level `status` `incomplete`. `:warn` does not.
  The endpoint still returns 200.
- Assertions run per request, and only on this tier, never on `/alive`,
  `/ready` or the aggregate. They have no timeout, so keep them cheap.
- Re-registering a name replaces it, so it is safe inside `to_prepare`.
  `reset_diagnostics_assertions!` clears them in specs.
- A host that keeps its own diagnostics controller can render
  `StandardHealth::DiagnosticsAssertions.run` itself.

**Replace your host code with it.** sidekick-web's
`app/controllers/health_diagnostics_controller.rb` exists to add three
assertions (`statement_timeout`, `rate_limit_store`, `attestation_roots`) to
the env audit. Move each into a `register_diagnostics_assertion`, delete the
controller, and delete its route
(`get "/health/diagnostics/env", to: "health_diagnostics#env"` ahead of the
engine mount). Its `rescue => e; { status: :error, error: e.message }`
wrappers go too, because the gem does that now.

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

**Per-registration options (0.6.0).** Keywords other than `critical:` and
`timeout:` are forwarded to the check's constructor, and validated against its
signature at registration — a typo fails at boot, not on every probe:

```ruby
class QueueDepthCheck < StandardHealth::Check
  def initialize(name:, critical: false, max_depth: 1_000)
    super(name: name, critical: critical)
    @max_depth = max_depth
  end
  # ...
end

c.register_check :queue_depth, QueueDepthCheck, max_depth: 5_000
```

**String class names.** `klass` may be a String, resolved each time the check
runs. That lets an initializer register an autoloaded app constant (which isn't
resolvable yet at initializer time) without a `to_prepare` block, and picks up
class reloads in development. An unresolvable name reports a failing row
(`error_class: "NameError"`) rather than raising.

```ruby
c.register_check :runner, "RunnerHealthCheck"
```

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

To narrow what counts as a failure, pass `fail_on:` at registration (0.6.0+
forwards it to the constructor — no subclass needed):

```ruby
c.register_check :forbidden_toggles, StandardHealth::Checks::EnvSpecAudit,
                 fail_on: %i[forbidden]
```

Note the failure message is subject to [redaction](#failure-detail-is-redacted)
on `/ready` like any other check; the detail reaches you through logs and
Sentry. The row carries a stable `error_class` of
`StandardHealth::EnvSpecViolation`, so the redacted body still groups on
`error_code: "standard_health_env_spec_violation"` rather than a useless
`standard_error`.

## Auth

`/alive` and `/ready` are typically left open for orchestrator probes. `/diagnostics/env` enumerates which env vars are missing — that's potentially sensitive, so it must be protected.

### Built-in basic auth for diagnostics (0.6.0)

The simplest option is to let the engine gate it:

```ruby
StandardHealth.configure do |c|
  c.diagnostics_basic_auth = true   # ADMIN_BASIC_AUTH_USERNAME / ADMIN_BASIC_AUTH_PASSWORD
end
```

or, with your own credential source (Strings or callables, resolved **per
request**, so rotation needs no restart):

```ruby
c.diagnostics_basic_auth = {
  username: -> { Current.config.admin_basic_auth_username },
  password: -> { Current.config.admin_basic_auth_password },
  realm: "Health Diagnostics",                                  # default
  allow_unconfigured: -> { Rails.env.local? }                   # default: false
}
```

- Only `/diagnostics/env` is gated; `/alive`, `/ready` and the aggregate tier stay anonymous.
- **Fails closed.** If either credential resolves blank (or the lookup raises),
  the endpoint answers **403** `{"error":"diagnostics refused", ...}` rather
  than serving env state. 403, not 503: DigitalOcean App Platform's edge
  replaces an app 5xx with its own error page, which reads as "app down". Not
  401: there are no credentials that could succeed. `allow_unconfigured`
  (boolean or callable) opts a credential-less environment — typically local
  dev — into passing through.
- Both halves are compared with `secure_compare` over SHA-256 digests, so a
  wrong username still costs a password comparison and differing lengths leak
  nothing.
- Off by default; independent of `diagnostics_parent_controller` (if you set
  both, the parent's callbacks run first).
- The request-time gate is the `StandardHealth::DiagnosticsAuthentication`
  concern, which the engine includes into its own `DiagnosticsController`.
  **Since 0.7.0 it is public, semver-stable API:** `include
  StandardHealth::DiagnosticsAuthentication` into any `ActionController::API`
  or `::Base` controller to put a host endpoint behind the same fail-closed
  gate. The contract is the include, the one `before_action` it installs, and
  the 401 challenge / 403 refusal behaviour. Its private method names are not
  part of it. It is a no-op until `diagnostics_basic_auth` is set. If your
  controller only exists to add runtime assertions, use
  [`register_diagnostics_assertion`](#runtime-assertions-register_diagnostics_assertion-070)
  instead and delete the controller.

**Replace your host code with it.** Delete
`app/controllers/standard_health_host_controller.rb` and the
`c.diagnostics_parent_controller = "StandardHealthHostController"` line, then:

| App | Was | Set |
|---|---|---|
| jumpdrive | fail-closed 403 on unset `ADMIN_BASIC_AUTH_*` | `c.diagnostics_basic_auth = true` |
| sidekick | 503 when unset in staging/preview/production, open locally | `c.diagnostics_basic_auth = { allow_unconfigured: -> { !%w[staging preview production].include?(ENV["APP_ENVIRONMENT"]) } }` |
| fundbright, luminality | open when unset (boot-enforced in deployed envs) | `c.diagnostics_basic_auth = { allow_unconfigured: -> { Rails.env.local? } }` |
| nutripod | `Current.config.admin_basic_auth_*` | `c.diagnostics_basic_auth = { username: -> { Current.config.admin_basic_auth_username }, password: -> { Current.config.admin_basic_auth_password }, allow_unconfigured: -> { Rails.env.local? } }` |

(Sidekick moves from 503 to 403 on a missing gate — see above for why.)

### Bring your own parent controller

The pre-0.6.0 pattern is to point `parent_controller` at a host app controller that enforces auth:

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

## Probe paths (0.6.0)

Hosts copy the probe regex into `production.rb` and their Sentry samplers. The
gem now owns it, built from the same `PROBE_ACTIONS` list its routes are drawn
from, so it cannot drift:

```ruby
StandardHealth::PROBE_PATHS
# => matches /up, /health, /health/alive, /health/ready (optional trailing /)
#    never /health/diagnostics/env, never /healthy-habits
StandardHealth.probe_path?(path)                    # predicate, same default
StandardHealth.probe_path?(path, mount: "/_status") # engine mounted elsewhere
```

Anchored at both ends. The doctor tier is deliberately excluded — it's authed,
hit by on-call rather than on a timer, and belongs in logs and APM.

**If you mount the engine anywhere but `/health`, `PROBE_PATHS` is wrong for
you** — call `probe_path?(path, mount: "/your-prefix")` or build your own with
`StandardHealth.probe_path_pattern(mount:, up: true, aggregate: true, extra: [])`.
`aggregate: false` reproduces the old exact set without the bare `/health`;
`extra:` adds exact paths such as fundbright's `/circuits` alias.

Replace your host code with it:

```ruby
# config/environments/production.rb
# was: %r{\A/(up|health/(alive|ready))\z}  (x3 in fundbright/luminality/nutripod)
config.silence_healthcheck_path = StandardHealth::PROBE_PATHS
config.x.silence_console_paths  = [StandardHealth::PROBE_PATHS]   # luminality/sidekick
config.ssl_options = { redirect: { exclude: ->(r) { StandardHealth.probe_path?(r.path) } } }
config.host_authorization = { exclude: ->(r) { StandardHealth.probe_path?(r.path) } }

# config/initializers/sentry.rb traces_sampler
# was: Sentry::ProbePaths.probe?(path) (lib/sentry/probe_paths.rb in
#      fundbright/luminality/sidekick) or SentryTracesSampler#health_or_stream?
#      in jumpdrive, or the inline start_with? in nutripod
return 0.0 if StandardHealth.probe_path?(rack_env["PATH_INFO"])
return 0.0 if StandardHealth.probe_path?(path, extra: ["/circuits"])   # fundbright
```

Note the difference from the samplers' segment-prefix match: this is an
**exact** match on the probe routes the engine actually serves, so a future
`/health/<something>` sub-route is covered by a gem release rather than by a
prefix. Paths the gem doesn't serve (sidekick's `/api/v1/provisioning/health`)
go in `extra:`.

## Status semantics

`/ready` returns:

| Overall status | HTTP code | Meaning |
|---|---|---|
| `ok` | 200 | All checks passed |
| `degraded` | 200 | A non-critical check failed |
| `unavailable` | 503 | A critical check failed |

The orchestrator should pull the instance out of rotation only on 503; degraded means "still serving, page someone."

`skipped` also exists, in two flavours that roll up differently:

- **A check that returns `status: :skipped` itself** — "not applicable here"
  (the feature it covers isn't configured or enforced). This is **neutral**
  (since 0.7.1): it neither degrades nor fails the roll-up, whether the check
  is critical or not, and it is left out of the evaluation events' `failed[]`.
  It still renders in `checks[]` with `"status": "skipped"` and still emits
  `check.completed`, so it stays visible. A critical check is neutral too on
  purpose: "not applicable" says nothing about whether the instance can serve,
  so it must not pull it out of rotation — and it must not mark it healthy
  *because of* that check either; it simply doesn't count. If the state should
  page, return `:fail`.
- **A check the total budget never reached** (see Timeouts) — rendered with
  `"budget_exhausted": true`. That check was not performed, which is not the
  same as healthy, so it floors the roll-up at `degraded` and **never**
  produces `unavailable`, even for a critical check.

A real failure still rolls up exactly as before alongside any skip: a failing
critical check is `unavailable`, a failing non-critical one `degraded`.

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
| `standard_health.ready.evaluated` | `status`, `duration_ms`, `failed[]`, `failures[]` |
| `standard_health.aggregate.evaluated` | `status`, `duration_ms`, `failed[]`, `failures[]`, `circuits_status`, `red_circuits[]` (0.6.0, only with `aggregate_endpoint`) |

Checks run by the aggregate tier also emit `check.completed` / `check.timed_out`,
carrying `tier: :aggregate`; readiness payloads carry no `tier` key, exactly as
before 0.6.0. The aggregate evaluation deliberately gets its **own** event:
the Sentry notifier keeps per-process transition state on `ready.evaluated`,
and an aggregate that includes soft checks would make it flap.

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
  distributions are what make `latency_ms` chartable. Aggregate-tier check
  counts carry a `tier` attribute.

The Logger also reports `aggregate.evaluated` (silent on ok); Sentry and
Metrics ignore it.

### Narrowing metrics (0.6.0)

The per-poll events are the metric volume (~2 evaluations × N checks per probe
interval per instance). To keep the rare, actionable timeout metric and drop
the per-poll firehose:

```ruby
c.metric_events = %w[standard_health.check.timed_out]
# or equivalently:
c.metric_events = StandardHealth::Notifiers::Metrics::EVENTS -
                  StandardHealth::Notifiers::Metrics::PER_POLL_EVENTS
```

or drop the Metrics notifier entirely — unlike `instrumentation_enabled =
false`, this keeps the Logger and Sentry notifiers:

```ruby
c.metrics_enabled = false
```

`metric_events` is an allow-list (nil, the default, records everything) and
unknown names raise at boot. **Replace your host code with it:** sidekick's
`config/initializers/standard_health_metrics.rb` (the
`StandardHealthPollMetricSuppression` prepend) becomes the first snippet above;
its spec's "is patched with the suppression module" example goes, the
behavioural examples stay.

```ruby
StandardHealth.configure do |c|
  c.instrumentation_enabled = true    # default
  c.logger        = Rails.logger      # default: Rails.logger
  c.sentry_enabled = true             # default
  c.metric_prefix  = "health"         # default
  c.metrics_enabled = true            # default (0.6.0)
  c.metric_events   = nil             # default: all (0.6.0)

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

Checks the total budget never reaches report `:skipped` (with
`budget_exhausted: true`), never silently `:ok`. A budget skip alone floors the roll-up at `degraded` — otherwise a slow *non-critical*
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
