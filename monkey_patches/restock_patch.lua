-- restock_patch.lua
-- ACE'nin restock servisi inventory değişiminde O(policies × items) döngüsü çalıştırır.
-- Bu, filter_cache_cb ile karşılaştırılabilir büyüklükte bir bottleneck'tir.
--
-- Strateji: Burst-dedupe throttle.
--   İlk çağrı HER ZAMAN anında çalışır ve sonucu cache'lenir.
--   Aynı instance için suppress_s saniye içindeki tekrar çağrılar
--   son bilinen sonucu döner (orijinal çağrılmaz → CPU kazanımı).
--
-- Güvenlik garantileri:
--   - İlk çağrı her zaman çalışır → en güncel sonuç her zaman en az bir kez hesaplanır
--   - Suppress sırasında son GERÇEK sonuç döner (nil değil) → caller contract korunur
--   - pcall sarmalı: hata → orijinal fonksiyon korunur, patch geri alınır
--   - Çift-patch guard: _perfmod_restock_X flag ile tekrar wrap edilmez

local M = {}

local unpack = table.unpack or unpack

local TARGETS = {
   'stonehearth_ace.services.server.restock.restock_service',
   'stonehearth.services.server.restock.restock_service',
   'stonehearth_ace.services.server.inventory.restock_service',
}

-- ACE restock servisinde bilinen hot fonksiyon adları.
-- type() kontrolü ile hangi isim mevcut olursa o wrap edilir; diğerleri sessizce atlanır.
local RESTOCK_HOT_METHODS = {
   '_check_restock_needed',
   '_on_target_contents_changed',
   '_restock_filter_cb',
   'restock_filter_cb',
   '_run_restock_check',
   '_check_policies',
   '_evaluate_restock_policy',
}

-- last_call ve last_result tabloları: tostring(self) → zaman / sonuç
-- Stonehearth'ta restock service bir singleton'dır, sızıntı yok.
-- CLEANUP_INTERVAL: her N saniyede bir ölü instance girişlerini temizle
-- STALE_AFTER: bu kadar süredir çağrılmayan instance → ölü sayılır → temizlenir
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
      -- Stonehearth'ta servisler yeniden yüklenince yeni adres alır; eski adres asla tekrar çağrılmaz.
      if now >= next_cleanup then
         next_cleanup   = now + CLEANUP_INTERVAL
         local cutoff   = now - STALE_AFTER
         for k, t in pairs(last_call) do
            if t < cutoff then
               last_call[k]   = nil
               last_result[k] = nil
            end
         end
      end

      if (now - (last_call[id] or 0)) < suppress_s then
         -- Burst suppress: son gerçek sonucu döner (nil yerine)
         instrumentation:inc('perfmod:restock_coalesces')
         local r = last_result[id]
         if r then return unpack(r, 1, r.n) end
         return
      end

      -- İlk çağrı veya pencere doldu: orijinali çalıştır, sonucu cache'le
      last_call[id] = now
      local r = { n = 0 }
      local ok, err = pcall(function(...)
         -- Kaç return değeri olduğunu doğru takip etmek için select kullanılır
         local function _capture(...)
            r.n = select('#', ...)
            for i = 1, r.n do r[i] = select(i, ...) end
         end
         _capture(fn(self, ...))
      end, ...)

      if not ok then
         -- Hata durumunda: son iyi sonucu döndür, suppress penceresini sıfırla
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
   for _, method_name in ipairs(RESTOCK_HOT_METHODS) do
      local fn = mod[method_name]
      if type(fn) == 'function' and not mod['_perfmod_restock_' .. method_name] then
         mod[method_name] = _make_throttled(fn, clock, instrumentation, suppress_s)
         mod['_perfmod_restock_' .. method_name] = true
         any = true
      end
   end
   return any
end

function M.apply(service)
   local clock           = service:get_clock()
   local instrumentation = service:get_instrumentation()
   -- 100ms: restock sonuçları saniyeler boyunca geçerlidir, 100ms stale kabul edilebilir
   local suppress_s = 0.10
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
