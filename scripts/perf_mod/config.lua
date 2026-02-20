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
      max_candidates_to_hook = 1,
      max_cache_entries = 1200,
      max_cached_result_size = 96,
      admit_after_hits = 1,
      urgent_cache_bypass = false
   },
   BALANCED = {
      id = 'BALANCED',
      cache_ttl = 0.45,
      negative_ttl = 0.65,
      coalesce_ms = 60,
      incremental_budget_ms = 1.5,
      query_deadline_ms = 14,
      deferred_wait_ms = 60,
      max_candidates_to_hook = 2,
      max_cache_entries = 2200,
      max_cached_result_size = 128,
      admit_after_hits = 2,
      urgent_cache_bypass = true
   },
   AGGRESSIVE = {
      id = 'AGGRESSIVE',
      cache_ttl = 0.75,
      negative_ttl = 1.0,
      coalesce_ms = 90,
      incremental_budget_ms = 2.5,
      query_deadline_ms = 18,
      deferred_wait_ms = 80,
      max_candidates_to_hook = 2,
      max_cache_entries = 3200,
      max_cached_result_size = 160,
      admit_after_hits = 2,
      urgent_cache_bypass = true
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
