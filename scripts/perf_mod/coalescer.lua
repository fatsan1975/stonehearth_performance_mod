local Coalescer = class()

local MAX_CALLBACKS_PER_PUMP = 8
local MAX_PUMP_BUDGET_MS = 1.5

function Coalescer:initialize(clock, log, instrumentation)
   self._clock = clock
   self._log = log
   self._instrumentation = instrumentation
   self._pending = {}
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
      due = now + (coalesce_ms / 1000)
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
         if ran >= MAX_CALLBACKS_PER_PUMP then
            return
         end
         if self._clock:get_elapsed_ms(started) >= MAX_PUMP_BUDGET_MS then
            return
         end
      end
   end
end

return Coalescer
