local Coalescer = class()

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
   for context, entry in pairs(self._pending) do
      if now >= entry.due then
         self._pending[context] = nil
         self._instrumentation:inc('perfmod:recompute_calls')
         local ok, err = pcall(entry.fn)
         if not ok then
            self._log:error('Coalesced recompute failed for %s: %s', context, tostring(err))
         end
      end
   end
end

return Coalescer
