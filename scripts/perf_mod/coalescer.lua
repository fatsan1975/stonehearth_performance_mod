local Coalescer = class()

local DEFAULT_MAX_CALLBACKS_PER_PUMP = 6
local DEFAULT_MAX_PUMP_BUDGET_MS = 1.2

function Coalescer:initialize(clock, log, instrumentation)
   self._clock = clock
   self._log = log
   self._instrumentation = instrumentation
   self._pending = {}
   self._max_callbacks_per_pump = DEFAULT_MAX_CALLBACKS_PER_PUMP
   self._max_pump_budget_ms = DEFAULT_MAX_PUMP_BUDGET_MS
end

function Coalescer:set_budget(max_callbacks, budget_ms)
   if type(max_callbacks) == 'number' and max_callbacks > 0 then
      self._max_callbacks_per_pump = max_callbacks
   end
   if type(budget_ms) == 'number' and budget_ms > 0 then
      self._max_pump_budget_ms = budget_ms
   end
end

function Coalescer:mark_dirty(context, fn, coalesce_ms)
   local now = self._clock:get_realtime_seconds()
   local entry = self._pending[context]
   if entry then
      entry.fn = fn
      self._instrumentation:inc('perfmod:recomputes_coalesced')
      return false
   end

   self._pending[context] = {
      fn = fn,
      due = now + ((coalesce_ms or 0) / 1000)
   }

   return true
end

function Coalescer:pump()
   local now = self._clock:get_realtime_seconds()
   local started = now
   local ran = 0

   for context, entry in pairs(self._pending) do
      if now >= entry.due then
         self._pending[context] = nil
         self._instrumentation:inc('perfmod:recompute_calls')
         local ok, err = pcall(entry.fn)
         if not ok then
            self._log:error('Coalesced recompute failed for %s: %s', context, tostring(err))
         end

         ran = ran + 1
         if ran >= self._max_callbacks_per_pump then
            self._instrumentation:inc('perfmod:pump_budget_breaks')
            return
         end
         if self._clock:get_elapsed_ms(started) >= self._max_pump_budget_ms then
            self._instrumentation:inc('perfmod:pump_budget_breaks')
            return
         end
      end
   end
end

return Coalescer
