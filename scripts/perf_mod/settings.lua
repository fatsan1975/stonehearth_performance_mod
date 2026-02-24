local Config = require 'scripts.perf_mod.config'

local Settings = class()

local function _read_global_config(path, default)
   if radiant and radiant.util and radiant.util.get_global_config then
      local v = radiant.util.get_global_config(path, nil)
      if v ~= nil then
         return v
      end
   end
   return default
end

local function _clone_context_map(map)
   return {
      inventory = map and map.inventory and true or false,
      storage = map and map.storage and true or false,
      filter = map and map.filter and true or false
   }
end

function Settings:initialize(saved_variables)
   self._sv = saved_variables:get_data()
   for key, value in pairs(Config.DEFAULTS) do
      if self._sv[key] == nil then
         if key == 'context_cache_enabled' then
            self._sv[key] = _clone_context_map(value)
         else
            self._sv[key] = value
         end
      end
   end

   self._sv.profile = _read_global_config('mods.stonehearth_performance_mod.profile', self._sv.profile)
   self._sv.performance_preset = _read_global_config('mods.stonehearth_performance_mod.performance_preset', self._sv.performance_preset)
   self._sv.instrumentation_enabled = _read_global_config('mods.stonehearth_performance_mod.instrumentation_enabled', self._sv.instrumentation_enabled) and true or false
   self._sv.discovery_enabled = _read_global_config('mods.stonehearth_performance_mod.discovery_enabled', self._sv.discovery_enabled) and true or false
   self._sv.long_ticks_only = _read_global_config('mods.stonehearth_performance_mod.long_ticks_only', self._sv.long_ticks_only) and true or false
   self._sv.auto_profile_downshift = _read_global_config('mods.stonehearth_performance_mod.auto_profile_downshift', self._sv.auto_profile_downshift) and true or false
   self._sv.warm_resume_guard_s = tonumber(_read_global_config('mods.stonehearth_performance_mod.warm_resume_guard_s', self._sv.warm_resume_guard_s)) or Config.DEFAULTS.warm_resume_guard_s

   self._sv.context_cache_enabled = _clone_context_map(self._sv.context_cache_enabled)
end

function Settings:get()
   return self._sv
end

function Settings:is_context_enabled(context)
   if not context then
      return true
   end

   local map = self._sv.context_cache_enabled or Config.DEFAULTS.context_cache_enabled
   if map[context] == nil then
      return true
   end

   return map[context] and true or false
end

function Settings:get_preset_data()
   return Config.PRESETS[self._sv.performance_preset]
end

function Settings:update(data)
   if type(data) ~= 'table' then
      return false
   end

   if data.performance_preset and Config.PRESETS[data.performance_preset] then
      self._sv.performance_preset = data.performance_preset
      local preset = Config.PRESETS[data.performance_preset]
      self._sv.profile = preset.profile
      self._sv.auto_profile_downshift = preset.auto_profile_downshift and true or false
      self._sv.context_cache_enabled = _clone_context_map(preset.context_cache_enabled)
   end

   if data.profile and Config.PROFILES[data.profile] then
      self._sv.profile = data.profile
   end

   if data.instrumentation_enabled ~= nil then
      self._sv.instrumentation_enabled = data.instrumentation_enabled and true or false
   end

   if data.discovery_enabled ~= nil then
      self._sv.discovery_enabled = data.discovery_enabled and true or false
   end

   if data.long_ticks_only ~= nil then
      self._sv.long_ticks_only = data.long_ticks_only and true or false
   end

   if data.auto_profile_downshift ~= nil then
      self._sv.auto_profile_downshift = data.auto_profile_downshift and true or false
   end

   if data.warm_resume_guard_s ~= nil then
      local value = tonumber(data.warm_resume_guard_s)
      if value and value >= 0 then
         self._sv.warm_resume_guard_s = value
      end
   end

   if type(data.context_cache_enabled) == 'table' then
      self._sv.context_cache_enabled = _clone_context_map(data.context_cache_enabled)
   end

   return true
end

return Settings
