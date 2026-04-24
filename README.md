# Performance Mod for ACE Stonehearth v400,7

Late-game performance optimization for Stonehearth with the ACE expansion. Cuts simulation CPU load so your town can grow larger before the engine starts choking.

---

## Why This Mod Exists

Stonehearth's entire simulation runs on a single CPU thread. Early game this is fine, but as your town grows past twenty hearthlings with hundreds of items and dozens of storage containers, the same handful of functions start eating almost all of your per-tick CPU budget. The game begins to stutter, workers spend more time idle waiting for queries to resolve, and eventually the engine can't finish a tick in time — causing hitches, dropped updates, and that familiar late-game slowdown.

The biggest offenders, measurable in any profiler, are the filter cache callback and Lua's garbage collector. The C++ filter cache gets hammered every time an item moves, causing cascading cache invalidations. The garbage collector runs overtime cleaning up per-tick allocations that the engine doesn't need to produce in the first place.

This mod rewrites those hot paths to do far less duplicate work, without changing what the game actually does. Hearthlings still haul, restock, craft, and build exactly as before — they just stop waiting on the engine for things it already knows.

---

## Measured Impact

Numbers from in-game profiler, 23-hearthling late-game town with ACE + companion mods, SAFE profile:

| Profiler Metric | Without Mod | With Mod | Change |
|---|---|---|---|
| `filter_cache_cb` | 15–18% | **0.0–0.6%** | eliminated |
| `lua_gc` | ~22% | **~21%** | slightly improved |
| `idle` (available CPU) | 30–35% | **~42%** | +10 percentage points |

The `filter_cache_cb` reduction is where most of the win comes from. In a busy hauling burst, that function can briefly consume more than half of a long tick in the unmodded game. After this mod, it is essentially free.

Results depend heavily on town size, item count, storage layout, and hardware. Small and mid-game towns show little difference — the bottlenecks haven't kicked in yet. Large late-game towns see the most dramatic improvement, because that's where the modded systems were spending all their time.

---

## How It Works

The mod hooks a small number of specific engine functions at runtime. Each hook is independently toggleable and has a fallback to the original behavior if anything goes wrong.

**URI-based filter rejection cache.** When a hearthling checks whether an item passes a storage filter, the engine normally does several C++ boundary crossings per item. This mod caches the result by `(player_id, item_uri)` so that, for example, after the first "pine log" is rejected by a stone-only filter, every other pine log rejection returns instantly without touching C++. Only negative results are cached (positive results depend on runtime state like accessibility).

**Reconsider deduplication.** When an item changes, ACE's reconsider cascade fires for the item, its container, and often its parent — all in the same tick. This mod tracks which entities have already been processed this tick and skips duplicate work. The engine gets the same notifications it would normally get, just without the redundant ones.

**Filter cache throttle.** The ACE per-storage filter cache gets invalidated on item changes. Our throttle prevents the same `(storage, item)` pair from being invalidated twice in one tick, because the second invalidation does no new work.

**Allocation elimination.** The engine's reconsider callback loop creates a new table and a closure per entity per tick. We replace that with a reused callback snapshot and direct pcall dispatch — same behavior, zero allocations per tick. In a busy burst this saves hundreds of short-lived tables per second, which means less garbage for Lua to collect.

**Contents-changed coalescing.** When a trade wagon dumps twenty items into the same storage in the same second, the storage component's update handler fires twenty times. We fire it once per storage per second. The storage state is idempotent from this handler's perspective, so the result is identical.

**Adaptive garbage collection.** Stonehearth ships with Lua's default GC parameters, which cause large full collections at unpredictable moments. This mod tunes the GC to pause earlier and step incrementally on a heartbeat, so GC work is spread across many small steps instead of spiking.

---

## Profiles

Three profiles control the aggressiveness of caching and workload limits. You can switch between them in the ACE Gameplay Settings panel at any time — no reload required.

**SAFE** — The recommended starting point. Conservative cache lifetimes, standard workload limits. Works well for most towns and has been the highest-measured profile in testing.

**BALANCED** — Slightly tighter workload spreading, faster cache refresh. Good for towns in the 15–20 hearthling range.

**AGGRESSIVE** — Maximum caching with longer retention, tighter entity spread per tick, and experimental coalescing enabled. Intended for very large towns where every last millisecond matters.

All three profiles use the same garbage-collector tuning. That was a deliberate decision after testing showed more aggressive GC parameters actually hurt performance by doubling up on Lua's already-tuned automatic cycles.

---

## Installation

1. Subscribe to this mod on the Stonehearth Steam Workshop, or download and place the `aceperformancemodforstonehearth` folder in your Stonehearth `mods/` directory.
2. Make sure Stonehearth ACE is also installed. This mod requires ACE and loads automatically after it.
3. Launch the game. The mod initializes during server startup and logs its status to `stonehearth.log`.
4. Open Settings → Gameplay → Performance Mod to pick a profile. SAFE is the default.

