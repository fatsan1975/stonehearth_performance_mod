-- config.lua
-- Performance Mod konfig?rasyonu ? sadele?tirilmi? versiyon
--
-- Eski mod: 3 profil ? 30+ parametre = karma??k ama etkisiz
-- Yeni mod: 3 profil ? patch toggle + birka? ayarlanabilir parametre

local Config = {}

Config.PROFILES = {
   SAFE = {
      id = 'SAFE',
      -- Patch toggle'lar?
      reconsider_alloc = true,    -- PATCH 1: allocation eliminasyonu
      filter_fast_reject = true,  -- PATCH 2: URI negatif cache
      reconsider_limiter = true,  -- PATCH 3: cascade dedup
      reconsider_spread = true,   -- PATCH 4: entity spread (PATCH 1 i?inde)
      gc_tuning = true,           -- GC parametreleri

      -- Ayarlanabilir parametreler
      max_reconsider_per_tick = 80,    -- PATCH 4: tick ba??na max entity
      reject_flush_interval = 400,     -- PATCH 2: reject cache flush (tick)

      -- GC parametreleri
      gc_pause = 120,
      gc_stepsize = 80,
      post_spike_steps = 1,
      spike_threshold_ms = 80,
   },
   BALANCED = {
      id = 'BALANCED',
      reconsider_alloc = true,
      filter_fast_reject = true,
      reconsider_limiter = true,
      reconsider_spread = true,
      gc_tuning = true,

      max_reconsider_per_tick = 64,
      reject_flush_interval = 300,

      gc_pause = 110,
      gc_stepsize = 100,
      post_spike_steps = 2,
      spike_threshold_ms = 60,
   },
   AGGRESSIVE = {
      id = 'AGGRESSIVE',
      reconsider_alloc = true,
      filter_fast_reject = true,
      reconsider_limiter = true,
      reconsider_spread = true,
      gc_tuning = true,

      max_reconsider_per_tick = 48,
      reject_flush_interval = 200,

      gc_pause = 105,
      gc_stepsize = 120,
      post_spike_steps = 3,
      spike_threshold_ms = 50,
   }
}

Config.DEFAULTS = {
   profile = 'BALANCED',
   gc_enabled = true,
   instrumentation_enabled = false,
}

function Config.get_profile(profile_name)
   return Config.PROFILES[profile_name] or Config.PROFILES[Config.DEFAULTS.profile]
end

return Config
