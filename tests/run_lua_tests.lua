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
assert_eq(Config.get_profile('BALANCED').coalesce_ms, 75, 'BALANCED coalesce')

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

cache:set(key1, 'ctx', { 'ok' }, 0, false)
assert(cache:get(key1, 'ctx', 0.1, 1.0, 1.0), 'cache hit expected')
cache:invalidate('ctx')
cache:prune_context('ctx')
assert_eq(cache:get(key1, 'ctx', 0.1, 1.0, 1.0), nil, 'generation invalidation')

local counters = {}
local instrumentation = {
   inc = function(_, name)
      counters[name] = (counters[name] or 0) + 1
   end,
   observe_query_time = function() end
}

local settings = {
   get_profile_data = function()
      return Config.get_profile('SAFE')
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

local r1 = wrapped({}, { value = 5 })
assert_eq(r1[1], 5, 'first result')
local r2 = wrapped({}, { value = 5 })
assert_eq(r2[1], 5, 'cached result')
assert_eq(calls, 1, 'must hit cache on second call')
assert((counters['perfmod:cache_hits'] or 0) >= 1, 'cache hit counter')
assert((counters['perfmod:full_scan_fallbacks'] or 0) >= 1, 'fallback counter on miss')

print('All Lua tests passed')
