-- Test di libs/sun.lua contro i riferimenti USNO in tests/fixtures/sun_reference.lua
local t = require "tests.support.harness"
local sun = require "libs.sun"
local refs = require "tests.fixtures.sun_reference"

-- Riferimenti USNO arrotondati al minuto: tolleranza 1 min (richiesta: +/-2).
local TOL = 1.0

for _, ref in ipairs(refs) do
	t.test("USNO " .. ref.name, function()
		local r = assert(sun.calculate(ref.lat, ref.lon, ref.date[1], ref.date[2], ref.date[3], ref.tz))
		t.near_clock(r.sunrise, t.hhmm(ref.sunrise), TOL, "alba")
		t.near_clock(r.solar_noon, t.hhmm(ref.noon), TOL, "mezzogiorno")
		t.near_clock(r.sunset, t.hhmm(ref.sunset), TOL, "tramonto")
		t.eq(r.polar, nil)
	end)
end

t.test("ordine: alba < mezzogiorno < tramonto (tranne tramonto oltre mezzanotte)", function()
	for _, ref in ipairs(refs) do
		local r = sun.calculate(ref.lat, ref.lon, ref.date[1], ref.date[2], ref.date[3], ref.tz)
		if ref.sunset_wraps then
			t.truthy(r.sunset < r.sunrise, ref.name .. ": il tramonto deve essere riportato nel giorno")
		else
			t.truthy(r.sunrise < r.solar_noon and r.solar_noon < r.sunset, ref.name)
		end
	end
end)

t.test("offset: orologio locale = tempo solare medio spostato di (offset - lon/15) ore", function()
	for _, ref in ipairs(refs) do
		local d = ref.date
		local mean = sun.calculate(ref.lat, ref.lon, d[1], d[2], d[3])
		local clock = sun.calculate(ref.lat, ref.lon, d[1], d[2], d[3], ref.tz)
		local shift = (ref.tz - ref.lon / 15) * 60
		t.near_clock(clock.solar_noon, mean.solar_noon + shift, 1e-6, ref.name)
		if mean.sunrise then
			t.near_clock(clock.sunrise, mean.sunrise + shift, 1e-6, ref.name)
			t.near_clock(clock.sunset, mean.sunset + shift, 1e-6, ref.name)
		end
	end
end)

t.test("Reykjavik giugno (64.1N) NON e' polar day: alba e tramonto esistono", function()
	local r = sun.calculate(64.1466, -21.9426, 2026, 6, 21, 0)
	t.eq(r.polar, nil)
	t.truthy(r.sunrise ~= nil and r.sunset ~= nil)
end)

t.test("soglie polari: day da ~65.7N (giugno), night da ~67.4N (dicembre)", function()
	t.eq(sun.calculate(65.0, 0, 2026, 6, 21).polar, nil)
	t.eq(sun.calculate(66.5, 0, 2026, 6, 21).polar, "day")
	t.eq(sun.calculate(66.5, 0, 2026, 12, 21).polar, nil) -- il sole sorge appena
	t.eq(sun.calculate(68.0, 0, 2026, 12, 21).polar, "night")
end)

t.test("offset frazionari e negativi: spostamento rigido (+5.5, +5.75, -3.5, +13, +14, -12)", function()
	local base = sun.calculate(28.6139, 77.2090, 2026, 6, 21, 0)
	for _, off in ipairs({ 5.5, 5.75, -3.5, 13, 14, -12 }) do
		local r = sun.calculate(28.6139, 77.2090, 2026, 6, 21, off)
		t.near_clock(r.sunrise, base.sunrise + off * 60, 1e-6, "alba offset " .. off)
		t.near_clock(r.solar_noon, base.solar_noon + off * 60, 1e-6, "mezzogiorno offset " .. off)
		t.near_clock(r.sunset, base.sunset + off * 60, 1e-6, "tramonto offset " .. off)
		t.truthy(r.sunrise >= 0 and r.sunrise < 1440 and r.sunset >= 0 and r.sunset < 1440)
	end
end)

t.test("mezzanotte solare = mezzogiorno - 720 (o + 720 se negativo)", function()
	for _, ref in ipairs(refs) do
		local r = sun.calculate(ref.lat, ref.lon, ref.date[1], ref.date[2], ref.date[3], ref.tz)
		local expected = r.solar_noon - 720
		if expected < 0 then expected = expected + 1440 end
		t.near(r.solar_midnight, expected, 1e-9, ref.name)
		t.truthy(r.solar_midnight >= 0 and r.solar_midnight < 1440, ref.name)
	end
end)

t.test("senza offset: tempo solare medio del sito (mezzogiorno vicino alle 12:00)", function()
	-- Milano giugno: E = -1.7 min circa => mezzogiorno ~ 12:02
	local r = sun.calculate(45.0, 9.0, 2026, 6, 21)
	t.near(r.solar_noon, 722, 1.5)
	-- stessa data con offset = lon/15 esplicito: identico
	local r2 = sun.calculate(45.0, 9.0, 2026, 6, 21, 9.0 / 15)
	t.near(r.sunrise, r2.sunrise, 1e-9)
	t.near(r.sunset, r2.sunset, 1e-9)
	-- alba e tramonto quasi simmetrici attorno al mezzogiorno
	t.near((r.sunrise + r.sunset) / 2, r.solar_noon, 2)
end)

