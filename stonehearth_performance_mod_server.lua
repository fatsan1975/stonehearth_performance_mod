-- stonehearth_performance_mod_server.lua
-- v400 — Massive Performance Update for Stonehearth + ACE
-- All patch code is inline. No `require` for patches. No `class()`. Plain tables.

stonehearth_performance_mod = {}

local log = radiant.log.create_logger('perf_mod')
log:always('[perf_mod] v400 server script loaded')

-- ═════════════════════════════════════════════════════════════════════════
-- FORWARD DECLARATIONS (filled in later — needed by watchdog/breaker closures)
-- ═════════════════════════════════════════════════════════════════════════

local _get_patch_map
local _resolve_patch_enabled
local _patch_enabled
local _breaker
local _current_profile = 'BALANCED'
local _heartbeat_count = 0

-- Safe monotonic time in seconds.
-- Stonehearth's sandbox uses strict.lua: accessing undeclared globals like `os`
-- throws, so we look it up via rawget(_G, 'os') (strict-safe). If that still
-- does not expose a real-time clock, we fall back to the heartbeat counter
-- (1-second granularity — coarser but good enough for 60s sliding windows and
-- heartbeat-paced GC stepping).
local function _safe_clock()
   local g = rawget(_G or {}, 'os')
   if type(g) == 'table' and type(g.clock) == 'function' then
      local ok, t = pcall(g.clock)
      if ok and type(t) == 'number' then return t end
   end
   return _heartbeat_count
end

-- ═════════════════════════════════════════════════════════════════════════
-- PROFILES
-- ═════════════════════════════════════════════════════════════════════════

local PROFILES = {
   SAFE = {
      id = 'SAFE',
      reconsider_alloc = true,
      filter_fast_reject = true,
      dedup_first = true,
      reconsider_limiter = true,
      gc_tuning = true,
      restock_throttle = false,
      contents_coalesce = false,
      max_reconsider_per_tick = 80,
      reject_flush_interval = 400,
      gc_pause = 120,
      gc_stepsize = 80,
      post_spike_steps = 1,
      spike_threshold_ms = 80,
      restock_throttle_ms = 150,
   },
   BALANCED = {
      id = 'BALANCED',
      reconsider_alloc = true,
      filter_fast_reject = true,
      dedup_first = true,
      reconsider_limiter = true,
      gc_tuning = true,
      restock_throttle = false,
      contents_coalesce = false,
      max_reconsider_per_tick = 64,
      reject_flush_interval = 300,
      gc_pause = 110,
      gc_stepsize = 100,
      post_spike_steps = 2,
      spike_threshold_ms = 60,
      restock_throttle_ms = 100,
   },
   AGGRESSIVE = {
      id = 'AGGRESSIVE',
      reconsider_alloc = true,
      filter_fast_reject = true,
      dedup_first = true,
      reconsider_limiter = true,
      gc_tuning = true,
      restock_throttle = true,
      contents_coalesce = true,
      max_reconsider_per_tick = 48,
      reject_flush_interval = 200,
      gc_pause = 105,
      gc_stepsize = 120,
      post_spike_steps = 3,
      spike_threshold_ms = 50,
      restock_throttle_ms = 80,
   },
}

local function _get_profile_data()
   return PROFILES[_current_profile] or PROFILES.BALANCED
end

-- ═════════════════════════════════════════════════════════════════════════
-- STATE
-- ═════════════════════════════════════════════════════════════════════════

local _initialized = false
local _patches_applied = false
local _applied_patches = {}
local _ace_present = false

-- ═════════════════════════════════════════════════════════════════════════
-- INSTRUMENTATION v2
--   Counter names follow 'GROUP:name' convention.
--   Groups: LIFECYCLE, P1, PA, PB, P3, PC, PD, PE, GC, SAFETY, SETTINGS
-- ═════════════════════════════════════════════════════════════════════════

local _counters = {}
local _counter_prev = {}

local _instrumentation = {}
_instrumentation._enabled = true

function _instrumentation:set_enabled(v)
   self._enabled = v and true or false
end

function _instrumentation:inc(name, amount)
   if not self._enabled then return end
   _counters[name] = (_counters[name] or 0) + (amount or 1)
end

function _instrumentation:set(name, value)
   if not self._enabled then return end
   _counters[name] = value
end

function _instrumentation:get(name)
   return _counters[name] or 0
end

function _instrumentation:delta(name)
   local cur = _counters[name] or 0
   local prev = _counter_prev[name] or 0
   return cur - prev
end

function _instrumentation:snapshot_prev()
   for k, v in pairs(_counters) do _counter_prev[k] = v end
end

function _instrumentation:get_snapshot()
   local snap = {}
   for k, v in pairs(_counters) do snap[k] = v end
   return snap
end

function _instrumentation:reset_all()
   for k in pairs(_counters) do _counters[k] = nil end
   for k in pairs(_counter_prev) do _counter_prev[k] = nil end
end

function _instrumentation:publish_if_available()
   if not self._enabled then return end
   if stonehearth and stonehearth.perf_mon and stonehearth.perf_mon.set_counter then
      for name, value in pairs(_counters) do
         stonehearth.perf_mon:set_counter(name, value)
      end
   end
end

local _GROUP_ORDER = { 'P1', 'PA', 'PB', 'P3', 'PC', 'PD', 'PE', 'GC', 'SAFETY' }

-- ═════════════════════════════════════════════════════════════════════════
-- PATCH 1+4: RECONSIDER ALLOC + ENTITY SPREAD
-- ═════════════════════════════════════════════════════════════════════════

