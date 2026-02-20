local unpack = table.unpack or unpack

local Config = require 'scripts.perf_mod.config'

local QueryOptimizer = class()

function QueryOptimizer:initialize(clock, cache, coalescer, instrumentation, settings, log)
   self._clock = clock
   self._cache = cache
   self._coalescer = coalescer
   self._instrumentation = instrumentation
   self._settings = settings
   self._log = log
   self._table_pool = {}
   self._context_state = {}
end

function QueryOptimizer:borrow_table()
   return table.remove(self._table_pool) or {}
end

function QueryOptimizer:return_table(t)
   for k in pairs(t) do
      t[k] = nil
   end
   self._table_pool[#self._table_pool + 1] = t
end

function QueryOptimizer:_get_context_state(context)
   local state = self._context_state[context]
   if not state then
      state = {
         dirty = false,
         dirty_since = 0,
         maintenance_scheduled = false
      }
      self._context_state[context] = state
   end
   return state
end

function QueryOptimizer:mark_inventory_dirty(context)
   self._cache:invalidate(context)
   local state = self:_get_context_state(context)
   state.dirty = true
   state.dirty_since = self._clock:get_realtime_seconds()

   if not state.maintenance_scheduled then
      state.maintenance_scheduled = true
      self:coalesce(context .. ':maintenance', function()
         self._cache:prune_context(context)
         state.dirty = false
         state.maintenance_scheduled = false
      end)
   end
end

local function _is_negative_result(first)
   return first == nil or (type(first) == 'table' and next(first) == nil)
end

local function _target_identity(target)
   if type(target) ~= 'table' then
      return '-'
   end

   if target.get_id then
      local ok, id = pcall(target.get_id, target)
      if ok and id ~= nil then
         return id
      end
   end

   if target.__self then
      return tostring(target.__self)
   end

   return tostring(target)
end

local function _args_signature(...)
   local count = select('#', ...)
   local max_args = math.min(count, 6)
   local sig = { count = count }
   for i = 1, max_args do
      sig[i] = select(i, ...)
   end
   return sig
end

local function _is_urgent_query(context, ...)
   if context == 'inventory' then
      return true
   end

   local first = select(1, ...)
   if type(first) ~= 'table' then
      return false
   end

   if first.require_immediate or first.urgent or first.allow_reserved then
      return true
   end

   return false
end

local function _result_size_hint(first)
   if type(first) ~= 'table' then
      return 1
   end

   if first[1] ~= nil then
      return #first
   end

   local count = 0
   for _ in pairs(first) do
      count = count + 1
      if count >= 256 then
         break
      end
   end
   return count
end

function QueryOptimizer:_effective_profile(profile, state)
   if profile.id == 'AGGRESSIVE' and state.dirty then
      return Config.get_profile('BALANCED')
   end
   return profile
end

function QueryOptimizer:_fallback_to_original(original_fn, target, filter, ...)
   self._instrumentation:inc('perfmod:full_scan_fallbacks')
   return original_fn(target, filter, ...)
end

function QueryOptimizer:wrap_query(context, original_fn)
   return function(target, filter, ...)
      local state = self:_get_context_state(context)
      local profile = self:_effective_profile(self._settings:get_profile_data(), state)
      local pipeline_start = self._clock:get_realtime_seconds()

      local player_id = target and target.get_player_id and target:get_player_id() or nil
      local target_key = _target_identity(target)
      local args_key = _args_signature(...)
      local key = self._cache:make_key(filter, context, player_id, target_key, args_key)

      local is_urgent = _is_urgent_query(context, ...)
      if profile.urgent_cache_bypass and is_urgent then
         self._instrumentation:inc('perfmod:urgent_bypasses')
         local started_urgent = self._clock:get_realtime_seconds()
         local out = { self:_fallback_to_original(original_fn, target, filter, ...) }
         self._instrumentation:observe_query_time(self._clock:get_elapsed_ms(started_urgent))
         return unpack(out)
      end

      local prelookup_ms = self._clock:get_elapsed_ms(pipeline_start)
      if prelookup_ms > profile.query_deadline_ms then
         self._instrumentation:inc('perfmod:deadline_fallbacks')
         return self:_fallback_to_original(original_fn, target, filter, ...)
      end

      local now = self._clock:get_realtime_seconds()
      local cached = self._cache:get(key, context, now, profile.cache_ttl, profile.negative_ttl)
      if cached then
         if cached.negative and state.dirty then
            self._instrumentation:inc('perfmod:dirty_negative_bypasses')
            cached = nil
         else
            if cached.negative then
               self._instrumentation:inc('perfmod:negative_hits')
            else
               self._instrumentation:inc('perfmod:cache_hits')
            end
            return unpack(cached.value)
         end
      end

      self._instrumentation:inc('perfmod:cache_misses')
      if state.dirty and profile.deferred_wait_ms <= 0 then
         state.dirty = false
      end

      local started = self._clock:get_realtime_seconds()
      local result = { self:_fallback_to_original(original_fn, target, filter, ...) }
      local elapsed = self._clock:get_elapsed_ms(started)

      if elapsed > profile.query_deadline_ms then
         self._instrumentation:inc('perfmod:deadline_fallbacks')
      end

      local result_size = _result_size_hint(result[1])
      if result_size > profile.max_cached_result_size then
         self._instrumentation:inc('perfmod:oversized_skips')
      else
         local seen_count = self._cache:touch_key(key)
         if seen_count >= profile.admit_after_hits then
            self._cache:set(key, context, result, now, _is_negative_result(result[1]), profile.max_cache_entries)
         else
            self._instrumentation:inc('perfmod:admission_skips')
         end
      end

      self._instrumentation:observe_query_time(elapsed)
      return unpack(result)
   end
end

function QueryOptimizer:run_incremental_scan(scan_state, scan_step_fn)
   local profile = self._settings:get_profile_data()
   local started = self._clock:get_realtime_seconds()
   while true do
      local done = scan_step_fn(scan_state)
      self._instrumentation:inc('perfmod:incremental_scan_steps')
      if done then
         return true
      end

      if self._clock:get_elapsed_ms(started) >= profile.incremental_budget_ms then
         return false
      end
   end
end

function QueryOptimizer:coalesce(context, fn)
   local profile = self._settings:get_profile_data()
   self._coalescer:mark_dirty(context, fn, profile.coalesce_ms)
end

return QueryOptimizer
