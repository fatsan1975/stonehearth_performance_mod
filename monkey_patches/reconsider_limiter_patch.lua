-- reconsider_limiter_patch.lua
-- PATCH 3: reconsider_entity cascade limiter
--
-- Sorun:
--   ACE'nin reconsider_entity override'? her ?a?r?da:
--     1) _add_reconsidered_entity(item) ? FAST_CALL_CACHES full sweep
--     2) container_for(item) lookup ? inventory traversal
--     3) reconsider_entity_in_filter_caches ? per-storage cache update
--     4) _add_reconsidered_entity(container) ? FAST_CALL_CACHES full sweep (tekrar!)
--   20 item burst = 40? FAST_CALL_CACHES sweep + 20? container_for lookup
--
-- ??z?m:
--   reconsider_entity seviyesinde dedup + container lookup cache:
--   1) Ayn? tick'te ayn? entity i?in tekrar reconsider ?a?r?l?rsa atla
--      (orijinal _add_reconsidered_entity de bunu yap?yor ama B?Z daha erken,
--       container_for lookup'tan ?NCE yakal?yoruz)
--   2) Container lookup sonu?lar?n? tick boyunca cache'le
--      (20 item ayn? storage'da ? 20 container_for yerine 1)
--   3) Ayn? container i?in tekrar _add_reconsidered_entity ?a?r?s?n? engelle
--
-- NOT: FAST_CALL_CACHES file-local oldu?u i?in do?rudan batch'leyemiyoruz.
--   Ama bu patch sayesinde _add_reconsidered_entity ?a?r? SAYISI azal?r,
--   dolay?s?yla FAST_CALL_CACHES sweep say?s? da azal?r.
--
-- G?venlik:
--   - Entity atlanmaz, sadece ayn? tick'teki duplikatlar engellenir
--   - Container cache her tick ba??nda temizlenir
--   - Kill-switch: config.patches.reconsider_limiter

local log = radiant.log.create_logger('perf_mod:reconsider_limiter')

local M = {}

-- Patch durumu
local _patched = false
local _original_reconsider_entity = nil

-- Tick-level dedup seti: bu tick'te zaten reconsider edilmi? entity ID'leri
local _reconsidered_this_tick = {}

-- Container lookup cache: entity_id ? container entity (veya false = yok)
local _container_cache = {}

-- Instrumentation
local _instrumentation = nil

-- ??? Tick flush ??????????????????????????????????????????????????????????
-- Her tick ba??nda ?a?r?l?r (service heartbeat'ten)
function M.flush_tick()
   -- Tablolar? wipe (reuse, yeni allocation yok)
   for k in pairs(_reconsidered_this_tick) do
      _reconsidered_this_tick[k] = nil
   end
   for k in pairs(_container_cache) do
      _container_cache[k] = nil
   end
end

-- ??? Patched reconsider_entity ???????????????????????????????????????????
-- ACE'nin reconsider_entity'sini replace eder.
-- Ayn? mant?k, ama dedup + container cache ekli.
local function _patched_reconsider_entity(self, entity, reason, reconsider_parent)
   if not entity or not entity:is_valid() then
      return
   end

   local id = entity:get_id()

   -- DEDUP: Bu tick'te zaten reconsider edildiyse atla
   -- Bu, _add_reconsidered_entity'deki dedup'tan DAHA erken yakal?yor:
   -- container_for lookup, reconsider_entity_in_filter_caches YAPILMAZ
   if _reconsidered_this_tick[id] then
      if _instrumentation then
         _instrumentation:inc('perfmod:reconsider_dedup_hits')
      end
      return
   end
   _reconsidered_this_tick[id] = true

   -- Orijinal _add_reconsidered_entity ?a?r?s? (FAST_CALL_CACHES clear dahil)
   self:_add_reconsidered_entity(entity, reason)

   -- Container lookup + reconsider (ACE mant???)
   local player_id = radiant.entities.get_player_id(entity)
   if player_id and player_id ~= '' then
      local inventory = stonehearth.inventory:get_inventory(player_id)
      if inventory and inventory.is_initialized and inventory:is_initialized() then
         -- Container cache: ayn? entity i?in container_for tekrar ?a?r?lmaz
         local container = _container_cache[id]
         if container == nil then
            -- Cache miss: ger?ek lookup yap
            container = inventory:container_for(entity) or false
            _container_cache[id] = container
         end

         if container and container ~= false then
            local container_id = container:get_id()
            local is_stockpile = container:get_component('stonehearth:stockpile')
            if not is_stockpile then
               -- ACE: storage filter cache g?ncelle
               local storage_comp = container:get_component('stonehearth:storage')
               if storage_comp then
                  pcall(storage_comp.reconsider_entity_in_filter_caches, storage_comp, id, entity)
               end

               -- Container i?in dedup kontrol?
               if not _reconsidered_this_tick[container_id] then
                  _reconsidered_this_tick[container_id] = true
                  self:_add_reconsidered_entity(container, reason .. '(also triggering container)')
               end
            end
         end
      end
   end

   if reconsider_parent then
      local parent = radiant.entities.get_parent(entity)
      if parent and parent:get_id() ~= radiant._root_entity_id then
         local parent_id = parent:get_id()
         if not _reconsidered_this_tick[parent_id] then
            _reconsidered_this_tick[parent_id] = true
            self:_add_reconsidered_entity(parent, reason .. '(reconsider_parent)')
         end
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
   end

   local ok, err = pcall(function()
      local ai_service = stonehearth.ai

      -- ACE'nin reconsider_entity override'?n? sakla
      _original_reconsider_entity = ai_service.reconsider_entity

      -- Patch uygula
      ai_service.reconsider_entity = _patched_reconsider_entity

      _patched = true
   end)

   if not ok then
      log:error('PATCH 3 (reconsider_limiter) failed: %s ? falling back to original', tostring(err))
      M.restore()
      return false
   end

   log:info('PATCH 3 applied: reconsider_limiter (dedup + container cache)')
   return true
end

function M.restore()
   if not _patched then
      return
   end

   pcall(function()
      local ai_service = stonehearth.ai
      if _original_reconsider_entity then
         ai_service.reconsider_entity = _original_reconsider_entity
      end
   end)

   _patched = false
   _original_reconsider_entity = nil
   M.flush_tick()

   log:info('PATCH 3 restored: reconsider_limiter')
end

function M.is_patched()
   return _patched
end

-- Global registration (Stonehearth require return degerini iletmiyor)
_G.perf_mod_patches = _G.perf_mod_patches or {}
_G.perf_mod_patches.reconsider_limiter = M

return M
