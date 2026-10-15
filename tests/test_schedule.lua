-- Test di libs/schedule.lua + integrazione sun + curve su un giorno con 4 SP
local t = require "tests.support.harness"
local schedule = require "libs.schedule"
local curve = require "libs.curve"
local sun = require "libs.sun"

-- proprieta' come tabella nome -> valore
local function getter(props) return function(name) return props[name] end end

local function props_4sp()
	return {
		["Scheduler Mode"] = "Brightness + Colour Temperature",
		["Number of Switchpoints"] = "4",
		["Minimum Colour Temperature"] = "2200",
		["Maximum Colour Temperature"] = "6500",
		["SP 1 Type"] = "Astronomical", ["SP 1 Astronomical Reference"] = "Sunrise", ["SP 1 Offset (mins)"] = "0",
		["SP 1 Brightness"] = "20", ["SP 1 Colour Temperature"] = "2900",
		["SP 2 Type"] = "Astronomical", ["SP 2 Astronomical Reference"] = "Solar Noon", ["SP 2 Offset (mins)"] = "0",
		["SP 2 Brightness"] = "90", ["SP 2 Colour Temperature"] = "5500",
		["SP 3 Type"] = "Astronomical", ["SP 3 Astronomical Reference"] = "Sunset", ["SP 3 Offset (mins)"] = "-30",
		["SP 3 Brightness"] = "60", ["SP 3 Colour Temperature"] = "3200",
		["SP 4 Type"] = "Set Time", ["SP 4 Time"] = "23:00",
		["SP 4 Brightness"] = "5", ["SP 4 Colour Temperature"] = "2200",
	}
end

t.test("parse_time: HH:MM valido e non valido", function()
	t.eq(schedule.parse_time("07:30"), 450)
	t.eq(schedule.parse_time("7:30"), 450)
	t.eq(schedule.parse_time(" 23:59 "), 1439)
	t.eq(schedule.parse_time("00:00"), 0)
	t.eq(schedule.parse_time("24:00"), nil)
	t.eq(schedule.parse_time("12:60"), nil)
	t.eq(schedule.parse_time("7.30"), nil)
	t.eq(schedule.parse_time(""), nil)
	t.eq(schedule.parse_time(nil), nil)
end)

t.test("parse_number: punto e virgola come separatore (Janus v114)", function()
	t.eq(schedule.parse_number("1.5"), 1.5)
	t.eq(schedule.parse_number("1,5"), 1.5)
	t.eq(schedule.parse_number(" 42 "), 42)
	t.eq(schedule.parse_number(7), 7)
	t.eq(schedule.parse_number("x"), nil)
	t.eq(schedule.parse_number(nil), nil)
end)

