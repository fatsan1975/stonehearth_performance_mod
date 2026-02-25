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
   self._context_state = {}
   self._circuit_state = {}
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

function QueryOptimizer:_get_circuit_state(context)
   local state = self._circuit_state[context]
   if not state then
      state = {
         failures = {},
         open_until = 0
      }
      self._circuit_state[context] = state
   end
   return state
end

function QueryOptimizer:_record_failure(context, profile, now)
   local circuit = self:_get_circuit_state(context)
   local failures = circuit.failures
   failures[#failures + 1] = now

   local window_s = profile.circuit_window_s or 10
   local keep_from = now - window_s
   local kept = {}
   for i = 1, #failures do
      local ts = failures[i]
      if ts >= keep_from then
         kept[#kept + 1] = ts
      end
   end
   circuit.failures = kept

   local threshold = profile.circuit_failures or 3
   if #kept >= threshold then
      circuit.open_until = now + (profile.circuit_open_s or 30)
      circuit.failures = {}
   end
end

function QueryOptimizer:_is_circuit_open(context, now)
   local circuit = self:_get_circuit_state(context)
   return now < (circuit.open_until or 0)
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

local NOISY_KEYS = {
   path = true,
   destination = true,
   location = true,
   region = true,
   search_region = true,
   nav_grid = true,
   traversal = true,
   ai = true,
   task = true,
   planner = true
}

local function _is_noisy_signature(filter, args_signature, noisy_limit)
   local noisy = 0
   if type(filter) == 'table' then
      for k in pairs(filter) do
         if NOISY_KEYS[k] then
            noisy = noisy + 1
         end
      end
   end

   if type(args_signature) == 'table' then
      for i = 1, math.min(args_signature.count or 0, 3) do
         local v = args_signature[i]
         if type(v) == 'table' then
            for k in pairs(v) do
               if NOISY_KEYS[k] then
                  noisy = noisy + 1
               end
            end
         end
      end
   end

   return noisy >= (noisy_limit or 5)
end

local function _classify_query(context, filter, ...)
   if context == 'inventory' then
      return 'urgent'
   end

   local first = select(1, ...)
   if type(first) == 'table' then
      if first.require_immediate or first.urgent or first.allow_reserved then
         return 'urgent'
      end
      if first.limit and type(first.limit) == 'number' and first.limit <= 3 then
         return 'urgent'
      end
   end

   local f = filter
   if type(f) == 'table' then
      if f.path or f.destination or f.region or f.search_region or f.ai or f.task then
         return 'ai_path'
      end
   end

   return 'normal'
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

function QueryOptimizer:_run_safe_optimized(context, profile, fn, original_fn, target, filter, packed_args)
   local ok, a, b, c, d, e, f = pcall(fn)
   if ok then
      return a, b, c, d, e, f
   end

   self._instrumentation:inc('perfmod:safety_fallbacks')
   self:_record_failure(context, profile, self._clock:get_realtime_seconds())
   if self._log and self._log.warning then
      self._log:warning('Optimizer safety fallback due to error: %s', tostring(a))
   end
   return self:_fallback_to_original(original_fn, target, filter, unpack(packed_args, 1, packed_args.n))
end

function QueryOptimizer:wrap_query(context, original_fn)
   return function(target, filter, ...)
      local packed_args = { n = select('#', ...), ... }
      local state = self:_get_context_state(context)
      local profile = self:_effective_profile(self._settings:get_profile_data(), state)

      if not self._settings:is_context_cache_enabled(context) then
        self._instrumentation:inc('perfmod:context_bypasses')
        return self:_fallback_to_original(original_fn, target, filter, unpack(packed_args, 1, packed_args.n))
      end

      if self._settings:is_warm_resume_guard_active() then
         self._instrumentation:inc('perfmod:warm_resume_guards')
         return self:_fallback_to_original(original_fn, target, filter, unpack(packed_args, 1, packed_args.n))
      end

      local now_for_circuit = self._clock:get_realtime_seconds()
      if self:_is_circuit_open(context, now_for_circuit) then
         self._instrumentation:inc('perfmod:circuit_open_bypasses')
         return self:_fallback_to_original(original_fn, target, filter, unpack(packed_args, 1, packed_args.n))
      end

      return self:_run_safe_optimized(context, profile, function()
         local pipeline_start = self._clock:get_realtime_seconds()

         local query_class = _classify_query(context, filter, unpack(packed_args, 1, packed_args.n))
         if profile.urgent_cache_bypass and query_class == 'urgent' then
            self._instrumentation:inc('perfmod:urgent_bypasses')
            local started_urgent = self._clock:get_realtime_seconds()
            local out = { self:_fallback_to_original(original_fn, target, filter, unpack(packed_args, 1, packed_args.n)) }
            self._instrumentation:observe_query_time(self._clock:get_elapsed_ms(started_urgent))
            return unpack(out)
         end

         if profile.ai_path_cache_bypass and query_class == 'ai_path' then
            self._instrumentation:inc('perfmod:ai_path_bypasses')
            local started_ai = self._clock:get_realtime_seconds()
            local out = { self:_fallback_to_original(original_fn, target, filter, unpack(packed_args, 1, packed_args.n)) }
            self._instrumentation:observe_query_time(self._clock:get_elapsed_ms(started_ai))
            return unpack(out)
         end

         local player_id = target and target.get_player_id and target:get_player_id() or nil
         local target_key = _target_identity(target)
         local args_key = _args_signature(unpack(packed_args, 1, packed_args.n))

         if _is_noisy_signature(filter, args_key, profile.noisy_signature_limit) then
            self._instrumentation:inc('perfmod:noisy_signature_bypasses')
            return self:_fallback_to_original(original_fn, target, filter, unpack(packed_args, 1, packed_args.n))
         end

         local key = self._cache:make_key(filter, context, player_id, target_key, args_key)

         if not key then
            self._instrumentation:inc('perfmod:key_bypass_complex')
            local started_complex = self._clock:get_realtime_seconds()
            local out = { self:_fallback_to_original(original_fn, target, filter, unpack(packed_args, 1, packed_args.n)) }
            self._instrumentation:observe_query_time(self._clock:get_elapsed_ms(started_complex))
            return unpack(out)
         end

         local prelookup_ms = self._clock:get_elapsed_ms(pipeline_start)
         if prelookup_ms > profile.query_deadline_ms then
            self._instrumentation:inc('perfmod:deadline_fallbacks')
            return self:_fallback_to_original(original_fn, target, filter, unpack(packed_args, 1, packed_args.n))
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
         local result = { self:_fallback_to_original(original_fn, target, filter, unpack(packed_args, 1, packed_args.n)) }
         local elapsed = self._clock:get_elapsed_ms(started)

         if elapsed > profile.query_deadline_ms then
            self._instrumentation:inc('perfmod:deadline_fallbacks')
         end

         local is_negative = _is_negative_result(result[1])
         local result_size = _result_size_hint(result[1])
         if is_negative and not profile.cache_negative_results then
            self._instrumentation:inc('perfmod:negative_cache_skips')
         elseif result_size > profile.max_cached_result_size then
            self._instrumentation:inc('perfmod:oversized_skips')
         else
            local seen_count = self._cache:touch_key(key, profile.max_cache_entries * 2)
            if seen_count >= profile.admit_after_hits then
               self._cache:set(key, context, result, now, is_negative, profile.max_cache_entries)
            else
               self._instrumentation:inc('perfmod:admission_skips')
            end
         end

         self._instrumentation:observe_query_time(elapsed)
         return unpack(result)
      end, original_fn, target, filter, packed_args)
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
