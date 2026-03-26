local unpack = table.unpack or unpack

local Config = require 'scripts.perf_mod.config'

local QueryOptimizer = class()

-- Module-level scratch: her query'de yeni tablo allocation'ı engeller (GC baskısı azalır).
-- Lua single-threaded → concurrent erişim yok, reuse tamamen güvenli.
local _args_scratch = {}
local _args_scratch_prev_max = 0

function QueryOptimizer:initialize(clock, cache, coalescer, instrumentation, settings, log)
   self._clock = clock
   self._cache = cache
   self._coalescer = coalescer
   self._instrumentation = instrumentation
   self._settings = settings
   self._log = log
   self._context_state = {}
   self._circuit_state = {}
   self._tick_results = {}

   -- Hot path'te nil check + tablo yaratma yok: bilinen context'leri startup'ta pre-warm et
   local function _new_ctx()
      return { dirty = false, dirty_since = 0, maintenance_scheduled = false }
   end
   self._context_state['storage']   = _new_ctx()
   self._context_state['filter']    = _new_ctx()
   self._context_state['inventory'] = _new_ctx()
end

-- Her 50ms heartbeat'te çağrılır — tick-local memo temizlenir
function QueryOptimizer:flush_tick_results()
   -- Önce flood tespiti için say
   local count = 0
   for _ in pairs(self._tick_results) do count = count + 1 end

   -- Tam tablo değişimi: nil-out yerine yeni tablo → Lua eski tablonun hash slot'larını GC'ye verir.
   -- nil-out sonrası tablo küçülmez; tam değişim belleği geri kazandırır.
   self._tick_results = {}

   -- Flood tespiti: çok fazla entry → context sık invalidate ediliyor, tick memo verimsiz
   if count > 30 then
      local now = self._clock:get_realtime_seconds()
      if now > (self._tick_flood_warn_at or 0) then
         self._tick_flood_warn_at = now + 30
         if self._log and self._log.warning then
            self._log:warning('perf_mod: tick memo flush with %d entries — frequent invalidation?', count)
         end
      end
   end
end

-- Task tamamlandığında coalesced invalidation — burst durumunda nesil bir kez ilerler
function QueryOptimizer:mark_task_dirty(context)
   local state = self:_get_context_state(context)
   state.dirty = true
   state.dirty_since = self._clock:get_realtime_seconds()

   -- İlk task → anında invalidasyon; ardışık task'lar suppress_ms içinde dedupe edilir
   if not state.task_inval_pending then
      state.task_inval_pending = true
      self._cache:invalidate(context)

      local profile = self._settings:get_profile_data()
      local suppress_ms = math.max(50, profile.coalesce_ms or 0)
      self._coalescer:mark_dirty(context .. ':task_inval_reset', function()
         state.task_inval_pending = false
         state.dirty = false
         state.maintenance_scheduled = false
         self._cache:prune_context(context)
      end, suppress_ms)
   end
end

function QueryOptimizer:_get_context_state(context)
   local state = self._context_state[context]
   if not state then
      state = {
         dirty = false,
         dirty_since = 0,
         maintenance_scheduled = false
      }
      self._context_state[context] = state
   end
   return state
end

function QueryOptimizer:_get_circuit_state(context)
   local state = self._circuit_state[context]
   if not state then
      state = {
         failures = {},
         open_until = 0
      }
      self._circuit_state[context] = state
   end
   return state
end

