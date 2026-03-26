-- counter_optimization_patch.lua
-- İterasyon tabanlı sayımları integer counter'lara dönüştürür.

local M = {}

local TASK_TARGETS = {
   'stonehearth_ace.services.server.tasks.task',
   'stonehearth.services.server.tasks.task',
}

local RESTOCK_TARGETS = {
   'stonehearth_ace.services.server.inventory.restock_director',
   'stonehearth.services.server.inventory.restock_director',
}

local INVENTORY_TARGETS = {
   'stonehearth_ace.services.server.inventory.inventory',
   'stonehearth.services.server.inventory.inventory',
}

local function _patch_task_module(mod)
   if mod._perfmod_counter_patched then return false end
   local any = false

   if type(mod._get_active_action_count) == 'function' then
      local original_count = mod._get_active_action_count

      mod._get_active_action_count = function(self)
         local count = self._perfmod_action_count
         if count ~= nil then
            return count
         end
         count = original_count(self)
         self._perfmod_action_count = count
         return count
      end
      any = true
   end

   if type(mod.__action_try_start) == 'function' then
      local original_try_start = mod.__action_try_start

      mod.__action_try_start = function(self, entity, ...)
         local result = original_try_start(self, entity, ...)
         self._perfmod_action_count = nil
         return result
      end
      any = true
   end

   if type(mod.__action_stopped) == 'function' then
      local original_stopped = mod.__action_stopped

      mod.__action_stopped = function(self, entity, ...)
         local result = original_stopped(self, entity, ...)
         self._perfmod_action_count = nil
         return result
      end
      any = true
   end

   if type(mod._action_try_start) == 'function' and not mod._perfmod_ats_wrapped then
      local original = mod._action_try_start
      mod._action_try_start = function(self, ...)
         local result = original(self, ...)
         self._perfmod_action_count = nil
         return result
      end
      mod._perfmod_ats_wrapped = true
      any = true
   end

   if type(mod._action_stopped) == 'function' and not mod._perfmod_as_wrapped then
      local original = mod._action_stopped
      mod._action_stopped = function(self, ...)
         local result = original(self, ...)
         self._perfmod_action_count = nil
         return result
      end
      mod._perfmod_as_wrapped = true
      any = true
   end

   if any then
      mod._perfmod_counter_patched = true
   end
   return any
end

local function _patch_restock_module(mod, clock)
   if mod._perfmod_counter_patched then return false end
   local any = false

   local add_methods = {
      '_add_errand', 'add_errand', '_create_errand',
      '_generate_next_errand_impl'
   }
   for _, name in ipairs(add_methods) do
      local fn = mod[name]
      if type(fn) == 'function' and not mod['_perfmod_ec_' .. name] then
         mod[name] = function(self, ...)
            local result = fn(self, ...)
            self._perfmod_errand_count = nil
            return result
         end
         mod['_perfmod_ec_' .. name] = true
         any = true
      end
   end

   local remove_methods = {
      '_remove_errand', 'remove_errand', '_on_errand_completed',
      '_on_errand_failed', '_dispose_errand'
   }
   for _, name in ipairs(remove_methods) do
      local fn = mod[name]
      if type(fn) == 'function' and not mod['_perfmod_ec_' .. name] then
         mod[name] = function(self, ...)
            local result = fn(self, ...)
            self._perfmod_errand_count = nil
            return result
         end
         mod['_perfmod_ec_' .. name] = true
         any = true
      end
   end

   if type(mod._get_max_errands) == 'function' and not mod._perfmod_ec_max then
      local original_max = mod._get_max_errands
      local cached_max = nil
      local cached_at = 0

      mod._get_max_errands = function(self, ...)
         local now = clock:get_realtime_seconds()
         if cached_max and (now - cached_at) < 2.0 then
            return cached_max
         end
         cached_max = original_max(self, ...)
         cached_at = now
         return cached_max
      end
      mod._perfmod_ec_max = true
      any = true
   end

   if any then
      mod._perfmod_counter_patched = true
   end
   return any
end

local function _patch_inventory_module(mod)
   if mod._perfmod_counter_patched then return false end
   local any = false

   if type(mod._check_public_storage_space) == 'function' and not mod._perfmod_inv_fullness then
      local original = mod._check_public_storage_space

      mod._check_public_storage_space = function(self, ...)
         local cached = self._perfmod_storage_full_cache
         if cached ~= nil and self._perfmod_storage_full_valid then
            return cached
         end

         local result = original(self, ...)
         self._perfmod_storage_full_cache = result
         self._perfmod_storage_full_valid = true
         return result
      end
      mod._perfmod_inv_fullness = true
      any = true
   end

   local invalidate_methods = {
      'add_storage', '_add_storage', 'remove_storage', '_remove_storage',
      'add_item', '_add_item', '_add_item_internal',
      'remove_item', '_remove_item'
   }
   for _, name in ipairs(invalidate_methods) do
      local fn = mod[name]
      if type(fn) == 'function' and not mod['_perfmod_inv_' .. name] then
         mod[name] = function(self, ...)
            self._perfmod_storage_full_valid = false
            return fn(self, ...)
         end
         mod['_perfmod_inv_' .. name] = true
         any = true
      end
   end

   if any then
      mod._perfmod_counter_patched = true
   end
   return any
end

function M.apply(service)
   local clock = service:get_clock()
   local patched = false

   for _, path in ipairs(TASK_TARGETS) do
      local ok, mod = pcall(require, path)
      if ok and type(mod) == 'table' then
         local ok2, result = pcall(_patch_task_module, mod)
         if ok2 and result then patched = true end
      end
   end

   for _, path in ipairs(RESTOCK_TARGETS) do
      local ok, mod = pcall(require, path)
      if ok and type(mod) == 'table' then
         local ok2, result = pcall(_patch_restock_module, mod, clock)
         if ok2 and result then patched = true end
      end
   end

   for _, path in ipairs(INVENTORY_TARGETS) do
      local ok, mod = pcall(require, path)
      if ok and type(mod) == 'table' then
         local ok2, result = pcall(_patch_inventory_module, mod)
         if ok2 and result then patched = true end
      end
   end

   return patched
end

return M
