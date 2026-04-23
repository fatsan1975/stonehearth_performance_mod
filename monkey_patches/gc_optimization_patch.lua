-- gc_optimization_patch.lua
-- GC tuning — sadeleştirilmiş versiyon
--
-- Hedefler:
--   1) object_tracker.lua'daki collectgarbage() → incremental step'e çevir
--   2) Adaptif GC step: frame yüküne göre boyut ayarla
--   3) Post-spike boost: uzun tick sonrası ekstra GC
--   4) Profil bazlı GC parametreleri
--
-- NOT: Bu patch allocation AZALDIKTAN SONRA etkili olur.
--   PATCH 1-3 allocation'ı düşürür → GC tuning daha az iş yapar → kazanç.

local log = radiant.log.create_logger('perf_mod:gc')

local M = {}

local _patched = false
local _instrumentation = nil

-- Frame timing
local _last_heartbeat = nil
local _was_spiking = false
local _consecutive_spikes = 0

-- ─── Object Tracker collectgarbage() Throttle ────────────────────────────
local function _patch_object_tracker()
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
   local real_collectgarbage = collectgarbage

   tracker.get_count = function(category)
      local saved = collectgarbage
      collectgarbage = function(cmd, ...)
         if cmd == nil or cmd == 'collect' then
            return real_collectgarbage('step', 5)
         end
         return real_collectgarbage(cmd, ...)
      end
      local success, ret = pcall(original_get_count, category)
      collectgarbage = saved
      if success then return ret end
      error(ret)
   end

   tracker._perfmod_gc_patched = true
   return true
end

-- ─── Adaptif GC Step ─────────────────────────────────────────────────────
function M.adaptive_gc_step(profile)
   local now = os.clock()
   local frame_ms = 0

   if _last_heartbeat then
      frame_ms = (now - _last_heartbeat) * 1000
   end
   _last_heartbeat = now

   local spike_threshold = profile.spike_threshold_ms or 80

   if frame_ms > spike_threshold then
      _consecutive_spikes = _consecutive_spikes + 1
      _was_spiking = true
      if _instrumentation then _instrumentation:inc('perfmod:gc_spike_skips') end
      return  -- CPU zaten yoğun, GC step yapma
   end

   -- Normal frame: GC step yap
   _consecutive_spikes = 0
   local step_size = 0
   if frame_ms < 20 then
      step_size = 2
   elseif frame_ms < 40 then
      step_size = 1
   end

   pcall(collectgarbage, 'step', step_size)
   if _instrumentation then _instrumentation:inc('perfmod:gc_adaptive_steps') end

   -- Post-spike boost
   if _was_spiking then
      _was_spiking = false
      local boost_steps = profile.post_spike_steps or 1
      for _ = 1, boost_steps do
         pcall(collectgarbage, 'step', 1)
      end
      if _instrumentation then _instrumentation:inc('perfmod:gc_post_spike_boosts') end
   end
end

-- ─── GC Parametreleri Uygula ─────────────────────────────────────────────
function M.apply_gc_params(profile)
   pcall(collectgarbage, 'setpause', profile.gc_pause or 110)
   pcall(collectgarbage, 'setstepsize', profile.gc_stepsize or 100)
end

-- ─── Apply / Restore ─────────────────────────────────────────────────────
function M.apply(config)
   if _patched then
      return true
   end

   if config then
      _instrumentation = config.instrumentation
   end

   -- Object tracker throttle
   local ok = pcall(_patch_object_tracker)

   _patched = true
   log:info('GC optimization applied (object_tracker_patched=%s)', tostring(ok))
   return true
end

function M.set_instrumentation(inst)
   _instrumentation = inst
end

function M.is_patched()
   return _patched
end

-- Global registration (Stonehearth require return degerini iletmiyor)
_G.perf_mod_patches = _G.perf_mod_patches or {}
_G.perf_mod_patches.gc_optimization = M

return M
