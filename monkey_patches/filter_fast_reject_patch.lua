-- filter_fast_reject_patch.lua
-- PATCH 2: URI-bazl? negatif sonu? cache (fast-reject)
--
-- Sorun:
--   _filter_passes her entity i?in C++ boundary crossing yap?yor:
--     is_valid ? get_player_id ? get_component ? get_uri ? catalog ? material
--   Ayn? URI'ye sahip 50 kereste ? 50 kez ayn? expensive kontroller.
--   ACE'nin filter_materials_uris cache'i sadece material matching ad?m?n? cache'liyor,
--   ?nceki 4 ad?m (is_valid, player_id, entity_forms, ghost_form) her seferinde tekrarlan?yor.
--
-- ??z?m:
--   filter_from_key'i wrap ederek her filter fonksiyonunun ?n?ne URI-bazl?
--   negatif cache ekliyoruz. "Basit entity" (entity_forms yok, ghost_form yok)
--   i?in: player_id + URI ? deterministik sonu?.
--   Sadece NEGAT?F sonu?lar cache'lenir ? pozitif sonu? dinamik fakt?rlere
--   (konum, eri?ilebilirlik) ba?l? olabilir.
--
-- Invalidation:
--   - reconsider_entity ?a?r?ld???nda entity URI'si t?m cache'lerden silinir
--   - Periyodik full flush (her N tick)
--
-- G?venlik:
--   - Cache miss = orijinal _filter_passes ?a?r?l?r, sonu? her zaman do?ru
--   - Sadece false cache'lenir, true asla cache'lenmez
--   - Kill-switch: config.patches.filter_fast_reject

local log = radiant.log.create_logger('perf_mod:filter_reject')

local M = {}

-- Patch durumu
local _patched = false
local _original_filter_from_key = nil
local _original_add_reconsidered_entity = nil

-- Her filter_fn i?in ayr? URI reject tablosu
-- _reject_caches[filter_fn] = { ["player_id:uri"] = true }
local _reject_caches = {}

-- T?m aktif wrapped filter'lar (invalidation i?in)
local _wrapped_filters = {}  -- wrapped_fn ? original_fn mapping
local _filter_to_reject = {} -- original_fn ? reject_cache mapping

-- Instrumentation
local _instrumentation = nil

-- Tick counter for periodic flush
local _tick_count = 0
local _flush_interval = 400  -- Her 400 tick (~20s) full flush

-- ??? URI Reject Cache Y?netimi ???????????????????????????????????????????

-- Entity URI'sini t?m reject cache'lerden sil (invalidation)
local function _invalidate_entity_uri(entity)
   -- Entity'den URI al
   local ok, uri = pcall(entity.get_uri, entity)
   if not ok or not uri then
      return
   end

   -- player_id al
   local ok2, pid = pcall(radiant.entities.get_player_id, entity)
   local player_id = ok2 and pid or ''

   local key = player_id .. ':' .. uri

   -- T?m reject cache'lerden bu key'i sil
   for _, cache in pairs(_reject_caches) do
      if rawget(cache, key) then
         rawset(cache, key, nil)
      end
   end
end

