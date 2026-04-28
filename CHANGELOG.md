# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-04-28

### Added

- Initial release of `standard_health` — a mountable Rails engine providing `/alive`, `/ready`, and `/diagnostics/env` endpoints.
- `StandardHealth.configure` block with `register_check`, `parent_controller`, and `env_spec` accessors.
- `StandardHealth::EnvSpec` DSL for declaring required and recommended environment variables, with optional per-mode applicability via `in:`.
- Built-in checks: `Checks::ActiveRecord`, `Checks::SolidQueue`, `Checks::SolidCache`.
- `StandardHealth::Aggregator` rolls registered checks into `:ok` / `:degraded` / `:unavailable` overall status.
- `StandardHealth::Check` base class with a `with_timing` helper for subclasses.
