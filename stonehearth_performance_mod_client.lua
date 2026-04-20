-- stonehearth_performance_mod_client.lua
-- Client init ? UI resources are loaded through manifest.ui

stonehearth_performance_mod_client = {}

local log = radiant.log.create_logger('perf_mod_client')

function stonehearth_performance_mod_client:_on_init()
   log:always('perf_mod: client initialized')
end

radiant.events.listen(stonehearth_performance_mod_client, 'radiant:init', stonehearth_performance_mod_client, stonehearth_performance_mod_client._on_init)

return stonehearth_performance_mod_client