t.test("l'offset sposta tutto in modo rigido", function()
	local a = sun.calculate(45.0, 9.0, 2026, 6, 21, 0)
	local b = sun.calculate(45.0, 9.0, 2026, 6, 21, 2)
	t.near(b.sunrise - a.sunrise, 120, 1e-9)
	t.near(b.solar_noon - a.solar_noon, 120, 1e-9)
	t.near(b.sunset - a.sunset, 120, 1e-9)
end)

t.test("stagionalita': giorno piu' lungo a giugno che a dicembre (45N), inverso a Sydney", function()
	local jun = sun.calculate(45.0, 9.0, 2026, 6, 21, 0)
	local dec = sun.calculate(45.0, 9.0, 2026, 12, 21, 0)
	t.truthy(jun.sunset - jun.sunrise > dec.sunset - dec.sunrise + 300)
	local sj = sun.calculate(-33.87, 151.21, 2026, 6, 21, 10)
	local sd = sun.calculate(-33.87, 151.21, 2026, 12, 21, 11)
	t.truthy(sd.sunset - sd.sunrise > sj.sunset - sj.sunrise + 200)
end)

t.test("equatore all'equinozio: giorno ~12h07 (rifrazione)", function()
	local r = sun.calculate(0, 0, 2026, 3, 20, 0)
	t.near(r.sunset - r.sunrise, 727, 3)
end)

t.test("latitudini polari: sole di mezzanotte / notte polare", function()
	local day = sun.calculate(80, 0, 2026, 6, 21)
	t.eq(day.polar, "day")
	t.eq(day.sunrise, nil)
	t.eq(day.sunset, nil)
	t.truthy(day.solar_noon ~= nil and day.solar_midnight ~= nil)
	local night = sun.calculate(80, 0, 2026, 12, 21)
	t.eq(night.polar, "night")
	t.eq(night.sunrise, nil)
	-- ai poli esatti non esplode
	t.truthy(sun.calculate(90, 0, 2026, 6, 21) ~= nil)
	t.truthy(sun.calculate(-90, 0, 2026, 12, 21) ~= nil)
end)

t.test("continuita' sul cambio d'anno e anno bisestile", function()
	local a = sun.calculate(45, 9, 2026, 12, 31, 0)
	local b = sun.calculate(45, 9, 2027, 1, 1, 0)
	t.near(a.solar_noon, b.solar_noon, 1)
	t.near(a.sunrise, b.sunrise, 2)
	t.truthy(sun.calculate(45, 9, 2028, 2, 29, 0) ~= nil)
	local feb28 = sun.calculate(45, 9, 2028, 2, 28, 0)
	local mar1 = sun.calculate(45, 9, 2028, 3, 1, 0)
	t.near(feb28.solar_noon, mar1.solar_noon, 1.5)
end)

t.test("argomenti non validi => nil + messaggio", function()
	local cases = {
		{ 91, 0, 2026, 6, 21 }, { -91, 0, 2026, 6, 21 },
		{ 45, 181, 2026, 6, 21 }, { 45, -181, 2026, 6, 21 },
		{ 45, 9, 2026, 13, 1 }, { 45, 9, 2026, 0, 1 },
		{ 45, 9, 2026, 2, 29 }, { 45, 9, 2026, 4, 31 }, { 45, 9, 2026, 6, 0 },
	}
	for i, c in ipairs(cases) do
		local r, err = sun.calculate(c[1], c[2], c[3], c[4], c[5])
		t.eq(r, nil, "caso " .. i)
		t.truthy(type(err) == "string", "messaggio caso " .. i)
	end
	t.eq((sun.calculate("45", 9, 2026, 6, 21)), nil)
	t.eq((sun.calculate(45, 9, 2026, 6, 21, "due")), nil)
end)

t.test("deterministico (stesso input, stesso output)", function()
	local a = sun.calculate(45.123, 9.456, 2026, 7, 4, 2)
	local b = sun.calculate(45.123, 9.456, 2026, 7, 4, 2)
	t.eq(a.sunrise, b.sunrise)
	t.eq(a.sunset, b.sunset)
	t.eq(a.solar_noon, b.solar_noon)
end)

t.test("velocita': 2000 calcoli in meno di 1 s", function()
	local start = os.clock()
	for i = 1, 2000 do
		sun.calculate(45.0, 9.0, 2026, 1 + (i % 12), 1 + (i % 28), 1)
	end
	local elapsed = os.clock() - start
	t.truthy(elapsed < 1, "tempo: " .. elapsed .. " s")
end)

t.test("format_minutes", function()
	t.eq(sun.format_minutes(0), "00:00")
	t.eq(sun.format_minutes(722.4), "12:02")
	t.eq(sun.format_minutes(1439.6), "00:00")
	t.eq(sun.format_minutes(nil), "--:--")
end)

t.finish()