Load order is handled automatically through the dependency system. You do not need to edit any config files or modify the mod load order.

---

## Compatibility

- **Stonehearth ACE** (required dependency, Pre-Release 0.9.6 and newer)
- Compatible with LostEms, autoharvest_mod, and most other ACE-compatible content mods
- Safe to add to existing saves
- Safe to remove from existing saves (the game reverts cleanly)
- Does not affect multiplayer sync or save file format
- Does not modify any game files — all changes are runtime monkey-patches

If you run other performance-oriented mods that also hook the AI service or inventory system, disable them first to avoid conflicting overrides.

---

## Safety Design

The mod is built around a simple rule: **hearthlings must never stop working because of this mod**. Everything else is secondary. Three independent safety layers enforce this.

**Hearthling idle watchdog.** Every ten seconds the mod samples all citizens and computes the percentage that are idle. If more than 60% remain idle for three consecutive samples (thirty seconds sustained), the mod immediately disables all non-GC patches and switches to the SAFE profile. When the idle ratio recovers, patches re-apply automatically.

**Per-patch circuit breaker.** If any patch throws an error five times within sixty seconds, that patch is automatically disabled and a warning is logged. Other patches continue running normally.

**Warm-resume guard.** If the real-time heartbeat gap exceeds three seconds (the user paused the game, alt-tabbed, or suspended the system), the mod flushes all in-memory caches on resume to prevent any stale data from being served.

Every state change — profile switch, patch toggle, safety trigger — is logged to `stonehearth.log` with a clear prefix (`[perf_mod.state]`, `[perf_mod.safety]`, `[perf_mod.error]`) so troubleshooting is straightforward.

---

## Log Output

The mod logs its own activity every ten seconds (short summary) and every sixty seconds (full counter snapshot). Typical output looks like this:

```
[perf_mod.metric]  60s (Δ10s) P1=52 PA=11797 P3=242 PC=5 PE=27 GC=2
[perf_mod.metric]  60s (total) patches=6 PA_reject=107092 PA_cache=2840 
                   P3_dedup=359 PC_throttle=0 PE_evt=329 PE_coal=23(6%) 
                   P1_spread=218 GC_step=6 wd_trips=0 cb_trips=0
```

These numbers tell you the mod is actually working. `PA_reject` should grow continuously during gameplay; `wd_trips` and `cb_trips` should stay at zero. If they don't, check the `[perf_mod.safety]` log lines for the reason.

---

## Troubleshooting

**"No noticeable improvement."** The mod targets late-game bottlenecks. On early and mid game towns, the bottlenecks don't dominate, so the improvement is small. Try the same save before and after with a town of 20+ hearthlings and lots of items — the difference is much more visible there.

**"Hearthlings seem slower to react."** If you use the AGGRESSIVE profile, entity spread limits are tighter, so bursts of reconsider events are processed over more ticks. Switch to SAFE if this is a problem — reaction time is back to vanilla.

**"Mod says it failed to apply a patch."** Check `stonehearth.log` for a line starting with `[perf_mod.error]`. The most common cause is an engine API mismatch after a major Stonehearth update. The mod falls back gracefully in this case — the other patches continue working.

**"Watchdog fired unexpectedly."** The 60% idle threshold is deliberately generous, so a watchdog fire usually means something else is affecting hearthlings (a city alarm, a quest, a physical terrain issue). The mod disables itself as a safety measure. Investigate the root cause; then the mod will re-enable automatically.

**"Still seeing `game loop exhausted`."** The mod reduces Lua-side overhead, but the C++ simulation has its own per-tick budget. In very heavy saves, simply lowering graphics settings, reducing hearthling count, or consolidating storage containers often helps more than any additional code-side optimization.

---

## For Developers and Modders

The mod is a single-file inline architecture to avoid Stonehearth's tricky module loading behavior. All patch code lives in `stonehearth_performance_mod_server.lua` with clearly separated blocks for each patch.

For complete technical details — every hook point, every counter, every architecture decision — see **`CURRENT_STATE.md`** in the repository. That document is kept up to date with the current implementation and is the canonical reference for anyone continuing this work.

Contributions and issue reports are welcome. Please include a profiler screenshot (the in-game perf bar) and the last few `[perf_mod.metric]` lines from `stonehearth.log` with any report.

---

## Credits

- **Author:** Fatih1975
- **Steam Workshop ID:** 3669297036
- **License:** See the `LICENSE` file in the repository
- Special thanks to the ACE team for keeping Stonehearth alive and to the Radiant engine community whose analysis of the filter cache made this work possible.
