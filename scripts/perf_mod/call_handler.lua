-- call_handler.lua
-- UI call handler
--
-- stonehearth_performance_mod global table uzerinden API erisimi.
-- Bu dosya Stonehearth'un functions sistemi tarafindan lazy yuklenir.

local log = radiant.log.create_logger('perf_mod_call_handler')

local PerfModCallHandler = class()

local function _get_mod()
   return stonehearth_performance_mod
end

function PerfModCallHandler:get_settings(session, response)
   local mod = _get_mod()
   if not mod or not mod.get_settings then
      response:resolve({ profile = 'BALANCED', instrumentation_enabled = false })
      return
   end
   response:resolve(mod:get_settings())
end

function PerfModCallHandler:update_settings(session, response, payload)
   local mod = _get_mod()
   if not mod or not mod.update_settings then
      response:reject({ error = 'service_not_available' })
      return
   end

   local ok = mod:update_settings(payload or {})
   if not ok then
      response:reject({ error = 'invalid_payload' })
      return
   end

   response:resolve({
      ok = true,
      settings = mod:get_settings(),
      counters = mod:get_instrumentation_snapshot()
   })
end

function PerfModCallHandler:set_profile_command(session, response, value)
   local mod = _get_mod()
   if mod and mod.update_settings then
      mod:update_settings({ profile = value })
   end
   response:resolve({ ok = true })
end

function PerfModCallHandler:set_instrumentation_command(session, response, value)
   local mod = _get_mod()
   if mod and mod.update_settings then
      mod:update_settings({ instrumentation_enabled = value and true or false })
   end
   response:resolve({ ok = true })
end

function PerfModCallHandler:get_instrumentation_snapshot(session, response)
   local mod = _get_mod()
   if not mod or not mod.get_instrumentation_snapshot then
      response:resolve({})
      return
   end
   response:resolve(mod:get_instrumentation_snapshot())
end

function PerfModCallHandler:dump_instrumentation(session, response)
   local mod = _get_mod()
   if not mod or not mod.dump_instrumentation then
      response:resolve({})
      return
   end
   local snap = mod:dump_instrumentation()
   response:resolve(snap or {})
end

function PerfModCallHandler:reset_counters(session, response)
   local mod = _get_mod()
   if not mod or not mod.reset_counters then
      response:reject({ error = 'service_not_available' })
      return
   end
   mod:reset_counters()
   response:resolve({ ok = true })
end

return PerfModCallHandler