local P1 = {}
do
   local _p1_patched = false
   local _orig_call_reconsider_cbs = nil
   local _orig_on_reconsider_entity = nil
   local _cb_snapshot = {}
   local _cb_snapshot_len = 0
   local _cb_dirty = true
   local _overflow = {}
   local _overflow_count = 0
   local _max_per_tick = 64

   local function _rebuild_snapshot(ai)
      for i = 1, _cb_snapshot_len do _cb_snapshot[i] = nil end
      local n = 0
      for _, entry in pairs(ai._reconsider_callbacks) do
         n = n + 1
         _cb_snapshot[n] = entry.callback
      end
      _cb_snapshot_len = n
      _cb_dirty = false
      _instrumentation:inc('P1:cb_rebuilds')
   end

   local function _patched_call(self)
      local reconsidered = self._reconsidered_entities
      if _overflow_count > 0 then
         for id, msg in pairs(_overflow) do
            if not reconsidered[id] then reconsidered[id] = msg end
            _overflow[id] = nil
         end
         _overflow_count = 0
      end
      if not next(reconsidered) then return end
      self._reconsidered_entities = {}
      if _cb_dirty then _rebuild_snapshot(self) end

      local entity_count = 0
      if _max_per_tick > 0 then
         for _ in pairs(reconsidered) do entity_count = entity_count + 1 end
         if entity_count > _max_per_tick then
            local processed = 0
            for id, msg in pairs(reconsidered) do
               if processed >= _max_per_tick then
                  _overflow[id] = msg
                  _overflow_count = _overflow_count + 1
                  reconsidered[id] = nil
               else
                  processed = processed + 1
               end
            end
            _instrumentation:inc('P1:spread_defers', entity_count - _max_per_tick)
         end
      end

      local snap = _cb_snapshot
      local snap_len = _cb_snapshot_len
      local single = self._single_entity_reconsider_callbacks
      for id, msg in pairs(reconsidered) do
         if msg.entity and msg.entity:is_valid() then
            for i = 1, snap_len do
               pcall(snap[i], msg)
            end
         end
         local ecbs = single[id]
         if ecbs then
            for fn in pairs(ecbs) do pcall(fn) end
         end
      end
      _radiant.sim.reconsider_entities(reconsidered)
      _instrumentation:inc('P1:callback_ticks')
   end

   local function _patched_on_reconsider(self, reason, callback)
      local id = self._next_reconsider_callback_id
      self._next_reconsider_callback_id = id + 1
      self._reconsider_callbacks[id] = { reason = reason, callback = callback }
      _cb_dirty = true
      return radiant.lib.Destructor(function()
         self._reconsider_callbacks[id] = nil
         _cb_dirty = true
      end)
   end

   function P1.apply(config)
      if _p1_patched then return true end
      _max_per_tick = (config and config.max_reconsider_per_tick) or 64
      local ai = stonehearth.ai
      if not ai or not ai._call_reconsider_callbacks or not ai.on_reconsider_entity then
         log:always('[perf_mod.error] P1: required AI methods missing')
         return false
      end
      _orig_call_reconsider_cbs = ai._call_reconsider_callbacks
      _orig_on_reconsider_entity = ai.on_reconsider_entity
      ai._call_reconsider_callbacks = _patched_call
      ai.on_reconsider_entity = _patched_on_reconsider
      _rebuild_snapshot(ai)
      _p1_patched = true
      return true
   end

   function P1.is_patched() return _p1_patched end

   function P1.set_max_per_tick(v)
      _max_per_tick = v or 64
   end

   function P1.restore()
      if not _p1_patched then return end
      local ai = stonehearth.ai
      if ai and _orig_call_reconsider_cbs then
         ai._call_reconsider_callbacks = _orig_call_reconsider_cbs
      end
      if ai and _orig_on_reconsider_entity then
         ai.on_reconsider_entity = _orig_on_reconsider_entity
      end
      _p1_patched = false
      _orig_call_reconsider_cbs = nil
      _orig_on_reconsider_entity = nil
      for k in pairs(_overflow) do _overflow[k] = nil end
      _overflow_count = 0
      log:always('[perf_mod.state] P1 restored')
   end
end

-- ═════════════════════════════════════════════════════════════════════════
-- PATCH A: RETROACTIVE FILTER WRAPPING (fast_call_filter_fn URI reject cache)
--   + per-entity (uri, pid) lookup cache
-- ═════════════════════════════════════════════════════════════════════════

local PA = {}
do
   local _pa_patched = false
   local _orig_fast_call = nil

   -- URI → false cache (negative results), keyed by filter_fn then 'pid:uri'
   local _uri_reject = {}

   -- URI → has entity_forms component (cached across entities of same URI)
   PA._has_entity_forms = {}

   local _pa_tick_count = 0
   local _pa_flush_interval = 300

   local get_player_id = radiant.entities.get_player_id
   local get_component = nil  -- filled lazily to avoid table lookup per call

   -- Hot path. Must be as lean as possible — called 2k-3k times per second in
   -- late-game colonies. No instrumentation increment for TOTAL invocations
   -- (too expensive in hot loop). Only count hits/caches.
   local function _patched_fast_call(self, filter_fn, entity)
      if not entity or not entity:is_valid() then return false end

      local uri = entity:get_uri()
      local pid = get_player_id(entity) or ''

      local reject = _uri_reject[filter_fn]
      if not reject then
         reject = {}
         _uri_reject[filter_fn] = reject
      end

      local cache_key = pid .. ':' .. uri

      if rawget(reject, cache_key) then
         _instrumentation:inc('PA:reject_hits')
         return false
      end

      local result = _orig_fast_call(self, filter_fn, entity)

      if not result then
         local has_ef = PA._has_entity_forms[uri]
         if has_ef == nil then
            has_ef = entity:get_component('stonehearth:entity_forms') ~= nil
            PA._has_entity_forms[uri] = has_ef
         end
         if not has_ef then
            rawset(reject, cache_key, true)
            _instrumentation:inc('PA:caches_added')
         end
      end

      return result
   end

   function PA._invalidate_entity(entity)
      if not entity then return end
      local ok, uri = pcall(entity.get_uri, entity)
      if not ok or not uri then return end
      local ok2, pid = pcall(get_player_id, entity)
      local player_id = ok2 and pid or ''
      local key = player_id .. ':' .. uri

      for _, cache in pairs(_uri_reject) do
         if rawget(cache, key) then
            rawset(cache, key, nil)
         end
      end
   end

   function PA.flush_all()
      for _, cache in pairs(_uri_reject) do
         for k in pairs(cache) do cache[k] = nil end
      end
      _instrumentation:inc('PA:flushes')
   end

   function PA.tick()
      _pa_tick_count = _pa_tick_count + 1
      if _pa_tick_count >= _pa_flush_interval then
         _pa_tick_count = 0
         PA.flush_all()
      end
   end

   function PA.apply(config)
      if _pa_patched then return true end
      _pa_flush_interval = (config and config.reject_flush_interval) or 300

      local ai = stonehearth.ai
      if not ai or not ai.fast_call_filter_fn then
         log:always('[perf_mod.error] PA: fast_call_filter_fn not found on stonehearth.ai')
         return false
      end

      _orig_fast_call = ai.fast_call_filter_fn
      ai.fast_call_filter_fn = _patched_fast_call

      _pa_patched = true
      return true
   end

   function PA.is_patched() return _pa_patched end

   function PA.restore()
      if not _pa_patched then return end
      local ai = stonehearth.ai
      if ai and _orig_fast_call then
         ai.fast_call_filter_fn = _orig_fast_call
      end
      _pa_patched = false
      _orig_fast_call = nil
      PA.flush_all()
      log:always('[perf_mod.state] PA restored')
   end
end

