package.path = './?.lua;./?/init.lua;' .. package.path

function class()
   local c = {}
   c.__index = c
   setmetatable(c, {
      __call = function(cls, ...)
         local self = setmetatable({}, cls)
         if self.initialize then
            self:initialize(...)
         end
         return self
      end
   })
   return c
end

local function assert_eq(actual, expected, msg)
   if actual ~= expected then
      error((msg or 'assert_eq failed') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual))
   end
end

local Config = require 'scripts.perf_mod.config'
local MicroCache = require 'scripts.perf_mod.micro_cache'
local QueryOptimizer = require 'scripts.perf_mod.query_optimizer'

assert_eq(Config.get_profile('SAFE').query_deadline_ms, 10, 'SAFE deadline')
assert_eq(Config.get_profile('BALANCED').coalesce_ms, 60, 'BALANCED coalesce')
assert_eq(Config.get_profile('AGGRESSIVE').max_cache_entries, 3200, 'AGGRESSIVE cache cap')
assert_eq(Config.get_profile('BALANCED').admit_after_hits, 2, 'admission threshold')

local fake_clock = {
   now = 0,
   get_realtime_seconds = function(self)
      return self.now
   end,
   get_elapsed_ms = function(self, start)
      return (self.now - start) * 1000
   end
}

local cache = MicroCache(fake_clock)
cache:initialize(fake_clock)
local key1 = cache:make_key({ a = 1, b = 2 }, 'ctx', 'p1', nil)
local key2 = cache:make_key({ b = 2, a = 1 }, 'ctx', 'p1', nil)
assert_eq(key1, key2, 'stable key order')
local key3 = cache:make_key({ a = 1, b = 2 }, 'ctx', 'p1', nil, { q = 1 })
local key4 = cache:make_key({ a = 1, b = 2 }, 'ctx', 'p1', nil, { q = 2 })
assert(key3 ~= key4, 'extra key must affect cache key')

cache:set(key1, 'ctx', { 'ok' }, 0, false)
assert(cache:get(key1, 'ctx', 0.1, 1.0, 1.0), 'cache hit expected')
cache:invalidate('ctx')
cache:prune_context('ctx')
assert_eq(cache:get(key1, 'ctx', 0.1, 1.0, 1.0), nil, 'generation invalidation')

for i = 1, 25 do
   cache:set('k' .. i, 'ctx', { i }, i, false, 20)
end
assert(cache._entry_count <= 20, 'cache cap pruning expected')

local counters = {}
local instrumentation = {
   inc = function(_, name)
      counters[name] = (counters[name] or 0) + 1
   end,
   observe_query_time = function() end
}

local settings = {
   get_profile_data = function()
      return Config.get_profile('BALANCED')
   end
}

local optimizer = QueryOptimizer()
optimizer:initialize(fake_clock, cache, {
   mark_dirty = function() end
}, instrumentation, settings, {})

local calls = 0
local wrapped = optimizer:wrap_query('ctx', function(_, filter)
   calls = calls + 1
   return { filter.value }
end)

local target = {}
local r1 = wrapped(target, { value = 5 })
assert_eq(r1[1], 5, 'first result')
local r2 = wrapped(target, { value = 5 })
assert_eq(r2[1], 5, 'second result')
local r3 = wrapped(target, { value = 5 })
assert_eq(r3[1], 5, 'third result')
assert_eq(calls, 2, 'admission should skip first cache write')
assert((counters['perfmod:admission_skips'] or 0) >= 1, 'admission skip counter')
assert((counters['perfmod:cache_hits'] or 0) >= 1, 'cache hit counter')

local arg_calls = 0
local wrapped_with_arg = optimizer:wrap_query('ctx', function(_, filter, need)
   arg_calls = arg_calls + 1
   return { filter.value + (need or 0) }
end)

local arg_target = {}
local a1 = wrapped_with_arg(arg_target, { value = 7 }, 1)
local a2 = wrapped_with_arg(arg_target, { value = 7 }, 2)
assert_eq(a1[1], 8, 'arg variant 1')
assert_eq(a2[1], 9, 'arg variant 2')
assert_eq(arg_calls, 2, 'different args should not collide in cache')

local neg_calls = 0
local neg_wrapped = optimizer:wrap_query('storage', function(_, _)
   neg_calls = neg_calls + 1
   return nil
end)
optimizer:mark_inventory_dirty('storage')
neg_wrapped({}, { need = 'x' })
neg_wrapped({}, { need = 'x' })
assert_eq(neg_calls, 2, 'dirty context should bypass negative cache')

local urgent_calls = 0
local urgent_wrapped = optimizer:wrap_query('inventory', function(_, filter)
   urgent_calls = urgent_calls + 1
   return { filter.value }
end)
urgent_wrapped({}, { value = 10 })
urgent_wrapped({}, { value = 10 })
assert_eq(urgent_calls, 2, 'urgent inventory path should bypass cache')
assert((counters['perfmod:urgent_bypasses'] or 0) >= 1, 'urgent bypass counter')

print('All Lua tests passed')
