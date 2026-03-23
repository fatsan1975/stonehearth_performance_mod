local M = {}

-- filter_cache_cb bulunabilecek tüm servis yolları (pcall ile denenir, bulunamasa hata vermez)
-- ACE, base storage servisini genişletir ve kendi namespace'ine kopyalar.
-- storage_service yerine doğrudan storage namespace'i de kontrol edilir (require cache farklı olabilir).
local TARGETS = {
   'stonehearth_ace.services.server.storage.storage_service',
   'stonehearth_ace.services.server.storage',
   'stonehearth.services.server.storage.storage_service',
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
      end
   end

   return patched
end

return M
