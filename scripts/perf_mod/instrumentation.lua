-- instrumentation.lua
-- Performans sayaçları — sadeleştirilmiş versiyon
--
-- Eski mod: 60+ counter → çoğu artık silinen modüllere ait
-- Yeni mod: Sadece aktif patch'lerin sayaçları

local Instrumentation = class()

local COUNTER_NAMES = {
   -- PATCH 1+4: Reconsider allocation + entity spread
   'perfmod:reconsider_alloc_ticks',      -- patched tick sayısı
   'perfmod:reconsider_spread_ticks',     -- overflow olan tick sayısı
   'perfmod:reconsider_spread_defers',    -- ertelenen entity sayısı

   -- PATCH 2: Filter URI fast-reject
   'perfmod:uri_reject_hits',             -- URI reject cache hit'leri
   'perfmod:uri_reject_caches',           -- yeni URI reject cache entry'leri

   -- PATCH 3: Reconsider limiter
   'perfmod:reconsider_dedup_hits',       -- tick-level dedup ile engellenen çağrılar

   -- GC
   'perfmod:gc_adaptive_steps',
   'perfmod:gc_spike_skips',
   'perfmod:gc_post_spike_boosts',

   -- Genel
   'perfmod:health_score',
   'perfmod:heavy_heartbeats',
}

function Instrumentation:initialize(log)
   self._log = log
   self._enabled = false
   self._counters = {}
   for _, name in ipairs(COUNTER_NAMES) do
      self._counters[name] = 0
   end
end

function Instrumentation:set_enabled(enabled)
   self._enabled = enabled and true or false
end

function Instrumentation:set(name, value)
   self._counters[name] = value or 0
end

function Instrumentation:inc(name, amount)
   if not self._enabled then
      return
   end
   self._counters[name] = (self._counters[name] or 0) + (amount or 1)
end

function Instrumentation:get_snapshot()
   local snapshot = {}
   for name, value in pairs(self._counters) do
      snapshot[name] = value
   end
   return snapshot
end

function Instrumentation:publish_if_available()
   if not self._enabled then
      return
   end

   if stonehearth and stonehearth.perf_mon and stonehearth.perf_mon.set_counter then
      for name, value in pairs(self._counters) do
         stonehearth.perf_mon:set_counter(name, value)
      end
   end
end

return Instrumentation
