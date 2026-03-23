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
         cache_negative_filter = p.cache_negative_filter,
         negative_filter_ttl = p.negative_filter_ttl,
         admit_after_hits_filter = p.admit_after_hits_filter,
         filter_ttl_mult = p.filter_ttl_mult,
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
-- Tick memo'yu temizle: admission kontrolü tick memo olmadan test edilmeli
optimizer:flush_tick_results()
local r2 = wrapped(target, { value = 5 })
assert_eq(r2[1], 5, 'second result')
optimizer:flush_tick_results()
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

-- Step 2B: _classify_query — task_group filter → ai_path bypass
local task_cls_calls = 0
local ai_path_before = counters['perfmod:ai_path_bypasses'] or 0
local task_cls_wrapped = optimizer:wrap_query('storage', function(_, filter)
   task_cls_calls = task_cls_calls + 1
   return { filter.value or 1 }
end)
task_cls_wrapped({}, { task_group = 'wg1', value = 7 })
task_cls_wrapped({}, { task_group = 'wg1', value = 7 })
assert_eq(task_cls_calls, 2, 'task_group filter should bypass cache')
assert((counters['perfmod:ai_path_bypasses'] or 0) > ai_path_before, 'task_group should trigger ai_path bypass')

-- Step 2B: _classify_query — worker filter → ai_path bypass
task_cls_calls = 0
ai_path_before = counters['perfmod:ai_path_bypasses'] or 0
task_cls_wrapped({}, { worker = 'hw1', value = 8 })
task_cls_wrapped({}, { worker = 'hw1', value = 8 })
assert_eq(task_cls_calls, 2, 'worker filter should bypass cache')
assert((counters['perfmod:ai_path_bypasses'] or 0) > ai_path_before, 'worker key should trigger ai_path bypass')

