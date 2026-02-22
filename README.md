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
- Load order: put this mod **after** `stonehearth_ace` (via `dependencies` in `manifest.json`).
- Defensive patching via `pcall(require, ...)` and nil-checked wrappers.
- If uncertainty is detected, wrappers default to original behavior.

## Profiles

### SAFE
- TTL: 0.25s (negative TTL 0.35s)
- Coalescing: same-tick
- Query deadline cap: 10ms
- Deferred wait cap: 0ms (no intentional deferral)
- Cache cap: ~1200 entries; max cached result size: 96; admission: first-hit cache enabled

### BALANCED
- TTL: 0.45s (negative TTL 0.65s)
- Coalescing: ~60ms
- Query deadline cap: 14ms
- Deferred wait cap: 60ms
- Cache cap: ~2200 entries; max cached result size: 128; admission: cache after 2nd hit; urgent inventory bypass

### AGGRESSIVE
- TTL: 0.75s (negative TTL 1.0s)
- Coalescing: ~90ms
- Query deadline cap: 18ms
- Deferred wait cap: 80ms
- Cache cap: ~3200 entries; max cached result size: 160; admission: cache after 2nd hit; urgent inventory bypass

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
- `perfmod:admission_skips`
- `perfmod:oversized_skips`
- `perfmod:dirty_negative_bypasses`
- `perfmod:urgent_bypasses`
- `perfmod:key_bypass_complex`
- `perfmod:negative_cache_skips`
- `perfmod:safety_fallbacks`
- `perfmod:circuit_open_bypasses`

## Patch discovery

By default discovery is OFF.

When enabled:
- preloads known ACE/base candidates,
- scans `package.loaded` for allowlisted module roots (`stonehearth*`, `stonehearth_ace*`),
- ranks likely hot-path candidates by names/source hints (`filter_cache_cb`, `filter`, `inventory`, `storage`, etc.),
- hooks only top N candidates per profile (kept very low for stability).

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


## Troubleshooting: Invalid Manifest

If the game shows `Invalid Manifest`, verify:
- `manifest.json` has `info.namespace` and `info.version` set to API version `3`.
- The file is valid JSON (UTF-8, no trailing commas).
- Folder layout is exactly `.../mods/stonehearth_performance_mod/manifest.json` (no extra nested folder).


## Multiplayer stability notes

To avoid worker-idle stalls under very high item counts, this mod now uses stricter cache keys (target + query args), shorter negative-cache windows in BALANCED/AGGRESSIVE, bounded cache capacity with oldest-entry pruning, second-hit cache admission (to avoid one-off pollution), urgent inventory bypass, complex filter signatures bypass (safety over risky hashing), and a conservative discovery allowlist that only wraps known query-shaped methods.


## Item visibility safety

To reduce "item exists but not found" reports, negative result caching is disabled by default in all profiles. Positive-result cache still provides the performance win, while negative misses always re-check on the next query.


## AI/IPF stability

To reduce AI/IPF spike risk, wrapping scope is narrowed to core matching callback (`filter_cache_cb`) and excludes broader search helpers like `find_best`/`find_items` that can influence pathing and task selection flow more directly.


## Safety circuit breaker

If optimizer-side errors repeat in a short time window for the same context, optimization for that context is temporarily opened (bypassed) and all calls fall back to original behavior. This protects simulation/UI stability during unexpected runtime shapes.


## Manifest compatibility note

Stonehearth expects `client_init_script` and `server_init_script` to reference Lua scripts. UI JavaScript/HTML are loaded through the `ui` section in `manifest.json`, and remote calls are exposed via the `functions` section.


## Gameplay tab integration (ACE)

This mod now injects its settings into ACE gameplay settings via `mixintos` targeting `stonehearth_ace:data:modded_settings`. The settings should appear under the mod section in the Settings > Gameplay panel.
