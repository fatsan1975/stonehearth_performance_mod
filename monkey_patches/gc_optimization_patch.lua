-- gc_optimization_patch.lua
-- Lua Garbage Collection iyileştirmeleri.

local M = {}

local GC_PROFILES = {
   SAFE = {
      gc_pause = 120,
      gc_stepsize = 80,
      heartbeat_step = 0,
      post_spike_steps = 1,
      spike_threshold_ms = 80,
   },
   BALANCED = {
      gc_pause = 110,
      gc_stepsize = 100,
      heartbeat_step = 0,
      post_spike_steps = 2,
      spike_threshold_ms = 60,
   },
   AGGRESSIVE = {
      gc_pause = 105,
      gc_stepsize = 120,
      heartbeat_step = 0,
      post_spike_steps = 3,
      spike_threshold_ms = 50,
   }
}

local function _patch_object_tracker()
   local ok, result = pcall(function()
      local tracker = nil
      for name, mod in pairs(package.loaded) do
         if type(name) == 'string' and name:find('object_tracker') then
            if type(mod) == 'table' and type(mod.get_count) == 'function' then
               tracker = mod
               break
            end
         end
      end

      if not tracker then return false end
      if tracker._perfmod_gc_patched then return false end

      local original_get_count = tracker.get_count
      tracker.get_count = function(category)
         pcall(collectgarbage, 'step', 5)
         return original_get_count(category)
      end

      tracker._perfmod_gc_patched = true
      return true
   end)

   return ok and result
end

local _last_frame_ms = 0
local _consecutive_spikes = 0
local _was_spiking = false

function M.get_adaptive_step_size(frame_ms, profile_name)
   local profile = GC_PROFILES[profile_name] or GC_PROFILES.SAFE
   _last_frame_ms = frame_ms

   if frame_ms > profile.spike_threshold_ms then
      _consecutive_spikes = _consecutive_spikes + 1
      _was_spiking = true
      return -1
   end

   _consecutive_spikes = 0

   if frame_ms < 20 then
      return 2
   elseif frame_ms < 40 then
      return 1
   else
      return 0
   end
end

function M.should_post_spike_boost(profile_name)
   if not _was_spiking then
      return false, 0
   end

   if _consecutive_spikes > 0 then
      return false, 0
   end

   _was_spiking = false
   local profile = GC_PROFILES[profile_name] or GC_PROFILES.SAFE
   local steps = profile.post_spike_steps
   return steps > 0, steps
end

function M.apply_gc_params(profile_name)
   local profile = GC_PROFILES[profile_name] or GC_PROFILES.SAFE
   pcall(collectgarbage, 'setpause', profile.gc_pause)
   pcall(collectgarbage, 'setstepsize', profile.gc_stepsize)
end

function M.apply(service)
   local patched = false

   local ok1 = pcall(_patch_object_tracker)
   if ok1 then patched = true end

   local profile_name = 'SAFE'
   pcall(function()
      profile_name = service:get_settings().profile or 'SAFE'
   end)
   M.apply_gc_params(profile_name)

   return patched
end

M._instrumentation = nil

function M.set_instrumentation(inst)
   M._instrumentation = inst
end

function M.adaptive_gc_step(clock, profile_name)
   local now = clock:get_realtime_seconds()

   local frame_ms = clock:get_elapsed_ms(M._last_heartbeat or now)
   M._last_heartbeat = now

   local step_size = M.get_adaptive_step_size(frame_ms, profile_name)
   local inst = M._instrumentation

   if step_size >= 0 then
      pcall(collectgarbage, 'step', step_size)
      if inst then inst:inc('perfmod:gc_adaptive_steps') end
   else
      if inst then inst:inc('perfmod:gc_spike_skips') end
   end

   local should_boost, boost_steps = M.should_post_spike_boost(profile_name)
   if should_boost and boost_steps > 0 then
      for _ = 1, boost_steps do
         pcall(collectgarbage, 'step', 1)
      end
      if inst then inst:inc('perfmod:gc_post_spike_boosts') end
   end
end

return M
