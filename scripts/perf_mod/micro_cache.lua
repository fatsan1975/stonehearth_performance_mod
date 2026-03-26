local MicroCache = class()

local MAX_HASH_DEPTH = 3
local MAX_HASH_KEYS = 24

local _EMPTY_ARGS_HASH = '{s:count=0}'

local function _clear_table(t)
   for k in pairs(t) do
      t[k] = nil
   end
end

local function _fast_hash_or_nil(filter, scratch)
   local keys = scratch.keys
   _clear_table(keys)

   local count = 0
   for k, v in pairs(filter) do
      count = count + 1
      if count > 4 then return nil end
      if type(k) ~= 'string' then return nil end
      local vt = type(v)
      if vt ~= 'string' and vt ~= 'number' and vt ~= 'boolean' then return nil end
      keys[count] = k
   end

   if count == 0 then return '{}' end

   table.sort(keys, function(a, b) return a < b end)

   local chunks = scratch.chunks
   _clear_table(chunks)

   for i = 1, count do
      local k = keys[i]
      local v = filter[k]
      local vt = type(v)
      local vr
      if vt == 'string' then vr = 's:' .. v
      else vr = tostring(v) end
      chunks[i] = k .. '=' .. vr
   end

   return '{' .. table.concat(chunks, ',') .. '}'
end

local function _stable_hash(value, scratch, visited, depth)
   local value_type = type(value)
   if value_type == 'nil' then
      return 'n', true
   elseif value_type == 'number' or value_type == 'boolean' then
      return tostring(value), true
   elseif value_type == 'string' then
      return 's:' .. value, true
   elseif value_type ~= 'table' then
      return value_type .. ':' .. tostring(value), false
   end

   if depth >= MAX_HASH_DEPTH then
      return nil, false
   end

   if visited[value] then
      return 'cycle', true
   end

   visited[value] = true
   local keys = scratch.keys
   _clear_table(keys)

   local count = 0
   for k in pairs(value) do
      count = count + 1
      if count > MAX_HASH_KEYS then
         visited[value] = nil
         return nil, false
      end
      keys[count] = k
   end

   table.sort(keys, function(a, b)
      return tostring(a) < tostring(b)
   end)

   local chunks = scratch.chunks
   _clear_table(chunks)

   for i = 1, count do
      local k = keys[i]
      local kh, kok = _stable_hash(k, scratch, visited, depth + 1)
      local vh, vok = _stable_hash(value[k], scratch, visited, depth + 1)
      if not kok or not vok then
         visited[value] = nil
         return nil, false
      end
      chunks[i] = kh .. '=' .. vh
   end

   visited[value] = nil
   return '{' .. table.concat(chunks, ',') .. '}', true
end

function MicroCache:initialize(clock)
   self._clock = clock
   self._entries = {}
   self._entry_count = 0
   self._generation = {}
   self._seen_keys = {}
   self._seen_count = 0
   self._scratch = {
      keys = {},
      chunks = {},
      visited = {}
   }
end

function MicroCache:invalidate(context)
   if context then
      self._generation[context] = (self._generation[context] or 0) + 1
      return
   end

   self._entries = {}
   self._entry_count = 0
   self._generation = {}
   self._seen_keys = {}
   self._seen_count = 0
end

function MicroCache:get_generation(context)
   return self._generation[context] or 0
end

function MicroCache:make_key(filter, context, player_id, region_key, extra_key)
   local filter_hash
   local fast_path = false

   if type(filter) == 'table' then
      local fast = _fast_hash_or_nil(filter, self._scratch)
      if fast then
         filter_hash = fast
         fast_path = true
      end
   end

   if not fast_path then
      local visited = self._scratch.visited
      _clear_table(visited)
      local filter_ok
      filter_hash, filter_ok = _stable_hash(filter, self._scratch, visited, 0)
      if not filter_ok then
         return nil
      end
   end

   local extra_hash
   if type(extra_key) == 'table' and (extra_key.count == 0 or extra_key.n == 0) then
      extra_hash = _EMPTY_ARGS_HASH
   else
      local visited = self._scratch.visited
      _clear_table(visited)
      local extra_ok
      extra_hash, extra_ok = _stable_hash(extra_key, self._scratch, visited, 0)
      if not extra_ok then
         return nil
      end
   end

   return table.concat({
      context or 'unknown',
      player_id or '-',
      region_key or '-',
      filter_hash,
      extra_hash
   }, '|'), fast_path
end

function MicroCache:touch_key(key, max_seen)
   local hit_count = (self._seen_keys[key] or 0) + 1
   if self._seen_keys[key] == nil then
      self._seen_count = self._seen_count + 1
   end
   self._seen_keys[key] = hit_count

   if max_seen and self._seen_count > max_seen then
      self._seen_keys = {}
      self._seen_count = 0
      self._seen_keys[key] = 1
      self._seen_count = 1
      return 1
   end

   return hit_count
end

function MicroCache:get(key, context, now, ttl, negative_ttl)
   local entry = self._entries[key]
   if not entry then
      return nil
   end

   if entry.generation ~= self:get_generation(context) then
      self._entries[key] = nil
      self._entry_count = math.max(0, self._entry_count - 1)
      return nil
   end

   local age = now - entry.time
   local max_age = entry.negative and negative_ttl or ttl
   if age > max_age then
      self._entries[key] = nil
      self._entry_count = math.max(0, self._entry_count - 1)
      return nil
   end

   return entry
end

function MicroCache:set(key, context, value, now, is_negative, max_entries)
   if not self._entries[key] then
      self._entry_count = self._entry_count + 1
   end

   self._entries[key] = {
      value = value,
      time = now,
      context = context,
      generation = self:get_generation(context),
      negative = is_negative and true or false
   }

   if max_entries and self._entry_count > max_entries then
      self:_prune_approx_oldest(math.max(1, math.min(8, math.floor(max_entries * 0.02))))
   end
end

function MicroCache:_prune_approx_oldest(remove_count)
   local removed = 0
   for key, entry in pairs(self._entries) do
      if entry.generation ~= self:get_generation(entry.context) then
         self._entries[key] = nil
         self._entry_count = math.max(0, self._entry_count - 1)
         removed = removed + 1
         if removed >= remove_count then
            return
         end
      end
   end

   local need = remove_count - removed
   if need <= 0 then return end

   local candidates = {}
   local scanned = 0
   for key, entry in pairs(self._entries) do
      candidates[#candidates + 1] = { t = entry.time, k = key }
      scanned = scanned + 1
      if scanned >= 512 then break end
   end

   if #candidates == 0 then return end

   table.sort(candidates, function(a, b) return a.t < b.t end)

   for i = 1, math.min(need, #candidates) do
      local k = candidates[i].k
      if self._entries[k] then
         self._entries[k] = nil
         self._entry_count = math.max(0, self._entry_count - 1)
      end
   end
end

function MicroCache:prune_context(context)
   if not context then
      return
   end

   for key, entry in pairs(self._entries) do
      if entry.context == context and entry.generation ~= self:get_generation(context) then
         self._entries[key] = nil
         self._entry_count = math.max(0, self._entry_count - 1)
      end
   end
end

return MicroCache
