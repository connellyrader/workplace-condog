# Slack Backfill Manifest

## Purpose
Define the canonical philosophy and implementation for Slack history backfill.

This document is the source of truth for how backfill should behave in production.

## Philosophy
1. Onboarding-first: get useful historical coverage visible quickly across many channels.
2. Deterministic stages: complete 30-day readiness first, then deepen history in waves.
3. Parallel without overlap: allow concurrent runs, but never process the same channel in two runs at once.
4. Minimal knobs: tune by channel count, not many paging flags.
5. Resilient retries: retry transient failures after cooldown, skip known non-actionable failures.

## Stage Model
There are only two execution stages:

1. Phase A (`phase_a_30d`)
- Goal: make every eligible channel 30-day ready.
- Behavior: selected channels page unbounded until they hit the 30-day cutoff (or channel creation boundary if newer).
- Status outcomes:
  - `ok` if progress was made
  - `empty_complete_30d` if no messages exist in that window

2. Phase B (`phase_b_deep`)
- Goal: deepen history for channels that already passed phase A.
- Behavior: breadth-first wave progression in staged milestones:
  - 60d
  - 90d
  - 6 months
  - 9 months
  - 12 months
  - 15 months
  - then continue in +3 month increments
  Not full-drain per channel in one pass.
- Ordering bias: least-covered channels first.
- Status outcomes:
  - `ok` if progress was made in the current wave target
  - `empty_complete_deep` when no messages remain at/near the deepest boundary
  - `backfill_complete=true` when channel reaches creation boundary

## Scheduler Behavior
Backfill tick runs every 2 minutes with bounded channel count:

```ruby
every '*/2 * * * *' do
  rake "slack:backfill:tick BACKFILL_MAX_PER_TICK=12"
end
```

Tick policy:
1. If any phase A channel exists, run phase A only.
2. If phase A is fully drained, run phase B.

## Eligibility and Filtering
Base scope:
1. Slack integrations only (`integrations.kind = 'slack'`)
2. Non-archived channels only (`channels.is_archived = false`)
3. Optional workspace scoping via `BACKFILL_WORKSPACE_ID`

Retry/cooldown policy:
1. `history_unreachable = true` channels are excluded.
2. `No available Slack user token...` error channels are excluded (non-actionable).
3. Other error-like statuses retry only after cooldown (`DEFAULT_ERROR_RETRY_AFTER_MINUTES = 30`).

## Concurrency and Locking
Backfill uses advisory locks in two levels:

1. Channel-level claim lock (`PgLease` scope `:backfill`)
- A run claims up to `BACKFILL_MAX_PER_TICK` channels up front.
- Claimed channels are disjoint across concurrent runs.
- Locks are released in `ensure` for each channel and again in final cleanup.

2. No global backfill tick lock
- Parallel runs are allowed.
- Overlapping runs should process different channels due to up-front claiming.

## Paging Semantics
1. API page size is fixed (`PAGE=200`).
2. Channel pagination is time-window based (oldest/latest bounds), not stored Slack cursor tokens.
3. Cursor advancement uses the oldest timestamp seen on the page with overlap safety.
4. Phase A is unbounded to its stage boundary for selected channels.
5. Phase B is unbounded to the current wave target boundary for selected channels.

## Profile and User Resolution
Backfill ingestion does not call `users.info` for per-message enrichment.

Current behavior:
1. Ensure `IntegrationUser` exists by `slack_user_id`.
2. Fill profile fields from message payload when available.
3. Avoid `users.info` in the hot path to keep backfill throughput high.

## Operational Knobs
Supported backfill knobs:
1. `BACKFILL_MAX_PER_TICK` (primary throughput control)
2. `BACKFILL_WORKSPACE_ID` (scope runs to one workspace)

Defaults in code:
1. `DEFAULT_MAX_PER_TICK = 80`
2. `DEFAULT_ERROR_RETRY_AFTER_MINUTES = 30`

## Health Expectations
Expected logs during healthy runs:
1. Tick mode line:
   - `[slack:backfill:tick] mode=phase_a_30d ...`
   - `[slack:backfill:tick] mode=phase_b_deep ...`
2. Phase lines:
   - `[slack:backfill:phase_a] channels=N paging=unbounded ...`
   - `[slack:backfill:phase_b] channels=N paging=wave_30d ...`

Expected DB movement:
1. `backfill_next_oldest_ts` moves backward in time for active channels.
2. `backfill_window_days` grows (minimum remains 30 by design).
3. `last_history_status` changes (`ok`, `empty_complete_30d`, `empty_complete_deep`, `error`, etc.).
4. `backfill_complete` eventually flips to `true` for completed deep history.

## Anti-Goals
Do not reintroduce:
1. Many independent stage flags (`60d`, `90d`, `1y`) as scheduler states.
2. Per-message `users.info` API calls in backfill hot path.
3. Global tick serialization unless explicitly required for incident response.

## Source Files
Implementation currently lives in:
1. `lib/tasks/slack_sync.rake`
2. `app/services/slack/history_ingestor.rb`
3. `app/services/slack/user_resolver.rb`
4. `config/schedule.rb`
