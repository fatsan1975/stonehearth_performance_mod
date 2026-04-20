-- stonehearth_performance_mod_server.lua
-- Tum patch kodu inline ? require ba??ml?l??? YOK

stonehearth_performance_mod = {}

local log = radiant.log.create_logger('perf_mod')
log:always('perf_mod: server script loaded (v320)')

-- ?????????????????????????????????????????????????????????????????????????
-- CONFIG
-- ?????????????????????????????????????????????????????????????????????????

local PROFILES = {
   SAFE = {
      id = 'SAFE',
      reconsider_alloc = true, filter_fast_reject = true,
      reconsider_limiter = true, gc_tuning = true,
      max_reconsider_per_tick = 80, reject_flush_interval = 400,
      gc_pause = 120, gc_stepsize = 80,
      post_spike_steps = 1, spike_threshold_ms = 80,
   },
   BALANCED = {
      id = 'BALANCED',
      reconsider_alloc = true, filter_fast_reject = true,
      reconsider_limiter = true, gc_tuning = true,
      max_reconsider_per_tick = 64, reject_flush_interval = 300,
      gc_pause = 110, gc_stepsize = 100,
      post_spike_steps = 2, spike_threshold_ms = 60,
   },
   AGGRESSIVE = {
      id = 'AGGRESSIVE',
      reconsider_alloc = true, filter_fast_reject = true,
      reconsider_limiter = true, gc_tuning = true,
      max_reconsider_per_tick = 48, reject_flush_interval = 200,
      gc_pause = 105, gc_stepsize = 120,
      post_spike_steps = 3, spike_threshold_ms = 50,
   }
}

-- ?????????????????????????????????????????????????????????????????????????
-- STATE
-- ?????????????????????????????????????????????????????????????????????????

local _initialized = false
local _patches_applied = false
local _applied_patches = {}
local _heartbeat_count = 0
local _ace_present = false
local _current_profile = 'BALANCED'

local _counters = {}
local _instrumentation = {
   _enabled = true,
   set_enabled = function(self, v) self._enabled = v and true or false end,
   inc = function(self, name, amount)
      if not self._enabled then return end
      _counters[name] = (_counters[name] or 0) + (amount or 1)
   end,
   get_snapshot = function(self)
      local snap = {}
      for k, v in pairs(_counters) do snap[k] = v end
      return snap
   end,
   publish_if_available = function(self)
      if not self._enabled then return end
      if stonehearth and stonehearth.perf_mon and stonehearth.perf_mon.set_counter then
         for name, value in pairs(_counters) do
            stonehearth.perf_mon:set_counter(name, value)
         end
      end
   end,
}

local function _get_profile_data()
   return PROFILES[_current_profile] or PROFILES.BALANCED
end

-- ?????????????????????????????????????????????????????????????????????????
-- PATCH 1+4: RECONSIDER ALLOC + ENTITY SPREAD (inline)
-- ?????????????????????????????????????????????????????????????????????????

local P1 = {} -- reconsider_alloc
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
            _instrumentation:inc('perfmod:reconsider_spread_defers', entity_count - _max_per_tick)
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
      _instrumentation:inc('perfmod:reconsider_alloc_ticks')
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
      _max_per_tick = config.max_reconsider_per_tick or 64
      local ai = stonehearth.ai
      _orig_call_reconsider_cbs = ai._call_reconsider_callbacks
      _orig_on_reconsider_entity = ai.on_reconsider_entity
      ai._call_reconsider_callbacks = _patched_call
      ai.on_reconsider_entity = _patched_on_reconsider
      _rebuild_snapshot(ai)
      _p1_patched = true
      return true
   end
   function P1.is_patched() return _p1_patched end
   function P1.set_max_per_tick(v) _max_per_tick = v or 64 end
   function P1.restore()
      if not _p1_patched then return end
      local ai = stonehearth.ai
      if _orig_call_reconsider_cbs then ai._call_reconsider_callbacks = _orig_call_reconsider_cbs end
      if _orig_on_reconsider_entity then ai.on_reconsider_entity = _orig_on_reconsider_entity end
      _p1_patched = false
   end
