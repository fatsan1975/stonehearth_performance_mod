local Config = {}

Config.PROFILES = {
   SAFE = {
      id = 'SAFE',
      cache_ttl = 0.25,
      negative_ttl = 0.35,
      coalesce_ms = 0,
      incremental_budget_ms = 0.75,
      query_deadline_ms = 10,
      deferred_wait_ms = 0,
      max_candidates_to_hook = 1
   },
   BALANCED = {
      id = 'BALANCED',
      cache_ttl = 0.55,
      negative_ttl = 0.8,
      coalesce_ms = 75,
      incremental_budget_ms = 1.8,
      query_deadline_ms = 15,
      deferred_wait_ms = 75,
      max_candidates_to_hook = 3
   },
   AGGRESSIVE = {
      id = 'AGGRESSIVE',
      cache_ttl = 1.2,
      negative_ttl = 1.8,
      coalesce_ms = 150,
      incremental_budget_ms = 3.2,
      query_deadline_ms = 24,
      deferred_wait_ms = 150,
      max_candidates_to_hook = 5
   }
}

Config.DEFAULTS = {
   profile = 'SAFE',
   instrumentation_enabled = false,
   discovery_enabled = false,
   long_ticks_only = true
}

function Config.get_profile(profile_name)
   return Config.PROFILES[profile_name] or Config.PROFILES[Config.DEFAULTS.profile]
end

return Config