-- ??? Filter Wrapper ??????????????????????????????????????????????????????
-- Orijinal filter_fn'in ?n?ne URI reject kontrol? ekler.
local function _create_wrapped_filter(original_filter_fn)
   -- Bu filter i?in reject cache
   local reject_cache = {}
   _reject_caches[original_filter_fn] = reject_cache

   local get_player_id = radiant.entities.get_player_id

   local function wrapped_filter(entity)
      -- H?zl? validity check
      if not entity or not entity:is_valid() then
         return false
      end

      -- "Basit entity" kontrol?: entity_forms varsa bypass (recursive call yap?yor)
      -- entity_forms check'i ucuz de?il (C++ boundary) ama reject cache hit
      -- ?ok daha fazla ?a?r?y? kurtar?r.
      -- Strateji: ?nce URI + player_id ile reject cache'e bak.
      -- Cache hit ? h?zl? false. Cache miss ? orijinal fonksiyona devret.

      -- URI al (C++ boundary ama tek bir ?a?r?)
      local entity_uri = entity:get_uri()

      -- Player ID al
      local item_player_id = get_player_id(entity)
      if not item_player_id then
         item_player_id = ''
      end

      local cache_key = item_player_id .. ':' .. entity_uri

      -- Reject cache hit ? h?zl? false d?n
      if rawget(reject_cache, cache_key) then
         if _instrumentation then
            _instrumentation:inc('perfmod:uri_reject_hits')
         end
         return false
      end

      -- Cache miss ? orijinal filter'? ?a??r
      local result = original_filter_fn(entity)

      -- Sadece NEGAT?F sonu?lar? cache'le
      -- Ek g?venlik: entity_forms olan entity'leri cache'leme
      -- (recursive call yap?yorlar, URI iconic entity'ye ait olabilir)
      if not result then
         -- entity_forms kontrol? ? bu component varsa cachelemiyoruz
         -- ??nk? ayn? URI iconic vs root entity farkl? sonu? verebilir
         local efc = entity:get_component('stonehearth:entity_forms')
         if not efc then
            rawset(reject_cache, cache_key, true)
            if _instrumentation then
               _instrumentation:inc('perfmod:uri_reject_caches')
            end
         end
      end

      return result
   end

   _wrapped_filters[wrapped_filter] = original_filter_fn
   _filter_to_reject[original_filter_fn] = reject_cache

   return wrapped_filter
end

-- ??? Patched filter_from_key ?????????????????????????????????????????????
-- filter_from_key ayn? filter_key i?in ayn? filter_fn d?nd?r?r.
-- Biz sadece YEN? filter'lar olu?turuldu?unda wrap ekliyoruz.
local function _patched_filter_from_key(self, namespace, filter_key, filter_impl_fn)
   local ns = rawget(self._all_filters_ref or {}, namespace)

   -- Orijinal filter_from_key mant???n? takip et
   -- AMA: ALL_FILTERS file-local oldu?u i?in do?rudan eri?emiyoruz.
   -- ??z?m: Orijinal fonksiyonu ?a??r, ama filter_impl_fn'i wrap edilmi? versiyonla de?i?tir.

   -- filter_impl_fn zaten wrap edilmi? mi kontrol et
   if _wrapped_filters[filter_impl_fn] then
      -- Zaten wrapped, orijinalden ge?ir
      return _original_filter_from_key(self, namespace, filter_key, filter_impl_fn)
   end

   -- Yeni filter: wrap et
   local wrapped = _create_wrapped_filter(filter_impl_fn)

   -- Orijinal filter_from_key'e wrapped versiyonu ver
   return _original_filter_from_key(self, namespace, filter_key, wrapped)
end

-- ??? Patched _add_reconsidered_entity ????????????????????????????????????
-- Entity reconsider edildi?inde URI'sini reject cache'lerden sil.
-- PATCH 3 ile birle?ik: FAST_CALL_CACHES temizleme batch'e ta??n?r.
local function _patched_add_reconsidered_entity(self, entity, reason)
   -- ?nce URI reject invalidation
   _invalidate_entity_uri(entity)

   -- Sonra orijinal davran??
   return _original_add_reconsidered_entity(self, entity, reason)
end

-- ??? Tick flush ??????????????????????????????????????????????????????????
-- Periyodik full cache flush (stale entry birikimi ?nleme)
function M.tick()
   _tick_count = _tick_count + 1
   if _tick_count >= _flush_interval then
      _tick_count = 0
      M.flush_all_caches()
   end
end

function M.flush_all_caches()
   for fn, cache in pairs(_reject_caches) do
      -- Tabloyu temizle ama reuse et (yeni tablo allocation yok)
      for k in pairs(cache) do
         cache[k] = nil
      end
   end
end

-- ??? Apply / Restore ?????????????????????????????????????????????????????
function M.apply(config)
   if _patched then
      return true
   end

   if config then
      _instrumentation = config.instrumentation
      _flush_interval = config.reject_flush_interval or 400
   end

   local ok, err = pcall(function()
      local ai_service = stonehearth.ai

      -- Orijinalleri sakla
      _original_filter_from_key = ai_service.filter_from_key
      _original_add_reconsidered_entity = ai_service._add_reconsidered_entity

      -- Patch uygula
      ai_service.filter_from_key = _patched_filter_from_key
      ai_service._add_reconsidered_entity = _patched_add_reconsidered_entity

      _patched = true
   end)

   if not ok then
      log:error('PATCH 2 (filter_fast_reject) failed: %s ? falling back to original', tostring(err))
      M.restore()
      return false
   end

   log:info('PATCH 2 applied: filter_fast_reject (flush_interval=%d ticks)', _flush_interval)
   return true
end

function M.restore()
   if not _patched then
      return
   end

   pcall(function()
      local ai_service = stonehearth.ai
      if _original_filter_from_key then
         ai_service.filter_from_key = _original_filter_from_key
      end
      if _original_add_reconsidered_entity then
         ai_service._add_reconsidered_entity = _original_add_reconsidered_entity
      end
   end)

   _patched = false
   _original_filter_from_key = nil
   _original_add_reconsidered_entity = nil

   -- Cache'leri temizle
   for k in pairs(_reject_caches) do
      _reject_caches[k] = nil
   end
   for k in pairs(_wrapped_filters) do
      _wrapped_filters[k] = nil
   end
   for k in pairs(_filter_to_reject) do
      _filter_to_reject[k] = nil
   end

   log:info('PATCH 2 restored: filter_fast_reject')
end

function M.is_patched()
   return _patched
end

-- Global registration (Stonehearth require return degerini iletmiyor)
_G.perf_mod_patches = _G.perf_mod_patches or {}
_G.perf_mod_patches.filter_fast_reject = M

return M
