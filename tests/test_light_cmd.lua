-- Test di libs/light_cmd.lua (comandi Light V2, capabilities, staggered) e libs/persist.lua
local t = require "tests.support.harness"
local lc = require "libs.light_cmd"
local persist = require "libs.persist"
local fake_env = require "tests.support.fake_env"

t.test("brightness: SET_BRIGHTNESS_TARGET con PERCENT e RATE in ms", function()
	local cmd, params = lc.brightness({ supports_target = true }, 55.4, 5000)
	t.eq(cmd, "SET_BRIGHTNESS_TARGET")
	t.eq(params.LIGHT_BRIGHTNESS_TARGET_PERCENT, 55)
	t.eq(params.RATE, 5000)
	cmd = lc.brightness(nil, 10, 0)           -- caps ignote => target
	t.eq(cmd, "SET_BRIGHTNESS_TARGET")
end)

t.test("brightness: clamp 0..100", function()
	local _, p1 = lc.brightness({}, 140, 0)
	local _, p2 = lc.brightness({}, -5, 0)
	t.eq(p1.LIGHT_BRIGHTNESS_TARGET_PERCENT, 100)
	t.eq(p2.LIGHT_BRIGHTNESS_TARGET_PERCENT, 0)
end)

t.test("brightness: fallback RAMP_TO_LEVEL senza supports_target", function()
	local cmd, params = lc.brightness({ supports_target = false }, 40, 3000)
	t.eq(cmd, "RAMP_TO_LEVEL")
	t.eq(params.LEVEL, 40)
	t.eq(params.TIME, 3000)
end)