end

-- ?????????????????????????????????????????????????????????????????????????
-- PATCH A: RETROAKTIF FILTER WRAPPING (fast_call_filter_fn hook)
-- ?????????????????????????????????????????????????????????????????????????

local PA = {}
do
   local _pa_patched = false
   local _orig_fast_call = nil
   local _orig_add_reconsidered = nil

   -- URI ? false cache (negatif sonuclar)
   -- _uri_reject[filter_fn] = { ["player_id:uri"] = true }
   local _uri_reject = {}

   -- Tick counter for periodic flush
   local _pa_tick_count = 0
   local _pa_flush_interval = 300

   -- entity_forms olan URI'leri cache'le (C++ boundary crossing 1 kez)
   local _has_entity_forms = {}  -- uri ? true/false

   local get_player_id = radiant.entities.get_player_id

   local function _patched_fast_call(self, filter_fn, entity)
      if not entity or not entity:is_valid() then
         return false
      end

      local uri = entity:get_uri()
      local pid = get_player_id(entity)
      if not pid then pid = '' end

      -- filter_fn icin reject cache al/olustur
      local reject = _uri_reject[filter_fn]
      if not reject then
         reject = {}
         _uri_reject[filter_fn] = reject
      end

      local cache_key = pid .. ':' .. uri

      -- REJECT CACHE HIT ? hizli false
      if rawget(reject, cache_key) then
         _instrumentation:inc('perfmod:fast_reject_hits')
         return false
      end

      -- CACHE MISS ? orijinal fast_call_filter_fn
      local result = _orig_fast_call(self, filter_fn, entity)

      -- NEGATIF sonucu cache'le (entity_forms yoksa)
      if not result then
         local has_ef = _has_entity_forms[uri]
         if has_ef == nil then
            has_ef = entity:get_component('stonehearth:entity_forms') ~= nil
            _has_entity_forms[uri] = has_ef
         end
         if not has_ef then
            rawset(reject, cache_key, true)
            _instrumentation:inc('perfmod:fast_reject_caches')
         end
      end

      return result
   end

   -- Entity reconsider edildiginde URI'sini reject cache'lerden sil
   local function _invalidate_entity(entity)
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

   -- _add_reconsidered_entity override: URI invalidation + orijinal
   local function _patched_add_reconsidered(self, entity, reason)
      _invalidate_entity(entity)
      return _orig_add_reconsidered(self, entity, reason)
   end

   function PA.flush_all()
      for _, cache in pairs(_uri_reject) do
         for k in pairs(cache) do cache[k] = nil end
      end
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
      _pa_flush_interval = config.reject_flush_interval or 300

      local ai = stonehearth.ai

      -- fast_call_filter_fn varligini kontrol et
      if not ai.fast_call_filter_fn then
         log:always('  PATCH A: fast_call_filter_fn BULUNAMADI')
         return false
      end

      _orig_fast_call = ai.fast_call_filter_fn
      _orig_add_reconsidered = ai._add_reconsidered_entity

      ai.fast_call_filter_fn = _patched_fast_call
      ai._add_reconsidered_entity = _patched_add_reconsidered

      _pa_patched = true
      return true
   end

   function PA.is_patched() return _pa_patched end

   function PA.restore()
      if not _pa_patched then return end
      local ai = stonehearth.ai
      if _orig_fast_call then ai.fast_call_filter_fn = _orig_fast_call end
      if _orig_add_reconsidered then ai._add_reconsidered_entity = _orig_add_reconsidered end
      _pa_patched = false
      _orig_fast_call = nil
      _orig_add_reconsidered = nil
      PA.flush_all()
   end
end

-- ?????????????????????????????????????????????????????????????????????????
-- PATCH C: reconsider_entity_in_filter_caches THROTTLE
-- ?????????????????????????????????????????????????????????????????????????