-- ═════════════════════════════════════════════════════════════════════════
-- PATCH B: _add_reconsidered_entity DEDUP-FIRST (NEW in v400 — the big win)
--
-- Vanilla engine clears C++ FAST_CALL_CACHES for an entity ID BEFORE checking
-- whether the entity is already scheduled for reconsideration this tick.
-- ACE's reconsider_entity cascade produces many duplicate _add_reconsidered
-- calls per burst (entity + container + parent). By reversing the order
-- (dedup first, sweep only on first add), we eliminate redundant C++ work.
--
-- Safety: between the first sweep (which clears cache for id) and a duplicate
-- add in the same tick, no filter call can re-populate the cache for that id
-- because filter calls run in _call_reconsider_callbacks later in the tick.
-- ═════════════════════════════════════════════════════════════════════════

local PB = {}
do
   local _pb_patched = false
   local _orig_add_reconsidered = nil

   -- _breaker is declared later (forward-referenced; available at call time)
   local function _patched_add_reconsidered(self, entity, reason)
      if not entity or not entity:is_valid() then return end
      local id = entity:get_id()

      if rawget(self._reconsidered_entities, id) then
         _instrumentation:inc('PB:dedup_sweeps_saved')
         return
      end

      if PA._invalidate_entity then
         PA._invalidate_entity(entity)
      end

      local ok, err = pcall(_orig_add_reconsidered, self, entity, reason)
      if not ok then
         if _breaker and _breaker.record_error then
            _breaker:record_error('PB', err)
         else
            log:always('[perf_mod.error] PB: %s', tostring(err))
         end
         return
      end
      _instrumentation:inc('PB:first_adds')
   end

   function PB.apply(config)
      if _pb_patched then return true end
      local ai = stonehearth.ai
      if not ai or not ai._add_reconsidered_entity then
         log:always('[perf_mod.error] PB: _add_reconsidered_entity not found')
         return false
      end
      _orig_add_reconsidered = ai._add_reconsidered_entity
      ai._add_reconsidered_entity = _patched_add_reconsidered
      _pb_patched = true
      return true
   end

   function PB.is_patched() return _pb_patched end

   function PB.restore()
      if not _pb_patched then return end
      local ai = stonehearth.ai
      if ai and _orig_add_reconsidered then
         ai._add_reconsidered_entity = _orig_add_reconsidered
      end
      _pb_patched = false
      _orig_add_reconsidered = nil
      log:always('[perf_mod.state] PB restored')
   end
end

-- ═════════════════════════════════════════════════════════════════════════
-- PATCH C: reconsider_entity_in_filter_caches THROTTLE
-- ═════════════════════════════════════════════════════════════════════════

local PC = {}
do
   local _pc_patched = false
   local _reconsider_cache_seen = {}

   function PC.should_reconsider_in_cache(storage_entity, entity_id)
      if not storage_entity or not entity_id then return true end
      _instrumentation:inc('PC:reconsider_cache_calls')
      local ok, storage_id = pcall(storage_entity.get_id, storage_entity)
      if not ok or not storage_id then return true end
      local seen = _reconsider_cache_seen[storage_id]
      if not seen then
         seen = {}
         _reconsider_cache_seen[storage_id] = seen
      end
      if seen[entity_id] then
         _instrumentation:inc('PC:throttle_hits')
         return false
      end
      seen[entity_id] = true
      return true
   end

   function PC.flush_tick()
      for k in pairs(_reconsider_cache_seen) do
         _reconsider_cache_seen[k] = nil
      end
   end

   function PC.apply(config)
      _pc_patched = true
      return true
   end

   function PC.is_patched() return _pc_patched end

   function PC.restore()
      _pc_patched = false
      for k in pairs(_reconsider_cache_seen) do
         _reconsider_cache_seen[k] = nil
      end
   end
end

-- ═════════════════════════════════════════════════════════════════════════
-- PATCH 3: RECONSIDER_ENTITY DEDUP + CONTAINER CACHE (ACE override target)
-- ═════════════════════════════════════════════════════════════════════════

local P3 = {}
do
   local _p3_patched = false
   local _orig_reconsider_entity = nil
   local _seen_this_tick = {}
   local _container_cache = {}

   local function _patched_reconsider(self, entity, reason, reconsider_parent)
      if not entity or not entity:is_valid() then return end
      _instrumentation:inc('P3:reconsider_calls')

      local id = entity:get_id()
      if _seen_this_tick[id] then
         _instrumentation:inc('P3:dedup_hits')
         return
      end
      _seen_this_tick[id] = true

      -- self._add_reconsidered_entity goes through PB if PB is patched
      self:_add_reconsidered_entity(entity, reason)

      local pid = radiant.entities.get_player_id(entity)
      if pid and pid ~= '' then
         local inv = stonehearth.inventory:get_inventory(pid)
         if inv and inv.is_initialized and inv:is_initialized() then
            local container = _container_cache[id]
            if container == nil then
               container = inv:container_for(entity) or false
               _container_cache[id] = container
            else
               _instrumentation:inc('P3:container_cache_hits')
            end
            if container and container ~= false then
               local cid = container:get_id()
               -- Preserve ACE's typo ('stoneheath') intentionally for behavioural parity.
               -- ACE's is_stockpile is always nil, so every container is treated as non-stockpile.
               local is_sp = container:get_component('stoneheath:stockpile')
               if not is_sp then
                  local sc = container:get_component('stonehearth:storage')
                  if sc and PC.should_reconsider_in_cache(container, id) then
                     pcall(sc.reconsider_entity_in_filter_caches, sc, id, entity)
                  end
                  if not _seen_this_tick[cid] then
                     _seen_this_tick[cid] = true
                     self:_add_reconsidered_entity(container, reason .. '(also triggering container)')
                  end
               end
            end
         end
      end

      if reconsider_parent then
         local parent = radiant.entities.get_parent(entity)
         if parent and parent:get_id() ~= radiant._root_entity_id then
            local pid2 = parent:get_id()
            if not _seen_this_tick[pid2] then
               _seen_this_tick[pid2] = true
               self:_add_reconsidered_entity(parent, reason .. '(reconsider_parent)')
            end
         end
      end
   end

   function P3.apply(config)
      if _p3_patched then return true end
      local ai = stonehearth.ai
      if not ai or not ai.reconsider_entity then
         log:always('[perf_mod.error] P3: reconsider_entity not found')
         return false
      end
      _orig_reconsider_entity = ai.reconsider_entity
      ai.reconsider_entity = _patched_reconsider
      _p3_patched = true
      return true
   end

   function P3.is_patched() return _p3_patched end

   function P3.flush_tick()
      for k in pairs(_seen_this_tick) do _seen_this_tick[k] = nil end
      for k in pairs(_container_cache) do _container_cache[k] = nil end
   end

   function P3.restore()
      if not _p3_patched then return end
      local ai = stonehearth.ai
      if ai and _orig_reconsider_entity then
         ai.reconsider_entity = _orig_reconsider_entity
      end
      _p3_patched = false
      _orig_reconsider_entity = nil
      P3.flush_tick()
      log:always('[perf_mod.state] P3 restored')
   end
