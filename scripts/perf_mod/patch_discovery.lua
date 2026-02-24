local PatchDiscovery = class()

local KNOWN_STRINGS = {
   'filter_cache_cb', 'filter_cache', 'entity_filter', 'make_filter', 'apply_filter',
   'find_items', 'find_best', 'get_items', 'get_matching_items',
   'inventory', 'storage', 'stockpile', 'container', 'item_tracker',
   'ai.filter', 'ai.filters', 'filter_fn', 'filterer', 'cached_filter',
   'query', 'search', 'matcher', 'predicate',
   'stonehearth.inventory', 'stonehearth.storage', 'stonehearth:storage', 'stonehearth:inventory'
}

local DISCOVERY_METHOD_HINTS = {
   filter_cache_cb = true,
   get_matching_items = true,
   get_items = true,
   find_items = true,
   find_best = true
}

local KNOWN_MODULE_CANDIDATES = {
   'stonehearth_ace.services.server.storage',
   'stonehearth_ace.services.server.inventory',
   'stonehearth_ace.monkey_patches',
   'stonehearth_ace.ai',
   'stonehearth.services.server.storage',
   'stonehearth.services.server.inventory',
   'stonehearth.ai',
   'stonehearth.lib'
}

local function _contains_any(text, strings)
   if type(text) ~= 'string' then
      return false
   end

   for _, needle in ipairs(strings) do
      if string.find(text, needle, 1, true) then
         return true
      end
   end

   return false
end

local function _allowed_module(name)
   return type(name) == 'string' and (string.sub(name, 1, 11) == 'stonehearth' or string.sub(name, 1, 15) == 'stonehearth_ace')
end

local function _upvalue_hint(fn)
   for i = 1, 8 do
      local up_name = debug.getupvalue(fn, i)
      if not up_name then
         return false
      end
      if _contains_any(up_name, KNOWN_STRINGS) then
         return true
      end
   end
   return false
end


local function _infer_context(module_name, key)
   local hay = (tostring(module_name) .. ':' .. tostring(key)):lower()
   if string.find(hay, 'inventory', 1, true) then
      return 'inventory'
   end
   if string.find(hay, 'storage', 1, true) or string.find(hay, 'stockpile', 1, true) then
      return 'storage'
   end
   return 'filter'
end

function PatchDiscovery:initialize(optimizer, service, instrumentation, log)
   self._optimizer = optimizer
   self._service = service
   self._instrumentation = instrumentation
   self._log = log
   self._hooks = {}
end

function PatchDiscovery:run()
   self:_prime_known_candidates()

   local ranked = {}
   for module_name, module_value in pairs(package.loaded) do
      if _allowed_module(module_name) and type(module_value) == 'table' then
         self:_scan_table(module_name, module_value, ranked)
      end
   end

   table.sort(ranked, function(a, b)
      return a.rank > b.rank
   end)

   local max_hooks = self._service:get_profile_data().max_candidates_to_hook
   local hooked = 0
   for _, candidate in ipairs(ranked) do
      if hooked >= max_hooks then
         break
      end

      if self:_hook_candidate(candidate) then
         hooked = hooked + 1
      end
   end

   self._log:info('Discovery mode found %s candidates; hooked %s', #ranked, hooked)
end

function PatchDiscovery:_prime_known_candidates()
   for _, path in ipairs(KNOWN_MODULE_CANDIDATES) do
      pcall(require, path)
   end
end

function PatchDiscovery:_scan_table(module_name, table_value, ranked)
   for key, value in pairs(table_value) do
      if type(value) == 'function' then
         local info = debug.getinfo(value, 'nSu')
         local name = info.name or tostring(key)
         local src = info.short_src or ''
         local rank = 0

         if info.what ~= 'Lua' then
            rank = 0
         elseif (info.nparams or 0) < 1 then
            rank = 0
         elseif name == 'filter_cache_cb' or string.find(src, 'filter_cache_cb', 1, true) then
            rank = rank + 100
         end
         if _contains_any(name, KNOWN_STRINGS) then
            rank = rank + 20
         end
         if _contains_any(src, KNOWN_STRINGS) then
            rank = rank + 10
         end
         if _contains_any(module_name, KNOWN_STRINGS) then
            rank = rank + 10
         end
         if _upvalue_hint(value) then
            rank = rank + 15
         end

         local key_s = tostring(key)
         local key_l = string.lower(key_s)
         if rank > 0
            and DISCOVERY_METHOD_HINTS[key_s]
            and not string.find(key_l, 'new', 1, true)
            and not string.find(key_l, 'initialize', 1, true)
            and not string.find(key_l, 'make_filter', 1, true)
            and not string.find(key_l, 'apply_filter', 1, true) then
            ranked[#ranked + 1] = {
               module_name = module_name,
               table_value = table_value,
               key = key,
               fn = value,
               rank = rank
            }
         end
      end
   end
end

function PatchDiscovery:_hook_candidate(candidate)
   if self._hooks[candidate.fn] then
      return false
   end

   local ok, wrapped = pcall(function()
      local context = _infer_context(candidate.module_name, candidate.key)
      return self._optimizer:wrap_query(context, candidate.fn)
   end)

   if not ok then
      self._log:error('Failed to wrap discovery candidate %s.%s: %s', candidate.module_name, tostring(candidate.key), tostring(wrapped))
      return false
   end

   candidate.table_value[candidate.key] = wrapped
   self._hooks[candidate.fn] = true
   self._log:info('Discovery hook applied: %s.%s (rank=%s)', candidate.module_name, tostring(candidate.key), candidate.rank)
   return true
end

return PatchDiscovery
