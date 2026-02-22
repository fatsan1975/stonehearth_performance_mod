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

function Settings:initialize(saved_variables)
   self._sv = saved_variables:get_data()
   for key, value in pairs(Config.DEFAULTS) do
      if self._sv[key] == nil then
         self._sv[key] = value
      end
   end

   self._sv.profile = _read_global_config('mods.stonehearth_performance_mod.profile', self._sv.profile)
   self._sv.instrumentation_enabled = _read_global_config('mods.stonehearth_performance_mod.instrumentation_enabled', self._sv.instrumentation_enabled) and true or false
   self._sv.discovery_enabled = _read_global_config('mods.stonehearth_performance_mod.discovery_enabled', self._sv.discovery_enabled) and true or false
   self._sv.long_ticks_only = _read_global_config('mods.stonehearth_performance_mod.long_ticks_only', self._sv.long_ticks_only) and true or false
end

function Settings:get()
   return self._sv
end

function Settings:update(data)
   if type(data) ~= 'table' then
      return false
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

   return true
end

return Settings
