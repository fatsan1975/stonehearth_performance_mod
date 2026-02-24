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

   self._runtime_profile_name = nil
   self._warm_resume_until = 0
   self._last_pump_at = self._clock:get_realtime_seconds()
   self._last_health_snapshot = {
      ['perfmod:deadline_fallbacks'] = 0,
      ['perfmod:safety_fallbacks'] = 0,
      ['perfmod:circuit_open_bypasses'] = 0,
      ['perfmod:long_ticks'] = 0
   }

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

function PerfModService:_on_heartbeat_tick()
   local now = self._clock:get_realtime_seconds()
   local stall_s = now - (self._last_pump_at or now)
   self._last_pump_at = now

   if stall_s >= 4 then
      self._warm_resume_until = now + (self._settings:get().warm_resume_guard_s or 0)
      self._instrumentation:inc('perfmod:warm_resume_guards')
   end

   local profile = self:get_profile_data()
   self._coalescer:set_budget(profile.max_callbacks_per_pump, profile.max_pump_budget_ms)
   self._coalescer:pump()
   self._instrumentation:publish_if_available()
   self:_recompute_health_and_runtime_profile(now)
end

function PerfModService:_recompute_health_and_runtime_profile(now)
   local snapshot = self._instrumentation:get_snapshot()
   local deadlines = (snapshot['perfmod:deadline_fallbacks'] or 0) - (self._last_health_snapshot['perfmod:deadline_fallbacks'] or 0)
   local safety = (snapshot['perfmod:safety_fallbacks'] or 0) - (self._last_health_snapshot['perfmod:safety_fallbacks'] or 0)
   local circuits = (snapshot['perfmod:circuit_open_bypasses'] or 0) - (self._last_health_snapshot['perfmod:circuit_open_bypasses'] or 0)
   local long_ticks = (snapshot['perfmod:long_ticks'] or 0) - (self._last_health_snapshot['perfmod:long_ticks'] or 0)

   local health = math.max(0, 100 - (deadlines * 3) - (safety * 15) - (circuits * 8) - (long_ticks * 5))
   self._instrumentation:set_health_score(health)

   self._last_health_snapshot = {
      ['perfmod:deadline_fallbacks'] = snapshot['perfmod:deadline_fallbacks'] or 0,
      ['perfmod:safety_fallbacks'] = snapshot['perfmod:safety_fallbacks'] or 0,
      ['perfmod:circuit_open_bypasses'] = snapshot['perfmod:circuit_open_bypasses'] or 0,
      ['perfmod:long_ticks'] = snapshot['perfmod:long_ticks'] or 0
   }

   local base_profile = self._settings:get().profile
   self._runtime_profile_name = nil
   if self._settings:get().auto_profile_downshift and base_profile == 'AGGRESSIVE' and (health < 75 or safety > 0 or circuits > 0) then
      self._runtime_profile_name = 'BALANCED'
      self._instrumentation:inc('perfmod:auto_profile_downshifts')
   elseif self._settings:get().auto_profile_downshift and base_profile ~= 'SAFE' and (health < 60 or long_ticks > 1) then
      self._runtime_profile_name = 'SAFE'
      self._instrumentation:inc('perfmod:auto_profile_downshifts')
   end
end

function PerfModService:_start_heartbeat()
   if stonehearth and stonehearth.calendar and stonehearth.calendar.set_interval then
      self._heartbeat = stonehearth.calendar:set_interval('perf_mod_pump', '50ms', function()
         self:_on_heartbeat_tick()
      end)
      return
   end

   if radiant and radiant.on_game_loop then
      self._heartbeat = radiant.on_game_loop('perf_mod_pump', function()
         self:_on_heartbeat_tick()
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
   local runtime_name = self._runtime_profile_name or self._settings:get().profile
   return Config.get_profile(runtime_name)
end

function PerfModService:get_settings()
   local view = self._settings:get()
   view.runtime_profile = self._runtime_profile_name or view.profile
   return view
end

function PerfModService:update_settings(data)
   if self._settings:update(data) then
      self._runtime_profile_name = nil
      self._instrumentation:set_enabled(self._settings:get().instrumentation_enabled)
      if data.discovery_enabled then
         self:_run_discovery_if_enabled()
      end
      return true
   end

   return false
end

function PerfModService:is_context_cache_enabled(context)
   return self._settings:is_context_enabled(context)
end

function PerfModService:is_warm_resume_guard_active()
   return self._clock:get_realtime_seconds() < (self._warm_resume_until or 0)
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