function QueryOptimizer:_record_failure(context, profile, now)
   local circuit = self:_get_circuit_state(context)
   local failures = circuit.failures
   failures[#failures + 1] = now

   -- In-place compaction: yeni `kept` tablo allocation yok → GC baskısı yok
   local window_s   = profile.circuit_window_s or 10
   local keep_from  = now - window_s
   local write      = 1
   for i = 1, #failures do
      if failures[i] >= keep_from then
         failures[write] = failures[i]
         write = write + 1
      end
   end
   for i = write, #failures do failures[i] = nil end

   local threshold = profile.circuit_failures or 3
   if (write - 1) >= threshold then
      circuit.open_until = now + (profile.circuit_open_s or 30)
      -- Circuit açıldı: failure listesi sıfırla
      for i = 1, #failures do failures[i] = nil end
   end
end

function QueryOptimizer:_is_circuit_open(context, now)
   local circuit = self:_get_circuit_state(context)
   return now < (circuit.open_until or 0)
end

function QueryOptimizer:mark_inventory_dirty(context)
   self._cache:invalidate(context)
   local state = self:_get_context_state(context)
   state.dirty = true
   state.dirty_since = self._clock:get_realtime_seconds()

   if not state.maintenance_scheduled then
      state.maintenance_scheduled = true
      self:coalesce(context .. ':maintenance', function()
         self._cache:prune_context(context)
         state.dirty = false
         state.maintenance_scheduled = false
      end)
   end
end

local function _is_negative_result(first)
   return first == nil or (type(first) == 'table' and next(first) == nil)
end

local function _target_identity(target)
   if type(target) ~= 'table' then
      return '-'
   end

   if target.get_id then
      local ok, id = pcall(target.get_id, target)
      if ok and id ~= nil then
         return id
      end
   end

   if target.__self then
      return tostring(target.__self)
   end

   return tostring(target)
end

local function _args_signature(...)
   local count = select('#', ...)
   local max_args = math.min(count, 6)
   -- Scratch reuse: eski değerleri temizle, yenileri yaz — sıfır allocation
   for i = max_args + 1, _args_scratch_prev_max do
      _args_scratch[i] = nil
   end
   _args_scratch_prev_max = max_args
   -- .count: _is_noisy_signature tarafından okunur (eski kontrat korunur)
   _args_scratch.count = count
   for i = 1, max_args do
      _args_scratch[i] = select(i, ...)
   end
   return _args_scratch
end

local NOISY_KEYS = {
   -- Pathfinding / spatial (canlı, her tick değişir)
   path = true,
   destination = true,
   location = true,
   region = true,
   search_region = true,
   nav_grid = true,
   traversal = true,
   -- AI / planning (canlı state referansları)
   ai = true,
   task = true,
   planner = true,
   -- Task / worker canlı nesne referansları
   task_group = true,      -- live TaskGroup nesnesi
   worker = true,          -- live Entity referansı
   worker_filter = true,   -- genellikle fonksiyon referansı
   job_filter = true,      -- genellikle fonksiyon referansı
   action = true,          -- live AI action nesnesi
   compound_action = true, -- live compound action
   execution_frame = true  -- live execution frame
   -- NOT: 'entity', 'task_type', 'job' çıkarıldı — Stonehearth'ta bunlar
   -- çoğunlukla sabit URI string'ler ('stonehearth:jobs:worker' gibi), cachelenebilir.
}

local function _is_noisy_signature(filter, args_signature, noisy_limit)
   local noisy = 0
   if type(filter) == 'table' then
      for k in pairs(filter) do
         if NOISY_KEYS[k] then
            noisy = noisy + 1
         end
      end
   end

   if type(args_signature) == 'table' then
      for i = 1, math.min(args_signature.count or 0, 3) do
         local v = args_signature[i]
         if type(v) == 'table' then
            for k in pairs(v) do
               if NOISY_KEYS[k] then
                  noisy = noisy + 1
               end
            end
         end
      end
   end

   return noisy >= (noisy_limit or 5)
end

local function _classify_query(context, filter, ...)
   if context == 'inventory' then
      return 'urgent'
   end

   local first = select(1, ...)
   if type(first) == 'table' then
      if first.require_immediate or first.urgent or first.allow_reserved then
         return 'urgent'
      end
      if first.limit and type(first.limit) == 'number' and first.limit <= 3 then
         return 'urgent'
      end
   end

   local f = filter
   if type(f) == 'table' then
      -- Pathfinding / spatial patterns
      if f.path or f.destination or f.region or f.search_region or f.ai or f.task then
         return 'ai_path'
      end
      -- Task/worker/job/compound_action patterns (canlı nesne referansları → asla cachelenmesin)
      if f.task_group or f.worker or f.job or f.action or f.execution_frame or f.compound_action then
         return 'ai_path'
      end
   end

   return 'normal'
end

-- limit: profildeki max_cached_result_size — limit+1'de erken çık (256'ya kadar saymaya gerek yok)
local function _result_size_hint(first, limit)
   if type(first) ~= 'table' then
      return 1
   end

   if first[1] ~= nil then
      return #first
   end

   local count = 0
   local cap = (limit or 256) + 1
   for _ in pairs(first) do
      count = count + 1
      if count >= cap then
         break
      end
   end
   return count
