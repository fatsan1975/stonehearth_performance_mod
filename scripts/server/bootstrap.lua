local log = radiant.log.create_logger('perf_mod_bootstrap')

local PerfModService = require 'scripts.perf_mod.service'

local _initialized = false

local function _start()
   if _initialized then
      return
   end

   _initialized = true
   local ok, err = pcall(function()
      PerfModService:get():initialize()
   end)

   if not ok then
      log:error('Failed to initialize performance mod: %s', tostring(err))
   else
      log:info('Stonehearth Performance Mod initialized')
   end
end

radiant.events.listen_once(radiant, 'radiant:init', _start)

return {
   start = _start
}
