# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.5.0] - 2026-07-30

Closes the gap that had four host apps writing their own checks. The env-spec
DSL could only audit **presence**, so "this toggle must not be set on
production" and "this value must be exactly `false`" were inexpressible — and
the workaround was a hand-written check carrying a duplicate list of variable
names, kept in sync with the spec by comment.

Everything here is **additive and opt-in**. No check is auto-registered and no
existing status changes meaning, so this is a pure `bundle update` for
consumers on `~> 0.4`.

### Added

- **`forbidden` EnvSpec level.** Inverts the presence rule: absent is `:ok`,
  present reports the new `:forbidden` status. For dangerous ops toggles —
  demo modes, auth bypasses, bootstrap flags — that are legitimate on staging
  and must never survive promotion. Composes with `in:`, `mode_alias`, groups
  and the `if:`/`unless:` predicates like any other level.
- **`expected_value:` assertion** on `required` / `recommended`. Asserts the
  value, not just presence; a present-but-wrong value reports the new
  `:mismatch` status. Accepts a String, an Array (any-of), a Regexp (matched,
  not compared), or any object comparable by its string form. The **actual
  value is never surfaced** — env values are routinely secrets — only the
  declared expectation.
- **`Checks::EnvSpecAudit`** (opt-in). Runs the configured `env_spec` and
  fails on `:missing` / `:forbidden` / `:mismatch`, reporting offending
  variable *names* grouped by status. Reads the spec directly, so there is no
  second list to drift. Non-critical by default: config drift is visibility,
  not a rotation signal. Skips `consumed_by` resolution — that is file IO per
  entry, fine for an on-demand doctor endpoint and not on a polled tier.
- **`Checks::SolidCable`** (opt-in). Bounded read against
  `solid_cable_messages`. Promoted from sidekick-web. Falls back to the
  primary connection when SolidCable isn't pointed at its own database.
- **`standard_health:install` generator.** Writes the initializer and mounts
  the engine, with the aggregate-route ordering requirement noted inline.
  Idempotent; `--skip-initializer`, `--skip-routes`, `--force`.

### Changed

- **`/diagnostics/env` top-level `status`** now reports `incomplete` for
  `:forbidden` and `:mismatch` rows as well as `:missing`. Callers already
  gating on that one field pick up the new assertions for free, which is why
  they joined the existing roll-up instead of getting a verdict of their own.
  The endpoint still returns 200 either way. `:should_set` remains advisory
  and still never affects the roll-up.
- **Rails dependency relaxed** from `~> 8.0` to `>= 8.0`, matching the rest of
  the `standard_*` family. `~> 8.0` was the only floor in the family that
  would have blocked a Rails 9 host.

### Not in this release

