local M = {}

local TARGETS = {
   'stonehearth_ace.services.server.inventory.inventory_service',
   'stonehearth.services.server.inventory.inventory_service'
}

local METHODS = {}

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
   for _, method_name in ipairs(METHODS) do
      local fn = mod[method_name]
      if type(fn) == 'function' and not mod['_perfmod_wrapped_' .. method_name] then
         mod[method_name] = optimizer:wrap_query('inventory', fn)
         mod['_perfmod_wrapped_' .. method_name] = true
         any = true
      end
   end

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
