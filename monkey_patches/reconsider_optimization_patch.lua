-- reconsider_optimization_patch.lua
-- FAZ 2: Reconsider Cascade Optimizasyonu

local M = {}

local AI_TARGETS = {
   'stonehearth_ace.services.server.ai.ai_service',
   'stonehearth.services.server.ai.ai_service',
}

local _dedup = {}
local _dedup_count = 0

local _callback_snapshot = {}
local _callback_snapshot_len = 0
local _callbacks_dirty = true

local _stats = {
   dedup_hits = 0,
   snapshot_reuses = 0,
}

local _error_count = 0
local _error_window_start = 0
local _circuit_open = false
local _circuit_open_until = 0
local _ERROR_THRESHOLD = 5
local _ERROR_WINDOW = 15
local _CIRCUIT_COOLDOWN = 60

local _reconsidered_field = nil
local _reconsidered_field_detected = false

function M.flush_tick()
   if _dedup_count > 0 then
      _dedup = {}
      _dedup_count = 0
   end
end

local function _record_error(clock)
   local now = clock:get_realtime_seconds()
   if now - _error_window_start > _ERROR_WINDOW then
      _error_count = 0
      _error_window_start = now
   end
   _error_count = _error_count + 1
   if _error_count >= _ERROR_THRESHOLD then
      _circuit_open = true
      _circuit_open_until = now + _CIRCUIT_COOLDOWN
      _error_count = 0
   end
end

local function _is_circuit_open(clock)
   if not _circuit_open then return false end
   if clock:get_realtime_seconds() >= _circuit_open_until then
      _circuit_open = false
      return false
   end
   return true
end

local function _detect_reconsidered_field(self)
   if _reconsidered_field_detected then
      return _reconsidered_field
   end

   if self._reconsidered_entities ~= nil then
      _reconsidered_field = '_reconsidered_entities'
      _reconsidered_field_detected = true
      return _reconsidered_field
   end

   if self._reconsidered ~= nil then
      _reconsidered_field = '_reconsidered'
      _reconsidered_field_detected = true
      return _reconsidered_field
   end

   return nil
end

local function _make_dedup_add_reconsidered(original_add, clock)
   return function(self, entity, reason)
      if _is_circuit_open(clock) then
         return original_add(self, entity, reason)
      end

      local ok, err = pcall(function()
         local entity_id = nil
         if entity and entity.get_id then
            entity_id = entity:get_id()
         elseif entity and entity.id then
            entity_id = entity.id
         end

         if entity_id then
            if _dedup[entity_id] then
               _stats.dedup_hits = _stats.dedup_hits + 1
               return
            end

            _dedup[entity_id] = true
            _dedup_count = _dedup_count + 1
         end

         original_add(self, entity, reason)
      end)

      if not ok then
         _record_error(clock)
         pcall(original_add, self, entity, reason)
      end
   end
end

local function _make_optimized_call_reconsider(original_call, clock)
   return function(self)
      if _is_circuit_open(clock) then
         return original_call(self)
      end

      local field = _detect_reconsidered_field(self)
      if not field then
         return original_call(self)
      end

      local reconsidered = self[field]
      if not reconsidered then
         return original_call(self)
      end

      if not next(reconsidered) then
         return original_call(self)
      end

      self[field] = {}

      local ok = pcall(function()
         if _callbacks_dirty then
            local idx = 0
            local src = self._reconsider_callbacks
            if src then
               for _, entry in pairs(src) do
                  if entry and entry.callback then
                     idx = idx + 1
                     _callback_snapshot[idx] = entry.callback
                  end
               end
            end
            for i = idx + 1, _callback_snapshot_len do
               _callback_snapshot[i] = nil
            end
            _callback_snapshot_len = idx
            _callbacks_dirty = false
         else
            _stats.snapshot_reuses = _stats.snapshot_reuses + 1
         end

         for id, msg in pairs(reconsidered) do
            if msg and msg.entity and msg.entity:is_valid() then
               for i = 1, _callback_snapshot_len do
                  local cb = _callback_snapshot[i]
                  if cb then
                     local cb_ok, cb_err = pcall(cb, msg)
                     if not cb_ok and self._log then
                        pcall(function()
                           self._log:warning('reconsider callback error: %s', tostring(cb_err))
                        end)
                     end
                  end
               end
            end
         end

         if self._entity_reconsider_callbacks then
            for id, msg in pairs(reconsidered) do
               if msg and msg.entity and msg.entity:is_valid() then
                  local entity_cbs = self._entity_reconsider_callbacks[id]
                  if entity_cbs then
                     for _, ecb in pairs(entity_cbs) do
                        if ecb then
                           pcall(ecb, msg)
                        end
                     end
                  end
               end
            end
         end

         if _radiant and _radiant.sim and _radiant.sim.reconsider_entities then
            _radiant.sim.reconsider_entities(reconsidered)
         end
      end)

      if not ok then
         self[field] = reconsidered
         _record_error(clock)
         pcall(original_call, self)
      end
   end
end

local function _patch_callback_registration(mod, clock)
   local reg_names = {
      'register_reconsider_callback',
      '_register_reconsider_callback',
      'add_reconsider_callback',
   }
   for _, name in ipairs(reg_names) do
      local fn = mod[name]
      if type(fn) == 'function' and not mod['_perfmod_rc_' .. name] then
         mod[name] = function(self, ...)
            _callbacks_dirty = true
            return fn(self, ...)
         end
         mod['_perfmod_rc_' .. name] = true
      end
   end

   local unreg_names = {
      'unregister_reconsider_callback',
      '_unregister_reconsider_callback',
      'remove_reconsider_callback',
   }
   for _, name in ipairs(unreg_names) do
      local fn = mod[name]
      if type(fn) == 'function' and not mod['_perfmod_rc_' .. name] then
         mod[name] = function(self, ...)
            _callbacks_dirty = true
            return fn(self, ...)
         end
         mod['_perfmod_rc_' .. name] = true
      end
   end
end

function M.apply(service)
   local clock = service:get_clock()
   local instrumentation = service:get_instrumentation()
   local patched = false

   for _, path in ipairs(AI_TARGETS) do
      local ok, mod = pcall(require, path)
      if ok and type(mod) == 'table' then
         if mod._perfmod_reconsider_patched then
            patched = true
         else
            local ok2, err2 = pcall(function()
               if type(mod._add_reconsidered_entity) == 'function' then
                  mod._add_reconsidered_entity = _make_dedup_add_reconsidered(
                     mod._add_reconsidered_entity, clock)
               end

               if type(mod._call_reconsider_callbacks) == 'function' then
                  mod._call_reconsider_callbacks = _make_optimized_call_reconsider(
                     mod._call_reconsider_callbacks, clock)
               end

               _patch_callback_registration(mod, clock)

               mod._perfmod_reconsider_patched = true
            end)

            if ok2 then
               patched = true
            elseif err2 then
               local log = radiant.log.create_logger('perf_mod_reconsider')
               log:warning('Reconsider patch failed for %s: %s', path, tostring(err2))
            end
         end
      end
   end

   if patched and instrumentation then
      M._instrumentation = instrumentation
   end

   return patched
end

function M.publish_stats()
   local inst = M._instrumentation
   if not inst then return end

   inst:set('perfmod:reconsider_dedup_hits', _stats.dedup_hits)
   inst:set('perfmod:reconsider_snapshot_reuses', _stats.snapshot_reuses)
end

function M.get_stats()
   return _stats
end

return M
