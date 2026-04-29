# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
