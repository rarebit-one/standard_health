# CLAUDE.md

## Worktree-Only Workflow (Enforced)

**All file modifications are blocked in the main checkout.** A PreToolUse hook (`enforce-worktree.sh`) rejects Edit, Write, and NotebookEdit operations targeting files outside a worktree. There are no opt-outs. Do not use Bash to write files in the main checkout either (e.g., `echo >`, `sed -i`, `tee`, `cp`) — the hook cannot intercept shell commands, so this rule is instruction-enforced.

Before writing any code, create a worktree:

```bash
DEFAULT_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@refs/remotes/origin/@@')
DEFAULT_BRANCH=${DEFAULT_BRANCH:-main}
git fetch origin "$DEFAULT_BRANCH"
git worktree add .worktrees/<name> -b <branch-name> "origin/$DEFAULT_BRANCH"
```

Then work inside `.worktrees/<name>/` for the rest of the session.

**Naming:** Use the Linear issue identifier if available (e.g., `.worktrees/<identifier>`), a task slug (e.g., `.worktrees/fix-auth-timeout`), or today's date (e.g., `.worktrees/2026-04-01`) as fallback.

See the `/worktree` and `/start` skills for full conventions.

## Gem layout

`standard_health` is a mountable Rails engine. The shape is:

- `lib/standard_health.rb` — module entry point, `configure` block, `parent_controller` lazy resolution.
- `lib/standard_health/engine.rb` — `Rails::Engine` subclass with `isolate_namespace`.
- `lib/standard_health/configuration.rb` — runtime config (registered checks, `parent_controller`, `env_spec`).
- `lib/standard_health/check.rb` — base class with `with_timing` helper.
- `lib/standard_health/checks/` — built-ins for ActiveRecord, SolidQueue, SolidCache.
- `lib/standard_health/aggregator.rb` — runs checks, classifies overall status.
- `lib/standard_health/env_spec.rb` — DSL for declaring required/recommended env vars.
- `app/controllers/standard_health/` — `HealthController` (alive/ready) + `DiagnosticsController` (env audit).
- `config/routes.rb` — engine routes.
- `spec/dummy/` — minimal Rails API host for testing.

## Conventions

- Every Ruby file starts with `# frozen_string_literal: true`.
- Specs live under `spec/standard_health/` mirroring the lib layout.
- The aggregator must never raise — wrap each check in `safe_run`.
- Host-app auth is the host app's responsibility. The engine exposes `parent_controller` as the seam.
