-- bootstrap.lua ? Bombproof server init
--
-- PROBLEM: Eski bootstrap top-level'da class(), require chain calistiriyordu.
--   Mod yukleme zamaninda class() veya diger globaller hazir degilse
--   tum script crash edip nil donuyordu -> "module returned non-table type"
--
-- COZUM: Top-level'da SADECE engine core API (radiant.log, radiant.events).
--   Tum module loading radiant:init event handler icinde.
--   Bu zamanda class(), stonehearth.ai, ACE patch'leri hepsi hazir.

-- Safe logger: radiant.log yoksa bile crash etmez
local _log = nil
if radiant and radiant.log then
   _log = radiant.log.create_logger('perf_mod')
end

local function _safe_log(level, msg, ...)
   if _log then
      local ok, _ = pcall(_log[level], _log, msg, ...)
      if not ok and level ~= 'always' then
         pcall(_log.always, _log, 'perf_mod: log.' .. level .. ' failed')
      end
   end
end

_safe_log('always', 'perf_mod: bootstrap loaded (v310)')

-- State
local _initialized = false

local function _start()
   if _initialized then return end
   _initialized = true

   _safe_log('always', 'perf_mod: radiant:init fired ? loading service module...')

   -- 1) Service modulunu yukle (class() artik hazir)
   local ok_req, result = pcall(require, 'scripts.perf_mod.service')
   if not ok_req then
      _safe_log('error', 'perf_mod: FATAL ? service module load failed: %s', tostring(result))
      return
   end

   local PerfModService = result
   if type(PerfModService) ~= 'table' then
      _safe_log('error', 'perf_mod: FATAL ? service module returned %s (expected table)', type(PerfModService))
      return
   end

   -- 2) Service'i baslat
   local ok_init, err_init = pcall(function()
      PerfModService:get():initialize()
   end)

   if not ok_init then
      _safe_log('error', 'perf_mod: FATAL ? service initialization failed: %s', tostring(err_init))
   end
end

-- radiant:init event'ini dinle ? tum mod servisleri hazir olduktan sonra ates eder
if radiant and radiant.events then
   radiant.events.listen_once(radiant, 'radiant:init', _start)
else
   _safe_log('error', 'perf_mod: radiant.events not available ? cannot register init listener')
end

return { start = _start }
