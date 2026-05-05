# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
