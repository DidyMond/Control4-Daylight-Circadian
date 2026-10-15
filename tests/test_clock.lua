-- Test di libs/clock.lua (offset UTC con fuso, DST e mezzi fusi)
local t = require "tests.support.harness"
local clock = require "libs.clock"

-- tabella {year, month, day, hour, min} di un istante
local function at(y, mo, d, h, mi) return { year = y, month = mo, day = d, hour = h, min = mi } end

local function check(name, utc, loc, expected)
	t.test(name, function()
		t.near(clock.offset_from_clocks(loc, utc), expected, 1e-9)
	end)
end

check("UTC+0", at(2026, 12, 21, 12, 0), at(2026, 12, 21, 12, 0), 0)
check("Milano CEST +2", at(2026, 6, 21, 11, 26), at(2026, 6, 21, 13, 26), 2)
check("Milano CET +1", at(2026, 12, 21, 11, 22), at(2026, 12, 21, 12, 22), 1)
check("New York EDT -4", at(2026, 6, 21, 16, 58), at(2026, 6, 21, 12, 58), -4)
check("Auckland NZDT +13 (passa al giorno dopo)", at(2026, 10, 10, 11, 0), at(2026, 10, 11, 0, 0), 13)
check("Auckland NZST +12", at(2026, 6, 21, 12, 0), at(2026, 6, 22, 0, 0), 12)
check("Kiribati +14", at(2026, 6, 21, 12, 0), at(2026, 6, 22, 2, 0), 14)
check("Baker Island -12", at(2026, 6, 21, 3, 0), at(2026, 6, 20, 15, 0), -12)
check("India +5:30", at(2026, 6, 21, 20, 0), at(2026, 6, 22, 1, 30), 5.5)
check("Nepal +5:45", at(2026, 6, 21, 20, 0), at(2026, 6, 22, 1, 45), 5.75)
check("Terranova -3:30", at(2026, 6, 21, 2, 0), at(2026, 6, 20, 22, 30), -3.5)
check("cambio d'anno in avanti (+2)", at(2026, 12, 31, 23, 0), at(2027, 1, 1, 1, 0), 2)
check("cambio d'anno indietro (-5)", at(2027, 1, 1, 1, 0), at(2026, 12, 31, 20, 0), -5)
check("29 febbraio bisestile (+2)", at(2028, 2, 28, 23, 0), at(2028, 2, 29, 1, 0), 2)
check("29 febbraio bisestile (-3)", at(2028, 3, 1, 1, 0), at(2028, 2, 29, 22, 0), -3)
check("fine febbraio non bisestile (+2)", at(2026, 2, 28, 23, 0), at(2026, 3, 1, 1, 0), 2)

t.test("la formula con sole ore sbaglia per UTC+12/+13: motivo di clock.lua", function()
	local function naive(local_hour, utc_hour) return (local_hour - utc_hour + 36) % 24 - 12 end
	-- Auckland NZDT: UTC 11:00 -> locale 00:00 del giorno dopo
	t.eq(naive(0, 11), -11, "UTC+13 letto come -11")
	-- Auckland NZST: UTC 12:00 -> locale 00:00
	t.eq(naive(0, 12), -12, "UTC+12 letto come -12")
	t.near(clock.offset_from_clocks(at(2026, 10, 11, 0, 0), at(2026, 10, 10, 11, 0)), 13, 1e-9)
	t.near(clock.offset_from_clocks(at(2026, 6, 22, 0, 0), at(2026, 6, 21, 12, 0)), 12, 1e-9)
end)

t.test("utc_offset_hours() del sistema: valore plausibile, multiplo di 15 minuti", function()
	local off = clock.utc_offset_hours()
	t.truthy(type(off) == "number" and off >= -12 and off <= 14, "offset: " .. tostring(off))
	t.near(off * 4, math.floor(off * 4 + 0.5), 1e-9)
end)

t.test("utc_offset_hours_for_date: coerente con utc_offset_hours sull'epoch di mezzogiorno", function()
	local jan = clock.utc_offset_hours_for_date(2026, 1, 15)
	local jul = clock.utc_offset_hours_for_date(2026, 7, 15)
	t.truthy(type(jan) == "number" and type(jul) == "number")
	t.truthy(math.abs(jan - jul) <= 2, "differenza DST insolita")
	local epoch = os.time({ year = 2026, month = 7, day = 15, hour = 12, min = 0, sec = 0 })
	t.near(jul, clock.utc_offset_hours(epoch), 1e-9)
end)

t.finish()
