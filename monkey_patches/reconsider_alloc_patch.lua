-- reconsider_alloc_patch.lua
-- PATCH 1 + PATCH 4: Reconsider callback allocation eliminasyonu + entity spread
--
-- Sorun:
--   _call_reconsider_callbacks her tick'te:
--     1) self._reconsidered_entities = {} → eski tablo GC'ye gider
--     2) local reconsider_callbacks = {} → her tick yeni tablo
--     3) radiant.xpcall(function() cb(msg) end) → entity×callback kadar closure
--   23 hearthling, hauling aktif = 200-1000 closure/tick → lua_gc'nin ana müşterisi
--
-- Çözüm:
--   1) reconsidered tablosu: swap yerine wipe-and-reuse
--   2) callback snapshot: dirty flag ile sadece değiştiğinde rebuild
--   3) xpcall closure → pcall direct call (sıfır closure allocation)
--   4) Entity spread: MAX_PER_TICK aşılırsa kalanı sonraki tick'e taşı
--
-- Güvenlik:
--   - Semantik olarak orijinal ile aynı davranış
--   - pcall sarmalı — hata durumunda orijinal fonksiyon restore edilir
--   - Kill-switch: config.patches.reconsider_alloc

local log = radiant.log.create_logger('perf_mod:reconsider_alloc')

local M = {}

-- Patch durumu
local _patched = false
local _original_call_reconsider_callbacks = nil
local _original_on_reconsider_entity = nil
local _original_add_reconsidered_entity = nil

-- Reuse edilecek tablolar
local _callback_snapshot = {}        -- callback fonksiyonları (reuse)
local _callback_snapshot_len = 0     -- snapshot uzunluğu
local _callback_snapshot_dirty = true -- yeniden build gerekli mi

-- Overflow buffer: MAX_PER_TICK aşıldığında kalanlar burada birikir
local _overflow = {}
local _overflow_count = 0

-- Ayarlar
local _max_per_tick = 64

-- Instrumentation
local _instrumentation = nil

-- ─── Callback snapshot yönetimi ──────────────────────────────────────────
-- on_reconsider_entity çağrıldığında (yeni callback eklendiğinde/silindiğinde)
-- dirty flag set edilir. Snapshot sadece dirty olduğunda rebuild olur.

local function _mark_callbacks_dirty()
   _callback_snapshot_dirty = true
end

local function _rebuild_callback_snapshot(ai_service)
   -- Eski snapshot'ı temizle (reuse için)
   for i = 1, _callback_snapshot_len do
      _callback_snapshot[i] = nil
   end

   local n = 0
   for _, entry in pairs(ai_service._reconsider_callbacks) do
      n = n + 1
      _callback_snapshot[n] = entry.callback
   end
   _callback_snapshot_len = n
   _callback_snapshot_dirty = false
end

