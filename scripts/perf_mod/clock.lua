local Clock = class()

function Clock:get_realtime_seconds()
   if radiant and radiant.util and radiant.util.get_realtime_in_seconds then
      return radiant.util.get_realtime_in_seconds()
   end

   if stonehearth and stonehearth.calendar and stonehearth.calendar.get_elapsed_time then
      return stonehearth.calendar:get_elapsed_time()
   end

   return os.clock()
end

function Clock:get_elapsed_ms(start_time)
   return (self:get_realtime_seconds() - start_time) * 1000
end

return Clock
