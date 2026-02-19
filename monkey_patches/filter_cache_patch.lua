local M = {}

local TARGETS = {
   'stonehearth_ace.ai',
   'stonehearth.ai',
   'stonehearth_ace.services.server.storage',
   'stonehearth.services.server.storage'
}

local function _try_patch_named_function(mod, optimizer, context, fn_name)
   local fn = mod and mod[fn_name]
   if type(fn) ~= 'function' then
      return false
   end

   local key = '_perfmod_wrapped_' .. fn_name
   if mod[key] then
      return false
   end

   mod[fn_name] = optimizer:wrap_query(context, fn)
   mod[key] = true
   return true
end

function M.apply(service)
   local optimizer = service:get_optimizer()
   local patched = false

   for _, path in ipairs(TARGETS) do
      local ok, mod = pcall(require, path)
      if ok and type(mod) == 'table' then
         patched = _try_patch_named_function(mod, optimizer, 'filter', 'filter_cache_cb') or patched
         patched = _try_patch_named_function(mod, optimizer, 'filter', 'apply_filter') or patched
         patched = _try_patch_named_function(mod, optimizer, 'filter', 'make_filter') or patched
      end
   end

   return patched
end

return M
