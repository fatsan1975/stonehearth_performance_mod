local Instrumentation = class()

local COUNTER_NAMES = {
   'perfmod:cache_hits',
   'perfmod:cache_misses',
   'perfmod:negative_hits',
   'perfmod:recomputes_coalesced',
   'perfmod:recompute_calls',
   'perfmod:incremental_scan_steps',
   'perfmod:full_scan_fallbacks',
   'perfmod:deadline_fallbacks',
   'perfmod:avg_query_ms',
   'perfmod:long_ticks',
   'perfmod:admission_skips',
   'perfmod:oversized_skips',
   'perfmod:dirty_negative_bypasses',
   'perfmod:urgent_bypasses',
   'perfmod:key_bypass_complex',
   'perfmod:negative_cache_skips',
   'perfmod:safety_fallbacks',
   'perfmod:circuit_open_bypasses'
}

function Instrumentation:initialize(log)
   self._log = log
   self._enabled = false
   self._counters = {}
   self._rolling_samples = 0
   self._rolling_avg = 0
   for _, name in ipairs(COUNTER_NAMES) do
      self._counters[name] = 0
   end
end

function Instrumentation:set_enabled(enabled)
   self._enabled = enabled and true or false
end

function Instrumentation:inc(name, amount)
   if not self._enabled then
      return
   end

   self._counters[name] = (self._counters[name] or 0) + (amount or 1)
end

function Instrumentation:observe_query_time(ms)
   if not self._enabled then
      return
   end

   self._rolling_samples = self._rolling_samples + 1
   self._rolling_avg = self._rolling_avg + (ms - self._rolling_avg) / self._rolling_samples
   self._counters['perfmod:avg_query_ms'] = self._rolling_avg
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
