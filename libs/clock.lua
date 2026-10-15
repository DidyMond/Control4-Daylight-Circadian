-- ============================================================
-- libs/clock.lua - offset UTC del sistema (fuso + DST), in ore
--
-- Lua 5.1 puro, nessun riferimento a C4. Usa solo os.date/os.time, che sul
-- controller seguono il fuso del sistema (il log `[ASTRO] … UTC+n` mostra l'offset usato).
--
-- Perche' non basta confrontare solo le ore:
--   (local_hour - utc_hour + 36) % 24 - 12
-- restituisce valori in [-12, +11]: per UTC+12/+13/+14 (Nuova Zelanda, Fiji,
-- Kiribati) da' -12/-11/-10, e perde i mezzi fusi (India +5:30, Nepal +5:45).
-- Qui si confrontano data e ora complete (anno, mese, giorno, ora, minuti)
-- dello stesso istante visto dall'orologio locale e da quello UTC.
-- ============================================================

local M = {}

local floor = math.floor

-- Giorni dal 1970-01-01 per una data del calendario gregoriano
-- (Howard Hinnant, "chrono-Compatible Low-Level Date Algorithms").
local function days_from_civil(y, m, d)
	if m <= 2 then y = y - 1 end
	local era = floor(y / 400)
	local yoe = y - era * 400
	local mp = (m + 9) % 12 -- marzo = 0
	local doy = floor((153 * mp + 2) / 5) + d - 1
	local doe = yoe * 365 + floor(yoe / 4) - floor(yoe / 100) + doy
	return era * 146097 + doe - 719468
end

local function to_minutes(t)
	return days_from_civil(t.year, t.month, t.day) * 1440 + t.hour * 60 + t.min
end

-- offset_from_clocks(local_t, utc_t) -> ore (anche frazionarie)
-- local_t e utc_t sono tabelle {year, month, day, hour, min} dello STESSO
-- istante, come restituite da os.date("*t", ts) e os.date("!*t", ts).
function M.offset_from_clocks(local_t, utc_t)
	return (to_minutes(local_t) - to_minutes(utc_t)) / 60
end

-- Offset UTC del sistema all'istante `epoch` (default: adesso), DST incluso.
function M.utc_offset_hours(epoch)
	epoch = epoch or os.time()
	return M.offset_from_clocks(os.date("*t", epoch), os.date("!*t", epoch))
end

-- Offset UTC del sistema a mezzogiorno locale della data data: e' quello da
-- passare a sun.calculate (evita errori nei giorni di cambio ora, quando
-- l'offset "adesso" puo' essere diverso da quello del giorno calcolato).
function M.utc_offset_hours_for_date(year, month, day)
	local epoch = os.time({ year = year, month = month, day = day, hour = 12, min = 0, sec = 0 })
	return M.utc_offset_hours(epoch)
end

return M