end

function QueryOptimizer:_effective_profile(profile, state)
   if profile.id == 'AGGRESSIVE' and state.dirty then
      return Config.get_profile('BALANCED')
   end
   return profile
end

-- ═══════════════════════════════════════════════════════════════════════════
-- Cached Query Execution — named method, closure allocation sıfır
-- ═══════════════════════════════════════════════════════════════════════════
-- ESKİ: pcall(function() ... end) → her çağrıda anonymous closure allocation
-- YENİ: pcall(self._execute_cached_query, self, ...) → metod referansı, sıfır allocation
--
-- filter_cache_cb tick başına binlerce kez çağrılabilir.
-- Closure başına ~40-60 byte + GC object → binlerce closure/tick → ciddi GC baskısı.
-- Named method ile bu tamamen ortadan kalkar.
function QueryOptimizer:_execute_cached_query(context, profile, state, original_fn, target, filter, packed_args)
   local pipeline_start = self._clock:get_realtime_seconds()

   local query_class = _classify_query(context, filter, unpack(packed_args, 1, packed_args.n))

   -- Urgent/AI-path bypass: doğrudan orijinale yönlendir, result table allocation yok
   -- ESKİ: local out = { original_fn(...) }; return unpack(out) → gereksiz tablo
   -- YENİ: return original_fn(...) → tail call, tüm return değerleri doğrudan geçer
   if profile.urgent_cache_bypass and query_class == 'urgent' then
      self._instrumentation:inc('perfmod:urgent_bypasses')
      self._instrumentation:inc('perfmod:full_scan_fallbacks')
      return original_fn(target, filter, unpack(packed_args, 1, packed_args.n))
   end

   if profile.ai_path_cache_bypass and query_class == 'ai_path' then
      self._instrumentation:inc('perfmod:ai_path_bypasses')
      self._instrumentation:inc('perfmod:full_scan_fallbacks')
      return original_fn(target, filter, unpack(packed_args, 1, packed_args.n))
   end

   local player_id = target and target.get_player_id and target:get_player_id() or nil
   local target_key = _target_identity(target)
   local args_key = _args_signature(unpack(packed_args, 1, packed_args.n))

   if _is_noisy_signature(filter, args_key, profile.noisy_signature_limit) then
      self._instrumentation:inc('perfmod:noisy_signature_bypasses')
      self._instrumentation:inc('perfmod:full_scan_fallbacks')
      return original_fn(target, filter, unpack(packed_args, 1, packed_args.n))
   end

   local key, fast_key = self._cache:make_key(filter, context, player_id, target_key, args_key)
   if fast_key then
      self._instrumentation:inc('perfmod:fast_key_hits')
   end

   if not key then
      self._instrumentation:inc('perfmod:key_bypass_complex')
      self._instrumentation:inc('perfmod:full_scan_fallbacks')
      return original_fn(target, filter, unpack(packed_args, 1, packed_args.n))
   end

   -- Tick-local memo: aynı 50ms pencerede özdeş sorgu → sıfır maliyetle servis
   local cur_gen = self._cache:get_generation(context)
   local tick_hit = self._tick_results[key]
   if tick_hit and tick_hit.gen == cur_gen then
      self._instrumentation:inc('perfmod:tick_cache_hits')
      return unpack(tick_hit.r)
   end

   local prelookup_ms = self._clock:get_elapsed_ms(pipeline_start)
   if prelookup_ms > profile.query_deadline_ms then
      self._instrumentation:inc('perfmod:deadline_fallbacks')
      self._instrumentation:inc('perfmod:full_scan_fallbacks')
      return original_fn(target, filter, unpack(packed_args, 1, packed_args.n))
   end

   local now = self._clock:get_realtime_seconds()
   -- Context-aware TTL: filter kriterleri item'lardan daha yavaş değişir → uzun TTL
   local effective_ttl = profile.cache_ttl
   if context == 'filter' and profile.filter_ttl_mult then
      effective_ttl = effective_ttl * profile.filter_ttl_mult
   end
   -- Filter context: kısa negatif TTL (80-150ms) → generation guard ile güvenli
   local neg_ttl = (context == 'filter' and profile.negative_filter_ttl)
      and profile.negative_filter_ttl
      or profile.negative_ttl
   local cached = self._cache:get(key, context, now, effective_ttl, neg_ttl)
   if cached then
      if cached.negative and state.dirty then
         self._instrumentation:inc('perfmod:dirty_negative_bypasses')
         cached = nil
      else
         if cached.negative then
            self._instrumentation:inc('perfmod:negative_hits')
         else
            self._instrumentation:inc('perfmod:cache_hits')
         end
         return unpack(cached.value)
      end
   end

   self._instrumentation:inc('perfmod:cache_misses')
   if state.dirty and profile.deferred_wait_ms <= 0 then
      state.dirty = false
   end

   -- Cache miss: orijinali çalıştır, sonucu cache'e yaz
   -- Result table burada GEREKLİ çünkü cache'e yazılacak
   local started = self._clock:get_realtime_seconds()
   self._instrumentation:inc('perfmod:full_scan_fallbacks')
   local result = { original_fn(target, filter, unpack(packed_args, 1, packed_args.n)) }
   local elapsed = self._clock:get_elapsed_ms(started)

   if elapsed > profile.query_deadline_ms then
      self._instrumentation:inc('perfmod:deadline_fallbacks')
   end

   local is_negative = _is_negative_result(result[1])
   local result_size = _result_size_hint(result[1], profile.max_cached_result_size)

   -- Tick memo'ya her zaman yaz (pozitif ve negatif) — generation guard yeterli
   self._tick_results[key] = { gen = cur_gen, r = result }

   -- Filter context: negatif sonuçlar da cachelenebilir (çok kısa TTL ile güvenli)
   local cache_neg = profile.cache_negative_results or
      (context == 'filter' and profile.cache_negative_filter)
   -- Filter context: immediate admission (en tekrarlı sorgular burada)
   local admit_threshold = (context == 'filter' and profile.admit_after_hits_filter)
      and profile.admit_after_hits_filter
      or profile.admit_after_hits

   if is_negative and not cache_neg then
      self._instrumentation:inc('perfmod:negative_cache_skips')
   elseif result_size > profile.max_cached_result_size then
      self._instrumentation:inc('perfmod:oversized_skips')
   else
      local seen_count = self._cache:touch_key(key, profile.max_cache_entries * 2)
      if seen_count >= admit_threshold then
         self._cache:set(key, context, result, now, is_negative, profile.max_cache_entries)
      else
         self._instrumentation:inc('perfmod:admission_skips')
      end
   end

   self._instrumentation:observe_query_time(elapsed)
   return unpack(result)
