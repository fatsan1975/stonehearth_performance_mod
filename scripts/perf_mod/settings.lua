local Config = require 'scripts.perf_mod.config'

local Settings = class()

function Settings:initialize(saved_variables)
   self._sv = saved_variables:get_data()
   for key, value in pairs(Config.DEFAULTS) do
      if self._sv[key] == nil then
         self._sv[key] = value
      end
   end
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
