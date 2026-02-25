# Stonehearth Performance Mod — Full Agent Handoff Notes

This document is a **deep technical handoff** for the next agent. It captures project intent, architecture, past problems, fixes, caveats, workflow, and actionable next steps so development can continue immediately without losing context.

---

## 1) Project identity

- **Mod name**: Stonehearth Performance Mod
- **Namespace**: `stonehearth_performance_mod`
- **Target stack**:
  - Stonehearth (base game)
  - Stonehearth ACE (Pre-Release line referenced by user, esp. 0.9.x)
- **Language/runtime**:
  - Server/client init and gameplay logic in **Lua**
  - UI view layer may include HTML/JS assets in manifest `ui` section (this is valid), but init scripts must be Lua.

Core manifest settings are in `manifest.json` and currently point to Lua init scripts and ACE mixin integration. See: `server_init_script`, `client_init_script`, `functions`, `mixintos`, and `ui` sections.  

---

## 2) What this mod is trying to solve

### Primary hotspot
- User profiling repeatedly identified `filter_cache_cb` as dominant CPU cost (often very high share in long ticks).

### Secondary pain points
- `lua_gc` spikes
- Lua script time spikes generally
- AI/IPF/path-related jumps in busy colonies/multiplayer
- gameplay regressions from over-aggressive caching/wrapping (idle workers, missed item visibility, UI/input unresponsiveness)

### Hard requirement from user
- Improve performance **without breaking gameplay correctness**.
- “Fast but safe”: always prefer fallback/original behavior if uncertainty or risk.

---

## 3) Key constraints learned during this project

1. **Stonehearth init scripts must be Lua**  
   - `client_init_script`/`server_init_script` cannot be JS.
2. **UI HTML/JS are still valid** in `manifest.json` under `ui` resources.
3. **Localization path matters** for ACE Gameplay settings labels:
   - Use `locales/en.json` (not old `i18n/en.json`) so i18n keys resolve in settings UI.
4. **ACE gameplay settings injection** works via `mixintos`:
   - target `stonehearth_ace:data:modded_settings`.

---

## 4) High-level architecture

### Server bootstrap and service
- `scripts/server/bootstrap.lua` initializes mod server side.
- `scripts/perf_mod/service.lua` is the orchestration layer:
  - settings initialization
  - cache/coalescer/instrumentation/optimizer wiring
  - applying monkey patches
  - best-effort event listeners
  - heartbeat scheduling
  - adaptive runtime guardrails (health score, warm-resume guard, runtime profile downshift)

### Settings and config
- `scripts/perf_mod/config.lua` holds profile values and defaults.
- `scripts/perf_mod/settings.lua` stores/reads runtime settings and global config values.

### Query optimization pipeline
- `scripts/perf_mod/query_optimizer.lua`
  - wraps selected query callbacks
  - strict deadline-based fallbacks
  - admission control before caching
  - multiple bypass paths (urgent, ai/path, noisy signature, context-disabled, warm-resume)
  - safety fallback via `pcall`
  - per-context circuit breaker to force original path when failures repeat

### Cache and maintenance
- `scripts/perf_mod/micro_cache.lua`
  - stable key generation
  - complexity/depth safety bypass (returns nil key => no cache)
  - generation invalidation per context
  - bounded capacity and pruning

- `scripts/perf_mod/coalescer.lua`
  - coalesces invalidation/recompute work
  - runtime budget limits per pump (callback count + ms budget)

### Discovery and patching
- `scripts/perf_mod/patch_discovery.lua`
  - conservative candidate discovery when enabled
- `monkey_patches/*.lua`
  - narrowed patch surface (focus on core matching callbacks, reduce AI/path flow interference)

### Instrumentation
- `scripts/perf_mod/instrumentation.lua`
  - internal counters
  - optional publication to perf monitor

### RPC/endpoint handlers
- `scripts/perf_mod/call_handler.lua`
  - settings getter/updater
  - ACE gameplay on_change command endpoints

### UI and Gameplay settings integration
- UI view files:
  - `ui/game/modes/mods/perf_mod/perf_mod_settings.html`
  - `ui/game/modes/mods/perf_mod/perf_mod_settings.js`