end

-- ═══════════════════════════════════════════════════════════════════════════
-- wrap_query — optimized: early bypass + closure-free pcall
-- ═══════════════════════════════════════════════════════════════════════════
-- 3 temel iyileştirme:
--   1) Early bypass: context kapalı / warm-resume / circuit-open durumlarında
--      packed_args tablosu OLUŞTURULMADAN doğrudan orijinal çağrılır (... forwarding)
--   2) Closure-free pcall: inner logic named method (_execute_cached_query) olarak
--      tanımlı, pcall(self.method, self, ...) → sıfır closure allocation
--   3) Bypass path'lerde result table yok: urgent/ai_path/noisy bypass'ları
--      doğrudan return original_fn(...) ile tail call yapar
function QueryOptimizer:wrap_query(context, original_fn)
   return function(target, filter, ...)
      -- ── Early bypass: packed_args allocation'ı ATLA ──────────────────
      -- Bu 3 kontrol args gerektirmez, doğrudan ... forward eder
      if not self._settings:is_context_cache_enabled(context) then
         self._instrumentation:inc('perfmod:context_bypasses')
         self._instrumentation:inc('perfmod:full_scan_fallbacks')
         return original_fn(target, filter, ...)
      end

      if self._settings:is_warm_resume_guard_active() then
         self._instrumentation:inc('perfmod:warm_resume_guards')
         self._instrumentation:inc('perfmod:full_scan_fallbacks')
         return original_fn(target, filter, ...)
      end

      local now_for_circuit = self._clock:get_realtime_seconds()
      if self:_is_circuit_open(context, now_for_circuit) then
         self._instrumentation:inc('perfmod:circuit_open_bypasses')
         self._instrumentation:inc('perfmod:full_scan_fallbacks')
         return original_fn(target, filter, ...)
      end

      -- ── Cache pipeline: packed_args gerekli ─────────────────────────
      local packed_args = { n = select('#', ...), ... }
      local state = self:_get_context_state(context)
      local profile = self:_effective_profile(self._settings:get_profile_data(), state)

      -- pcall(named_method, self, ...) → closure allocation YOK
      local ok, a, b, c, d, e, f = pcall(
         self._execute_cached_query, self,
         context, profile, state, original_fn, target, filter, packed_args)

      if ok then
         return a, b, c, d, e, f
      end

      -- Safety fallback: _execute_cached_query hata verdi
      self._instrumentation:inc('perfmod:safety_fallbacks')
      self:_record_failure(context, profile, self._clock:get_realtime_seconds())
      if self._log and self._log.warning then
         self._log:warning('Optimizer safety fallback due to error: %s', tostring(a))
      end
      self._instrumentation:inc('perfmod:full_scan_fallbacks')
      return original_fn(target, filter, unpack(packed_args, 1, packed_args.n))
   end
