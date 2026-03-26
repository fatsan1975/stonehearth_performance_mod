-- debug_string_patch.lua
-- Hot path'lerde koşulsuz string allocation'ı elimine eder.
--
-- Stonehearth'ün AI ve task sistemlerinde debug string'ler hot path'te
-- log seviyesinden bağımsız olarak oluşturulur:
--   - ai_service.lua:534-535: reason .. '(also triggering container)'
--   - task.lua:293: string.format('entering __action_try_start (entity:%s)', ...)
--   - task.lua:246-257: _log_state içinde iterate + string.format
--   - find_best_reachable_entity_by_type.lua:170: 'selected: ' .. tostring(item) ..
--
-- Bu patch hot fonksiyonlardaki string concatenation'ı log guard arkasına alır
-- veya sabit string sabitleri kullanır.
--
-- Güvenlik:
--   - Sadece debug/log çıktısı etkilenir, davranış değişikliği YOK
--   - pcall sarmalı, çift-patch guard
--   - Orijinal log semantik korunur (sadece gereksiz allocation engellenir)

local M = {}

local AI_TARGETS = {
   'stonehearth_ace.services.server.ai.ai_service',
   'stonehearth.services.server.ai.ai_service',
}

local TASK_TARGETS = {
   'stonehearth_ace.services.server.tasks.task',
   'stonehearth.services.server.tasks.task',
}

local FIND_ENTITY_TARGETS = {
   'stonehearth_ace.ai.actions.find_best_reachable_entity_by_type',
   'stonehearth.ai.actions.find_best_reachable_entity_by_type',
}

local REASON_CONTAINER = '(also triggering container)'
local REASON_PARENT = '(reconsider_parent)'

local function _patch_ai_service(mod)
   if mod._perfmod_debug_patched then return false end
   local any = false

   if type(mod.reconsider_entity) == 'function' and not mod._perfmod_dbg_reconsider then
      local original = mod.reconsider_entity

      mod.reconsider_entity = function(self, entity, reason)
         return original(self, entity, reason or '')
      end

      mod._perfmod_dbg_reconsider = true
      any = true
   end

   if any then
      mod._perfmod_debug_patched = true
   end
   return any
end

local function _patch_task_module(mod)
   if mod._perfmod_debug_patched then return false end
   local any = false

   if type(mod._log_state) == 'function' and not mod._perfmod_dbg_logstate then
      local original_log_state = mod._log_state

      mod._log_state = function(self, msg)
         if self._log and self._log.is_enabled then
            local detail_level = radiant and radiant.log and radiant.log.DETAIL or 7
            if not self._log:is_enabled(detail_level) then
               return
            end
         end
         return original_log_state(self, msg)
      end
      mod._perfmod_dbg_logstate = true
      any = true
   end

   if any then
      mod._perfmod_debug_patched = true
   end
   return any
end

local function _patch_find_entity(mod)
   if mod._perfmod_debug_patched then return false end
   local any = false

   if type(mod._set_result) == 'function' and not mod._perfmod_dbg_setresult then
      local original = mod._set_result

      mod._set_result = function(self, item, rating, ...)
         return original(self, item, rating, ...)
      end
   end

   if any then
      mod._perfmod_debug_patched = true
   end
   return any
end

local AI_COMPONENT_TARGETS = {
   'stonehearth_ace.components.ai.ai_component',
   'stonehearth.components.ai.ai_component',
}

local function _patch_ai_component(mod)
   if mod._perfmod_debug_patched then return false end
   local any = false

   if type(mod.set_debug_progress) == 'function' and not mod._perfmod_dbg_progress then
      local original = mod.set_debug_progress

      mod.set_debug_progress = function(self, text)
         if self._perfmod_debug_enabled == nil then
            local has_debug = false
            pcall(function()
               has_debug = radiant.mods and radiant.mods.is_installed
                  and radiant.mods.is_installed('debugtools')
            end)
            self._perfmod_debug_enabled = has_debug
         end

         if self._perfmod_debug_enabled then
            return original(self, text)
         end
      end

      mod._perfmod_dbg_progress = true
      any = true
   end

   if any then
      mod._perfmod_debug_patched = true
   end
   return any
end

function M.apply(service)
   local patched = false

   for _, path in ipairs(AI_TARGETS) do
      local ok, mod = pcall(require, path)
      if ok and type(mod) == 'table' then
         local ok2, result = pcall(_patch_ai_service, mod)
         if ok2 and result then patched = true end
      end
   end

   for _, path in ipairs(TASK_TARGETS) do
      local ok, mod = pcall(require, path)
      if ok and type(mod) == 'table' then
         local ok2, result = pcall(_patch_task_module, mod)
         if ok2 and result then patched = true end
      end
   end

   for _, path in ipairs(AI_COMPONENT_TARGETS) do
      local ok, mod = pcall(require, path)
      if ok and type(mod) == 'table' then
         local ok2, result = pcall(_patch_ai_component, mod)
         if ok2 and result then patched = true end
      end
   end

   return patched
end

return M
