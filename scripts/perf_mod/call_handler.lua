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

   log:info('Updated settings profile=%s discovery=%s instrumentation=%s',
      tostring(PerfModService:get():get_settings().profile),
      tostring(PerfModService:get():get_settings().discovery_enabled),
      tostring(PerfModService:get():get_settings().instrumentation_enabled)
   )

   response:resolve({
      ok = true,
      settings = PerfModService:get():get_settings(),
      counters = PerfModService:get():get_instrumentation_snapshot()
   })
end

return PerfModCallHandler