- ACE Gameplay panel integration:
  - `data/gameplay_settings/perf_mod_gameplay_settings_mixin.json`
- Localization:
  - `locales/en.json`

---

## 5) Current behavior and safety model (important)

The mod now follows a layered safety model:

1. **Conservative defaults**
   - SAFE profile default
   - negative result caching disabled
2. **Bypass-first for risky classes**
   - urgent inventory-like queries bypass
   - AI/path-shaped query signatures bypass
   - noisy signature bypass
3. **Context kill-switches**
   - enable/disable cache optimization per context (inventory/storage/filter)
4. **Deadline fallback**
   - if optimization prelude exceeds budget, call original immediately
5. **Safety fallback (`pcall`)**
   - optimizer exceptions trigger immediate original behavior
6. **Circuit breaker**
   - repeated failures open circuit for context; bypass optimization temporarily
7. **Warm-resume guard**
   - after stall/pause-like heartbeat gap, temporarily bypass optimization
8. **Adaptive profile downshift**
   - runtime health score can downshift profile to BALANCED/SAFE
9. **Bounded maintenance budget**
   - coalescer pump budget prevents maintenance from monopolizing ticks

---

## 6) Presets/profiles currently implemented

### Profiles
- SAFE / BALANCED / AGGRESSIVE each define:
  - TTLs
  - coalesce intervals
  - query deadlines
  - cache caps
  - result-size limits
  - admission threshold
  - circuit settings
  - coalescer budget
  - noisy-signature threshold

### Presets
- MULTIPLAYER_SAFE
- MEGA_TOWN_STABILITY
- SINGLEPLAYER_THROUGHPUT

Presets map to profile + kill-switch defaults and are exposed in ACE Gameplay settings and call handlers.

---

## 7) Major historical issues and what fixed them

### A) “Invalid Manifest” and load failures
- Cause: non-compatible manifest shapes/fields in earlier iterations.
- Fix: normalize manifest to Stonehearth-compatible layout with proper `info.namespace`, `version`, Lua init scripts, and valid sections.

### B) “Stonehearth doesn’t read JS scripts” feedback
- Clarification and fix:
  - init scripts switched to Lua (`scripts/client/bootstrap.lua`, `scripts/server/bootstrap.lua`)
  - UI JS kept under manifest `ui.js`, which is valid for UI resources.

### C) Gameplay settings not appearing / raw i18n keys
- Cause: missing/incomplete ACE mixin wiring and localization path mismatch.
- Fix:
  - `mixintos` into `stonehearth_ace:data:modded_settings`
  - gameplay settings schema file added and expanded
  - localization moved to `locales/en.json`
  - labels/descriptions shortened for readable UI

### D) Item visible in storage but query says not found
- Cause hypothesis: stale negative cache entries.
- Fix: disable negative caching by default (`cache_negative_results = false`) and keep positive caching only.

### E) Idle workers / simulation stalls / freeze-like symptoms
- Cause hypothesis: overly broad hook surface + stale/unsafe cache reuse + maintenance pressure.
- Fixes over iterations:
  - narrower hook surface
  - strict fallback and circuit breaker
  - complex-key/noisy-signature bypass
  - urgent bypass
  - coalescer budget caps
  - warm-resume guard
  - adaptive downshift

---

## 8) External references and research sources used

### Official docs / guidance
- Stonehearth modding guide provided by user:
  - `https://stonehearth.github.io/modding_guide/index.html`

### Community signal collection used during troubleshooting
- Steam community discussions list (for recurring complaints like idle workers / lag / saves for perf bugs):
  - `https://steamcommunity.com/app/253250/discussions/`
- Stonehearth Discourse search endpoints for `performance`, `pathfinding`, `idle hearthlings`, multiplayer performance:
  - `https://discourse.stonehearth.net/search.json?q=performance`
  - plus analogous search queries.

Notes from those sources that guided priorities:
- late-game degradation is common
- idle worker reports are common
- multiplayer performance drop/lockups are recurrent
- pathfinding/AI spikes are recurring complaints
- save-driven diagnosis is often requested by maintainers/community

---

## 9) Libraries/dependencies/tooling actually used

