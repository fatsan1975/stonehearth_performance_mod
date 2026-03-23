-- town_population_patch.lua
-- Town score ve population istatistikleri event flood sırasında defalarca yeniden
-- hesaplanır. Bu hesaplamalar simülasyon-kritik değildir; kısa stale pencere kabul edilir.
--
-- Town score (500ms window):
--   UI tier gösterimi ve achievement için kullanılır — simülasyon kararları değil.
-- Population stats (200ms window):
--   UI ve bazı soft kararlar için kullanılır — 200ms stale kabul edilebilir.
--
-- Strateji: Burst-dedupe throttle (restock_patch ile aynı mekanizma).
--   İlk çağrı anında çalışır, sonucu cache'lenir.
--   Pencere içindeki tekrar çağrılar son sonucu döner (orijinal çalışmaz).
--
-- Güvenlik:
--   - Caller contract korunur: nil yerine son gerçek sonuç döner
--   - pcall sarmalı: hata → son iyi sonuç döner, pencere sıfırlanır
--   - Çift-patch guard: _perfmod_townpop_X flag ile

local M = {}

local unpack = table.unpack or unpack

local TOWN_TARGETS = {
   'stonehearth_ace.services.server.town.town_service',
   'stonehearth.services.server.town.town_service',
}

-- Town score hesaplama hot fonksiyonları (sürüme göre değişir; hangisi varsa wrap edilir)
local TOWN_SCORE_METHODS = {
   '_update_score',
   '_recompute_score',
   '_compute_score',
   '_on_score_timer',
   '_recalculate_score',
   'update_score',
   '_recount_score',
}

local POPULATION_TARGETS = {
   'stonehearth_ace.services.server.population.population_service',
   'stonehearth.services.server.population.population_service',
}

-- Population stats hot fonksiyonları
local POPULATION_METHODS = {
   '_recount',
   '_update_population_stats',
   '_recalculate_population',
   '_on_population_timer',
   'recount_population',
   '_recalculate_happiness',
   '_update_stats',
}

local CLEANUP_INTERVAL = 60
local STALE_AFTER      = 120

local function _make_throttled(fn, clock, instrumentation, counter_name, suppress_s)
   local last_call    = {}
   local last_result  = {}
   local next_cleanup = 0

   return function(self, ...)
      local id  = tostring(self)
      local now = clock:get_realtime_seconds()

      -- Periyodik temizlik: ölü instance referanslarını sil (bellek sızıntısı önleme)
      if now >= next_cleanup then
         next_cleanup = now + CLEANUP_INTERVAL
         local cutoff = now - STALE_AFTER
         for k, t in pairs(last_call) do
            if t < cutoff then
               last_call[k]   = nil
               last_result[k] = nil
            end
         end
      end

      if (now - (last_call[id] or 0)) < suppress_s then
         -- Burst suppress: son gerçek sonucu döner (caller contract korunur)
         instrumentation:inc(counter_name)
         local r = last_result[id]
         if r then return unpack(r, 1, r.n) end
         return
      end

      last_call[id] = now
      local r = { n = 0 }
      local ok = pcall(function(...)
         local function _capture(...)
            r.n = select('#', ...)
            for i = 1, r.n do r[i] = select(i, ...) end
         end
         _capture(fn(self, ...))
      end, ...)

      if not ok then
         -- Hata: pencereyi sıfırla ve son iyi sonucu döndür
         last_call[id] = 0
         local prev = last_result[id]
         if prev then return unpack(prev, 1, prev.n) end
         return
      end

      last_result[id] = r
      return unpack(r, 1, r.n)
   end
end

local function _patch_module(mod, methods, clock, instrumentation, counter_name, suppress_s)
   local any = false
   for _, method_name in ipairs(methods) do
      local fn = mod[method_name]
      if type(fn) == 'function' and not mod['_perfmod_townpop_' .. method_name] then
         mod[method_name] = _make_throttled(
            fn, clock, instrumentation, counter_name, suppress_s)
         mod['_perfmod_townpop_' .. method_name] = true
         any = true
      end
   end
   return any
end

local function _try_targets(targets, methods, clock, instrumentation, counter_name, suppress_s)
   local patched = false
   for _, path in ipairs(targets) do
      local ok, mod = pcall(require, path)
      if ok and type(mod) == 'table' then
         local ok2, result = pcall(
            _patch_module, mod, methods, clock, instrumentation, counter_name, suppress_s)
         if ok2 and result then patched = true end
      end
   end
   return patched
end

function M.apply(service)
   local clock           = service:get_clock()
   local instrumentation = service:get_instrumentation()
   local patched         = false

   -- Town score: 500ms pencere — tier değişimi nadirdir, 500ms stale tamamen kabul edilebilir
   local ok1, r1 = pcall(_try_targets,
      TOWN_TARGETS, TOWN_SCORE_METHODS,
      clock, instrumentation, 'perfmod:town_score_coalesces', 0.5)
   if ok1 and r1 then patched = true end

   -- Population: 200ms pencere — daha dinamik ama yine de coalesable
   local ok2, r2 = pcall(_try_targets,
      POPULATION_TARGETS, POPULATION_METHODS,
      clock, instrumentation, 'perfmod:population_coalesces', 0.2)
   if ok2 and r2 then patched = true end

   return patched
end

return M
