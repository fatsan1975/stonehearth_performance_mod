-- inventory_service_patch.lua
-- Inventory invalidation event'lerini dirty marking ile sararlar.
--
-- CONDITIONAL: inventory context cache kapalıysa (default: kapalı) wrapping ATLANIR.
-- Kapalı durumda wrapping yapmak saf overhead'dir:
--   - Her item add/remove/move → mark_inventory_dirty('inventory') çağrılır
--   - Bu cache:invalidate('inventory') → generation artırır
--   - Ama hiçbir query 'inventory' context'i kullanmaz → sıfır fayda
--   - prune_context('inventory') tüm cache entry'lerini tarar, 'inventory' bulamaz → boşa iterasyon
--
-- Açık durumda: invalidation wrapping aktif, inventory query'leri cachelenebilir.

local M = {}

local TARGETS = {
   'stonehearth_ace.services.server.inventory.inventory_service',
   'stonehearth.services.server.inventory.inventory_service'
}

local INVALIDATION_METHODS = {
   'add_item',
   '_add_item',
   'remove_item',
   '_remove_item',
   'move_item',
   '_move_item',
   'set_storage_filter',
   '_set_storage_filter'
}

local function _patch_table(mod, optimizer)
   local any = false
   for _, method_name in ipairs(INVALIDATION_METHODS) do
      local fn = mod[method_name]
      if type(fn) == 'function' and not mod['_perfmod_inval_' .. method_name] then
         mod[method_name] = function(self, ...)
            optimizer:mark_inventory_dirty('inventory')
            return fn(self, ...)
         end
         mod['_perfmod_inval_' .. method_name] = true
         any = true
      end
   end
   return any
end

function M.apply(service)
   -- Inventory cache kapalıysa wrapping atla (saf overhead engellenir)
   local inv_enabled = false
   pcall(function()
      inv_enabled = service:is_context_cache_enabled('inventory')
   end)
   if not inv_enabled then
      return false
   end

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
