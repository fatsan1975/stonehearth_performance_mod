local log = radiant.log.create_logger('perf_mod_service')

local Config = require 'scripts.perf_mod.config'
local Settings = require 'scripts.perf_mod.settings'
local Clock = require 'scripts.perf_mod.clock'
local MicroCache = require 'scripts.perf_mod.micro_cache'
local Coalescer = require 'scripts.perf_mod.coalescer'
local Instrumentation = require 'scripts.perf_mod.instrumentation'
local QueryOptimizer = require 'scripts.perf_mod.query_optimizer'
local PatchDiscovery = require 'scripts.perf_mod.patch_discovery'

local PerfModService = class()

local _instance = nil

local function _fallback_saved_variables()
   local data = {}
   return {
      get_data = function()
         return data
      end
   }
end

function PerfModService:get()
   if not _instance then
      _instance = PerfModService()
   end
   return _instance
end

function PerfModService:initialize()
   self._sv = self.__saved_variables or _fallback_saved_variables()
   self._settings = Settings()
   self._settings:initialize(self._sv)

   self._clock = Clock()
   self._instrumentation = Instrumentation()
   self._instrumentation:initialize(log)
   self._instrumentation:set_enabled(self._settings:get().instrumentation_enabled)

   self._cache = MicroCache()
   self._cache:initialize(self._clock)

   self._coalescer = Coalescer()
   self._coalescer:initialize(self._clock, log, self._instrumentation)

   self._optimizer = QueryOptimizer()
   self._optimizer:initialize(self._clock, self._cache, self._coalescer, self._instrumentation, self, log)

   self._discovery = PatchDiscovery()
   self._discovery:initialize(self._optimizer, self, self._instrumentation, log)

   self:_detect_ace()
   self:_apply_known_patches()
   self:_wire_best_effort_inventory_events()
   self:_run_discovery_if_enabled()
   self:_start_heartbeat()
end

function PerfModService:_wire_best_effort_inventory_events()
   self._listeners = self._listeners or {}
   local ok, err = pcall(function()
      if stonehearth and stonehearth.inventory and stonehearth.inventory.get_inventory then
         local inventory = stonehearth.inventory:get_inventory()
         if inventory and radiant and radiant.events and radiant.events.listen then
            self._listeners.inventory_changed = radiant.events.listen(inventory, 'stonehearth:inventory:changed', function()
               self._optimizer:mark_inventory_dirty('inventory')
               self._optimizer:mark_inventory_dirty('storage')
            end)
         end
      end
   end)

   if not ok then
      log:debug('Best-effort inventory listener unavailable: %s', tostring(err))
   end
end

function PerfModService:_start_heartbeat()
   if stonehearth and stonehearth.calendar and stonehearth.calendar.set_interval then
      self._heartbeat = stonehearth.calendar:set_interval('perf_mod_pump', '50ms', function()
         self._coalescer:pump()
         self._instrumentation:publish_if_available()
      end)
      return
   end

   if radiant and radiant.on_game_loop then
      self._heartbeat = radiant.on_game_loop('perf_mod_pump', function()
         self._coalescer:pump()
         self._instrumentation:publish_if_available()
      end)
      return
   end

   log:warning('No heartbeat scheduler available; coalescer/perf publishing will run only on query access')
end

function PerfModService:_detect_ace()
   self._ace_present = false
   if radiant and radiant.mods and radiant.mods.is_installed then
      self._ace_present = radiant.mods.is_installed('stonehearth_ace')
   end

   log:info('ACE present: %s', tostring(self._ace_present))
end

function PerfModService:_apply_known_patches()
   local candidates = {
      'monkey_patches.storage_service_patch',
      'monkey_patches.inventory_service_patch',
      'monkey_patches.filter_cache_patch'
   }

   self._applied_patch_points = {}
   for _, path in ipairs(candidates) do
      local ok, patch_module = pcall(require, path)
      if ok and patch_module and patch_module.apply then
         local applied = patch_module.apply(self)
         if applied then
            self._applied_patch_points[#self._applied_patch_points + 1] = path
            log:info('Applied known patch: %s', path)
         end
      end
   end
end

function PerfModService:_run_discovery_if_enabled()
   if not self._settings:get().discovery_enabled then
      return
   end

   self._discovery:run()
end

function PerfModService:get_profile_data()
   return Config.get_profile(self._settings:get().profile)
end

function PerfModService:get_settings()
   return self._settings:get()
end

function PerfModService:update_settings(data)
   if self._settings:update(data) then
      self._instrumentation:set_enabled(self._settings:get().instrumentation_enabled)
      if data.discovery_enabled then
         self:_run_discovery_if_enabled()
      end
      return true
   end

   return false
end

function PerfModService:get_optimizer()
   return self._optimizer
end

function PerfModService:get_discovery()
   return self._discovery
end

function PerfModService:get_instrumentation_snapshot()
   return self._instrumentation:get_snapshot()
end

return PerfModService
