local MicroCache = class()

local function _clear_table(t)
   for k in pairs(t) do
      t[k] = nil
   end
end

local function _stable_hash(value, scratch, visited)
   local value_type = type(value)
   if value_type == 'nil' then
      return 'n'
   elseif value_type == 'number' or value_type == 'boolean' then
      return tostring(value)
   elseif value_type == 'string' then
      return 's:' .. value
   elseif value_type ~= 'table' then
      return value_type .. ':' .. tostring(value)
   end

   if visited[value] then
      return 'cycle'
   end

   visited[value] = true
   local keys = scratch.keys
   _clear_table(keys)

   local count = 0
   for k in pairs(value) do
      count = count + 1
      keys[count] = k
   end

   table.sort(keys, function(a, b)
      return tostring(a) < tostring(b)
   end)

   local chunks = scratch.chunks
   _clear_table(chunks)

   for i = 1, count do
      local k = keys[i]
      chunks[i] = _stable_hash(k, scratch, visited) .. '=' .. _stable_hash(value[k], scratch, visited)
   end

   visited[value] = nil
   return '{' .. table.concat(chunks, ',') .. '}'
end

function MicroCache:initialize(clock)
   self._clock = clock
   self._entries = {}
   self._generation = {}
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
   self._generation = {}
end

function MicroCache:get_generation(context)
   return self._generation[context] or 0
end

function MicroCache:make_key(filter, context, player_id, region_key)
   local visited = {}
   local filter_hash = _stable_hash(filter, self._scratch, visited)
   return table.concat({
      context or 'unknown',
      player_id or '-',
      region_key or '-',
      filter_hash
   }, '|')
end

function MicroCache:get(key, context, now, ttl, negative_ttl)
   local entry = self._entries[key]
   if not entry then
      return nil
   end

   if entry.generation ~= self:get_generation(context) then
      self._entries[key] = nil
      return nil
   end

   local age = now - entry.time
   local max_age = entry.negative and negative_ttl or ttl
   if age > max_age then
      self._entries[key] = nil
      return nil
   end

   return entry
end

function MicroCache:set(key, context, value, now, is_negative)
   self._entries[key] = {
      value = value,
      time = now,
      context = context,
      generation = self:get_generation(context),
      negative = is_negative and true or false
   }
end

function MicroCache:prune_context(context)
   if not context then
      return
   end

   for key, entry in pairs(self._entries) do
      if entry.context == context and entry.generation ~= self:get_generation(context) then
         self._entries[key] = nil
      end
   end
end

return MicroCache
