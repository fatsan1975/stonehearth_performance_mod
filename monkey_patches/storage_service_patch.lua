local M = {}

local TARGETS = {
   'stonehearth_ace.services.server.storage.storage_service',
   'stonehearth.services.server.storage.storage_service'
}

local METHODS = {
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
   for _, method_name in ipairs(METHODS) do
      local fn = mod[method_name]
      if type(fn) == 'function' and not mod['_perfmod_wrapped_' .. method_name] then
         mod[method_name] = optimizer:wrap_query('storage', fn)
         mod['_perfmod_wrapped_' .. method_name] = true
         any = true
      end
   end

   for _, method_name in ipairs(INVALIDATION_METHODS) do
      local fn = mod[method_name]
      if type(fn) == 'function' and not mod['_perfmod_inval_' .. method_name] then
         mod[method_name] = function(self, ...)
            optimizer:mark_inventory_dirty('storage')
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
