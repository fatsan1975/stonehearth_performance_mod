-- service.lua
-- Performance Mod ana servis
--
-- Tum patch modulleri initialize() icinde require edilir (lazy loading).
-- Bootstrap radiant:init event'inde bu modulu yukler, bu zamanda
-- class(), stonehearth.ai, ACE patch'leri hepsi hazirdir.

local log = radiant.log.create_logger('perf_mod_service')

-- Config pure table, class() kullanmiyor — top-level safe
local Config = require 'scripts.perf_mod.config'

local PerfModService = class()

local _instance = nil

-- Lazy-loaded moduller (initialize icinde require edilir)
local Settings = nil
local Instrumentation = nil
local ReconsiderAllocPatch = nil
local FilterFastRejectPatch = nil
local ReconsiderLimiterPatch = nil
local GcOptimization = nil

local function _fallback_saved_variables()
   local data = {}
   return {
      get_data = function()
         return data
      end
   }
end

function PerfModService:get()
   if not _instance then
      _instance = PerfModService()
   end
   return _instance
end

function PerfModService:initialize()
   -- 1) Lazy module loading — hepsi pcall ile korunuyor
   local modules_ok = self:_load_modules()
   if not modules_ok then
      log:error('perf_mod: Critical modules failed to load — aborting')
      return
   end

   -- 2) Settings
   self._sv = self.__saved_variables or _fallback_saved_variables()
   self._settings = Settings()
   self._settings:initialize(self._sv)

   -- 3) Instrumentation
   self._instrumentation = Instrumentation()
   self._instrumentation:initialize(log)
   self._instrumentation:set_enabled(self._settings:get().instrumentation_enabled)

   -- 4) ACE kontrolu
   self:_detect_ace()

   -- 5) stonehearth.ai hazirlik kontrolu + patch uygulama
   self._applied_patches = {}
   if self:_check_ai_service_ready() then
      self:_apply_patches()
      self:_apply_gc_tuning()
      self:_start_heartbeat()
      self:_log_startup_summary()
   else
      log:warning('perf_mod: stonehearth.ai not ready at init — deferring patch application...')
      self:_defer_patch_application()
   end
end

-- ─── Module Loading ──────────────────────────────────────────────────────

function PerfModService:_load_modules()
   local all_ok = true

   -- Settings (class-based)
   local ok1, r1 = pcall(require, 'scripts.perf_mod.settings')
   if ok1 then Settings = r1
   else log:error('perf_mod: settings load failed: %s', tostring(r1)); all_ok = false end

   -- Instrumentation (class-based)
   local ok2, r2 = pcall(require, 'scripts.perf_mod.instrumentation')
   if ok2 then Instrumentation = r2
   else log:error('perf_mod: instrumentation load failed: %s', tostring(r2)); all_ok = false end

   -- Patch modules (table-based, class() kullanmiyor)
   local ok3, r3 = pcall(require, 'monkey_patches.reconsider_alloc_patch')
   if ok3 then ReconsiderAllocPatch = r3
   else log:warning('perf_mod: reconsider_alloc_patch load failed: %s', tostring(r3)) end

   local ok4, r4 = pcall(require, 'monkey_patches.filter_fast_reject_patch')
   if ok4 then FilterFastRejectPatch = r4
   else log:warning('perf_mod: filter_fast_reject_patch load failed: %s', tostring(r4)) end

   local ok5, r5 = pcall(require, 'monkey_patches.reconsider_limiter_patch')
   if ok5 then ReconsiderLimiterPatch = r5
   else log:warning('perf_mod: reconsider_limiter_patch load failed: %s', tostring(r5)) end

   local ok6, r6 = pcall(require, 'monkey_patches.gc_optimization_patch')
   if ok6 then GcOptimization = r6
   else log:warning('perf_mod: gc_optimization_patch load failed: %s', tostring(r6)) end

   return all_ok
end

-- ─── stonehearth.ai Readiness ────────────────────────────────────────────

function PerfModService:_check_ai_service_ready()
   if not stonehearth then return false end
   if not stonehearth.ai then return false end
   -- ACE'nin reconsider_entity override'i uygulandi mi?
   if not stonehearth.ai.reconsider_entity then return false end
   if not stonehearth.ai._call_reconsider_callbacks then return false end
   if not stonehearth.ai._add_reconsidered_entity then return false end
   return true
end