t.test("read_config: valori letti, modalita', flag brightness/cct", function()
	local cfg, warnings = schedule.read_config(getter(props_4sp()))
	t.eq(#warnings, 0)
	t.eq(cfg.count, 4)
	t.eq(cfg.use_brightness, true)
	t.eq(cfg.use_cct, true)
	t.eq(cfg.sps[1].type, "Astronomical")
	t.eq(cfg.sps[3].offset, -30)
	t.eq(cfg.sps[4].time, 1380)
	local p = props_4sp()
	p["Scheduler Mode"] = "Brightness Only"
	cfg = schedule.read_config(getter(p))
	t.eq(cfg.use_brightness, true); t.eq(cfg.use_cct, false)
	p["Scheduler Mode"] = "Colour Temperature Only"
	cfg = schedule.read_config(getter(p))
	t.eq(cfg.use_brightness, false); t.eq(cfg.use_cct, true)
end)

t.test("read_config: valori fuori range o invalidi => limitati con warning", function()
	local p = props_4sp()
	p["Number of Switchpoints"] = "20"
	p["Scheduler Mode"] = "boh"
	p["Minimum Colour Temperature"] = "5000"
	p["Maximum Colour Temperature"] = "3000"
	p["SP 4 Time"] = "25:99"
	p["SP 1 Offset (mins)"] = "500"
	p["SP 1 Brightness"] = "150"
	local cfg, warnings = schedule.read_config(getter(p))
	t.eq(cfg.count, 10)
	t.eq(cfg.mode, schedule.MODE_BOTH)
	t.eq(cfg.ct_min, 3000); t.eq(cfg.ct_max, 5000)
	t.eq(cfg.sps[1].offset, 180)
	t.eq(cfg.sps[1].brightness, 100)
	t.eq(cfg.sps[4].time, nil)
	t.truthy(#warnings >= 4)
end)

t.test("read_config: proprieta' mancanti => default sicuri", function()
	local cfg = schedule.read_config(function() return nil end)
	t.eq(cfg.count, 4)
	t.eq(cfg.mode, schedule.MODE_BOTH)
	t.eq(cfg.ct_min, 1600); t.eq(cfg.ct_max, 6500)
end)

t.test("build_points: SP astronomici con offset e SP a orario fisso", function()
	local cfg = schedule.read_config(getter(props_4sp()))
	local astro = { sunrise = 330, solar_noon = 780, sunset = 1210, solar_midnight = 60 }
	local points, warnings = schedule.build_points(cfg, astro)
	t.eq(#warnings, 0)
	t.eq(#points, 4)
	t.eq(points[1].t, 330)
	t.eq(points[2].t, 780)
	t.eq(points[3].t, 1180) -- tramonto - 30
	t.eq(points[4].t, 1380)
end)

t.test("build_points: offset oltre mezzanotte e' riportato nel giorno", function()
	local p = props_4sp()
	p["SP 3 Offset (mins)"] = "180"
	local cfg = schedule.read_config(getter(p))
	local points = schedule.build_points(cfg, { sunrise = 330, solar_noon = 780, sunset = 1400, solar_midnight = 60 })
	t.eq(points[3].t, 140) -- 1400 + 180 = 1580 -> 140
end)

t.test("build_points: SP astronomici non risolvibili (polare/senza dati) sono saltati con warning", function()
	local cfg = schedule.read_config(getter(props_4sp()))
	local points, warnings = schedule.build_points(cfg, nil)
	t.eq(#points, 1) -- resta solo l'SP 4 a orario fisso
	t.eq(#warnings, 3)
	points, warnings = schedule.build_points(cfg, { solar_noon = 780, solar_midnight = 60 }) -- niente alba/tramonto
	t.eq(#points, 2)
	t.eq(#warnings, 2)
end)

t.test("target: la CCT e' riportata nei CT Limits", function()
	local p = props_4sp()
	p["Minimum Colour Temperature"] = "3000"
	p["Maximum Colour Temperature"] = "5000"
	local cfg = schedule.read_config(getter(p))
	local prepared = assert(curve.prepare(schedule.build_points(cfg, { sunrise = 330, solar_noon = 780, sunset = 1210, solar_midnight = 60 })))
	for minute = 0, 1439, 10 do
		local v = schedule.target(prepared, cfg, minute)
		t.truthy(v.cct >= 3000 and v.cct <= 5000, "cct " .. v.cct .. " a " .. minute)
	end
end)

t.test("integrazione sun + curve: un giorno con 4 SP (Milano, 21 giugno, UTC+2)", function()
	local day = assert(sun.calculate(45.4642, 9.19, 2026, 6, 21, 2))
	local cfg = schedule.read_config(getter(props_4sp()))
	local points = schedule.build_points(cfg, day)
	local prepared = assert(curve.prepare(points))

	-- passa esattamente per ogni SP (risolti e arrotondati al minuto)
	local function r(x) return math.floor(x + 0.5) end
	local sunrise = schedule.target(prepared, cfg, r(day.sunrise))
	local noon = schedule.target(prepared, cfg, r(day.solar_noon))
	local sunset_m30 = schedule.target(prepared, cfg, r(day.sunset - 30))
	local night = schedule.target(prepared, cfg, 23 * 60)
	t.near(sunrise.brightness, 20, 1e-6); t.near(sunrise.cct, 2900, 1e-6)
	t.near(noon.brightness, 90, 1e-6); t.near(noon.cct, 5500, 1e-6)
	t.near(sunset_m30.brightness, 60, 1e-6); t.near(sunset_m30.cct, 3200, 1e-6)
	t.near(night.brightness, 5, 1e-6); t.near(night.cct, 2200, 1e-6)

	-- alba ~05:36, mezzogiorno ~13:26: fra i due la brightness sale in modo monotono
	t.truthy(day.sunrise > 5 * 60 and day.sunrise < 6 * 60)
	local prev = -1
	for minute = math.floor(day.sunrise), math.floor(day.solar_noon) do
		local v = schedule.target(prepared, cfg, minute)
		t.truthy(v.brightness >= prev - 1e-9, "brightness cala a " .. minute)
		prev = v.brightness
	end
	-- dal mezzogiorno al tramonto-30 scende
	prev = 101
	for minute = math.ceil(day.solar_noon), math.floor(day.sunset - 30) do
		local v = schedule.target(prepared, cfg, minute)
		t.truthy(v.brightness <= prev + 1e-9, "brightness sale a " .. minute)
		prev = v.brightness
	end
	-- continuita' a mezzanotte (SP 4 -> SP 1 del giorno dopo): nessun salto
	local before = schedule.target(prepared, cfg, 1439)
	local after = schedule.target(prepared, cfg, 1)
	t.truthy(math.abs(before.brightness - after.brightness) < 1)
	-- sempre dentro i valori degli SP
	for minute = 0, 1439 do
		local v = schedule.target(prepared, cfg, minute)
		t.truthy(v.brightness >= 5 - 1e-9 and v.brightness <= 90 + 1e-9)
	end
end)

t.test("describe: righe ordinate per orario", function()
	local cfg = schedule.read_config(getter(props_4sp()))
	local lines = schedule.describe(cfg, { sunrise = 330, solar_noon = 780, sunset = 1210, solar_midnight = 60 })
	t.eq(#lines, 5)
	t.truthy(lines[2]:find("05:30", 1, true))
	t.truthy(lines[5]:find("23:00", 1, true))
end)

t.test("resolve: SP arrotondati al minuto e label con offset", function()
	local cfg = schedule.read_config(getter(props_4sp()))
	local entries = schedule.resolve(cfg, { sunrise = 330.4, solar_noon = 780.6, sunset = 1210, solar_midnight = 60 })
	t.eq(entries[1].t, 330)
	t.eq(entries[2].t, 781)
	t.eq(entries[1].label, "Sunrise+0")
	t.eq(entries[2].label, "Solar Noon+0")
	t.eq(entries[3].label, "Sunset-30")
	t.eq(entries[4].label, "Set Time")
end)

t.test("collisione: due SP allo stesso minuto => warning esplicito, vince l'ultimo", function()
	local p = props_4sp()
	p["SP 4 Time"] = "05:30" -- come l'alba (330)
	p["SP 4 Brightness"] = "7"
	local cfg = schedule.read_config(getter(p))
	local astro = { sunrise = 330, solar_noon = 780, sunset = 1210, solar_midnight = 60 }
	local entries, warnings = schedule.resolve(cfg, astro)
	t.eq(#warnings, 1)
	t.eq(warnings[1], "SP 1 e SP 4 coincidono a 05:30: l'ultimo vince")
	-- nella curva vince l'SP con numero piu' alto
	local prepared = assert(curve.prepare(schedule.points(entries)))
	t.near(prepared:evaluate(330).brightness, 7, 1e-9)
end)

t.test("collisione dopo l'offset e dopo l'arrotondamento al minuto", function()
	local p = props_4sp()
	p["SP 1 Offset (mins)"] = "450"  -- 330 + 450 = 780 = mezzogiorno solare dell'SP 2
	local cfg = schedule.read_config(getter(p))
	local _, warnings = schedule.resolve(cfg, { sunrise = 330, solar_noon = 780, sunset = 1210, solar_midnight = 60 })
	t.eq(#warnings, 0, "offset max e' 180: 450 viene limitato")
	p["SP 1 Offset (mins)"] = "180"  -- 510
	p["SP 2 Astronomical Reference"] = "Sunrise"
	p["SP 2 Offset (mins)"] = "180"  -- 510: coincide
	cfg = schedule.read_config(getter(p))
	_, warnings = schedule.resolve(cfg, { sunrise = 330.3, solar_noon = 780, sunset = 1210, solar_midnight = 60 })
	t.eq(#warnings, 1)
	t.truthy(warnings[1]:find("SP 1 e SP 2 coincidono a 08:30", 1, true), warnings[1])
end)

t.test("nessuna collisione con SP non risolvibili o con orari diversi", function()
	local cfg = schedule.read_config(getter(props_4sp()))
	local _, warnings = schedule.resolve(cfg, { sunrise = 330, solar_noon = 780, sunset = 1210, solar_midnight = 60 })
	t.eq(#warnings, 0)
end)

t.test("summary: riga compatta con orari risolti, label e valori", function()
	local cfg = schedule.read_config(getter(props_4sp()))
	local entries = schedule.resolve(cfg, { sunrise = 330, solar_noon = 780, sunset = 1210, solar_midnight = 60 })
	t.eq(schedule.summary(entries),
		"SP1 05:30 (Sunrise+0) b=20 cct=2900 | SP2 13:00 (Solar Noon+0) b=90 cct=5500 | "
		.. "SP3 19:40 (Sunset-30) b=60 cct=3200 | SP4 23:00 (Set Time) b=5 cct=2200")
	-- SP non risolvibile: orario "--:--"
	entries = schedule.resolve(cfg, nil)
	t.truthy(schedule.summary(entries):find("SP1 --:-- (Sunrise+0)", 1, true))
end)

t.test("describe include i warning di collisione", function()
	local p = props_4sp()
	p["SP 4 Time"] = "05:30"
	local cfg = schedule.read_config(getter(p))
	local lines = schedule.describe(cfg, { sunrise = 330, solar_noon = 780, sunset = 1210, solar_midnight = 60 })
	local found = false
	for _, l in ipairs(lines) do
		if l:find("ATTENZIONE: SP 1 e SP 4 coincidono a 05:30: l'ultimo vince", 1, true) then found = true end
	end
	t.truthy(found)
end)

t.finish()
