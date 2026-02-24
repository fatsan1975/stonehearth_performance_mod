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

assert_eq(Config.get_profile('SAFE').query_deadline_ms, 8, 'SAFE deadline')
assert_eq(Config.get_profile('BALANCED').coalesce_ms, 45, 'BALANCED coalesce')
assert_eq(Config.get_profile('AGGRESSIVE').max_cache_entries, 2600, 'AGGRESSIVE cache cap')
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

local deep = { a = { b = { c = { d = 1 } } } }
local deep_key = cache:make_key(deep, 'ctx', 'p1', nil)
assert_eq(deep_key, nil, 'deep filter should bypass cache keying')

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
      local p = Config.get_profile('BALANCED')
      return {
         id = p.id,
         cache_ttl = p.cache_ttl,
         negative_ttl = p.negative_ttl,
         coalesce_ms = p.coalesce_ms,
         incremental_budget_ms = p.incremental_budget_ms,
         query_deadline_ms = p.query_deadline_ms,
         deferred_wait_ms = p.deferred_wait_ms,
         max_candidates_to_hook = p.max_candidates_to_hook,
         max_cache_entries = p.max_cache_entries,
         max_cached_result_size = p.max_cached_result_size,
         admit_after_hits = p.admit_after_hits,
         urgent_cache_bypass = p.urgent_cache_bypass,
         ai_path_cache_bypass = p.ai_path_cache_bypass,
         noisy_signature_limit = p.noisy_signature_limit,
         cache_negative_results = p.cache_negative_results,
         circuit_failures = 2,
         circuit_window_s = 9999,
         circuit_open_s = 9999
      }
   end,
   is_context_cache_enabled = function(_, context)
      return context ~= 'disabled'
   end,
   is_warm_resume_guard_active = function() return false end
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

local context_calls = 0
local context_bypass = optimizer:wrap_query('disabled', function() context_calls = context_calls + 1 return { 'x' } end)
context_bypass({}, { value = 1 })
context_bypass({}, { value = 1 })
assert_eq(context_calls, 2, 'disabled context should bypass cache')
assert((counters['perfmod:context_bypasses'] or 0) >= 1, 'context bypass counter')

local urgent_calls = 0
local urgent_wrapped = optimizer:wrap_query('inventory', function(_, filter)
   urgent_calls = urgent_calls + 1
   return { filter.value }
end)
urgent_wrapped({}, { value = 10 })
urgent_wrapped({}, { value = 10 })
assert_eq(urgent_calls, 2, 'urgent inventory path should bypass cache')
assert((counters['perfmod:urgent_bypasses'] or 0) >= 1, 'urgent bypass counter')

local ai_calls = 0
local ai_wrapped = optimizer:wrap_query('storage', function(_, filter)
   ai_calls = ai_calls + 1
   return { filter.value or 1 }
end)
ai_wrapped({}, { path = 'x', value = 1 })
ai_wrapped({}, { path = 'x', value = 1 })
assert_eq(ai_calls, 2, 'ai/path queries should bypass cache')
assert((counters['perfmod:ai_path_bypasses'] or 0) >= 1, 'ai/path bypass counter')

local noisy_calls = 0
local noisy_wrapped = optimizer:wrap_query('ctx', function(_, filter)
   noisy_calls = noisy_calls + 1
   return { filter.value or 1 }
end)
noisy_wrapped({}, { location = 1, nav_grid = 2, traversal = 3, planner = 4, value = 9 }, { location = 99 })
noisy_wrapped({}, { location = 1, nav_grid = 2, traversal = 3, planner = 4, value = 9 }, { location = 99 })
assert_eq(noisy_calls, 2, 'noisy signatures should bypass cache')
assert((counters['perfmod:noisy_signature_bypasses'] or 0) >= 1, 'noisy bypass counter')

local fail_calls = 0
local fail_wrapped = optimizer:wrap_query('ctx', function(_, _)
   fail_calls = fail_calls + 1
   return { 'ok' }
end)
cache.make_key = function() error('boom') end
local sf = fail_wrapped({}, { any = true })
assert_eq(sf[1], 'ok', 'safety fallback returns original result')
assert_eq(fail_calls, 1, 'original called on safety fallback')
assert((counters['perfmod:safety_fallbacks'] or 0) >= 1, 'safety fallback counter')

print('All Lua tests passed')
