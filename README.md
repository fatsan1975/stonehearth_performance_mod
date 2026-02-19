# Stonehearth Performance Mod (ACE 0.9.6)

This mod targets the primary long-tick hotspot seen in perf graphs (`filter_cache_cb`) while preserving gameplay behavior.

## What it does

- Adds a **micro-cache** for repeated filter/query calls in storage/inventory/filter contexts.
- Adds **coalescing** so repeated dirty/update events trigger fewer recomputes.
- Query wrappers use a strict optimization budget check and immediately fall back to original query execution if the optimization prelude exceeds profile deadline.
- Cache invalidation schedules coalesced maintenance-only pruning (never defers gameplay-critical query responses).
- Adds **deadline fallback** so optimized paths immediately defer to original behavior if budgets are exceeded.
- Adds conservative **runtime patch discovery** for ACE/base modules where exact function paths differ.
- Adds low-overhead **instrumentation counters** to validate improvements.
- Adds runtime-selectable profiles: **SAFE / BALANCED / AGGRESSIVE**.

## Compatibility and safety

- Designed for ACE Pre-Release 0.9.6 monkey patch style.
- Load order: put this mod **after** `stonehearth_ace` (priority 210 in manifest).
- Defensive patching via `pcall(require, ...)` and nil-checked wrappers.
- If uncertainty is detected, wrappers default to original behavior.

## Profiles

### SAFE
- TTL: 0.25s (negative TTL 0.35s)
- Coalescing: same-tick
- Query deadline cap: 10ms
- Deferred wait cap: 0ms (no intentional deferral)

### BALANCED
- TTL: 0.55s (negative TTL 0.8s)
- Coalescing: ~75ms
- Query deadline cap: 15ms
- Deferred wait cap: 75ms

### AGGRESSIVE
- TTL: 1.2s (negative TTL 1.8s)
- Coalescing: ~150ms
- Query deadline cap: 24ms
- Deferred wait cap: 150ms

## Instrumentation counters

- `perfmod:cache_hits`
- `perfmod:cache_misses`
- `perfmod:negative_hits`
- `perfmod:recomputes_coalesced`
- `perfmod:recompute_calls`
- `perfmod:incremental_scan_steps`
- `perfmod:full_scan_fallbacks`
- `perfmod:deadline_fallbacks`
- `perfmod:avg_query_ms`
- `perfmod:long_ticks`

## Patch discovery

By default discovery is OFF.

When enabled:
- preloads known ACE/base candidates,
- scans `package.loaded` for allowlisted module roots (`stonehearth*`, `stonehearth_ace*`),
- ranks likely hot-path candidates by names/source hints (`filter_cache_cb`, `filter`, `inventory`, `storage`, etc.),
- hooks only top N candidates per profile.

## Test plan

1. **Baseline**
   - Disable mod and collect perf data (`perf_mon` + long tick logs).
   - Record long tick count and `filter_cache_cb` CPU share.
2. **SAFE profile**
   - Enable mod with SAFE and verify hauling/crafting feel unchanged.
   - Expect reduced spikes and some cache-hit wins.
3. **BALANCED profile**
   - Verify responsiveness remains unchanged in busy colonies.
   - Expect higher hit rate and fewer repeated recomputes.
4. **AGGRESSIVE profile**
   - Stress with 20+ hearthlings and large item count.
   - Confirm deadline fallback remains low and no visible action lag.
5. **Validation targets**
   - Lower long-tick frequency,
   - Lower `filter_cache_cb` share,
   - Higher idle percentage,
   - High cache-hit ratio without stalled task acquisition.

## Local static test commands (used in CI shell)

- `find scripts monkey_patches -name '*.lua' -print0 | xargs -0 -n1 luac -p`
- `lua tests/run_lua_tests.lua`