end

-- ═════════════════════════════════════════════════════════════════════════
-- GC OPTIMIZATION
-- ═════════════════════════════════════════════════════════════════════════

local GC = {}
do
   local _gc_patched = false
   local _last_hb = nil
   local _was_spiking = false

   local function _patch_object_tracker()
      local tracker = nil
      for name, mod in pairs(package.loaded) do
         if type(name) == 'string' and name:find('object_tracker') then
            if type(mod) == 'table' and type(mod.get_count) == 'function' then
               tracker = mod; break
            end
         end
      end
      if not tracker or tracker._perfmod_gc_patched then return false end
      local orig = tracker.get_count
      local real_gc = collectgarbage
      tracker.get_count = function(category)
         local saved = collectgarbage
         collectgarbage = function(cmd, ...)
            if cmd == nil or cmd == 'collect' then return real_gc('step', 5) end
            return real_gc(cmd, ...)
         end
         local ok, ret = pcall(orig, category)
         collectgarbage = saved
         if ok then return ret end
         error(ret)
      end
      tracker._perfmod_gc_patched = true
      return true
   end

   -- Heartbeat-paced GC stepping.
   -- We cannot rely on os.clock in this sandbox (strict.lua), so sub-second
   -- frame timing is unavailable. Instead we step GC on every 1s heartbeat,
   -- with a periodic larger cleanup every 10 heartbeats. Combined with the
   -- setpause/setstepsize tuning in GC.apply_gc_params, this spreads GC work
   -- over time and prevents full-collection spikes in late-game sessions.
   function GC.adaptive_gc_step(profile)
      -- Per-heartbeat small step (size matches profile aggressiveness)
      local step = 1
      if profile.id == 'BALANCED' then step = 2
      elseif profile.id == 'AGGRESSIVE' then step = 3
      end
      local ok = pcall(collectgarbage, 'step', step)
      if ok then
         _instrumentation:inc('GC:adaptive_steps')
      else
         _instrumentation:inc('GC:step_errors')
      end

      -- Periodic larger cleanup every 10 heartbeats
      if _heartbeat_count % 10 == 0 then
         for _ = 1, (profile.post_spike_steps or 1) do
            pcall(collectgarbage, 'step', 1)
         end
         _instrumentation:inc('GC:post_spike_boosts')
      end

      -- Warm-resume guard: detect if _last_hb tracking indicates large gap.
      -- With heartbeat-only timing, a "large gap" means _heartbeat_count
      -- jumped by > 1 between calls (we skipped heartbeats — game was
      -- paused/alt-tabbed). Flush caches defensively.
      if _last_hb and (_heartbeat_count - _last_hb) > 3 then
         log:always('[perf_mod.safety] warm-resume detected (%d heartbeat gap); flushing caches',
            _heartbeat_count - _last_hb)
         _instrumentation:inc('SAFETY:warm_resume_events')
         if PA.is_patched() then pcall(PA.flush_all) end
         if P3.is_patched() then pcall(P3.flush_tick) end
         if PC.is_patched() then pcall(PC.flush_tick) end
      end
      _last_hb = _heartbeat_count
   end

   function GC.apply_gc_params(profile)
      pcall(collectgarbage, 'setpause', profile.gc_pause or 110)
      pcall(collectgarbage, 'setstepsize', profile.gc_stepsize or 100)
   end

   function GC.apply(config)
      if _gc_patched then return true end
      pcall(_patch_object_tracker)
      _gc_patched = true
      return true
   end

   function GC.is_patched() return _gc_patched end

   function GC.restore()
      _gc_patched = false
   end
end

-- ═════════════════════════════════════════════════════════════════════════
-- HEARTHLING IDLE WATCHDOG (Safety)
-- ═════════════════════════════════════════════════════════════════════════

local _watchdog = {}
_watchdog._idle_ratio_threshold = 0.60
_watchdog._consecutive_hits = 0
_watchdog._consecutive_needed = 3
_watchdog._last_sample_tick = 0
_watchdog._sample_interval_s = 10
_watchdog._tripped = false
_watchdog._min_citizens = 6

function _watchdog:set_threshold(r)
   if type(r) ~= 'number' or r <= 0 or r > 1 then return end
   self._idle_ratio_threshold = r
   self._consecutive_hits = 0
end

local function _try_detect_idle(citizen)
   local ai = citizen:get_component('stonehearth:ai')
   if not ai then return nil end
   if type(ai.get_current_activity_name) == 'function' then
      local ok, a = pcall(ai.get_current_activity_name, ai)
      if ok and a and a ~= '' then
         -- Only exact idle/loiter markers; avoid false positives from normal 'wait_*' actions
         return a:find('idle') ~= nil or a:find('loiter') ~= nil
      end
      if ok and (not a or a == '') then return true end
   end
   if ai._current_activity then
      local s = tostring(ai._current_activity)
      return s:find('idle') ~= nil or s:find('loiter') ~= nil
   end
   return nil
end

function _watchdog:_sample_idle_ratio()
   if not stonehearth or not stonehearth.town then return nil end
   local idle = 0
   local total = 0
   for _, player_id in ipairs({ 'player_1', 'player_2', 'player_3', 'player_4' }) do
      local ok, town = pcall(stonehearth.town.get_town, stonehearth.town, player_id)
      if ok and town and town.get_citizens then
         local ok2, citizens = pcall(town.get_citizens, town)
         if ok2 and citizens and citizens.each then
            pcall(citizens.each, citizens, function(_, citizen)
               if citizen and citizen.is_valid and citizen:is_valid() then
                  total = total + 1
                  local is_idle = _try_detect_idle(citizen)
                  if is_idle == true then
                     idle = idle + 1
                  end
               end
            end)
         end
      end
   end
   if total == 0 then return nil end
   return idle, total
end

function _watchdog:tick()
   if (_heartbeat_count - self._last_sample_tick) < self._sample_interval_s then return end
   self._last_sample_tick = _heartbeat_count

   local idle, total = self:_sample_idle_ratio()
   if not idle or total < self._min_citizens then return end

   local ratio = idle / total
   _instrumentation:set('SAFETY:last_idle_ratio_pct', math.floor(ratio * 100))

   if ratio > self._idle_ratio_threshold then
      self._consecutive_hits = self._consecutive_hits + 1
      log:always('[perf_mod.safety] idle sample: %d/%d idle (%d%%) threshold=%d%% consec=%d/%d',
         idle, total, math.floor(ratio * 100),
         math.floor(self._idle_ratio_threshold * 100),
         self._consecutive_hits, self._consecutive_needed)
      if self._consecutive_hits >= self._consecutive_needed and not self._tripped then
         self:_trip()
      end
   else
      if self._tripped then
         self:_recover()
      end
      self._consecutive_hits = 0
   end
