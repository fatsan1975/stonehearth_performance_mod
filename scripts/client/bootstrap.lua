local log = radiant.log.create_logger('perf_mod_client_bootstrap')

local ok, err = pcall(function()
   -- UI resources are loaded through manifest.ui; this bootstrap intentionally stays lightweight.
end)

if not ok then
   log:error('Client bootstrap failed: %s', tostring(err))
end

return true