-- insieme delle chiavi di una tabella, ordinato: "A,B,C"
local function keys_of(params)
	local keys = {}
	for k in pairs(params) do keys[#keys + 1] = k end
	table.sort(keys)
	return table.concat(keys, ",")
end

t.test("parse_caps: XML della documentazione (tag non chiusi), luce legacy, input non valido", function()
	local caps = lc.parse_caps(fake_env.CAPS_CCT)
	t.eq(caps.supports_target, true)
	t.eq(caps.supports_cct, true)
	t.eq(caps.cct_min, 2000)
	t.eq(caps.cct_max, 6500)
	local legacy = lc.parse_caps(fake_env.CAPS_LEGACY)
	t.eq(legacy.supports_target, false)
	t.eq(legacy.supports_cct, false)
	t.eq(legacy.cct_min, nil)
	t.eq(lc.parse_caps(nil), nil)
	t.eq(lc.parse_caps(""), nil)
	t.eq(lc.parse_caps("<DynamicCapabilities></DynamicCapabilities>").supports_target, nil)
end)

t.test("parse_device_list: separata da virgole, ordinata, senza duplicati e rumore", function()
	local ids = lc.parse_device_list("16, 13,18,13,x,,20")
	t.eq(table.concat(ids, ","), "13,16,18,20")
	t.eq(#lc.parse_device_list(""), 0)
	t.eq(#lc.parse_device_list(nil), 0)
end)

t.test("stagger: fino a 10 luci un solo batch, oltre batch da 5 ogni 50 ms", function()
	local b = lc.stagger(0)
	t.eq(#b, 0)
	b = lc.stagger(1)
	t.eq(#b, 1); t.eq(b[1].delay_ms, 0); t.eq(b[1].first, 1); t.eq(b[1].last, 1)
	b = lc.stagger(10)
	t.eq(#b, 1); t.eq(b[1].last, 10)
	b = lc.stagger(11)
	t.eq(#b, 3)
	t.eq(b[1].first, 1); t.eq(b[1].last, 5); t.eq(b[1].delay_ms, 0)
	t.eq(b[2].first, 6); t.eq(b[2].last, 10); t.eq(b[2].delay_ms, 50)
	t.eq(b[3].first, 11); t.eq(b[3].last, 11); t.eq(b[3].delay_ms, 100)
	b = lc.stagger(23)
	t.eq(#b, 5); t.eq(b[5].last, 23); t.eq(b[5].delay_ms, 200)
end)

t.test("persist: get con default, set ripulisce tipi non persistibili", function()
	local store = {}
	local p = persist.new({ get = function(k) return store[k] end, set = function(k, v) store[k] = v end })
	t.eq(p.get("x", "d"), "d")
	p.set("x", 5)
	t.eq(p.get("x", "d"), 5)
	p.set("t", { a = 1, b = "s", c = true, f = function() end, n = { deep = 2, g = print }, [3] = 7 })
	local saved = store.t
	t.eq(saved.a, 1); t.eq(saved.b, "s"); t.eq(saved.c, true)
	t.eq(saved.f, nil); t.eq(saved.n.g, nil); t.eq(saved.n.deep, 2); t.eq(saved[3], 7)
	p.set("fn", function() end)
	t.eq(store.fn, nil)
end)

-- ---------------------------------------------------------------- SET_COLOR_TARGET: coerenza mode/payload
t.test("color_cct: MODE=1 con ESATTAMENTE kelvin + MODE + RATE; niente X/Y/H/S/V", function()
	local cmd, params = lc.color_cct(3024.4, 5000)
	t.eq(cmd, "SET_COLOR_TARGET")
	t.eq(params.LIGHT_COLOR_TARGET_MODE, 1)
	t.eq(params[lc.KEY_CCT], 3024)
	t.eq(params.RATE, 5000)
	t.eq(keys_of(params), "LIGHT_COLOR_TARGET_COLOR_CORRELATED_TEMPERATURE,LIGHT_COLOR_TARGET_MODE,RATE")
	for _, forbidden in ipairs({ "LIGHT_COLOR_TARGET_X", "LIGHT_COLOR_TARGET_Y", "LIGHT_COLOR_TARGET_H",
		"LIGHT_COLOR_TARGET_S", "LIGHT_COLOR_TARGET_V", "LIGHT_COLOR_TARGET_HUE", "LIGHT_COLOR_TARGET_SATURATION" }) do
		t.eq(params[forbidden], nil, forbidden)
	end
end)

t.test("color_xy: MODE=0 con ESATTAMENTE X + Y + MODE + RATE; niente kelvin", function()
	local cmd, params = lc.color_xy(0.4, 0.38, 2000)
	t.eq(cmd, "SET_COLOR_TARGET")
	t.eq(params.LIGHT_COLOR_TARGET_MODE, 0)
	t.eq(keys_of(params), "LIGHT_COLOR_TARGET_MODE,LIGHT_COLOR_TARGET_X,LIGHT_COLOR_TARGET_Y,RATE")
	t.eq(params[lc.KEY_CCT], nil)
end)

t.test("coerenza: nessuna combinazione MODE=1 con X/Y (la regressione che non vira) ne' MODE=0 con kelvin", function()
	for _, k in ipairs({ 1700, 2700, 4000, 6500 }) do
		local _, p = lc.color_cct(k, 1000)
		t.eq(p.LIGHT_COLOR_TARGET_MODE == 1 and p.LIGHT_COLOR_TARGET_X ~= nil, false)
		local _, q = lc.color_xy(0.3, 0.3, 1000)
		t.eq(q.LIGHT_COLOR_TARGET_MODE == 0 and q[lc.KEY_CCT] ~= nil, false)
	end
end)

t.test("color_rate: nessun limite senza caps; clamp a color_rate_min/max; behavior 0 => nessun RATE", function()
	t.eq(lc.color_rate(nil, 5000), 5000)
	t.eq(lc.color_rate({}, 5000), 5000)
	t.eq(lc.color_rate({ color_rate_behavior = 2, color_rate_min = 0, color_rate_max = 0 }, 5000), 5000, "max 0 = nessun limite")
	t.eq(lc.color_rate({ color_rate_min = 200, color_rate_max = 2000 }, 5000), 2000)
	t.eq(lc.color_rate({ color_rate_min = 200, color_rate_max = 2000 }, 50), 200)
	t.eq(lc.color_rate({ color_rate_min = 200, color_rate_max = 2000 }, 1000), 1000)
	t.eq(lc.color_rate({ color_rate_behavior = 0 }, 5000), nil)
	local _, params = lc.color_cct(3000, 5000, { color_rate_behavior = 0 })
	t.eq(params.RATE, nil)
	t.eq(keys_of(params), "LIGHT_COLOR_TARGET_COLOR_CORRELATED_TEMPERATURE,LIGHT_COLOR_TARGET_MODE")
	_, params = lc.color_cct(3000, 5000, { color_rate_min = 200, color_rate_max = 2000 })
	t.eq(params.RATE, 2000)
end)

t.test("describe_color: mode e coppia (parametro,valore) a colpo d'occhio", function()
	local _, p = lc.color_cct(3024, 5000)
	t.eq(lc.describe_color(p), "mode=1 {CCT=3024} rate=5000")
	local _, q = lc.color_xy(0.4355, 0.4036, 1000)
	t.eq(lc.describe_color(q), "mode=0 {X=0.43550 Y=0.40360} rate=1000")
	local _, r = lc.color_cct(3000, 5000, { color_rate_behavior = 0 })
	t.eq(lc.describe_color(r), "mode=1 {CCT=3000} rate=-")
end)

t.test("all_tags/dump_tags: tutti i tag delle capabilities (anche non chiusi), contenitori saltati", function()
	local tags = lc.all_tags(fake_env.CAPS_CCT)
	t.eq(tags.supports_target, "True")
	t.eq(tags.supports_color, "False")
	t.eq(tags.supports_color_correlated_temperature, "True")
	t.eq(tags.color_correlated_temperature_min, "2000")
	t.eq(tags.color_rate_behavior, "2")
	t.eq(tags.color_trace_tolerance, "0.006")
	t.eq(tags.DynamicCapabilities, nil)
	local dump = lc.dump_tags(fake_env.CAPS_CCT)
	t.truthy(dump:find("color_rate_behavior=2", 1, true) and dump:find("supports_color=False", 1, true))
	t.eq(lc.dump_tags(nil), "")
	t.eq(lc.compact_xml("<a>\n  <b>1</b>\n</a>  "), "<a> <b>1</b> </a>")
end)

t.test("parse_caps: campi colore (supports_color, color_rate_*, tolleranza)", function()
	local caps = lc.parse_caps(fake_env.CAPS_COLOR_RATE)
	t.eq(caps.supports_color, false)
	t.eq(caps.color_rate_behavior, 2)
	t.eq(caps.color_rate_min, 200)
	t.eq(caps.color_rate_max, 2000)
	t.near(caps.color_trace_tolerance, 0.006, 1e-9)
	t.eq(lc.parse_caps(fake_env.CAPS_FIXED_COLOR_RATE).color_rate_behavior, 0)
end)

t.test("tabella documentata di SET_COLOR_TARGET disponibile per il log una tantum", function()
	local text = table.concat(lc.COLOR_TARGET_DOC, "\n")
	for _, token in ipairs({ "LIGHT_COLOR_TARGET_X", "LIGHT_COLOR_TARGET_Y", "LIGHT_COLOR_TARGET_MODE",
		"RATE", lc.KEY_CCT, "0 colore pieno, 1 CCT" }) do
		t.truthy(text:find(token, 1, true), token)
	end
end)

t.finish()