### Runtime/game side
- Stonehearth/Radiant APIs (Lua environment)
- ACE mod data mixin system (`mixintos`)

### Development/test side
- JSON validation: `jq`
- Lua syntax check: `luac` / `luac5.4`
- Lua test run: `lua` / `lua5.4`
- In this environment, `lua5.4` was installed via apt during testing.

No third-party Lua libraries are introduced into mod runtime.

---

## 10) Files to read first (for new agent)

1. `manifest.json` (loading/wiring surface)
2. `scripts/perf_mod/config.lua` (profiles/presets/defaults)
3. `scripts/perf_mod/settings.lua` (persistence + config read)
4. `scripts/perf_mod/service.lua` (runtime orchestration)
5. `scripts/perf_mod/query_optimizer.lua` (core behavior)
6. `scripts/perf_mod/micro_cache.lua` (cache semantics)
7. `scripts/perf_mod/coalescer.lua` (maintenance budget)
8. `scripts/perf_mod/instrumentation.lua` (observability)
9. `data/gameplay_settings/perf_mod_gameplay_settings_mixin.json` (ACE UI config)
10. `locales/en.json` (display strings)
11. `tests/run_lua_tests.lua` (behavior assertions)
12. `README.md` (intent and operator guidance)

---

## 11) What still needs cleanup / caution

1. **README numeric values may lag config**
   - Ensure profile numbers in README match `config.lua` after each tuning pass.
2. **Adaptive downshift hysteresis**
   - Runtime profile logic may need dampening windows to avoid oscillation.
3. **Warm-resume tuning**
   - Guard duration may need scenario-specific tuning (esp multiplayer).
4. **Context defaults**
   - Inventory bypass is safest but may reduce throughput; evaluate with reproducible saves.
5. **Discovery mode**
   - Keep OFF by default; only enable for controlled profiling sessions.

---

## 12) Suggested workflow for the next agent

1. Reproduce with at least 3 save scenarios:
   - mega item storage
   - large construction workflow
   - multiplayer-style high churn
2. Collect before/after counters:
   - long ticks
   - fallback rates
   - circuit openings
   - warm-resume guard triggers
   - health score trend
3. Tune one variable group at a time:
   - deadlines/ttl
   - bypass thresholds
   - coalescer budget
4. Keep correctness first:
   - any sign of “item not found”, input freeze, or idle collapse => increase bypass and fallback conservatism.
5. Update README + locale strings when behavior changes.

---

## 13) Regression checklist before release

- [ ] Mod loads without invalid manifest.
- [ ] ACE Gameplay settings show readable labels (no raw i18n keys).
- [ ] Preset selection updates settings correctly.
- [ ] No negative-cache sticky miss behavior.
- [ ] No optimizer exception can break gameplay path (safety fallback active).
- [ ] Circuit opens and recovers as expected.
- [ ] Warm-resume guard triggers after long stall and restores controls.
- [ ] Unit tests pass.
- [ ] JSON + Lua syntax checks pass.

---

## 14) Compact module-by-module summary

- **config.lua**: canonical tuning source (profiles, presets, defaults).
- **settings.lua**: persistent config model + preset application + context map.
- **service.lua**: boot + heartbeat + adaptive health/downshift + event wiring.
- **query_optimizer.lua**: wrapping, classification, bypasses, cache decisions, safety fallback, circuit logic.
- **micro_cache.lua**: key generation, admission support, bounded cache, generation invalidation.
- **coalescer.lua**: defers and bounds maintenance callbacks.
- **instrumentation.lua**: counter registry and publishing.
- **call_handler.lua**: server endpoints for UI/ACE on_change calls.
- **manifest.json**: integration contract (scripts/functions/ui/mixins).
- **mixin + locales**: player-facing settings UX.

---

## 15) Final intent statement (for continuity)

This mod is no longer “cache as much as possible.” It is now designed as a **stability-first optimizer** for Stonehearth/ACE: it attempts to reduce `filter_cache_cb` pressure but aggressively falls back to original behavior when runtime uncertainty appears. Performance wins are acceptable only when they do **not** compromise simulation correctness, item visibility, worker task acquisition, or UI responsiveness.