function PerfModService:_defer_patch_application()
   -- Kisa bir timer ile tekrar dene — stonehearth.ai birkaç ms icinde hazir olacak
   local retry_count = 0
   local max_retries = 50  -- 50 × 100ms = 5 saniye max bekleme

   local function _try_apply()
      retry_count = retry_count + 1

      if self:_check_ai_service_ready() then
         log:always('perf_mod: stonehearth.ai ready after %d retries — applying patches', retry_count)
         self:_apply_patches()
         self:_apply_gc_tuning()
         self:_start_heartbeat()
         self:_log_startup_summary()
         return
      end

      if retry_count < max_retries then
         -- radiant.set_realtime_timer kullan (game loop'a bagli degil)
         if radiant and radiant.set_realtime_timer then
            radiant.set_realtime_timer('perf_mod_retry_' .. retry_count, 100, _try_apply)
         else
            log:error('perf_mod: Cannot retry — radiant.set_realtime_timer not available')
         end
      else
         log:error('perf_mod: stonehearth.ai not ready after %d retries — patches NOT applied', max_retries)
         -- Heartbeat'i yine baslat (GC tuning icin)
         self:_apply_gc_tuning()
         self:_start_heartbeat()
         self:_log_startup_summary()
      end
   end

   _try_apply()
end

-- ─── ACE Detection ───────────────────────────────────────────────────────

function PerfModService:_detect_ace()
   self._ace_present = false
   if radiant and radiant.mods and radiant.mods.is_installed then
      self._ace_present = radiant.mods.is_installed('stonehearth_ace')
   end
end

-- ─── Patch Application ──────────────────────────────────────────────────

function PerfModService:_apply_patches()
   local profile = self:get_profile_data()
   local patch_config = {
      instrumentation = self._instrumentation,
      max_reconsider_per_tick = profile.max_reconsider_per_tick,
      reject_flush_interval = profile.reject_flush_interval,
   }

   -- Uygulama sirasi onemli:
   -- PATCH 3 (reconsider_limiter) -> reconsider_entity'yi override eder
   -- PATCH 2 (filter_fast_reject) -> _add_reconsidered_entity + filter_from_key
   -- PATCH 1 (reconsider_alloc)   -> _call_reconsider_callbacks + on_reconsider_entity
   -- Bu sira ile her patch kendi katmaninda calisir, cakisma olmaz.

   -- PATCH 3: Reconsider cascade limiter
   if profile.reconsider_limiter and ReconsiderLimiterPatch then
      local ok, err = pcall(ReconsiderLimiterPatch.apply, patch_config)
      if ok and ReconsiderLimiterPatch.is_patched() then
         self._applied_patches[#self._applied_patches + 1] = 'PATCH 3: reconsider_limiter'
         log:always('  [OK] PATCH 3 applied: reconsider cascade dedup + container cache')
      else
         log:error('  [FAIL] PATCH 3 (reconsider_limiter): %s', tostring(err))
      end
   end

   -- PATCH 2: Filter URI fast-reject
   if profile.filter_fast_reject and FilterFastRejectPatch then
      local ok, err = pcall(FilterFastRejectPatch.apply, patch_config)
      if ok and FilterFastRejectPatch.is_patched() then
         self._applied_patches[#self._applied_patches + 1] = 'PATCH 2: filter_fast_reject'
         log:always('  [OK] PATCH 2 applied: URI negative cache (flush=%d ticks)', profile.reject_flush_interval)
      else
         log:error('  [FAIL] PATCH 2 (filter_fast_reject): %s', tostring(err))
      end
   end

   -- PATCH 1+4: Reconsider allocation + entity spread
   if profile.reconsider_alloc and ReconsiderAllocPatch then
      local ok, err = pcall(ReconsiderAllocPatch.apply, patch_config)
      if ok and ReconsiderAllocPatch.is_patched() then
         self._applied_patches[#self._applied_patches + 1] = 'PATCH 1+4: reconsider_alloc + spread'
         log:always('  [OK] PATCH 1+4 applied: zero-alloc reconsider + entity spread (max=%d)', profile.max_reconsider_per_tick)
      else
         log:error('  [FAIL] PATCH 1+4 (reconsider_alloc): %s', tostring(err))
      end
   end
end

function PerfModService:_apply_gc_tuning()
   local profile = self:get_profile_data()
   if not profile.gc_tuning or not GcOptimization then
      return
   end

   GcOptimization.apply_gc_params(profile)
   GcOptimization.set_instrumentation(self._instrumentation)

   local ok, err = pcall(GcOptimization.apply, { instrumentation = self._instrumentation })
   if ok then
      self._applied_patches[#self._applied_patches + 1] = 'GC: tuning + object_tracker throttle'
      log:always('  [OK] GC tuning applied (pause=%d, step=%d)', profile.gc_pause, profile.gc_stepsize)
   else
      log:warning('  [WARN] GC object_tracker patch failed: %s', tostring(err))
   end
end

-- ─── Heartbeat ───────────────────────────────────────────────────────────

function PerfModService:_start_heartbeat()
   -- Oncelik: stonehearth.calendar (game tick ile senkron)
   if stonehearth and stonehearth.calendar and stonehearth.calendar.set_interval then
      self._heartbeat = stonehearth.calendar:set_interval('perf_mod_pump', '50ms', function()
         self:_on_heartbeat_tick()
      end)
      return
   end

   -- Fallback: radiant.on_game_loop
   if radiant and radiant.on_game_loop then
      self._heartbeat = radiant.on_game_loop('perf_mod_pump', function()
         self:_on_heartbeat_tick()
      end)
      return
   end

   log:warning('perf_mod: No heartbeat scheduler available — tick-level flush disabled')
end

function PerfModService:_on_heartbeat_tick()
   self._heartbeat_count = (self._heartbeat_count or 0) + 1

   -- PATCH 3: Tick-level dedup + container cache temizle
   if ReconsiderLimiterPatch and ReconsiderLimiterPatch.is_patched() then
      pcall(ReconsiderLimiterPatch.flush_tick)
   end

   -- PATCH 2: Periyodik reject cache flush
   if FilterFastRejectPatch and FilterFastRejectPatch.is_patched() then
      pcall(FilterFastRejectPatch.tick)
   end

   -- GC adaptif step
   local profile = self:get_profile_data()
   if profile.gc_tuning and GcOptimization then
      pcall(GcOptimization.adaptive_gc_step, profile)
   end

   -- Instrumentation publish
   if self._instrumentation then
      self._instrumentation:publish_if_available()
   end

   -- 30s ozet log (600 tick ~ 30s)
   if self._heartbeat_count % 600 == 0 then
      local snap = self._instrumentation:get_snapshot()
      log:always('perf_mod 30s: profile=%s patches=%d reject=%d dedup=%d spread=%d gc_steps=%d',
         self._settings:get().profile,
         #self._applied_patches,
         snap['perfmod:uri_reject_hits'] or 0,
         snap['perfmod:reconsider_dedup_hits'] or 0,
         snap['perfmod:reconsider_spread_defers'] or 0,
         snap['perfmod:gc_adaptive_steps'] or 0)
   end
end

-- ─── Startup Summary ─────────────────────────────────────────────────────

function PerfModService:_log_startup_summary()
   local profile = self._settings:get().profile or 'BALANCED'
   local total = #self._applied_patches

   log:always('=======================================================')
   log:always('perf_mod v310 initialized')
   log:always('  Profile: %s | ACE: %s | Patches: %d/%d',
      profile, tostring(self._ace_present), total, 4)

   if total == 0 then
      log:always('  WARNING: No patches applied! Check errors above.')
   end

   log:always('=======================================================')
end

-- ─── Destroy ─────────────────────────────────────────────────────────────

function PerfModService:destroy()
   if self._heartbeat then
      pcall(function()
         if stonehearth and stonehearth.calendar and stonehearth.calendar.cancel_interval then
            stonehearth.calendar:cancel_interval(self._heartbeat)
         end
      end)
      self._heartbeat = nil
   end

   if ReconsiderAllocPatch then pcall(ReconsiderAllocPatch.restore) end
   if FilterFastRejectPatch then pcall(FilterFastRejectPatch.restore) end
   if ReconsiderLimiterPatch then pcall(ReconsiderLimiterPatch.restore) end
end

-- ─── Public API ──────────────────────────────────────────────────────────

function PerfModService:get_profile_data()
   local profile_name = self._settings and self._settings:get().profile or 'BALANCED'
   return Config.get_profile(profile_name)
end

function PerfModService:get_settings()
   if not self._settings then return { profile = 'BALANCED', instrumentation_enabled = false } end
   return self._settings:get()
end

function PerfModService:update_settings(data)
   if not self._settings then return false end
   if self._settings:update(data) then
      self._instrumentation:set_enabled(self._settings:get().instrumentation_enabled)

      local profile = self:get_profile_data()
      if ReconsiderAllocPatch and ReconsiderAllocPatch.is_patched() then
         ReconsiderAllocPatch.set_max_per_tick(profile.max_reconsider_per_tick)
      end

      if profile.gc_tuning and GcOptimization then
         GcOptimization.apply_gc_params(profile)
      end

      log:always('perf_mod: settings updated — profile=%s', self._settings:get().profile)
      return true
   end
   return false
end

function PerfModService:get_instrumentation()
   return self._instrumentation
end

function PerfModService:get_instrumentation_snapshot()
   if not self._instrumentation then return {} end
   return self._instrumentation:get_snapshot()
end

return PerfModService
