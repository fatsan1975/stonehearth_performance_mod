local MicroCache = class()

local MAX_HASH_DEPTH = 3
local MAX_HASH_KEYS = 24

local function _clear_table(t)
   for k in pairs(t) do
      t[k] = nil
   end
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
      chunks = {}
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
   local visited = {}
   local filter_hash, filter_ok = _stable_hash(filter, self._scratch, visited, 0)
   if not filter_ok then
      return nil
   end

   local extra_hash, extra_ok = _stable_hash(extra_key, self._scratch, visited, 0)
   if not extra_ok then
      return nil
   end

   return table.concat({
      context or 'unknown',
      player_id or '-',
      region_key or '-',
      filter_hash,
      extra_hash
   }, '|')
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
   local oldest_key = nil
   local oldest_time = nil

   for _ = 1, remove_count do
      oldest_key = nil
      oldest_time = nil
      local scanned = 0
      for key, entry in pairs(self._entries) do
         scanned = scanned + 1
         if oldest_time == nil or entry.time < oldest_time then
            oldest_time = entry.time
            oldest_key = key
         end
         if scanned >= 512 then
            break
         end
      end

      if oldest_key == nil then
         return
      end

      self._entries[oldest_key] = nil
      self._entry_count = math.max(0, self._entry_count - 1)
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