- **Timeout defaults remain unset.** 0.4.1 said sensible `default_check_timeout`
  / budget values would be chosen "in 0.5.0". They are not: choosing them still
  needs enough real p99 latency data from the instrumentation 0.4.1 added, and
  guessing a timeout on a health check is how you cause the outage you were
  trying to prevent. The machinery stays opt-in per check. The stale promise in
  `Configuration` has been repointed (#48).
- **`/diagnostics/env` still returns 200** when `status` is `incomplete`.
  Turning that into a 503 is a breaking contract change for any caller gating on
  the response code, so it wants its own decision rather than riding along with
  an otherwise additive release.

### Documentation

- **The aggregate `GET /health` tier and its ordering requirement are now
  documented.** The engine draws sub-paths only; the aggregate tier is the
  host's job and must be drawn **before** `mount`. An app that mounts first
  and relies on the engine to serve it silently has no aggregate tier — no
  boot error, no failing route spec. Also documents what each of the four
  tiers is for, and that readiness gates only on hard infra the app owns.
- New README section on opt-in checks, including why nothing here
  auto-registers.

## [0.4.1] - 2026-07-29

Observability release. Until now the gem emitted **nothing** — no events, no
logs, no metrics. It computed `latency_ms` for every check and discarded it
into the response body. A failing check was invisible unless somebody happened
to call `/ready` at the right moment, so there was no history, no alerting
hook, and no way to chart check latency.

Everything here is **additive**: no status code, roll-up rule, or response
field changes meaning, so this is a pure `bundle update` for consumers on
`~> 0.4`.

### Added

- **Instrumentation.** Three events over whichever bus is live (`Rails.event`
  on Rails 8.1+, `ActiveSupport::Notifications` otherwise), matching
  `standard_circuit`'s `EventEmitter` idiom:
  - `standard_health.check.completed` — `name`, `critical`, `status`,
    `latency_ms`, `error_class`, `error_message`
  - `standard_health.check.timed_out` — `name`, `critical`, `timeout_s`
  - `standard_health.ready.evaluated` — `status`, `duration_ms`, `failed[]`
- **Three built-in subscribers**, registered by a new engine initializer
  (`after: :load_config_initializers`, so host config is final):
  - `Notifiers::Logger` — **silent while healthy.** `warn` on degraded,
    `error` on unavailable. Health events are polls (~6/min/instance), not
    transitions; a line per evaluation is ~8,640/day/instance of "everything
    is fine".
  - `Notifiers::Sentry` — **transition-only**, with a 60s repeat floor and
    one `info` on recovery. Capturing every non-ok poll would turn a
    five-minute outage into ~30 duplicate issues. Mutex-guarded (Puma is
    threaded). Sentry stays a soft dependency.
  - `Notifiers::Metrics` — per-poll counters and latency distributions. This
    fires on every evaluation on purpose: it is what makes `latency_ms`
    chartable.
- `config.add_notifier` for host-supplied `call(event_name, payload)`
  subscribers, validated at add time.
- Config: `instrumentation_enabled`, `logger`, `sentry_enabled`,
  `metric_prefix`.
- **Per-check timeout machinery** — `default_check_timeout`,
  `total_check_budget`, and a `timeout:` option on `register_check`. Uses a
  dedicated `StandardHealth::CheckTimeout` rather than bare `Timeout::Error`,
  so a timeout the host raised for its own reasons is never mislabelled as
  ours. **All default to `nil` (OFF)** — see below.
- `status` on `/diagnostics/env`: `:ok` or `:incomplete` (a `required` var is
  missing). **Additive — the endpoint still returns 200 either way.**

### Fixed

- `Check#with_timing` now records `error_class` alongside the message. All
  three built-in checks route through it, so without this every real driver
  failure reached the aggregator with no class and the redacted body fell back
  to a generic `StandardError` — exactly the useless label redaction exists to
  replace.
- Failure detail (`error_class` + `error_message`) now rides on
  `ready.evaluated`, not only on `check.completed`. Both built-in subscribers
  are driven by `ready.evaluated` (deliberately — it is the transition-gated
  event), so the message would otherwise have been deleted from the response
  without ever reaching logs or Sentry.

### Security

- **`/ready` no longer returns raw exception messages.** The endpoint is
  unauthenticated by design, and a driver error will happily tell an anonymous
  caller the database host, port and username — during exactly the incident
  you least want to be leaking. Failing rows now carry `error_class` and a
  stable `error_code` instead. The full message is not lost: it goes to logs
  and Sentry via the instrumentation above, which is why redaction ships in
  the same release rather than separately.
  - `config.expose_check_errors = true` restores the previous bodies.
  - `config.detail_token` + an `X-Health-Token` header is a break-glass path
    for on-call, compared in constant time.
  - `status`, `name`, `critical`, `latency_ms` and `generated_at` are
    unchanged, so dashboards and existing specs keep working.

### Notes on what is deliberately NOT on

Timeouts and the total budget default to **off**, giving byte-identical
behaviour to 0.4.0. Turning them on is a semantic change: a check that has
always been slow-but-fine starts reporting `:fail`, and for a critical check
that pulls the instance out of rotation. Shipping that in a patch, to five
apps, on a `bundle update`, is how you cause the outage you were preventing.

The machinery ships now so apps can opt in per check, and so the events above
can reveal the real p99 latencies. Defaults get chosen from that data in
0.5.0, which requires an explicit Gemfile edit.

One semantic guard is already in place for when they are enabled: a check
skipped because the budget ran out reports `:skipped` and floors the roll-up
at `:degraded` — **never `:unavailable`**, even when the skipped check is
critical. Otherwise a slow *non-critical* check could exhaust the budget,
leave the database check unrun, and pull a healthy instance out of rotation.

`total_check_budget` bounds **how many checks run**, not how long the probe
takes — it is evaluated before each check starts, not during one. Clamping
each check to the remaining budget would close that gap but would apply
`Timeout.timeout` to checks whose author never asked for one, so setting a
budget deliberately does not opt you into that. Asserted by spec, not just
documented.

A second reason to leave them off: `Timeout.timeout` raises into the running
thread at an arbitrary point, so firing one mid-connection-checkout can return
a broken connection to the pool. The dedicated `CheckTimeout` fixes
mislabelling, not this. The README now carries the full caveat — the right
answer for datastore checks is usually a driver-level timeout
(`connect_timeout` / `statement_timeout`), not this setting.

## [0.4.0] - 2026-05-05

### Added

- Consumer-presence detection for `consumed_by:` paths. `audit()` accepts an optional `root:` keyword (host-app root). When given, each entry whose `consumed_by:` is set is checked against the host app's tree, producing a new `consumer:` field on the audit row: `:present` (file exists and references the var via `ENV[...]` or `ENV.fetch(...)`), `:file_missing` (path missing on disk), or `:not_referenced` (file exists but no `ENV` reference). Catches renamed/deleted consumer files, `consumed_by:` typos, and vars declared in env-spec but never actually `ENV.fetch`'d.
- `DiagnosticsController#env` now passes `Rails.root` automatically, so host apps get the new `consumer:` field with no host-side change.
- Deprecation metadata on `required` / `recommended`: `deprecated: true`, `sunset_on:` (target removal date), `replacement:` (what to use instead). Surfaced verbatim in audit rows. Lets vars be staged for removal with audit trail.

### Changed

- `Entry` struct extended with `deprecated`, `sunset_on`, `replacement`. Backward-compatible — every 0.3.0 spec produces identical audit output when the new opts aren't used and `root:` isn't passed.

## [0.3.0] - 2026-04-29

### Added

- `if:` and `unless:` Proc predicates on `required` and `recommended`. Evaluated at audit time; when `unless:` returns truthy or `if:` returns falsy the entry is reported with `status: :not_applicable` and a `reason` field. Solves the MyInfo mock-mode case where `MYINFO_PRIVATE_JWKS` is only required outside mock mode.
- `mode_alias` top-level DSL inside `EnvSpec.define`. Maps a Symbol to an `Array<String>` of `APP_ENVIRONMENT` values. `in:` now accepts a Symbol that is resolved against declared aliases at audit time; an undefined Symbol raises `StandardHealth::EnvSpec::UnknownModeAlias`.
- `consumed_by:` keyword on `required`/`recommended`. Accepts a String or `Array<String>` pointing at where the env var is read in the host app; flows through to audit rows verbatim.
- `group "Label" do ... end` block inside `EnvSpec.define`. Tags enclosed entries with a `group` field in their audit rows. Pure metadata for ops UX.
- New `:not_applicable` value for the `status` field, used when an `if:`/`unless:` predicate suppresses an entry.

### Changed

- `EnvSpec` internals refactored: `Entry` struct extended with `consumed_by`, `if_predicate`, `unless_predicate`, and `group`. Backward-compatible — every 0.2.0 spec produces identical audit output (modulo `description` now appearing where it was previously suppressed and `group`/`consumed_by` appearing only when set).

## [0.2.0] - 2026-04-29

### Added

- `c.diagnostics_parent_controller` config option. When set, only `StandardHealth::DiagnosticsController` inherits from it; `HealthController` still uses `parent_controller`. Lets consuming apps put auth (e.g. HTTP Basic) on the diagnostics endpoint without needing `raise_on_missing_callback_actions = false` — the workaround three rarebit-one web apps applied when adopting v0.1.0.

### Changed

- `StandardHealth::DiagnosticsController` now inherits from a new `StandardHealth::DiagnosticsApplicationController` that resolves to `diagnostics_parent_controller || parent_controller`. Backward-compatible — when the new option isn't set, behavior is identical to v0.1.0.

## [0.1.0] - 2026-04-28

### Added

- Initial release of `standard_health` — a mountable Rails engine providing `/alive`, `/ready`, and `/diagnostics/env` endpoints.
- `StandardHealth.configure` block with `register_check`, `parent_controller`, and `env_spec` accessors.
- `StandardHealth::EnvSpec` DSL for declaring required and recommended environment variables, with optional per-mode applicability via `in:`.
- Built-in checks: `Checks::ActiveRecord`, `Checks::SolidQueue`, `Checks::SolidCache`.
- `StandardHealth::Aggregator` rolls registered checks into `:ok` / `:degraded` / `:unavailable` overall status.
- `StandardHealth::Check` base class with a `with_timing` helper for subclasses.
