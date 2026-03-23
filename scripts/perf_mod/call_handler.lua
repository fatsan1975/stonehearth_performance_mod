local log = radiant.log.create_logger('perf_mod_call_handler')
local PerfModService = require 'scripts.perf_mod.service'

local PerfModCallHandler = class()

function PerfModCallHandler:get_settings(session, response)
   local settings = PerfModService:get():get_settings()
   response:resolve(settings)
end

function PerfModCallHandler:update_settings(session, response, payload)
   local ok = PerfModService:get():update_settings(payload or {})
   if not ok then
      response:reject({ error = 'invalid_payload' })
      return
   end

   local current = PerfModService:get():get_settings()
   log:info('Updated settings profile=%s runtime=%s preset=%s discovery=%s instrumentation=%s',
      tostring(current.profile),
      tostring(current.runtime_profile),
      tostring(current.performance_preset),
      tostring(current.discovery_enabled),
      tostring(current.instrumentation_enabled)
   )

   response:resolve({
      ok = true,
      settings = current,
      counters = PerfModService:get():get_instrumentation_snapshot()
   })
end

function PerfModCallHandler:set_profile_command(session, response, value)
   PerfModService:get():update_settings({ profile = value })
   response:resolve({ ok = true })
end

function PerfModCallHandler:set_performance_preset_command(session, response, value)
   PerfModService:get():update_settings({ performance_preset = value })
   response:resolve({ ok = true })
end

function PerfModCallHandler:set_instrumentation_command(session, response, value)
   PerfModService:get():update_settings({ instrumentation_enabled = value and true or false })
   response:resolve({ ok = true })
end

function PerfModCallHandler:set_discovery_command(session, response, value)
   PerfModService:get():update_settings({ discovery_enabled = value and true or false })
   response:resolve({ ok = true })
end

function PerfModCallHandler:set_long_ticks_only_command(session, response, value)
   PerfModService:get():update_settings({ long_ticks_only = value and true or false })
   response:resolve({ ok = true })
end

return PerfModCallHandler
