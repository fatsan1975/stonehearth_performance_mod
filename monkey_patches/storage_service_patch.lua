-- storage_service_patch.lua
-- filter_cache_cb sarmalı + storage invalidation event'leri.
--
-- ÖNEMLİ: filter_cache_cb 'filter' context ile sarılır ('storage' DEĞİL).
-- 'filter' context'in özel ayarları:
--   - filter_ttl_mult: TTL çarpanı (1.4x) — filter kriterleri item'lardan yavaş değişir
--   - negative_filter_ttl: kısa negatif TTL (80-150ms) — generation guard ile güvenli
--   - admit_after_hits_filter: immediate admission (=1) — en tekrarlı context
--   - cache_negative_filter: negatif sonuçlar da cachelenebilir
--
-- Invalidation event'leri 'storage' context ile dirty marking yapar:
-- item ekleme/çıkarma/değişiklik → cache generation ilerlet + maintenance planla.
--
-- NOT: Eski filter_cache_patch.lua bu patch ile aynı fonksiyonu sarıyordu ama
-- 'filter' yerine ikinci bir 'filter' context ile. Guard flag sayesinde
-- çift-sarma engelleniyordu ama context hatalıydı. O patch kaldırıldı.

local M = {}

local TARGETS = {
   'stonehearth_ace.services.server.storage.storage_service',
   'stonehearth.services.server.storage.storage_service'
}

-- filter_cache_cb: 'filter' context ile sarılır (özel TTL/admission ayarları için)
local FILTER_METHODS = {
   'filter_cache_cb'
}

local INVALIDATION_METHODS = {
   'on_item_added',
   '_on_item_added',
   'on_item_removed',
   '_on_item_removed',
   'on_item_changed',
   '_on_item_changed',
   'on_storage_filter_changed',
   '_on_storage_filter_changed'
}

local function _patch_table(mod, optimizer)
   local any = false

   -- filter_cache_cb → 'filter' context (TTL çarpanı, negatif cache, immediate admission)
   for _, method_name in ipairs(FILTER_METHODS) do
      local fn = mod[method_name]
      if type(fn) == 'function' and not mod['_perfmod_wrapped_' .. method_name] then
         mod[method_name] = optimizer:wrap_query('filter', fn)
         mod['_perfmod_wrapped_' .. method_name] = true
         any = true
      end
   end

   -- Invalidation event'leri → 'storage' context dirty marking
   for _, method_name in ipairs(INVALIDATION_METHODS) do
      local fn = mod[method_name]
      if type(fn) == 'function' and not mod['_perfmod_inval_' .. method_name] then
         mod[method_name] = function(self, ...)
            optimizer:mark_inventory_dirty('storage')
            -- filter context'i de invalidate et (filter_cache_cb sonuçları eski olabilir)
            optimizer:mark_inventory_dirty('filter')
            return fn(self, ...)
         end
         mod['_perfmod_inval_' .. method_name] = true
         any = true
      end
   end

   return any
end

function M.apply(service)
   local optimizer = service:get_optimizer()
   local patched = false

   for _, path in ipairs(TARGETS) do
      local ok, mod = pcall(require, path)
      if ok and type(mod) == 'table' then
         patched = _patch_table(mod, optimizer) or patched
      end
   end

   return patched
end

return M