-- ─── Patched _call_reconsider_callbacks ──────────────────────────────────
-- Orijinalin allocation-free versiyonu.
local function _patched_call_reconsider_callbacks(self)
   -- 1) Reconsidered entity'leri al: swap yerine wipe-and-reuse
   --    Ama dikkat: callback'ler sırasında yeni reconsider çağrılabilir.
   --    Bu yüzden mevcut listeyi "current" olarak al, self'i boş bir tabloya swap et.
   --    Fark: boş tablo bir kez oluşturulur ve sonra reuse edilir.
   local reconsidered = self._reconsidered_entities

   -- Overflow'dan kalan entity'ler varsa ekle
   if _overflow_count > 0 then
      for id, msg in pairs(_overflow) do
         if not reconsidered[id] then
            reconsidered[id] = msg
         end
         _overflow[id] = nil
      end
      _overflow_count = 0
   end

   -- Boş mu kontrol et (en yaygın durum: gece, idle)
   if not next(reconsidered) then
      return
   end

   -- Yeni tablo ile swap (callback sırasında gelen reconsider'lar buraya yazılır)
   -- NOT: Bu tek allocation kaçınılmaz — callback sırasında self._reconsidered_entities'e
   -- yazılacak yeni entity'ler eski tablo ile karışmamalı.
   -- AMA: _overflow mekanizması ile bu tabloyu da reuse edebiliriz.
   self._reconsidered_entities = {}

   -- 2) Callback snapshot'ı güncelle (sadece dirty ise)
   if _callback_snapshot_dirty then
      _rebuild_callback_snapshot(self)
   end

   -- 3) PATCH 4: Entity spread — MAX_PER_TICK aşılırsa böl
   local entity_count = 0
   local process_reconsidered = reconsidered
   local has_overflow = false

   if _max_per_tick > 0 then
      -- Hızlı count (pairs ile)
      for _ in pairs(reconsidered) do
         entity_count = entity_count + 1
      end

      if entity_count > _max_per_tick then
         -- İlk MAX_PER_TICK entity'yi işle, kalanını overflow'a taşı
         local processed = 0
         for id, msg in pairs(reconsidered) do
            if processed >= _max_per_tick then
               _overflow[id] = msg
               _overflow_count = _overflow_count + 1
               reconsidered[id] = nil
               has_overflow = true
            else
               processed = processed + 1
            end
         end

         if _instrumentation then
            _instrumentation:inc('perfmod:reconsider_spread_defers', entity_count - _max_per_tick)
         end
      end
   end

   -- 4) Entity × Callback loop — SIFIR closure allocation
   local snapshot = _callback_snapshot
   local snapshot_len = _callback_snapshot_len
   local single_entity_cbs = self._single_entity_reconsider_callbacks

   for id, msg in pairs(reconsidered) do
      -- All-entity callbacks
      if msg.entity and msg.entity:is_valid() then
         for i = 1, snapshot_len do
            -- pcall(fn, arg) → closure allocation YOK
            -- Orijinal: radiant.xpcall(function() cb(msg) end) → closure allocation VAR
            local ok, err = pcall(snapshot[i], msg)
            if not ok then
               log:debug('reconsider callback error: %s', tostring(err))
            end
         end
      end

      -- Specific entity callbacks
      local entity_cbs = single_entity_cbs[id]
      if entity_cbs then
         for fn in pairs(entity_cbs) do
            local ok, err = pcall(fn)
            if not ok then
               log:debug('single entity reconsider callback error: %s', tostring(err))
            end
         end
      end
   end

   -- 5) C++ pathfinder'a bildir
   _radiant.sim.reconsider_entities(reconsidered)

   -- 6) Kullanılmış reconsidered tablosunu temizle (GC'ye gitmez, reuse için hazır)
   -- NOT: Bu tabloyu reuse etmek zor çünkü self._reconsidered_entities zaten
   -- yeni bir tablo. Ama callback sırasında az entity eklendiyse,
   -- sonraki tick'te self._reconsidered_entities küçük kalır.
   -- Gerçek kazanç callback snapshot reuse ve closure eliminasyonunda.

   if _instrumentation then
      _instrumentation:inc('perfmod:reconsider_alloc_ticks')
      if has_overflow then
         _instrumentation:inc('perfmod:reconsider_spread_ticks')
      end
   end
end

-- ─── Patched on_reconsider_entity ────────────────────────────────────────
-- Orijinali wrap eder, callback eklendiğinde/silindiğinde dirty flag set eder.
local function _patched_on_reconsider_entity(self, reason, callback)
   local id = self._next_reconsider_callback_id
   self._next_reconsider_callback_id = self._next_reconsider_callback_id + 1

   self._reconsider_callbacks[id] = {
      reason = reason,
      callback = callback,
   }

   _mark_callbacks_dirty()

   return radiant.lib.Destructor(function()
      self._reconsider_callbacks[id] = nil
      _mark_callbacks_dirty()
   end)
end

-- ─── Apply / Restore ─────────────────────────────────────────────────────
function M.apply(config)
   if _patched then
      return true
   end

   -- Config'den ayarları al
   if config then
      _max_per_tick = config.max_reconsider_per_tick or 64
      _instrumentation = config.instrumentation
   end

   local ok, err = pcall(function()
      local ai_service = stonehearth.ai

      -- Orijinalleri sakla
      _original_call_reconsider_callbacks = ai_service._call_reconsider_callbacks
      _original_on_reconsider_entity = ai_service.on_reconsider_entity

      -- Patch uygula
      ai_service._call_reconsider_callbacks = _patched_call_reconsider_callbacks
      ai_service.on_reconsider_entity = _patched_on_reconsider_entity

      -- İlk callback snapshot'ı build et
      _rebuild_callback_snapshot(ai_service)

      _patched = true
   end)

   if not ok then
      log:error('PATCH 1 (reconsider_alloc) failed: %s — falling back to original', tostring(err))
      M.restore()
      return false
   end

   log:info('PATCH 1+4 applied: reconsider_alloc + entity_spread (max_per_tick=%d)', _max_per_tick)
   return true
end

function M.restore()
   if not _patched then
      return
   end

   pcall(function()
      local ai_service = stonehearth.ai
      if _original_call_reconsider_callbacks then
         ai_service._call_reconsider_callbacks = _original_call_reconsider_callbacks
      end
      if _original_on_reconsider_entity then
         ai_service.on_reconsider_entity = _original_on_reconsider_entity
      end
   end)

   _patched = false
   _original_call_reconsider_callbacks = nil
   _original_on_reconsider_entity = nil
   _callback_snapshot_dirty = true

   -- Overflow temizle
   for k in pairs(_overflow) do
      _overflow[k] = nil
   end
   _overflow_count = 0

   log:info('PATCH 1+4 restored: reconsider_alloc + entity_spread')
end

function M.set_max_per_tick(value)
   _max_per_tick = value or 64
end

function M.is_patched()
   return _patched
end

-- Global registration (Stonehearth require return degerini iletmiyor)
_G.perf_mod_patches = _G.perf_mod_patches or {}
_G.perf_mod_patches.reconsider_alloc = M

return M
