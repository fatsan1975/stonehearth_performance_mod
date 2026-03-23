local Config = {}

Config.PROFILES = {
   SAFE = {
      id = 'SAFE',
      cache_ttl = 0.20,
      negative_ttl = 0.30,
      coalesce_ms = 0,
      incremental_budget_ms = 0.5,
      query_deadline_ms = 8,
      deferred_wait_ms = 0,
      max_candidates_to_hook = 1,
      max_cache_entries = 1000,
      max_cached_result_size = 72,
      admit_after_hits = 2,
      urgent_cache_bypass = true,
      ai_path_cache_bypass = true,
      cache_negative_results = false,
      circuit_failures = 3,
      circuit_window_s = 10,
      circuit_open_s = 30,
      max_callbacks_per_pump = 4,
      max_pump_budget_ms = 0.8,
      noisy_signature_limit = 4,
      filter_ttl_mult = 1.4,
      -- Filter context negatif sonuç cache (çok kısa TTL — generation birincil guard)
      cache_negative_filter = true,
      negative_filter_ttl = 0.08,
      -- Filter context için immediate admission (en tekrarlı context)
      admit_after_hits_filter = 1
   },
   BALANCED = {
      id = 'BALANCED',
      cache_ttl = 0.35,
      negative_ttl = 0.50,
      coalesce_ms = 45,
      incremental_budget_ms = 1.0,
      query_deadline_ms = 12,
      deferred_wait_ms = 40,
      max_candidates_to_hook = 1,
      max_cache_entries = 1800,
      max_cached_result_size = 96,
      admit_after_hits = 2,
      urgent_cache_bypass = true,
      ai_path_cache_bypass = true,
      cache_negative_results = false,
      circuit_failures = 3,
      circuit_window_s = 10,
      circuit_open_s = 30,
      max_callbacks_per_pump = 6,
      max_pump_budget_ms = 1.2,
      noisy_signature_limit = 5,
      filter_ttl_mult = 1.4,
      cache_negative_filter = true,
      negative_filter_ttl = 0.12,
      admit_after_hits_filter = 1
   },
   AGGRESSIVE = {
      id = 'AGGRESSIVE',
      cache_ttl = 0.55,
      negative_ttl = 0.75,
      coalesce_ms = 70,
      incremental_budget_ms = 1.8,
      query_deadline_ms = 15,
      deferred_wait_ms = 65,
      max_candidates_to_hook = 1,
      max_cache_entries = 2600,
      max_cached_result_size = 128,
      admit_after_hits = 2,
      urgent_cache_bypass = true,
      ai_path_cache_bypass = true,
      cache_negative_results = false,
      circuit_failures = 3,
      circuit_window_s = 10,
      circuit_open_s = 25,
      max_callbacks_per_pump = 8,
      max_pump_budget_ms = 1.5,
      noisy_signature_limit = 6,
      filter_ttl_mult = 1.4,
      cache_negative_filter = true,
      negative_filter_ttl = 0.15,
      admit_after_hits_filter = 1
   }
}

Config.DEFAULTS = {
   profile = 'SAFE',
   -- GC yönetimi: spike'ları küçük adımlara yay (false ile devre dışı bırakılabilir)
   gc_enabled = true,
   gc_pause = 110,
   gc_stepsize = 100,
   performance_preset = 'MULTIPLAYER_SAFE',
   instrumentation_enabled = false,
   discovery_enabled = false,
   long_ticks_only = true,
   auto_profile_downshift = true,
   warm_resume_guard_s = 8,
   health_ema_alpha = 0.05,
   health_upshift_min_s = 20,
   context_cache_enabled = {
      inventory = false,
      storage = true,
      filter = true
   }
}

Config.PRESETS = {
   MULTIPLAYER_SAFE = {
      profile = 'SAFE',
      auto_profile_downshift = true,
      context_cache_enabled = { inventory = false, storage = true, filter = true }
   },
   MEGA_TOWN_STABILITY = {
      profile = 'SAFE',
      auto_profile_downshift = true,
      context_cache_enabled = { inventory = false, storage = true, filter = false }
   },
   SINGLEPLAYER_THROUGHPUT = {
      profile = 'BALANCED',
      auto_profile_downshift = true,
      context_cache_enabled = { inventory = false, storage = true, filter = true }
   }
}

function Config.get_profile(profile_name)
   return Config.PROFILES[profile_name] or Config.PROFILES[Config.DEFAULTS.profile]
end

return Config