local PC = {}
do
   local _pc_patched = false
   -- Bu tick'te zaten reconsider edilmis (storage_id, entity_id) ciftleri
   local _reconsider_cache_seen = {}

   function PC.should_reconsider_in_cache(storage_entity, entity_id)
      local storage_id = storage_entity:get_id()
      local seen = _reconsider_cache_seen[storage_id]
      if not seen then
         seen = {}
         _reconsider_cache_seen[storage_id] = seen
      end
      if seen[entity_id] then
         _instrumentation:inc('perfmod:cache_throttle_hits')
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
end

-- ?????????????????????????????????????????????????????????????????????????
-- PATCH 3: RECONSIDER LIMITER (inline)
-- ?????????????????????????????????????????????????????????????????????????

local P3 = {} -- reconsider_limiter
do
   local _p3_patched = false
   local _orig_reconsider_entity = nil
   local _seen_this_tick = {}
   local _container_cache = {}

   local function _patched_reconsider(self, entity, reason, reconsider_parent)
      if not entity or not entity:is_valid() then return end
      local id = entity:get_id()
      if _seen_this_tick[id] then
         _instrumentation:inc('perfmod:reconsider_dedup_hits')
         return
      end
      _seen_this_tick[id] = true
      self:_add_reconsidered_entity(entity, reason)

      local pid = radiant.entities.get_player_id(entity)
      if pid and pid ~= '' then
         local inv = stonehearth.inventory:get_inventory(pid)
         if inv and inv.is_initialized and inv:is_initialized() then
            local container = _container_cache[id]
            if container == nil then
               container = inv:container_for(entity) or false
               _container_cache[id] = container
            end
            if container and container ~= false then
               local cid = container:get_id()
               local is_sp = container:get_component('stonehearth:stockpile')
               if not is_sp then
                  local sc = container:get_component('stonehearth:storage')
                  if sc and PC.should_reconsider_in_cache(container, id) then
                     pcall(sc.reconsider_entity_in_filter_caches, sc, id, entity)
                  end
                  if not _seen_this_tick[cid] then
                     _seen_this_tick[cid] = true
                     self:_add_reconsidered_entity(container, reason .. '(container)')
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
               self:_add_reconsidered_entity(parent, reason .. '(parent)')
            end
         end
      end
   end

   function P3.apply(config)
      if _p3_patched then return true end
      local ai = stonehearth.ai
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
      if _orig_reconsider_entity then stonehearth.ai.reconsider_entity = _orig_reconsider_entity end
      _p3_patched = false
   end
end

-- ?????????????????????????????????????????????????????????????????????????
-- GC OPTIMIZATION (inline)
-- ?????????????????????????????????????????????????????????????????????????

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

   function GC.adaptive_gc_step(profile)
      local now = os.clock()
      local frame_ms = _last_hb and (now - _last_hb) * 1000 or 0
      _last_hb = now
      if frame_ms > (profile.spike_threshold_ms or 80) then
         _was_spiking = true
         _instrumentation:inc('perfmod:gc_spike_skips')
         return
      end
      local step = 0
      if frame_ms < 20 then step = 2 elseif frame_ms < 40 then step = 1 end
      pcall(collectgarbage, 'step', step)
      _instrumentation:inc('perfmod:gc_adaptive_steps')
      if _was_spiking then
         _was_spiking = false
         for _ = 1, (profile.post_spike_steps or 1) do pcall(collectgarbage, 'step', 1) end
         _instrumentation:inc('perfmod:gc_post_spike_boosts')
      end
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
end

-- ?????????????????????????????????????????????????????????????????????????
-- PATCH APPLICATION
-- ?????????????????????????????????????????????????????????????????????????

