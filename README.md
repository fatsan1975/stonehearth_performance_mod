# Stonehearth Performance Mod (ACE 0.9.6)

This mod targets the primary long-tick hotspot seen in perf graphs (`filter_cache_cb`) while preserving gameplay behavior.

## Realistic performance expectations

`filter_cache_cb` is the dominant CPU cost in mid-to-late game Stonehearth — community profiling confirms it can consume 50-90% of a long tick as item/storage counts grow.

| Scenario | Expected gain |
|---|---|
| Singleplayer, 20+ hearthlings, many items | 10–20% fewer long ticks |
| Singleplayer, early game / few items | 2–5% (filter load is low) |
| Multiplayer | 5–10% (sync overhead is a separate ceiling) |
| Mega town (30+ hearthlings) | 15–25% if BALANCED/AGGRESSIVE used |

These are conservative estimates. Results depend on hearthling count, item count, storage layout, and hardware. The mod does **not** fix pathfinding, AI tick cost, or render performance.

## What it does

- Adds a **micro-cache** for repeated `filter_cache_cb` calls in storage/filter contexts.
- Adds **coalescing** so repeated dirty/update events trigger fewer recomputes.
- **Lua GC spreading**: tunes GC parameters and runs incremental steps per heartbeat to eliminate spike frames.
- **ACE restock service throttling**: coalesces burst restock checks (100ms window) — same magnitude bottleneck as filter_cache_cb in late-game.
- **Town/population coalescing**: rate-limits town score (500ms) and population stat (200ms) recalculations during event floods.
- **Workshop/crafting coalescing**: throttles `_check_auto_craft` and order re-evaluation bursts (200ms window) — same burst pattern as restock in late-game crafting-heavy towns.
- Wraps both `stonehearth_ace` and base `stonehearth` storage service paths (ACE-aware).
- **Deadline fallback**: if optimization overhead exceeds deadline, immediately runs original.
- **EMA health scoring** (v2): smooths health over time to prevent profile oscillation on brief spikes.
- **Downshift hysteresis**: stays in safe profile for 20s after a downshift, prevents ping-pong.
- **AI/task/path bypass**: worker, task_group, compound_action, pathfinding-shaped queries bypass cache entirely (extended classification).
- **Circuit breaker**: repeated optimizer errors → bypass that context temporarily.
- **Warm-resume guard**: after long pause/alt-tab → brief bypass to prevent input lockups.
- Per-context **cache kill-switches** (inventory always OFF, storage/filter configurable).
- Runtime-selectable profiles: **SAFE / BALANCED / AGGRESSIVE**.
- Performance presets: **Multiplayer Safe / Mega Town Stability / Singleplayer Throughput**.

## Compatibility and safety

- Designed for ACE Pre-Release 0.9.6 monkey patch style.
- Load order: put this mod **after** `stonehearth_ace` (via `dependencies` in `manifest.json`).
- Defensive patching via `pcall(require, ...)` and nil-checked wrappers.
- If uncertainty is detected, wrappers default to original behavior.

## Profiles

Values below match `scripts/perf_mod/config.lua` (source of truth).

### SAFE (default)
- TTL: 0.20s | Coalescing: 0ms | Deadline: 8ms | Deferred wait: 0ms
- Cache cap: 1000 entries | Max result size: 72 | Admission: 2nd hit

### BALANCED
- TTL: 0.35s | Coalescing: 45ms | Deadline: 12ms | Deferred wait: 40ms
- Cache cap: 1800 entries | Max result size: 96 | Admission: 2nd hit

### AGGRESSIVE
- TTL: 0.55s | Coalescing: 70ms | Deadline: 15ms | Deferred wait: 65ms
- Cache cap: 2600 entries | Max result size: 128 | Admission: 2nd hit

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
- `perfmod:ai_path_bypasses`
- `perfmod:noisy_signature_bypasses`
- `perfmod:context_bypasses`
- `perfmod:warm_resume_guards`
- `perfmod:auto_profile_downshifts`
- `perfmod:pump_budget_breaks`
- `perfmod:health_score`
- `perfmod:heavy_heartbeats` — perf_mod kendi heartbeat'i 5ms+ sürdüğünde
- `perfmod:task_invalidations` — task completion → filter cache invalidation sayısı
- `perfmod:tick_cache_hits` — tick-local memo hit sayısı (50ms pencere dedup kazanımı)
- `perfmod:fast_key_hits` — fast-path key generation kullanım oranı
- `perfmod:cache_entry_count` — anlık cache entry sayısı (gauge)
- `perfmod:restock_coalesces` — ACE restock check burst suppression sayısı
- `perfmod:town_score_coalesces` — town score burst suppression sayısı
- `perfmod:population_coalesces` — population stats burst suppression sayısı
- `perfmod:workshop_coalesces` — workshop/crafting order re-evaluation burst suppression sayısı

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

Negative result caching is disabled globally (`cache_negative_results = false`). However, the `filter` context enables negative caching with a very short TTL (80–150ms by profile). This is safe because generation-based invalidation is the primary guard — any inventory change immediately expires these entries. All other contexts (storage, inventory) still re-check on every miss.


## AI/IPF stability

To reduce AI/IPF spike risk, wrapping scope is narrowed to core matching callback (`filter_cache_cb`) and excludes broader search helpers like `find_best`/`find_items` that can influence pathing and task selection flow more directly.


## Safety circuit breaker

If optimizer-side errors repeat in a short time window for the same context, optimization for that context is temporarily opened (bypassed) and all calls fall back to original behavior. This protects simulation/UI stability during unexpected runtime shapes.


## Manifest compatibility note

Stonehearth expects `client_init_script` and `server_init_script` to reference Lua scripts. UI JavaScript/HTML are loaded through the `ui` section in `manifest.json`, and remote calls are exposed via the `functions` section.


## Gameplay tab integration (ACE)

This mod now injects its settings into ACE gameplay settings via `mixintos` targeting `stonehearth_ace:data:modded_settings`. The settings should appear under the mod section in the Settings > Gameplay panel.


## Localization path note

Stonehearth/ACE localization should live in `locales/<lang>.json` (e.g. `locales/en.json`). If placed elsewhere, Gameplay settings labels can appear as raw i18n keys.


## Presets

- **Multiplayer Safe**: strictest defaults, safest for shared servers.
- **Mega Town Stability**: highest stability, disables riskier filter-context caching.
- **Singleplayer Throughput**: balanced throughput for solo towns with safeguards.

## Memory Leak Prevention

Long sessions accumulate RAM through several patterns. This mod addresses all of them:

| Source | Mechanism | Fix |
|---|---|---|
| Throttle patches (`last_call`/`last_result`) | Dead service instances after game reload keep string keys forever | Periodic 60s cleanup: entries not seen for >120s removed |
| `_tick_results` nil-out | Lua hash tables don't shrink when keys nilled | Full table replacement (`= {}`) every 50ms heartbeat |
| `_record_failure` allocation | New `kept = {}` on every error → GC churn | In-place array compaction, zero allocation |
| Dynamic context states | `storage:task_inval_reset` keys accumulate indefinitely | `prune_stale_states()` every 60s removes idle contexts |
| Event listeners | `radiant.events.listen()` closure never destroyed on reload | `destroy()` method cleans listeners on service shutdown |

## Adaptive guardrails

- Runtime health scoring monitors long ticks and safety counters.
- If health degrades, AGGRESSIVE can downshift to BALANCED/SAFE automatically.
- After long game-loop stalls (background/menu return), warm-resume guard bypasses optimization briefly.