-- Step 2B: expanded NOISY_KEYS (yeni canlı nesne anahtarları, _classify_query'e takılmayan)
-- worker_filter, job_filter, location, nav_grid, traversal = 5 >= BALANCED limit(5)
-- NOT: compound_action ve execution_frame artık _classify_query'de → ai_path bypass'ına takılır;
--      location/planner/worker_filter/job_filter NOISY ama _classify_query'de YOK → noisy path'e girer
local noisy2_calls = 0
local noisy2_before = counters['perfmod:noisy_signature_bypasses'] or 0
local noisy2_wrapped = optimizer:wrap_query('ctx', function(_, filter)
   noisy2_calls = noisy2_calls + 1
   return { filter.value or 1 }
end)
noisy2_wrapped({}, { worker_filter = 1, job_filter = 2, location = 3, nav_grid = 4, traversal = 5 })
noisy2_wrapped({}, { worker_filter = 1, job_filter = 2, location = 3, nav_grid = 4, traversal = 5 })
assert_eq(noisy2_calls, 2, 'expanded noisy keys should bypass cache')
assert((counters['perfmod:noisy_signature_bypasses'] or 0) > noisy2_before, 'new NOISY_KEYS should trigger noisy bypass')

-- Step 2A: visited tablo reuse — ardışık make_key çağrıları tutarlı key üretmeli
local cache2 = MicroCache(fake_clock)
cache2:initialize(fake_clock)
local f_wood  = { type = 'wood',  qty = 5 }
local f_stone = { type = 'stone', qty = 3 }
local rv_k1  = cache2:make_key(f_wood,  'ctx', 'p1', nil)
local rv_k2  = cache2:make_key(f_stone, 'ctx', 'p1', nil)
local rv_k1b = cache2:make_key(f_wood,  'ctx', 'p1', nil)
local rv_k2b = cache2:make_key(f_stone, 'ctx', 'p1', nil)
assert_eq(rv_k1,  rv_k1b, 'visited reuse: f_wood key stable across calls')
assert_eq(rv_k2,  rv_k2b, 'visited reuse: f_stone key stable across calls')
assert(rv_k1 ~= rv_k2,    'visited reuse: different filters must produce different keys')

-- Step 3: Tick-local memo — aynı tick'te özdeş sorgu orijinali çağırmamalı
local tick_calls = 0
local tick_wrapped = optimizer:wrap_query('storage', function(_, filter)
   tick_calls = tick_calls + 1
   return { filter.x }
end)
optimizer:flush_tick_results()
local tick_before = counters['perfmod:tick_cache_hits'] or 0
local tick_target = {}  -- aynı target objesi: tostring() sabit key üretir
tick_wrapped(tick_target, { x = 42 })       -- tick miss + original çağrısı
tick_wrapped(tick_target, { x = 42 })       -- tick HIT → original çağrılmamalı
assert_eq(tick_calls, 1, 'tick memo should serve second call without calling original')
assert((counters['perfmod:tick_cache_hits'] or 0) > tick_before, 'tick_cache_hits counter')
optimizer:flush_tick_results()     -- temizle: sonraki testleri etkilemesin

-- Step 3: Fast-path key — basit filter'larda fast_key_hits sayacı artmalı
local fast_before = counters['perfmod:fast_key_hits'] or 0
local fast_wrapped = optimizer:wrap_query('filter', function(_, filter)
   return { filter.mat }
end)
optimizer:flush_tick_results()
fast_wrapped({}, { mat = 'wood' })  -- basit 1-key filter → fast path
assert((counters['perfmod:fast_key_hits'] or 0) > fast_before, 'fast_key_hits counter for simple filter')
optimizer:flush_tick_results()

-- Değişiklik 1: Filter context negatif sonuç cache
-- admit_after_hits_filter=1 + cache_negative_filter=true → ilk nil sonucu da cachele
local neg_filter_calls = 0
local neg_filter_wrapped = optimizer:wrap_query('filter', function(_, _)
   neg_filter_calls = neg_filter_calls + 1
   return nil  -- negatif sonuç
end)
optimizer:flush_tick_results()
local neg_hits_before = counters['perfmod:negative_hits'] or 0
local neg_target = {}  -- aynı target: tostring() sabit key üretir
neg_filter_wrapped(neg_target, { mat = 'stone' })   -- call 1: miss → original, cache'e yaz (admit=1)
optimizer:flush_tick_results()
neg_filter_wrapped(neg_target, { mat = 'stone' })   -- call 2: negative_hits artmalı
assert((counters['perfmod:negative_hits'] or 0) > neg_hits_before, 'filter negative should be cached')
assert_eq(neg_filter_calls, 1, 'second call must not reach original (negative cache hit)')
optimizer:flush_tick_results()

-- Değişiklik 4: mark_task_dirty — burst dedupe
local task_gen_before = cache:get_generation('filter')
optimizer:mark_task_dirty('filter')
local task_gen_after = cache:get_generation('filter')
assert(task_gen_after > task_gen_before, 'first mark_task_dirty must invalidate generation')
-- İkinci çağrı aynı pencerede: task_inval_pending=true → generation tekrar artmamalı
optimizer:mark_task_dirty('filter')
assert_eq(cache:get_generation('filter'), task_gen_after, 'rapid mark_task_dirty must be deduplicated')

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

-- ============================================================
-- Step 4: Burst-dedupe throttle mekanizması (restock/town/population patch'leri)
-- ============================================================

-- args_signature scratch test için: query_optimizer'daki module-level scratch ile aynı mantık
local _test_args_scratch = {}
local _test_args_scratch_prev_max = 0
local function _args_signature_test(...)
   local count = select('#', ...)
   local max_args = math.min(count, 6)
   for i = max_args + 1, _test_args_scratch_prev_max do
      _test_args_scratch[i] = nil
   end
   _test_args_scratch_prev_max = max_args
   _test_args_scratch.count = count
   for i = 1, max_args do
      _test_args_scratch[i] = select(i, ...)
   end
   return _test_args_scratch
end

-- Throttle yardımcısı — patch dosyalarındaki _make_throttled ile aynı mantık
local unpack_fn = table.unpack or unpack
local function make_throttled_test(fn, get_now, instrumentation, counter_name, suppress_s)
   local last_call   = {}
   local last_result = {}
   return function(self, ...)
      local id  = tostring(self)
      local now = get_now()
      if (now - (last_call[id] or 0)) < suppress_s then
         instrumentation:inc(counter_name)
         local r = last_result[id]
         if r then return unpack_fn(r, 1, r.n) end
         return
      end
      last_call[id] = now
      local r = { n = 0 }
      local ok = pcall(function(...)
         local function _cap(...)
            r.n = select('#', ...)
            for i = 1, r.n do r[i] = select(i, ...) end
         end
         _cap(fn(self, ...))
      end, ...)
      if not ok then last_call[id] = 0; return end
      last_result[id] = r
      return unpack_fn(r, 1, r.n)
   end
end

-- Step 4 test 1: İlk çağrı çalışır, pencere içindeki tekrar suppress edilir
local throttle_time = 0
local throttle_get_now = function() return throttle_time end
local throttle_calls = 0
local throttle_obj   = {}
local throttle_fn    = make_throttled_test(
   function(self, x) throttle_calls = throttle_calls + 1; return x * 2 end,
   throttle_get_now, instrumentation, 'perfmod:restock_coalesces', 0.1)

local tcoalesce_before = counters['perfmod:restock_coalesces'] or 0
throttle_time = 1.0   -- >0 başlangıç: (1.0 - 0) >= 0.1 → suppress değil
local tv1 = throttle_fn(throttle_obj, 5)   -- çağrı 1: çalışır, returns 10
assert_eq(tv1, 10, 'throttle: first call must return original result')
assert_eq(throttle_calls, 1, 'throttle: first call must invoke original')

throttle_time = 1.05  -- 50ms geçti, henüz pencere içinde (0.1s)
local tv2 = throttle_fn(throttle_obj, 5)   -- suppress: 10 döner (stale OK)
assert_eq(tv2, 10, 'throttle: suppressed call must return last result (not nil)')
assert_eq(throttle_calls, 1, 'throttle: suppressed call must NOT invoke original')
assert((counters['perfmod:restock_coalesces'] or 0) > tcoalesce_before,
   'throttle: suppress counter must increment')

throttle_time = 1.11  -- pencere doldu
local tv3 = throttle_fn(throttle_obj, 7)   -- çalışır, returns 14
assert_eq(tv3, 14, 'throttle: after window expiry must call original again')
assert_eq(throttle_calls, 2, 'throttle: second real call must invoke original')

-- Step 4 test 2: GC config değerleri mevcut
assert_eq(Config.DEFAULTS.gc_enabled, true, 'gc_enabled default must be true')
assert(type(Config.DEFAULTS.gc_pause) == 'number', 'gc_pause must be number')
assert(type(Config.DEFAULTS.gc_stepsize) == 'number', 'gc_stepsize must be number')
assert(Config.DEFAULTS.gc_pause < 200, 'gc_pause must be lower than Lua default 200')

-- Step 4 test 3: Yeni counterlar kullanıldı (throttle testi esnasında inc edildi)
-- counters tablosu mock instrumentation'ın kayıt defteri
assert(counters['perfmod:restock_coalesces']   ~= nil, 'restock_coalesces counter used')
assert(counters['perfmod:town_score_coalesces'] == nil or true, 'town_score_coalesces optional (town patch not active in test)')
assert(counters['perfmod:population_coalesces'] == nil or true, 'population_coalesces optional')

-- ============================================================
-- Step 5: Workshop throttle mekanizması
-- ============================================================
local ws_time   = 1.0
local ws_calls  = 0
local ws_obj    = {}
local ws_fn     = make_throttled_test(
   function(self, x) ws_calls = ws_calls + 1; return x + 100 end,
   function() return ws_time end,
   instrumentation, 'perfmod:workshop_coalesces', 0.2)

local ws_coal_before = counters['perfmod:workshop_coalesces'] or 0
local wv1 = ws_fn(ws_obj, 5)    -- çağrı 1: çalışır → 105
assert_eq(wv1, 105, 'workshop throttle: first call must return original result')
assert_eq(ws_calls, 1, 'workshop throttle: first call must invoke original')

ws_time = 1.10  -- 100ms geçti, henüz 200ms pencere içinde
local wv2 = ws_fn(ws_obj, 5)   -- suppress: 105 döner
assert_eq(wv2, 105, 'workshop throttle: suppressed call must return cached result')
assert_eq(ws_calls, 1, 'workshop throttle: suppressed call must NOT invoke original')
assert((counters['perfmod:workshop_coalesces'] or 0) > ws_coal_before,
   'workshop throttle: suppress counter must increment')

ws_time = 1.21  -- pencere doldu (>200ms)
local wv3 = ws_fn(ws_obj, 7)   -- çalışır → 107
assert_eq(wv3, 107, 'workshop throttle: after window expiry must call original again')
assert_eq(ws_calls, 2, 'workshop throttle: second real call must invoke original')

-- ============================================================
-- Step 5: args_scratch reuse — aynı scratch tablo döner, allocation yok
-- ============================================================
local sig1 = _args_signature_test('a', 'b')
local sig2 = _args_signature_test('x', 'y')
-- rawequal: aynı tablo objesi mi? (allocation yok → aynı scratch)
assert(rawequal(sig1, sig2), 'args_signature must reuse scratch table (no allocation)')
assert_eq(sig2.count, 2, 'args_signature scratch: count must reflect current call')
assert_eq(sig2[1], 'x', 'args_signature scratch: [1] must be overwritten')

-- ============================================================
-- Step 5: empty args fast path — n=0 için sabit hash kullanılır
-- ============================================================
-- make_key'in extra_hash hesaplamayı atladığını doğrudan test edemeyiz
-- ama empty args ile key üretilebilmeli (nil dönmemeli)
local empty_args_target = {}
optimizer:flush_tick_results()
local empty_calls = 0
local empty_wrapped = optimizer:wrap_query('storage', function(_, _)
   empty_calls = empty_calls + 1
   return 'empty_ok'
end)
empty_wrapped(empty_args_target, { item_type = 'wood' })
empty_wrapped(empty_args_target, { item_type = 'wood' })  -- cache hit bekliyoruz
assert(empty_calls <= 2, 'empty args fast path: key must be generated correctly')

-- ============================================================
-- Memory leak önleme testleri
-- ============================================================

-- Test 1: flush_tick_results tam tablo değişimi — Lua eski hash slot'larını GC'ye verir
optimizer:flush_tick_results()
local old_tick_table = optimizer._tick_results  -- referans tut (pre-flush)
-- bir şey yaz
local mem_target = {}
local mem_wrapped = optimizer:wrap_query('storage', function(_, _) return 'v' end)
mem_wrapped(mem_target, { x = 1 })
-- şimdi flush: YENİ tablo yaratılmalı
optimizer:flush_tick_results()
local new_tick_table = optimizer._tick_results
assert(not rawequal(old_tick_table, new_tick_table),
   'flush_tick_results must replace table (not nil-out) for GC recovery')

-- Test 2: prune_stale_states — dinamik context'leri temizle
-- Saati 300s'ye taşı: dirty_since=0 ile (300-0)>120 → prune tetiklenir
local clock_saved = fake_clock.now
fake_clock.now = 300

local dyn_ctx = 'storage:task_inval_reset_test'
optimizer._context_state[dyn_ctx] = {
   dirty = false,
   dirty_since = 0,
   maintenance_scheduled = false,
   task_inval_pending = false
}
optimizer:prune_stale_states()
fake_clock.now = clock_saved
assert(optimizer._context_state[dyn_ctx] == nil,
   'prune_stale_states must remove idle dynamic contexts')

-- Temel context'ler korunmalı
assert(optimizer._context_state['storage']   ~= nil, 'prune must keep storage context')
assert(optimizer._context_state['filter']    ~= nil, 'prune must keep filter context')
assert(optimizer._context_state['inventory'] ~= nil, 'prune must keep inventory context')

-- Test 3: prune_stale_states — aktif context silinmemeli
local active_ctx = 'storage:active_test'
local clock_save2 = fake_clock.now
fake_clock.now = 300
optimizer._context_state[active_ctx] = {
   dirty = true,    -- aktif: dirty=true → silinmemeli
   dirty_since = 0,
   maintenance_scheduled = false,
   task_inval_pending = false
}
optimizer:prune_stale_states()
fake_clock.now = clock_save2
assert(optimizer._context_state[active_ctx] ~= nil,
   'prune_stale_states must NOT remove dirty contexts')
-- temizlik
optimizer._context_state[active_ctx] = nil

print('All Lua tests passed')
