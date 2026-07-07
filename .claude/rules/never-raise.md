---
paths:
  - "lib/standard_health/aggregator.rb"
  - "lib/standard_health/check.rb"
  - "lib/standard_health/checks/**/*.rb"
---

# The health path must never raise

A health endpoint that 500s is worse than useless — orchestrators read it to
decide rotation, and an exception there can cascade an outage. So the whole
check/aggregate path degrades instead of raising. Preserve this when editing
checks or the aggregator.

## Invariants

- **`Aggregator.safe_run` rescues `StandardError`** for every check and converts
  it into a `status: :fail` row (keeping `name`/`critical`). A buggy custom
  check must never take down `/ready`. Don't let an exception escape `call`.
- **`Check#run` returns a status hash — it does not raise.** The base `run`
  returns `{ status: :fail, error: "not implemented" }` rather than raising, so a
  misconfigured custom check degrades. Custom checks should follow suit; wrap
  fallible work in **`with_timing`**, which times the block and rescues
  `StandardError` into `{ status: :fail, error: ... }`.
- Do not add `raise` (or let a library call raise uncaught) anywhere on the
  check → aggregate → render path. If you need to signal failure, return a
  `:fail` status.

## Status roll-up (don't change casually)

`Aggregator.overall_status`:

- every check `:ok` → **`:ok`**
- at least one **non-critical** check failed → **`:degraded`** (still serving —
  page someone, but stay in rotation)
- at least one **critical** check failed → **`:unavailable`** (pull from rotation)

`:degraded` vs `:unavailable` is driven entirely by each check's `critical:`
flag. Getting this wrong changes rotation behaviour in production.

## Housekeeping

Every Ruby file in this gem starts with `# frozen_string_literal: true` (a
documented convention here — the omakase cop that would enforce it is disabled,
so it's on you). Specs live under `spec/standard_health/` mirroring `lib/`.
