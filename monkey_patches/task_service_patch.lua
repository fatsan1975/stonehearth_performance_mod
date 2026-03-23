-- task_service_patch.lua
-- SADECE invalidasyon: task tamamlandığında filter cache nesli ilerletir.
-- Cache wrapping YOK — task assignment sonuçları asla cachelenmiyor.
-- Güvenlik: pcall ile sarılı, başarısız olursa orijinal davranış korunur.
local M = {}

local TARGETS = {
   'stonehearth_ace.services.server.tasks.task_service',
   'stonehearth.services.server.tasks.task_service'
}

-- Yalnızca "task bitti/iptal/başarısız" metodları — bunlar çalışırken
-- item pozisyonları değişmiş olabilir, filter cache güncel değildir.
local INVALIDATION_METHODS = {
   'complete_task',
   '_complete_task',
   'cancel_task',
   '_cancel_task',
   'fail_task',
   '_fail_task'
}

local function _patch_table(mod, optimizer, instrumentation)
   local any = false
   for _, method_name in ipairs(INVALIDATION_METHODS) do
      local fn = mod[method_name]
      if type(fn) == 'function' and not mod['_perfmod_taskinval_' .. method_name] then
         mod[method_name] = function(self, ...)
            -- Filter context: task durumu değişti → coalesced invalidation
            -- Burst durumunda (art arda biten task'lar) yalnızca bir kez invalidate eder
            optimizer:mark_task_dirty('filter')
            instrumentation:inc('perfmod:task_invalidations')
            return fn(self, ...)
         end
         mod['_perfmod_taskinval_' .. method_name] = true
         any = true
      end
   end
   return any
end

function M.apply(service)
   local optimizer = service:get_optimizer()
   local instrumentation = service:get_instrumentation()
   local patched = false

   for _, path in ipairs(TARGETS) do
      local ok, mod = pcall(require, path)
      if ok and type(mod) == 'table' then
         patched = _patch_table(mod, optimizer, instrumentation) or patched
      end
   end

   return patched
end

return M