end

function _watchdog:_trip()
   log:always('[perf_mod.safety] ==============================================')
   log:always('[perf_mod.safety] WATCHDOG FIRED — hearthling idle ratio sustained')
   log:always('[perf_mod.safety] Disabling non-GC patches and switching to SAFE profile')
   log:always('[perf_mod.safety] ==============================================')
   _instrumentation:inc('SAFETY:watchdog_fires')
   self._tripped = true

   local patches = _get_patch_map and _get_patch_map() or {}
   for _, id in ipairs({ 'PE', 'PD', 'PC', 'P3', 'PB', 'PA', 'P1' }) do
      if patches[id] and patches[id].is_patched() then
         pcall(patches[id].restore)
         if _patch_enabled then _patch_enabled[id] = false end
      end
   end

   local old_profile = _current_profile
   _current_profile = 'SAFE'
   GC.apply_gc_params(_get_profile_data())
   log:always('[perf_mod.safety] profile forced %s -> SAFE', old_profile)
end

function _watchdog:_recover()
   log:always('[perf_mod.safety] idle ratio recovered — re-enabling patches')
   self._tripped = false
   self._consecutive_hits = 0
   local patches = _get_patch_map and _get_patch_map() or {}
   local cfg = {
      max_reconsider_per_tick = _get_profile_data().max_reconsider_per_tick,
      reject_flush_interval = _get_profile_data().reject_flush_interval,
   }
   for _, id in ipairs({ 'P3', 'PA', 'PB', 'PC', 'P1' }) do
      if _patch_enabled then _patch_enabled[id] = true end
      if patches[id] and not patches[id].is_patched() then
         local ok, err = pcall(patches[id].apply, cfg)
         if ok and patches[id].is_patched() then
            log:always('[perf_mod.safety] re-applied patch %s after recovery', id)
         else
            log:always('[perf_mod.error] recovery re-apply failed for %s: %s', id, tostring(err))
         end
      end
   end
end

-- ═════════════════════════════════════════════════════════════════════════
-- CIRCUIT BREAKER
-- ═════════════════════════════════════════════════════════════════════════

