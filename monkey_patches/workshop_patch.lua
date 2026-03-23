-- workshop_patch.lua
-- ACE workshop/crafting servisi inventory değişiminde O(workshops × orders) döngüsü çalıştırır.
-- _check_auto_craft ve _update_orders, item flood sırasında her inventory event'inde tetiklenir.
--
-- Strateji: Burst-dedupe throttle (restock_patch ile aynı mekanizma).
--   İlk çağrı anında çalışır, sonucu cache'lenir.
--   Pencere içindeki tekrar çağrılar son sonucu döner (orijinal çalışmaz → CPU kazanımı).
--
-- Güvenlik:
--   - Craft order değerlendirmesi zamana duyarlı değil; 200ms stale tamamen kabul edilebilir
--   - Caller contract korunur: nil yerine son gerçek sonuç döner
--   - pcall sarmalı: hata → son iyi sonuç döner, pencere sıfırlanır
--   - Çift-patch guard: _perfmod_workshop_X flag ile

local M = {}

local unpack = table.unpack or unpack

local TARGETS = {
   'stonehearth_ace.services.server.crafting.crafting_service',
   'stonehearth.services.server.crafting.crafting_service',
   'stonehearth_ace.services.server.workshop.workshop_service',
   'stonehearth.services.server.workshop.workshop_service',
}

-- ACE workshop/crafting servisinde bilinen hot fonksiyon adları.
-- type() kontrolü ile hangi isim mevcut olursa o wrap edilir; diğerleri sessizce atlanır.
local WORKSHOP_HOT_METHODS = {
   '_check_auto_craft',
   '_update_orders',
   '_recheck_orders',
   '_on_workshop_timer',
   '_evaluate_craft_orders',
   '_check_auto_queue',
   '_auto_requeue_orders',
   '_on_order_changed',
   '_refresh_orders',
   '_recompute_queues',
}

local CLEANUP_INTERVAL = 60
local STALE_AFTER      = 120

local function _make_throttled(fn, clock, instrumentation, suppress_s)
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
         -- Burst suppress: son gerçek sonucu döner (nil yerine)
         instrumentation:inc('perfmod:workshop_coalesces')
         local r = last_result[id]
         if r then return unpack(r, 1, r.n) end
         return
      end

      -- İlk çağrı veya pencere doldu: orijinali çalıştır, sonucu cache'le
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

local function _patch_table(mod, clock, instrumentation, suppress_s)
   local any = false
   for _, method_name in ipairs(WORKSHOP_HOT_METHODS) do
      local fn = mod[method_name]
      if type(fn) == 'function' and not mod['_perfmod_workshop_' .. method_name] then
         mod[method_name] = _make_throttled(fn, clock, instrumentation, suppress_s)
         mod['_perfmod_workshop_' .. method_name] = true
         any = true
      end
   end
   return any
end

function M.apply(service)
   local clock           = service:get_clock()
   local instrumentation = service:get_instrumentation()
   -- 200ms: craft order değerlendirmesi zaman-kritik değil, 200ms stale kabul edilebilir
   local suppress_s = 0.20
   local patched    = false

   for _, path in ipairs(TARGETS) do
      local ok, mod = pcall(require, path)
      if ok and type(mod) == 'table' then
         local ok2, result = pcall(_patch_table, mod, clock, instrumentation, suppress_s)
         if ok2 and result then
            patched = true
         end
      end
   end

   return patched
end

return M