local function _apply_patches()
   local profile = _get_profile_data()
   log:always('perf_mod: applying patches (profile=%s)...', profile.id)

   local cfg = { instrumentation = _instrumentation, max_reconsider_per_tick = profile.max_reconsider_per_tick, reject_flush_interval = profile.reject_flush_interval }

   -- PATCH 3 first (reconsider_entity override)
   if profile.reconsider_limiter then
      local ok, err = pcall(P3.apply, cfg)
      if ok and P3.is_patched() then
         _applied_patches[#_applied_patches + 1] = 'P3:limiter'
         log:always('  [OK] PATCH 3: reconsider dedup + container cache')
      else
         log:always('  [FAIL] PATCH 3: %s', tostring(err))
      end
   end

   -- PATCH A (fast_call_filter_fn URI reject ? retroaktif)
   if profile.filter_fast_reject then
      local ok, err = pcall(PA.apply, cfg)
      if ok and PA.is_patched() then
         _applied_patches[#_applied_patches + 1] = 'PA:fast_reject'
         log:always('  [OK] PATCH A: fast_call_filter_fn URI reject (flush=%d)', profile.reject_flush_interval)
      else
         log:always('  [FAIL] PATCH A: %s', tostring(err))
      end
   end

   -- PATCH C (reconsider_entity_in_filter_caches throttle)
   if profile.reconsider_limiter then
      local ok_c, err_c = pcall(PC.apply, cfg)
      if ok_c and PC.is_patched() then
         _applied_patches[#_applied_patches + 1] = 'PC:cache_throttle'
         log:always('  [OK] PATCH C: reconsider_entity_in_filter_caches throttle')
      else
         log:always('  [FAIL] PATCH C: %s', tostring(err_c))
      end
   end

   -- PATCH 1+4 (alloc + spread)
   if profile.reconsider_alloc then
      local ok, err = pcall(P1.apply, cfg)
      if ok and P1.is_patched() then
         _applied_patches[#_applied_patches + 1] = 'P1:alloc+spread'
         log:always('  [OK] PATCH 1+4: zero-alloc reconsider + spread (max=%d)', profile.max_reconsider_per_tick)
      else
         log:always('  [FAIL] PATCH 1+4: %s', tostring(err))
      end
   end

   -- GC tuning
   if profile.gc_tuning then
      GC.apply_gc_params(profile)
      local ok, err = pcall(GC.apply, cfg)
      if ok then
         _applied_patches[#_applied_patches + 1] = 'GC:tuning'
         log:always('  [OK] GC tuning (pause=%d step=%d)', profile.gc_pause, profile.gc_stepsize)
      else
         log:always('  [FAIL] GC: %s', tostring(err))
      end
   end

   _patches_applied = true
end

-- ?????????????????????????????????????????????????????????????????????????
-- HEARTBEAT
-- ?????????????????????????????????????????????????????????????????????????

local function _on_tick()
   _heartbeat_count = _heartbeat_count + 1
   if P3.is_patched() then pcall(P3.flush_tick) end
   if PC.is_patched() then pcall(PC.flush_tick) end
   if PA.is_patched() then pcall(PA.tick) end
   local profile = _get_profile_data()
   if profile.gc_tuning and GC.is_patched() then pcall(GC.adaptive_gc_step, profile) end
   _instrumentation:publish_if_available()
   if _heartbeat_count % 60 == 0 then
      local s = _instrumentation:get_snapshot()
      log:always('perf_mod %ds: patches=%d fast_reject=%d dedup=%d cache_throttle=%d spread=%d gc=%d',
         _heartbeat_count, #_applied_patches,
         s['perfmod:fast_reject_hits'] or 0, s['perfmod:reconsider_dedup_hits'] or 0,
         s['perfmod:cache_throttle_hits'] or 0,
         s['perfmod:reconsider_spread_defers'] or 0, s['perfmod:gc_adaptive_steps'] or 0)
   end
end

local function _start_heartbeat()
   if radiant.set_realtime_interval then
      radiant.set_realtime_interval('perf_mod_pump', 1000, function() _on_tick() end)
      log:always('perf_mod: heartbeat OK (1s realtime)')
      return true
   end
   if radiant.on_game_loop then
      local fc = 0
      radiant.on_game_loop('perf_mod_pump', function()
         fc = fc + 1
         if fc % 20 == 0 then _on_tick() end
      end)
      log:always('perf_mod: heartbeat OK (game_loop/20)')
      return true
   end
   log:always('perf_mod: WARNING ? no heartbeat available')
   return false
end

-- ?????????????????????????????????????????????????????????????????????????
-- AI READINESS + DEFERRED APPLICATION
-- ?????????????????????????????????????????????????????????????????????????

local function _ai_ready()
   if not stonehearth or not stonehearth.ai then return false end
   return stonehearth.ai.reconsider_entity ~= nil
      and stonehearth.ai._call_reconsider_callbacks ~= nil
      and stonehearth.ai._add_reconsidered_entity ~= nil
end

local function _summary()
   local n = #_applied_patches
   log:always('=======================================================')
   log:always('perf_mod v320 | Profile: %s | ACE: %s | Patches: %d/5', _current_profile, tostring(_ace_present), n)
   for _, name in ipairs(_applied_patches) do log:always('  + %s', name) end
   if n == 0 then log:always('  *** NO PATCHES ***') end
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
         log:always('perf_mod: AI ready after %d retries', retries)
         _go()
      elseif retries < 50 then
         radiant.set_realtime_timer('perf_mod_r' .. retries, 100, try)
      else
         log:always('perf_mod: GAVE UP on AI after 50 retries')
         GC.apply_gc_params(_get_profile_data())
         pcall(GC.apply, {})
         _applied_patches[#_applied_patches + 1] = 'GC:tuning'
         _start_heartbeat()
         _summary()
      end
   end
   try()
end

-- ?????????????????????????????????????????????????????????????????????????
-- LIFECYCLE
-- ?????????????????????????????????????????????????????????????????????????

function stonehearth_performance_mod:_on_init()
   log:always('perf_mod: _on_init')

   local ok, p = pcall(function() return radiant.util.get_global_config('mods.stonehearth_performance_mod.profile', nil) end)
   if ok and p and PROFILES[p] then _current_profile = p end

   local ok2, list = pcall(radiant.resources.get_mod_list)
   if ok2 and list then
      for _, m in ipairs(list) do
         if m == 'stonehearth_ace' then _ace_present = true; break end
      end
   end

   _initialized = true
   log:always('perf_mod: init done (profile=%s ace=%s)', _current_profile, tostring(_ace_present))
end

function stonehearth_performance_mod:_on_required_loaded()
   log:always('perf_mod: _on_required_loaded')
   if not _initialized then log:always('perf_mod: ERROR init incomplete'); return end
   if _patches_applied then return end
   if _ai_ready() then
      log:always('perf_mod: AI ready ? applying now')
      _go()
   else
      log:always('perf_mod: AI not ready ? deferring')
      _defer()
   end
end

-- ?????????????????????????????????????????????????????????????????????????
-- PUBLIC API
-- ?????????????????????????????????????????????????????????????????????????

function stonehearth_performance_mod:get_settings()
   return { profile = _current_profile, instrumentation_enabled = _instrumentation._enabled }
end

function stonehearth_performance_mod:update_settings(data)
   if type(data) ~= 'table' then return false end
   if data.profile and PROFILES[data.profile] then _current_profile = data.profile end
   if data.instrumentation_enabled ~= nil then _instrumentation:set_enabled(data.instrumentation_enabled) end
   local profile = _get_profile_data()
   if P1.is_patched() then P1.set_max_per_tick(profile.max_reconsider_per_tick) end
   if profile.gc_tuning then GC.apply_gc_params(profile) end
   log:always('perf_mod: settings -> profile=%s', _current_profile)
   return true
end

function stonehearth_performance_mod:get_instrumentation_snapshot()
   return _instrumentation:get_snapshot()
end

-- ?????????????????????????????????????????????????????????????????????????
-- EVENT REGISTRATION
-- ?????????????????????????????????????????????????????????????????????????

radiant.events.listen(stonehearth_performance_mod, 'radiant:init', stonehearth_performance_mod, stonehearth_performance_mod._on_init)
radiant.events.listen(radiant, 'radiant:required_loaded', stonehearth_performance_mod, stonehearth_performance_mod._on_required_loaded)

log:always('perf_mod: listeners registered')

return stonehearth_performance_mod