do
   local B = {}
   B._errors = {}
   B._window_s = 60
   B._max_errors = 5

   function B:record_error(patch_id, err)
      local now = _safe_clock()
      local list = self._errors[patch_id]
      if not list then list = {}; self._errors[patch_id] = list end
      local cutoff = now - self._window_s
      local i = 1
      while i <= #list do
         if list[i] < cutoff then
            table.remove(list, i)
         else
            i = i + 1
         end
      end
      list[#list + 1] = now
      log:always('[perf_mod.error] patch %s error #%d: %s', patch_id, #list, tostring(err))
      if #list >= self._max_errors then
         self:_trip(patch_id, err)
      end
   end

   function B:_trip(patch_id, err)
      local patches = _get_patch_map and _get_patch_map() or {}
      local entry = patches[patch_id]
      if entry and entry.is_patched() then
         log:always('[perf_mod.safety] CIRCUIT BREAKER: disabling %s after %d errors (last: %s)',
            patch_id, #self._errors[patch_id], tostring(err))
         _instrumentation:inc('SAFETY:circuit_breaker_trips')
         pcall(entry.restore)
         if _patch_enabled then _patch_enabled[patch_id] = false end
         self._errors[patch_id] = {}
      end
   end

   _breaker = B
end

-- ═════════════════════════════════════════════════════════════════════════
-- PATCH D: RESTOCK DIRECTOR THROTTLE (EXPERIMENTAL, opt-in)
-- ═════════════════════════════════════════════════════════════════════════

local PD = {}
do
   local _pd_patched = false
   local _director_mod = nil
   local _director_method_name = nil
   local _orig_update = nil
   local _throttle_ms = 100
   local _last_call = {}
   local _deferred_timer = {}

   local function _patched_update(self, ...)
      local now = _safe_clock() * 1000
      local last = _last_call[self]
      if last and (now - last) < _throttle_ms then
         if not _deferred_timer[self] and radiant.set_realtime_timer then
            local cap_self = self
            _deferred_timer[cap_self] = radiant.set_realtime_timer(
               'perf_mod_pd_' .. tostring(cap_self):gsub('[%s:]', '_'),
               _throttle_ms,
               function()
                  _deferred_timer[cap_self] = nil
                  _last_call[cap_self] = _safe_clock() * 1000
                  local ok, err = pcall(_orig_update, cap_self)
                  if not ok and _breaker and _breaker.record_error then
                     _breaker:record_error('PD', err)
                  end
               end
            )
            _instrumentation:inc('PD:throttle_skips')
         end
         return
      end
      _last_call[self] = now
      _instrumentation:inc('PD:director_ticks')
      local ok, ret = pcall(_orig_update, self, ...)
      if not ok then
         if _breaker and _breaker.record_error then
            _breaker:record_error('PD', ret)
         end
         return
      end
      return ret
   end

   function PD.apply(config)
      if _pd_patched then return true end
      local ok, mod = pcall(require, 'stonehearth.services.server.inventory.restock_director')
      if not ok or type(mod) ~= 'table' then
         -- Try scanning package.loaded
         for name, loaded in pairs(package.loaded) do
            if type(name) == 'string' and name:find('restock_director') and type(loaded) == 'table' then
               mod = loaded
               break
            end
         end
         if type(mod) ~= 'table' then
            log:always('[perf_mod.error] PD: restock_director module not accessible')
            return false
         end
      end
      _director_mod = mod
      local candidates = { 'update', '_update', 'on_update', '_on_update', '_on_game_loop' }
      for _, m in ipairs(candidates) do
         if type(mod[m]) == 'function' then
            _director_method_name = m; break
         end
      end
      if not _director_method_name then
         log:always('[perf_mod.error] PD: no update method found on restock_director')
         return false
      end
      _orig_update = mod[_director_method_name]
      _throttle_ms = (config and config.restock_throttle_ms) or 100
      mod[_director_method_name] = _patched_update
      log:always('[perf_mod.state] PD: restock_director.%s hooked (throttle=%d ms)',
         _director_method_name, _throttle_ms)
      _pd_patched = true
      return true
   end

   function PD.is_patched() return _pd_patched end

   function PD.restore()
      if not _pd_patched then return end
      if _director_mod and _director_method_name and _orig_update then
         _director_mod[_director_method_name] = _orig_update
      end
      _pd_patched = false
      _orig_update = nil
      _director_method_name = nil
      for k in pairs(_last_call) do _last_call[k] = nil end
      for k in pairs(_deferred_timer) do _deferred_timer[k] = nil end
      log:always('[perf_mod.state] PD restored')
   end

   function PD.set_throttle(ms)
      if type(ms) == 'number' and ms >= 0 and ms <= 10000 then
         _throttle_ms = ms
      end
   end
end

-- ═════════════════════════════════════════════════════════════════════════
-- PATCH E: _on_contents_changed COALESCING (EXPERIMENTAL, opt-in)
-- ═════════════════════════════════════════════════════════════════════════

local PE = {}
do
   local _pe_patched = false
   local _orig_contents_changed = nil
   local _storage_class = nil
   local _last_tick_fired = {}

   local function _patched_contents_changed(self, ...)
      local entity = self and self._entity
      if not entity or not entity.is_valid or not entity:is_valid() then
         local ok, ret = pcall(_orig_contents_changed, self, ...)
         if not ok and _breaker and _breaker.record_error then
            _breaker:record_error('PE', ret)
         end
         return
      end
      local id = entity:get_id()
      _instrumentation:inc('PE:contents_events')

      if _last_tick_fired[id] == _heartbeat_count then
         _instrumentation:inc('PE:coalesced')
         return
      end

      _last_tick_fired[id] = _heartbeat_count
      local ok, ret = pcall(_orig_contents_changed, self, ...)
      if not ok and _breaker and _breaker.record_error then
         _breaker:record_error('PE', ret)
      end
      return ret
   end

   function PE.flush_tick()
      for k in pairs(_last_tick_fired) do _last_tick_fired[k] = nil end
   end

   function PE.apply(config)
      if _pe_patched then return true end
      local mod = nil
      local ok, loaded = pcall(require, 'stonehearth_ace.monkey_patches.ace_storage_component')
      if ok and type(loaded) == 'table' then
         mod = loaded
      else
         for name, l in pairs(package.loaded) do
            if type(name) == 'string' and name:find('ace_storage_component') and type(l) == 'table' then
               mod = l
               break
            end
         end
      end
      if not mod then
         mod = rawget(_G, 'AceStorageComponent')
      end
      if type(mod) ~= 'table' or type(mod._on_contents_changed) ~= 'function' then
         log:always('[perf_mod.error] PE: ace_storage_component._on_contents_changed not found')
         return false
      end
      _storage_class = mod
      _orig_contents_changed = mod._on_contents_changed
      mod._on_contents_changed = _patched_contents_changed
      _pe_patched = true
      log:always('[perf_mod.state] PE: ace_storage_component._on_contents_changed hooked')
      return true
   end

   function PE.is_patched() return _pe_patched end

   function PE.restore()
      if not _pe_patched then return end
      if _storage_class and _orig_contents_changed then
         _storage_class._on_contents_changed = _orig_contents_changed
      end
      _pe_patched = false
      _orig_contents_changed = nil
      _storage_class = nil
      for k in pairs(_last_tick_fired) do _last_tick_fired[k] = nil end
      log:always('[perf_mod.state] PE restored')
   end
end

-- ═════════════════════════════════════════════════════════════════════════
-- PATCH REGISTRY + RESOLUTION
-- ═════════════════════════════════════════════════════════════════════════

-- Default enablement.
-- PB disabled by default: empirical data (v400.0) showed PB_skip=0 in a 23-hearthling
-- colony because P3's higher-level dedup catches all cascade duplicates first, leaving
-- PB with nothing to skip. User can opt in via update_settings if their workload differs.
_patch_enabled = {
   P1 = true, PA = true, PB = false, P3 = true, PC = true,
   PD = false, PE = false, GC = true,
}

_get_patch_map = function()
   return {
      P1 = { apply = P1.apply, restore = P1.restore, is_patched = P1.is_patched },
      PA = { apply = PA.apply, restore = PA.restore, is_patched = PA.is_patched },
      PB = { apply = PB.apply, restore = PB.restore, is_patched = PB.is_patched },
      P3 = { apply = P3.apply, restore = P3.restore, is_patched = P3.is_patched },
      PC = { apply = PC.apply, restore = PC.restore, is_patched = PC.is_patched },
      PD = { apply = PD.apply, restore = PD.restore, is_patched = PD.is_patched },
      PE = { apply = PE.apply, restore = PE.restore, is_patched = PE.is_patched },
      GC = { apply = GC.apply, restore = GC.restore, is_patched = GC.is_patched },
   }
end

_resolve_patch_enabled = function(patch_id, profile)
   if _patch_enabled[patch_id] == false then return false end
   if patch_id == 'P1' then return profile.reconsider_alloc ~= false end
   if patch_id == 'PA' then return profile.filter_fast_reject ~= false end
   if patch_id == 'PB' then return profile.dedup_first ~= false end
   if patch_id == 'P3' then return profile.reconsider_limiter ~= false end
   if patch_id == 'PC' then return profile.reconsider_limiter ~= false end
   if patch_id == 'PD' then return profile.restock_throttle == true end
   if patch_id == 'PE' then return profile.contents_coalesce == true end
   if patch_id == 'GC' then return profile.gc_tuning ~= false end
   return true
end

-- ═════════════════════════════════════════════════════════════════════════
-- PATCH APPLICATION
-- ═════════════════════════════════════════════════════════════════════════

local function _cfg_for_profile(profile)
   return {
      instrumentation = _instrumentation,
      max_reconsider_per_tick = profile.max_reconsider_per_tick,
      reject_flush_interval = profile.reject_flush_interval,
      restock_throttle_ms = profile.restock_throttle_ms,
   }
end

local function _try_apply(patch_id, apply_fn, cfg, label)
   local ok, err = pcall(apply_fn, cfg)
   if ok and _get_patch_map()[patch_id].is_patched() then
      _applied_patches[#_applied_patches + 1] = patch_id
      log:always('[perf_mod.state] [OK] %s %s', patch_id, label)
      _instrumentation:inc('LIFECYCLE:apply_success')
      return true
   else
      log:always('[perf_mod.error] [FAIL] %s: %s', patch_id, tostring(err))
      _instrumentation:inc('LIFECYCLE:apply_fail')
      return false
   end
end

local function _apply_patches()
   local profile = _get_profile_data()
   log:always('[perf_mod.state] applying patches (profile=%s)...', profile.id)
   _applied_patches = {}
   local cfg = _cfg_for_profile(profile)

   if _resolve_patch_enabled('P3', profile) then
      _try_apply('P3', P3.apply, cfg, 'reconsider_entity dedup + container cache')
   end
   if _resolve_patch_enabled('PA', profile) then
      _try_apply('PA', PA.apply, cfg, string.format('fast_call_filter_fn URI reject (flush=%d)', profile.reject_flush_interval))
   end
   if _resolve_patch_enabled('PB', profile) then
      _try_apply('PB', PB.apply, cfg, '_add_reconsidered_entity dedup-first')
   end
   if _resolve_patch_enabled('PC', profile) then
      _try_apply('PC', PC.apply, cfg, 'reconsider_entity_in_filter_caches throttle')
   end
   if _resolve_patch_enabled('P1', profile) then
      _try_apply('P1', P1.apply, cfg, string.format('reconsider alloc + spread (max=%d)', profile.max_reconsider_per_tick))
   end
   if _resolve_patch_enabled('PD', profile) then
      _try_apply('PD', PD.apply, cfg, 'restock_director throttle (experimental)')
   end
   if _resolve_patch_enabled('PE', profile) then
      _try_apply('PE', PE.apply, cfg, '_on_contents_changed coalescing (experimental)')
   end
   if _resolve_patch_enabled('GC', profile) then
      GC.apply_gc_params(profile)
      _try_apply('GC', GC.apply, cfg, string.format('GC tuning (pause=%d step=%d)', profile.gc_pause, profile.gc_stepsize))
   end

   _patches_applied = true
end

-- ═════════════════════════════════════════════════════════════════════════
-- HEARTBEAT
-- ═════════════════════════════════════════════════════════════════════════

local function _on_tick()
   _heartbeat_count = _heartbeat_count + 1

   -- Flush tick-local dedup tables
   if P3.is_patched() then pcall(P3.flush_tick) end
   if PC.is_patched() then pcall(PC.flush_tick) end
   if PE.is_patched() then pcall(PE.flush_tick) end

   -- Periodic cache pruning
   if PA.is_patched() then pcall(PA.tick) end

   -- Adaptive GC step (log any pcall error — we need to know why GC counters stay 0)
   local profile = _get_profile_data()
   if profile.gc_tuning and GC.is_patched() then
      local ok_gc, err_gc = pcall(GC.adaptive_gc_step, profile)
      if not ok_gc then
         -- Log once per 10 errors to avoid spam
         _instrumentation:inc('GC:call_errors')
         if (_counters['GC:call_errors'] or 0) % 10 == 1 then
            log:always('[perf_mod.error] GC.adaptive_gc_step: %s', tostring(err_gc))
         end
      end
   end

   -- Watchdog sample
   pcall(function() _watchdog:tick() end)

   -- Publish counters
   _instrumentation:publish_if_available()

   -- 10-second mini-heartbeat
   if _heartbeat_count % 10 == 0 and _heartbeat_count > 0 then
      local any = false
      local parts = {}
      for _, g in ipairs(_GROUP_ORDER) do
         local group_sum = 0
         local prefix = g .. ':'
         for name in pairs(_counters) do
            if name:sub(1, #prefix) == prefix then
               group_sum = group_sum + (_counters[name] - (_counter_prev[name] or 0))
            end
         end
         if group_sum > 0 then
            parts[#parts + 1] = string.format('%s=%d', g, group_sum)
            any = true
         end
      end
      local idle_pct = _counters['SAFETY:last_idle_ratio_pct']
      if idle_pct then
         parts[#parts + 1] = string.format('idle=%d%%', idle_pct)
      end
      if any then
         log:always('[perf_mod.metric] %3ds (Δ10s) %s', _heartbeat_count, table.concat(parts, ' '))
      else
         log:always('[perf_mod.metric] %3ds (Δ10s) idle — no patch activity', _heartbeat_count)
      end
      _instrumentation:snapshot_prev()
   end

   -- 60-second full snapshot
   if _heartbeat_count % 60 == 0 and _heartbeat_count > 0 then
      local s = _counters
      log:always('[perf_mod.metric] %3ds (total) patches=%d PA_reject=%d PA_cache=%d '
         .. 'PB_skip=%d PB_add=%d P3_dedup=%d PC_throttle=%d P1_spread=%d '
         .. 'GC_step=%d GC_skip=%d wd_trips=%d cb_trips=%d',
         _heartbeat_count, #_applied_patches,
         s['PA:reject_hits'] or 0, s['PA:caches_added'] or 0,
         s['PB:dedup_sweeps_saved'] or 0, s['PB:first_adds'] or 0,
         s['P3:dedup_hits'] or 0, s['PC:throttle_hits'] or 0,
         s['P1:spread_defers'] or 0,
         s['GC:adaptive_steps'] or 0, s['GC:spike_skips'] or 0,
         s['SAFETY:watchdog_fires'] or 0, s['SAFETY:circuit_breaker_trips'] or 0)
   end
end

local function _start_heartbeat()
   if radiant.set_realtime_interval then
      radiant.set_realtime_interval('perf_mod_pump', 1000, function()
         local ok, err = pcall(_on_tick)
         if not ok then
            log:always('[perf_mod.error] heartbeat exception: %s', tostring(err))
         end
      end)
      log:always('[perf_mod.state] heartbeat OK (1s realtime)')
      return true
   end
   if radiant.on_game_loop then
      local fc = 0
      radiant.on_game_loop('perf_mod_pump', function()
         fc = fc + 1
         if fc % 20 == 0 then
            local ok, err = pcall(_on_tick)
            if not ok then
               log:always('[perf_mod.error] heartbeat exception: %s', tostring(err))
            end
         end
      end)
      log:always('[perf_mod.state] heartbeat OK (game_loop/20)')
      return true
   end
   log:always('[perf_mod.error] no heartbeat mechanism available')
   return false
end

-- ═════════════════════════════════════════════════════════════════════════
-- AI READINESS + DEFERRED APPLICATION
-- ═════════════════════════════════════════════════════════════════════════

local function _ai_ready()
   if not stonehearth or not stonehearth.ai then return false end
   return stonehearth.ai.reconsider_entity ~= nil
      and stonehearth.ai._call_reconsider_callbacks ~= nil
      and stonehearth.ai._add_reconsidered_entity ~= nil
      and stonehearth.ai.fast_call_filter_fn ~= nil
end

local function _summary()
   local n = #_applied_patches
   log:always('=======================================================')
   log:always('[perf_mod] v400 | Profile: %s | ACE: %s | Patches: %d/8',
      _current_profile, tostring(_ace_present), n)
   for _, name in ipairs(_applied_patches) do
      log:always('[perf_mod]   + %s', name)
   end
   if n == 0 then
      log:always('[perf_mod]   *** NO PATCHES APPLIED ***')
   end
   log:always('[perf_mod] watchdog=%d%% threshold, circuit breaker=%d err/60s',
      math.floor(_watchdog._idle_ratio_threshold * 100),
      _breaker._max_errors)
   log:always('=======================================================')
end

local function _go()
   _apply_patches()
   _start_heartbeat()
   _summary()
end

local function _defer()
   local retries = 0
   local function try()
      retries = retries + 1
      if _ai_ready() then
         log:always('[perf_mod.state] AI ready after %d retries', retries)
         _go()
      elseif retries < 50 then
         radiant.set_realtime_timer('perf_mod_r' .. retries, 100, try)
      else
         log:always('[perf_mod.error] GAVE UP on AI after 50 retries — applying GC only')
         GC.apply_gc_params(_get_profile_data())
         pcall(GC.apply, {})
         _applied_patches[#_applied_patches + 1] = 'GC'
         _start_heartbeat()
         _summary()
      end
   end
   try()
end

-- ═════════════════════════════════════════════════════════════════════════
-- LIFECYCLE
-- ═════════════════════════════════════════════════════════════════════════

function stonehearth_performance_mod:_on_init()
   log:always('[perf_mod.state] _on_init')
   _instrumentation:inc('LIFECYCLE:boot_count')

   local ok, p = pcall(function()
      return radiant.util.get_global_config('mods.stonehearth_performance_mod.profile', nil)
   end)
   if ok and p and PROFILES[p] then _current_profile = p end

   local ok2, list = pcall(radiant.resources.get_mod_list)
   if ok2 and list then
      for _, m in ipairs(list) do
         if m == 'stonehearth_ace' then _ace_present = true; break end
      end
   end

   _initialized = true
   log:always('[perf_mod.state] init done (profile=%s ace=%s)', _current_profile, tostring(_ace_present))
end

function stonehearth_performance_mod:_on_required_loaded()
   log:always('[perf_mod.state] _on_required_loaded')
   if not _initialized then
      log:always('[perf_mod.error] init incomplete at required_loaded')
      return
   end
   if _patches_applied then return end
   if _ai_ready() then
      log:always('[perf_mod.state] AI ready — applying now')
      _go()
   else
      log:always('[perf_mod.state] AI not ready — deferring')
      _defer()
   end
end

-- ═════════════════════════════════════════════════════════════════════════
-- PUBLIC API
-- ═════════════════════════════════════════════════════════════════════════

function stonehearth_performance_mod:get_settings()
   local enabled_snapshot = {}
   for k, v in pairs(_patch_enabled) do enabled_snapshot[k] = v end
   return {
      profile = _current_profile,
      instrumentation_enabled = _instrumentation._enabled,
      patch_enabled = enabled_snapshot,
      applied_patches = _applied_patches,
      watchdog_threshold = _watchdog._idle_ratio_threshold,
      ace_present = _ace_present,
      version = 'v400',
      heartbeat_count = _heartbeat_count,
   }
end

function stonehearth_performance_mod:update_settings(data)
   if type(data) ~= 'table' then
      log:always('[perf_mod.error] update_settings called with non-table')
      return false
   end

   -- Profile change
   if data.profile and PROFILES[data.profile] and data.profile ~= _current_profile then
      local old = _current_profile
      _current_profile = data.profile
      log:always('[perf_mod.state] profile change: %s -> %s', old, _current_profile)
      _instrumentation:inc('SETTINGS:profile_changes')
      local profile = _get_profile_data()
      GC.apply_gc_params(profile)
      if P1.is_patched() then P1.set_max_per_tick(profile.max_reconsider_per_tick) end
      if PD.is_patched() then PD.set_throttle(profile.restock_throttle_ms) end
   end

   -- Instrumentation toggle
   if data.instrumentation_enabled ~= nil then
      _instrumentation:set_enabled(data.instrumentation_enabled and true or false)
      log:always('[perf_mod.state] instrumentation = %s', tostring(_instrumentation._enabled))
   end

   -- Per-patch toggles
   if type(data.patch_enabled) == 'table' then
      local patches = _get_patch_map()
      local profile = _get_profile_data()
      local cfg = _cfg_for_profile(profile)
      for patch_id, want_on in pairs(data.patch_enabled) do
         local entry = patches[patch_id]
         if entry then
            local now_on = entry.is_patched()
            if want_on and not now_on then
               local ok, err = pcall(entry.apply, cfg)
               if ok and entry.is_patched() then
                  _patch_enabled[patch_id] = true
                  -- Rebuild applied list
                  local found = false
                  for _, name in ipairs(_applied_patches) do
                     if name == patch_id then found = true; break end
                  end
                  if not found then
                     _applied_patches[#_applied_patches + 1] = patch_id
                  end
                  log:always('[perf_mod.state] patch %s ENABLED at runtime', patch_id)
                  _instrumentation:inc('SETTINGS:patch_toggles')
               else
                  log:always('[perf_mod.error] runtime enable %s failed: %s', patch_id, tostring(err))
               end
            elseif not want_on and now_on then
               local ok, err = pcall(entry.restore)
               _patch_enabled[patch_id] = false
               -- Remove from applied list
               for i = #_applied_patches, 1, -1 do
                  if _applied_patches[i] == patch_id then
                     table.remove(_applied_patches, i)
                     break
                  end
               end
               log:always('[perf_mod.state] patch %s DISABLED at runtime (ok=%s err=%s)',
                  patch_id, tostring(ok), tostring(err))
               _instrumentation:inc('SETTINGS:patch_toggles')
            end
         else
            log:always('[perf_mod.error] unknown patch id %s', tostring(patch_id))
         end
      end
   end

   -- Watchdog threshold
   if data.watchdog_idle_threshold ~= nil then
      _watchdog:set_threshold(tonumber(data.watchdog_idle_threshold))
      log:always('[perf_mod.state] watchdog threshold = %.2f', _watchdog._idle_ratio_threshold)
   end

   return true
end

function stonehearth_performance_mod:get_instrumentation_snapshot()
   return _instrumentation:get_snapshot()
end

function stonehearth_performance_mod:dump_instrumentation()
   log:always('[perf_mod.metric] DUMP t=%ds', _heartbeat_count)
   local keys = {}
   for k in pairs(_counters) do keys[#keys + 1] = k end
   table.sort(keys)
   for _, k in ipairs(keys) do
      log:always('[perf_mod.metric]   %-40s %d', k, _counters[k])
   end
   return _instrumentation:get_snapshot()
end

function stonehearth_performance_mod:reset_counters()
   _instrumentation:reset_all()
   log:always('[perf_mod.state] counters reset by user')
   return true
end

-- ═════════════════════════════════════════════════════════════════════════
-- EVENT REGISTRATION
-- ═════════════════════════════════════════════════════════════════════════

radiant.events.listen(stonehearth_performance_mod, 'radiant:init',
   stonehearth_performance_mod, stonehearth_performance_mod._on_init)
radiant.events.listen(radiant, 'radiant:required_loaded',
   stonehearth_performance_mod, stonehearth_performance_mod._on_required_loaded)

log:always('[perf_mod.state] listeners registered')

return stonehearth_performance_mod
