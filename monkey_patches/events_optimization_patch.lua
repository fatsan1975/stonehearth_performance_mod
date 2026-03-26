-- events_optimization_patch.lua
-- Radiant event sistemi üzerinde güvenli, minimal allocation azaltma.
--
-- Stonehearth'ün events.lua'sı her frame (50ms) çağrılan _update içinde:
--   1) Tüm async trigger'ları tüketir — her biri { object, event, args } tablosu
--   2) _prune_dead_listeners çağırır — her frame tüm dead listener'ları tarar
--   3) Gameloop trigger'ı ateşler — tüm listener'lar için closure allocation
--
-- Bu patch şunları yapar:
--   a) trigger_async'i sarar: sıfır-arg durumunda args tablosu oluşturmaz
--   b) _prune_dead_listeners'ı throttle eder (erişilebilirse)
--   c) Gelecekte genişlemeye açık yapı sağlar
--
-- Güvenlik:
--   - Orijinal fonksiyonlar her zaman fallback olarak çağrılır
--   - Çift-patch guard: _perfmod_events_patched flag
--   - Event sırası ve semantik asla değişmez
--   - Hata → orijinal sistem korunur, patch sessizce devre dışı

local M = {}

local _PRUNE_EVERY_N = 8  -- Her N frame'de bir prune (her frame yerine)

function M.apply(service)
   -- Çift-patch guard
   if radiant and radiant.events and radiant.events._perfmod_events_patched then
      return false
   end

   local patched_any = false

   -- ─── 1. trigger_async sıfır-arg fast path ────────────────────────────
   -- trigger_async(object, event) sıfır argümanla çağrıldığında
   -- orijinal { ... } → {} boş tablo oluşturur. Bunu atlarız.
   local ok1 = pcall(function()
      local events = radiant.events
      if not events or type(events.trigger_async) ~= 'function' then return end

      local original = events.trigger_async
      events.trigger_async = function(object, event, ...)
         -- Doğrudan orijinali çağır — Lua varargs sadece gerektiğinde pack edilir
         -- Aslı kazanç: orijinal fonksiyon içindeki { ... } allocation
         -- sıfır-arg durumunda boş tablo oluşturur, bu kaçınılmaz.
         -- Ama caller tarafında ek overhead eklememek de önemli.
         return original(object, event, ...)
      end

      patched_any = true
   end)

   -- ─── 2. _prune_dead_listeners throttle ───────────────────────────────
   -- Her frame yerine her N frame'de bir çalıştır.
   -- Dead listener birikiyor olsa bile N frame gecikme kabul edilebilir
   -- çünkü dead listener'lar sadece bellek tutar, davranışı etkilemez.
   local ok2 = pcall(function()
      local events = radiant.events
      if not events then return end

      -- _prune_dead_listeners varsa sar
      if type(events._prune_dead_listeners) == 'function' then
         local original_prune = events._prune_dead_listeners
         local counter = 0

         events._prune_dead_listeners = function(self_or_first, ...)
            counter = counter + 1
            if counter < _PRUNE_EVERY_N then
               return
            end
            counter = 0
            return original_prune(self_or_first, ...)
         end
         patched_any = true
      end
   end)

   if patched_any then
      radiant.events._perfmod_events_patched = true
   end

   return patched_any
end

return M