end

function QueryOptimizer:run_incremental_scan(scan_state, scan_step_fn)
   local profile = self._settings:get_profile_data()
   local started = self._clock:get_realtime_seconds()
   while true do
      local done = scan_step_fn(scan_state)
      self._instrumentation:inc('perfmod:incremental_scan_steps')
      if done then
         return true
      end

      if self._clock:get_elapsed_ms(started) >= profile.incremental_budget_ms then
         return false
      end
   end
end

function QueryOptimizer:coalesce(context, fn)
   local profile = self._settings:get_profile_data()
   self._coalescer:mark_dirty(context, fn, profile.coalesce_ms)
end

-- Her ~60s'de service heartbeat'ten çağrılır.
-- 'storage:task_inval_reset', 'filter:maintenance' gibi dinamik context anahtarları birikmeden temizlenir.
-- Pre-warm edilmiş temel context'ler (storage/filter/inventory) asla silinmez.
function QueryOptimizer:prune_stale_states()
   local now    = self._clock:get_realtime_seconds()
   local STALE  = 120  -- 2 dakika inactive → ölü

   -- Temel context'leri koru: bunlar her zaman aktiftir, silme
   local KEEP = { storage = true, filter = true, inventory = true }

   for ctx, state in pairs(self._context_state) do
      if not KEEP[ctx] then
         local idle = not state.dirty
            and not state.maintenance_scheduled
            and not state.task_inval_pending
            and (now - (state.dirty_since or 0)) > STALE
         if idle then
            self._context_state[ctx] = nil
         end
      end
   end

   for ctx, circuit in pairs(self._circuit_state) do
      if not KEEP[ctx] then
         local idle = (#circuit.failures == 0)
            and now > (circuit.open_until or 0) + STALE
         if idle then
            self._circuit_state[ctx] = nil
         end
      end
   end
end

return QueryOptimizer
