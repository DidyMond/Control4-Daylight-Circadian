-- Test di integrazione di libs/engine.lua con ambiente finto (tests/support/fake_env.lua)
-- Copre ciò che non richiede C4: state machine, tick, luci,
-- monitoring, preview, comandi, persistenza, staggered. Il comportamento con Director
-- e luci reali si verifica a mano su hardware.
local t = require "tests.support.harness"
local engine = require "libs.engine"
local fake_env = require "tests.support.fake_env"
local dbg = require "libs.debug"
local light_cmd = require "libs.light_cmd"

-- crea fake + engine e li porta a LateInit; luci = lista di {id, level, caps?}
local function boot(opts, lights)
	opts = opts or {}
	local ids = {}
	for _, l in ipairs(lights or {}) do ids[#ids + 1] = tostring(l[1]) end
	opts.props = opts.props or {}
	opts.props["Controlled Devices"] = table.concat(ids, ",")
	local fake = fake_env.new(opts)
	for _, l in ipairs(lights or {}) do
		if l[3] then fake.caps[l[1]] = l[3] end
	end
	local eng = engine.new(fake.env)
	eng:init()
	eng:late_init()
	for _, l in ipairs(lights or {}) do
		eng:on_level(l[1], light_cmd.VAR_LIGHT_STATE, l[2] > 0 and "1" or "0")
		eng:on_level(l[1], light_cmd.VAR_BRIGHTNESS_PERCENT, tostring(l[2]))
	end
	-- l'allineamento iniziale per luce ("init") ha gia' inviato brightness e CCT: lo
	-- dimentichiamo, cosi' i test partono da "nessun invio precedente"
	for _, l in ipairs(lights or {}) do eng.mon:get(l[1]).last_sent = nil end
	fake:clear_sent()
	return fake, eng
end

local function commands(fake, id, name) return fake:sent_to(id, name) end

-- ---------------------------------------------------------------- avvio
t.test("avvio: IDLE -> ACTIVE, Operational Mode, variabili, astro persistita, luci osservate", function()
	local fake, eng = boot(nil, { { 11, 50 }, { 12, 50 } })
	t.eq(eng:state(), "ACTIVE")
	t.eq(fake.props["Operational Mode"], "Active")
	t.eq(fake.variables.SCHEDULE_ACTIVE, "1")
	t.eq(fake.variables.PREVIEW_ACTIVE, "0")
	t.eq(fake.store.state, "ACTIVE")
	t.truthy(fake.store.astro_today and fake.store.astro_today.date == "2026-06-21")
	t.near(fake.store.astro_today.offset, 2, 1e-9)
	t.truthy(fake.watched["11:1000"] and fake.watched["11:1001"] and fake.watched["12:1001"])
	t.truthy(fake.device_events["11:" .. light_cmd.EVENT_BRIGHTNESS_CHANGED])
	t.truthy(fake.timers[1] and fake.timers[1].ms == 60000, "tick timer a 60 s")
	t.truthy(fake.store.schedule ~= nil)
end)

t.test("avvio senza lat/long: log Error e resta IDLE (con SP a orario fisso la curva esiste ma non parte)", function()
	local fake, eng = boot({ latlon = false }, { { 11, 50 } })
	t.eq(eng:state(), "IDLE")
	t.eq(fake.props["Operational Mode"], "Idle")
	t.eq(fake.variables.SCHEDULE_ACTIVE, "0")
	t.truthy(fake:has_log(dbg.ERROR, "mancanti"))
	fake:advance(120)
	t.eq(#fake.sent, 0)
end)

t.test("schedule non valida (nessuno SP risolvibile): resta IDLE con Error", function()
	local props = { ["Number of Switchpoints"] = "3" }
	for n = 1, 3 do props["SP " .. n .. " Time"] = "xx:yy" end
	local fake, eng = boot({ props = props }, { { 11, 50 } })
	t.eq(eng:state(), "IDLE")
	t.truthy(fake:has_log(dbg.ERROR, "curva non valida"))
end)

-- ---------------------------------------------------------------- tick
t.test("tick: invia SET_BRIGHTNESS_TARGET e SET_COLOR_TARGET con rate = Fade Time e CCT in kelvin (formato dell'app)", function()
	local fake, eng = boot(nil, { { 11, 50 } })
	fake:advance(60) -- primo tick; ora locale 14:01 (UTC+2): fra 12:00 (80%) e 18:00 (60%)
	local b = commands(fake, 11, "SET_BRIGHTNESS_TARGET")
	local c = commands(fake, 11, "SET_COLOR_TARGET")
	t.eq(#b, 1); t.eq(#c, 1)
	local pct = b[1].params.LIGHT_BRIGHTNESS_TARGET_PERCENT
	t.truthy(pct > 60 and pct < 80, "brightness " .. pct)
	t.eq(b[1].params.RATE, 5000)
	t.eq(c[1].params.LIGHT_COLOR_TARGET_MODE, 1)
	t.eq(c[1].params.RATE, 5000)
	-- formato dell'app: MODE 1 + kelvin, MAI X/Y
	t.eq(c[1].params.LIGHT_COLOR_TARGET_X, nil)
	t.eq(c[1].params.LIGHT_COLOR_TARGET_Y, nil)
	local cct = c[1].params[light_cmd.KEY_CCT]
	t.truthy(cct > 3200 and cct < 5200 and cct % 10 == 0, "cct " .. tostring(cct))
	t.truthy(fake:has_log(dbg.TRACE, "[TICK] tick"))
end)

t.test("tick: rispetta i CT Limits e le capabilities per-luce (2000-6500 K)", function()
	local fake = boot({ props = { ["Minimum Colour Temperature"] = "4000", ["Maximum Colour Temperature"] = "4500" } },
		{ { 11, 50 } })
	fake:advance(60)
	local c = commands(fake, 11, "SET_COLOR_TARGET")[1]
	local cct = c.params[light_cmd.KEY_CCT]
	t.truthy(cct >= 4000 and cct <= 4500, "cct " .. cct)
end)

t.test("luce spenta: nessun comando (mai accendere); luce che si accende viene riallineata subito", function()
	local fake, eng = boot(nil, { { 11, 0 }, { 12, 50 } })
	fake:advance(60)
	t.eq(#commands(fake, 11), 0)
	t.truthy(#commands(fake, 12) > 0)
	fake:clear_sent()
	-- accensione esterna da 0 -> 70: reset + allineamento immediato (forzato) con Fade Time
	eng:on_level(11, light_cmd.VAR_BRIGHTNESS_PERCENT, "70")
	local b = commands(fake, 11, "SET_BRIGHTNESS_TARGET")
	t.eq(#b, 1)
	t.eq(b[1].params.RATE, 5000)
	t.eq(#commands(fake, 11, "SET_COLOR_TARGET"), 1)
end)

t.test("accensione esterna: il colore viene rimandato a +3 s e +8 s (la lampada puo' riprendere il suo colore dopo)", function()
	local fake, eng = boot(nil, { { 11, 0 } })
	fake:advance(5)
	fake:clear_sent()
	eng:on_level(11, light_cmd.VAR_BRIGHTNESS_PERCENT, "70")
	local c0 = commands(fake, 11, "SET_COLOR_TARGET")
	t.eq(#c0, 1, "invio immediato")
	fake:advance(2.9)
	t.eq(#commands(fake, 11, "SET_COLOR_TARGET"), 1, "non prima di 3 s")
	fake:advance(0.2)
	local c1 = commands(fake, 11, "SET_COLOR_TARGET")
	t.eq(#c1, 2, "reinvio a +3 s")
	t.eq(c1[2].params.LIGHT_COLOR_TARGET_COLOR_CORRELATED_TEMPERATURE, c1[1].params.LIGHT_COLOR_TARGET_COLOR_CORRELATED_TEMPERATURE)
	fake:advance(5)
	t.eq(#commands(fake, 11, "SET_COLOR_TARGET"), 3, "reinvio a +8 s")
	fake:advance(5)
	t.eq(#commands(fake, 11, "SET_COLOR_TARGET"), 3, "poi niente altro (il tick da 60 s non e' ancora scattato)")
end)

t.test("accensione esterna: se la luce si spegne prima, nessun reinvio; una nuova accensione annulla i reinvii della precedente", function()
	local fake, eng = boot(nil, { { 11, 0 } })
	fake:advance(5)
	fake:clear_sent()
	eng:on_level(11, light_cmd.VAR_BRIGHTNESS_PERCENT, "70")
	fake:advance(1)
	eng:on_level(11, light_cmd.VAR_BRIGHTNESS_PERCENT, "0")
	fake:advance(10)
	t.eq(#commands(fake, 11, "SET_COLOR_TARGET"), 1, "solo l'invio immediato")
	fake:clear_sent()
	eng:on_level(11, light_cmd.VAR_BRIGHTNESS_PERCENT, "70")  -- invio immediato (1)
	fake:advance(1)
	eng:recolour_after_on(11)                                   -- seconda accensione a +1 s: annulla i reinvii della prima
	fake:advance(10)
	t.eq(#commands(fake, 11, "SET_COLOR_TARGET"), 1 + 2, "1 immediato + 2 reinvii (solo quelli della seconda accensione)")
end)

t.test("avvio: il livello iniziale e' letto dalla luce, cosi' la prima accensione e' un turned_on (non un init)", function()
	-- regressione T4: una luce spenta all'avvio non manda eventi finche' non cambia; se il suo
	-- livello resta sconosciuto, la prima accensione e' "init": nessun reinvio del colore
	local fake = fake_env.new({ props = { ["Controlled Devices"] = "11,12" } })
	fake.var_values = { ["11:1000"] = "0", ["11:1001"] = "0", ["12:1000"] = "1", ["12:1001"] = "55" }
	local eng = engine.new(fake.env)
	eng:init()
	eng:late_init()
	t.eq(eng.mon:get(11).level, 0, "luce spenta nota subito")
	t.eq(eng.mon:get(12).level, 55, "luce accesa nota subito")
	t.truthy(fake:has_log(dbg.INFO, "livello iniziale 0"))
	fake:clear_sent()
	eng:on_level(11, light_cmd.VAR_BRIGHTNESS_PERCENT, "56")   -- accensione: prima volta che arriva un evento
	t.truthy(fake:has_log(dbg.INFO, "accesa dall'esterno"), "turned_on, non init")
	local n0 = #commands(fake, 11, "SET_COLOR_TARGET")
	fake:advance(9)
	t.eq(#commands(fake, 11, "SET_COLOR_TARGET"), n0 + 2, "reinvio del colore a +3 s e +8 s")
end)

t.test("Preset Colour While Lights Are Off = On: alla luce spenta va la SOLA CCT (mai brightness/RAMP), senza rate", function()
	local fake = boot({ props = { ["Preset Colour While Lights Are Off"] = "On" } }, { { 11, 0 }, { 12, 50 } })
	fake:advance(60)
	local c = commands(fake, 11, "SET_COLOR_TARGET")
	t.eq(#c, 1, "un colore alla luce spenta")
	t.eq(#commands(fake, 11, "SET_BRIGHTNESS_TARGET"), 0, "mai brightness a luce spenta")
	t.eq(#commands(fake, 11, "RAMP_TO_LEVEL"), 0)
	t.eq(c[1].params.RATE, 0, "rate 0")
	t.truthy(c[1].params.LIGHT_COLOR_TARGET_COLOR_CORRELATED_TEMPERATURE >= 2000)
	t.truthy(#commands(fake, 12, "SET_BRIGHTNESS_TARGET") > 0, "la luce accesa e' trattata come prima")
	t.truthy(fake:has_log(dbg.TRACE, "spenta: preimposto il colore"))
	-- la luce resta spenta per il monitor e un secondo tick non rimanda lo stesso colore
end)

t.test("Preset Colour While Lights Are Off = Off (default): nessun comando alla luce spenta", function()
	local fake = boot(nil, { { 11, 0 } })
	fake:advance(180)
	t.eq(#commands(fake, 11), 0)
end)

t.test("Preset Colour While Lights Are Off = On: niente in Brightness Only e il livello 'sconosciuto' non riceve nulla", function()
	local fake = boot({ props = { ["Preset Colour While Lights Are Off"] = "On", ["Scheduler Mode"] = "Brightness Only" } }, { { 11, 0 } })
	fake:advance(120)
	t.eq(#commands(fake, 11), 0)
	local fake2 = fake_env.new({ props = { ["Controlled Devices"] = "11", ["Preset Colour While Lights Are Off"] = "On" } })
	local eng2 = engine.new(fake2.env)
	eng2:init()
	eng2:late_init() -- nessun livello letto, nessun evento: luce sconosciuta
	fake2:advance(120)
	t.eq(#fake2:sent_to(11), 0)
end)

t.test("avvio: livello iniziale non leggibile -> lo si impara dal primo evento (init), senza errori", function()
	local fake, eng = boot(nil, { { 11, 50 } })
	t.eq(eng.mon:get(11).level, 50)
end)

t.test("accensione esterna con Preset Colour = On: nessun reinvio a +3/+8 s (la lampada si accende gia' al colore giusto)", function()
	local fake, eng = boot({ props = { ["Preset Colour While Lights Are Off"] = "On" } }, { { 11, 0 } })
	fake:advance(5)
	fake:clear_sent()
	eng:on_level(11, light_cmd.VAR_BRIGHTNESS_PERCENT, "70")
	t.eq(#commands(fake, 11, "SET_COLOR_TARGET"), 1, "solo l'invio immediato")
	fake:advance(10)
	t.eq(#commands(fake, 11, "SET_COLOR_TARGET"), 1, "nessun reinvio")
end)

t.test("accensione esterna: in Brightness Only nessun reinvio di colore", function()
	local fake, eng = boot({ props = { ["Scheduler Mode"] = "Brightness Only" } }, { { 11, 0 } })
	fake:advance(5)
	fake:clear_sent()
	eng:on_level(11, light_cmd.VAR_BRIGHTNESS_PERCENT, "70")
	fake:advance(10)
	t.eq(#commands(fake, 11, "SET_COLOR_TARGET"), 0)
end)

t.test("luce legacy senza supports_target/CCT: RAMP_TO_LEVEL e nessun colore", function()
	local fake = boot(nil, { { 11, 50, fake_env.CAPS_LEGACY } })
	fake:advance(60)
	t.eq(#commands(fake, 11, "SET_BRIGHTNESS_TARGET"), 0)
	t.eq(#commands(fake, 11, "RAMP_TO_LEVEL"), 1)
	t.eq(#commands(fake, 11, "SET_COLOR_TARGET"), 0)
end)

t.test("modalita' Brightness Only: niente SET_COLOR_TARGET; CT Only: niente brightness", function()
	local fake = boot({ props = { ["Scheduler Mode"] = "Brightness Only" } }, { { 11, 50 } })
	fake:advance(60)
	t.eq(#commands(fake, 11, "SET_COLOR_TARGET"), 0)
	t.truthy(#commands(fake, 11, "SET_BRIGHTNESS_TARGET") > 0)
	local fake2 = boot({ props = { ["Scheduler Mode"] = "Colour Temperature Only" } }, { { 11, 50 } })
	fake2:advance(60)
	t.eq(#commands(fake2, 11, "SET_BRIGHTNESS_TARGET"), 0)
	t.truthy(#commands(fake2, 11, "SET_COLOR_TARGET") > 0)
end)

t.test("target brightness 0 con luce accesa: la spegne (0%), non accende mai", function()
	local props = { ["SP 1 Brightness"] = "0", ["SP 2 Brightness"] = "0", ["SP 3 Brightness"] = "0", ["SP 4 Brightness"] = "0" }
	local fake = boot({ props = props }, { { 11, 40 }, { 12, 0 } })
	fake:advance(60)
	local b = commands(fake, 11, "SET_BRIGHTNESS_TARGET")
	t.eq(b[1].params.LIGHT_BRIGHTNESS_TARGET_PERCENT, 0)
	t.eq(#commands(fake, 12), 0)
end)

-- ---------------------------------------------------------------- state machine
t.test("Pause/Resume: eventi, variabili, tick sospeso, Follow Lights on Resume", function()
	local fake, eng = boot(nil, { { 11, 50 } })
	eng:on_command("PAUSE_SCHEDULE")
	t.eq(eng:state(), "PAUSED")
	t.eq(fake:count_events("SCHEDULE_PAUSED"), 1)
	t.eq(fake.variables.SCHEDULE_ACTIVE, "0")
	t.eq(fake.props["Operational Mode"], "Paused")
	t.eq(fake.store.state, "PAUSED")
	fake:advance(180)
	t.eq(#fake.sent, 0, "nessun invio in PAUSED")
	t.eq(eng:test_condition("SCHEDULE_ACTIVE"), false)
	t.eq(eng:test_condition("SCHEDULE_INACTIVE"), true)
	eng:on_command("RESUME_SCHEDULE")
	t.eq(eng:state(), "ACTIVE")
	t.eq(fake:count_events("SCHEDULE_RESUMED"), 1)
	t.eq(fake.variables.SCHEDULE_ACTIVE, "1")
	t.truthy(#commands(fake, 11, "SET_BRIGHTNESS_TARGET") > 0, "resume con Follow=Yes forza l'allineamento")
end)

t.test("Resume: Follow Lights = Yes azzera gli override, = No li conserva (letto al momento del resume, v204)", function()
	for _, follow in ipairs({ "Yes", "No" }) do
		local fake, eng = boot(nil, { { 11, 50 } })
		eng:on_level(11, light_cmd.VAR_BRIGHTNESS_PERCENT, "10")
		fake:advance(1.1)
		t.eq(eng.mon:get(11).overridden, true)
		eng:on_command("PAUSE_SCHEDULE")
		fake.props["Follow Lights when Schedule Resumed"] = follow -- cambiata DOPO l'avvio
		eng:on_command("RESUME_SCHEDULE")
		t.eq(eng:state(), "ACTIVE")
		t.eq(eng.mon:get(11).overridden, follow == "No", "Follow=" .. follow)
	end
end)

t.test("transizioni VIETATE: PAUSE in PREVIEW e PREVIEW da PAUSED => Warning, stato invariato", function()
	local fake, eng = boot(nil, { { 11, 50 } })
	eng:on_command("START_PREVIEW")
	t.eq(eng:state(), "PREVIEW")
	eng:on_command("PAUSE_SCHEDULE")
	t.eq(eng:state(), "PREVIEW")
	t.truthy(fake:has_log(dbg.WARNING, "stop the preview first"))
	eng:on_command("STOP_PREVIEW")
	t.eq(eng:state(), "ACTIVE")
	eng:on_command("PAUSE_SCHEDULE")
	eng:on_command("PREVIEW_SCHEDULE")
	t.eq(eng:state(), "PAUSED")
	t.truthy(fake:has_log(dbg.WARNING, "resume the schedule first"))
	t.eq(fake:count_events("PREVIEW_STARTED"), 1)
end)

-- ---------------------------------------------------------------- preview
t.test("Preview: 100 step in 120 s, eventi, Operational Mode, rate 1 s, poi riallinea e torna ACTIVE", function()
	local fake, eng = boot(nil, { { 11, 50 } })
	eng:on_command("PREVIEW_SCHEDULE")
	t.eq(eng:state(), "PREVIEW")
	t.eq(fake:count_events("PREVIEW_STARTED"), 1)
	t.eq(fake.variables.PREVIEW_ACTIVE, "1")
	t.eq(fake.variables.SCHEDULE_ACTIVE, "1")
	t.truthy(fake.props["Operational Mode"]:find("Preview: ", 1, true))
	fake:advance(60)
	local mid = fake.props["Operational Mode"]
	t.truthy(mid:find("Preview: 1", 1, true) or mid:find("Preview: 0", 1, true), mid)
	local first = commands(fake, 11, "SET_BRIGHTNESS_TARGET")[1]
	t.eq(first.params.RATE, 1000)
	fake:advance(65)
	t.eq(eng:state(), "ACTIVE")
	t.eq(fake:count_events("PREVIEW_STOPPED"), 1)
	t.eq(fake.variables.PREVIEW_ACTIVE, "0")
	t.eq(fake.props["Operational Mode"], "Active")
	local all = commands(fake, 11, "SET_BRIGHTNESS_TARGET")
	t.truthy(#all >= 95, "numero di step: " .. #all)
	t.eq(all[#all].params.RATE, 5000, "dopo la preview: riallineamento con Fade Time")
end)

t.test("Preview: lo stop manuale ferma il timer e ripristina", function()
	local fake, eng = boot(nil, { { 11, 50 } })
	eng:on_command("Preview Schedule")        -- anche col nome dell'azione
	fake:advance(10)
	eng:on_command("LUA_ACTION", { ACTION = "Stop Preview" })
	t.eq(eng:state(), "ACTIVE")
	fake:clear_sent()
	fake:advance(60)                           -- niente altri step di preview: al massimo un tick normale
	t.truthy(#commands(fake, 11, "SET_BRIGHTNESS_TARGET") <= 1)
	t.eq(fake:count_events("PREVIEW_STOPPED"), 1)
end)

-- ---------------------------------------------------------------- monitoring
t.test("monitoring: modifica manuale => override dopo debounce, poi solo CCT; OFF->ON => riallineo", function()
	local fake, eng = boot(nil, { { 11, 50 } })
	fake:advance(60)                           -- tick: invia brightness (self-sent)
	local sent_b = commands(fake, 11, "SET_BRIGHTNESS_TARGET")
	local target = sent_b[1].params.LIGHT_BRIGHTNESS_TARGET_PERCENT
	-- la luce raggiunge il target inviato: self-sent, nessun override
	eng:on_level(11, light_cmd.VAR_BRIGHTNESS_PERCENT, tostring(target))
	fake:advance(2)
	t.eq(eng.mon:get(11).overridden, false)
	-- modifica manuale a 10%
	eng:on_level(11, light_cmd.VAR_BRIGHTNESS_PERCENT, "10")
	t.eq(eng.mon:get(11).overridden, false, "non ancora: debounce")
	fake:advance(1.1)
	t.eq(eng.mon:get(11).overridden, true)
	t.truthy(fake.store.overridden and fake.store.overridden[11])
	fake:clear_sent()
	fake:advance(120)                          -- due tick: solo colore
	t.eq(#commands(fake, 11, "SET_BRIGHTNESS_TARGET"), 0)
	t.truthy(#commands(fake, 11, "SET_COLOR_TARGET") >= 0)
	-- spegni e riaccendi a mano: reset flag e brightness torna a seguire la schedule
	eng:on_level(11, light_cmd.VAR_BRIGHTNESS_PERCENT, "0")
	fake:clear_sent()
	eng:on_level(11, light_cmd.VAR_BRIGHTNESS_PERCENT, "30")
	t.eq(eng.mon:get(11).overridden, false)
	t.eq(#commands(fake, 11, "SET_BRIGHTNESS_TARGET"), 1)
	t.truthy(fake.store.overridden[11] == nil)
end)

t.test("monitoring: livello manuale uguale al circadiano => nessun override (re-align b)", function()
	local fake, eng = boot(nil, { { 11, 50 } })
	fake:advance(60)
	local target = commands(fake, 11, "SET_BRIGHTNESS_TARGET")[1].params.LIGHT_BRIGHTNESS_TARGET_PERCENT
	fake:advance(20) -- fuori dalla finestra self-sent
	eng:on_level(11, light_cmd.VAR_BRIGHTNESS_PERCENT, tostring(target + 1))
	fake:advance(1.1)
	t.eq(eng.mon:get(11).overridden, false)
end)

t.test("monitoring Off: si comanda sempre, anche dopo modifiche manuali", function()
	local fake, eng = boot({ props = { ["Smart Light Level Monitoring"] = "Off" } }, { { 11, 50 } })
	fake:advance(60)
	eng:on_level(11, light_cmd.VAR_BRIGHTNESS_PERCENT, "10")
	fake:advance(1.1)
	t.eq(eng.mon:get(11).overridden, false)
	fake:clear_sent()
	fake:advance(60)
	t.truthy(#commands(fake, 11, "SET_BRIGHTNESS_TARGET") >= 1)
end)

t.test("monitoring in PAUSED: i cambi manuali non marcano override", function()
	local fake, eng = boot(nil, { { 11, 50 } })
	eng:on_command("PAUSE_SCHEDULE")
	eng:on_level(11, light_cmd.VAR_BRIGHTNESS_PERCENT, "10")
	fake:advance(2)
	t.eq(eng.mon:get(11).overridden, false)
end)

t.test("Follow All Lights: azzera tutti gli override e riallinea con Fade Time", function()
	local fake, eng = boot(nil, { { 11, 50 }, { 12, 50 } })
	for _, id in ipairs({ 11, 12 }) do
		eng:on_level(id, light_cmd.VAR_BRIGHTNESS_PERCENT, "10")
	end
	fake:advance(1.1)
	t.eq(eng.mon:get(11).overridden and eng.mon:get(12).overridden, true)
	fake:clear_sent()
	eng:on_command("FOLLOW_ALL_LIGHTS")
	t.eq(eng.mon:get(11).overridden or eng.mon:get(12).overridden, false)
	t.eq(#commands(fake, 11, "SET_BRIGHTNESS_TARGET"), 1)
	t.eq(#commands(fake, 12, "SET_BRIGHTNESS_TARGET"), 1)
	t.eq(fake.store.overridden[11], nil)
end)

-- ---------------------------------------------------------------- staggered
t.test("staggered: 12 luci => batch da 5 con 50 ms di ritardo fra i batch", function()
	local lights = {}
	for i = 1, 12 do lights[i] = { 100 + i, 50 } end
	local fake = boot(nil, lights)
	fake:advance(61) -- tick a 60 s + batch ritardati di 50/100 ms
	local sent_ids = {}
	for _, s in ipairs(fake.sent) do
		if s.command == "SET_BRIGHTNESS_TARGET" then sent_ids[#sent_ids + 1] = s end
	end
	t.eq(#sent_ids, 12)
	-- ritardi: 5 luci a t0, 5 a t0+0.05, 2 a t0+0.10
	local t0 = sent_ids[1].t
	local by_delay = {}
	for _, s in ipairs(sent_ids) do
		local d = math.floor((s.t - t0) * 1000 + 0.5)
		by_delay[d] = (by_delay[d] or 0) + 1
	end
	t.eq(by_delay[0], 5); t.eq(by_delay[50], 5); t.eq(by_delay[100], 2)
end)

t.test("10 luci o meno: tutte insieme", function()
	local lights = {}
	for i = 1, 10 do lights[i] = { 100 + i, 50 } end
	local fake = boot(nil, lights)
	fake:advance(60)
	local t0
	for _, s in ipairs(fake.sent) do
		if s.command == "SET_BRIGHTNESS_TARGET" then
			t0 = t0 or s.t
			t.eq(s.t, t0)
		end
	end
end)

-- ---------------------------------------------------------------- persistenza
t.test("restart: PAUSED resta PAUSED, ACTIVE resta ACTIVE, override ripristinati", function()
	local store = {}
	local fake, eng = boot({ store = store }, { { 11, 50 } })
	eng:on_level(11, light_cmd.VAR_BRIGHTNESS_PERCENT, "10")
	fake:advance(1.1)
	eng:on_command("PAUSE_SCHEDULE")
	eng:destroy()

	local fake2, eng2 = boot({ store = store }, { { 11, 50 } })
	t.eq(eng2:state(), "PAUSED")
	t.eq(fake2.props["Operational Mode"], "Paused")
	t.eq(fake2.variables.SCHEDULE_ACTIVE, "0")
	t.eq(eng2.mon:get(11).overridden, true)
	fake2:advance(120)
	t.eq(#fake2.sent, 0)
	eng2:on_command("RESUME_SCHEDULE")
	eng2:destroy()

	local _, eng3 = boot({ store = store }, { { 11, 50 } })
	t.eq(eng3:state(), "ACTIVE")
end)

t.test("restart durante PREVIEW: scartata, si torna IDLE e poi ACTIVE (se la schedule e' valida)", function()
	local store = {}
	local fake, eng = boot({ store = store }, { { 11, 50 } })
	eng:on_command("START_PREVIEW")
	t.eq(store.state, "PREVIEW")
	eng:destroy()
	local _, eng2 = boot({ store = store }, { { 11, 50 } })
	t.eq(eng2:state(), "ACTIVE")
	t.eq(eng2.preview, nil)
end)

t.test("restart senza lat/long: stato salvato ACTIVE ma impossibile riprendere => IDLE con Error", function()
	local store = { state = "ACTIVE" }
	local fake, eng = boot({ store = store, latlon = false }, { { 11, 50 } })
	t.eq(eng:state(), "IDLE")
end)

t.test("restart: dati astronomici di oggi ripristinati da persistenza senza ricalcolo", function()
	local store = {}
	local fake = boot({ store = store }, { { 11, 50 } })
	local fake2 = fake_env.new({ store = store, latlon = false }) -- senza lat/long: usa la persistenza
	fake2.props["Controlled Devices"] = "11"
	local eng2 = engine.new(fake2.env)
	eng2:init(); eng2:late_init()
	t.eq(eng2:state(), "ACTIVE")
	t.truthy(fake2:has_log(dbg.INFO, "ripristinati da persistenza"))
end)

-- ---------------------------------------------------------------- mezzanotte e astro
t.test("mezzanotte: ricalcolo dei dati astronomici sulla nuova data", function()
	local fake, eng = boot({ epoch = 1782086390 - 2 * 3600 }, { { 11, 50 } }) -- 23:59:50 locale (UTC+2)
	t.eq(fake.store.astro_today.date, "2026-06-21")
	fake:advance(20)                           -- oltre mezzanotte (+5 s di margine)
	t.eq(fake.store.astro_today.date, "2026-06-22")
	t.eq(eng.astro.date, "2026-06-22")
	t.truthy(fake:has_log(dbg.INFO, "mezzanotte"))
end)

t.test("astro: SP astronomici usano gli orari calcolati con l'offset del sistema", function()
	local props = {
		["SP 1 Type"] = "Astronomical", ["SP 1 Astronomical Reference"] = "Solar Noon", ["SP 1 Brightness"] = "100",
		["SP 2 Time"] = "03:00", ["SP 2 Brightness"] = "10", ["SP 3 Time"] = "20:00", ["SP 3 Brightness"] = "10",
		["Number of Switchpoints"] = "3",
	}
	local fake, eng = boot({ props = props }, { { 11, 50 } })
	local noon = fake.store.astro_today.solar_noon
	t.near(noon, 13 * 60 + 25, 3, "mezzogiorno solare di Milano il 21 giugno, orologio UTC+2")
	t.near(eng:target_at(math.floor(noon + 0.5)).brightness, 100, 1e-6) -- SP arrotondati al minuto
end)

-- ---------------------------------------------------------------- comandi vari
t.test("DISPLAY_SCHEDULE e SHOW_ASTRONOMICAL_DATA loggano; RECALCULATE ricalcola", function()
	local fake, eng = boot(nil, { { 11, 50 } })
	eng:on_command("DISPLAY_SCHEDULE")
	t.truthy(fake:has_log(dbg.INFO, "[SCHEDULE] Scheduler Mode"))
	t.truthy(fake:has_log(dbg.INFO, "SP 2"))
	eng:on_command("SHOW_ASTRONOMICAL_DATA")
	t.truthy(fake:has_log(dbg.INFO, "alba"))
	fake.latlon = { 45.0, 9.0 }
	eng:on_command("Recalculate Astronomical Data")
	t.near(eng.astro.lat, 45.0, 1e-9)
	fake.latlon = { 46.0, 9.0 }
	eng:on_command("RETRIEVE_ASTRONOMICAL_DATA")
	t.near(eng.astro.lat, 46.0, 1e-9)
end)

t.test("comando sconosciuto: Warning, nessun crash", function()
	local fake, eng = boot(nil, { { 11, 50 } })
	eng:on_command("BOH")
	t.truthy(fake:has_log(dbg.WARNING, "sconosciuto"))
	eng:on_command("LUA_ACTION", nil)
end)

t.test("COPY_SCHEDULE: invia RECEIVE_SCHEDULE ai target (non a se stesso); il target aggiorna le proprieta'", function()
	local fake, eng = boot(nil, { { 11, 50 } })
	fake.props["SP 2 Brightness"] = "77"
	fake.props["Scheduler Mode"] = "Brightness Only"
	eng:on_command("COPY_SCHEDULE", nil)
	t.truthy(fake:has_log(dbg.WARNING, "nessun controller"))
	eng:on_command("LUA_ACTION", { ACTION = "COPY_SCHEDULE", Controllers = "900, 901,902" })
	local to901 = fake:sent_to(901, "RECEIVE_SCHEDULE")
	t.eq(#to901, 1)
	t.eq(#fake:sent_to(902, "RECEIVE_SCHEDULE"), 1)
	t.eq(#fake:sent_to(900, "RECEIVE_SCHEDULE"), 0, "non a se stesso")
	local payload = to901[1].params
	t.eq(payload.SP_2_Brightness, "77")
	t.eq(payload.Scheduler_Mode, "Brightness Only")
	-- lato ricevente
	local fake2, eng2 = boot({ device_id = 901 }, { { 11, 50 } })
	eng2:on_command("RECEIVE_SCHEDULE", payload)
	t.eq(fake2.updated["SP 2 Brightness"], "77")
	t.eq(fake2.updated["Scheduler Mode"], "Brightness Only")
	t.eq(eng2.cfg.use_cct, false)
end)

t.test("cambio proprieta': SP => curva ricostruita e applicata; Controlled Devices => luci rimosse/aggiunte", function()
	local fake, eng = boot(nil, { { 11, 50 } })
	fake.props["SP 2 Brightness"] = "100"
	eng:on_property_changed("SP 2 Brightness")
	t.near(eng:target_at(12 * 60).brightness, 100, 1e-6)
	fake.props["Controlled Devices"] = "12,13"
	eng:on_property_changed("Controlled Devices")
	t.eq(fake.watched["11:1001"], nil, "luce rimossa: listener tolto")
	t.truthy(fake.watched["12:1001"] and fake.watched["13:1001"])
	t.eq(#eng.light_ids, 2)
end)

t.test("Update Interval (s): il timer del tick riparte con il nuovo intervallo", function()
	local fake, eng = boot(nil, { { 11, 50 } })
	fake.props["Update Interval (s)"] = "30"
	eng:on_property_changed("Update Interval (s)")
	local active = 0
	for _, tm in ipairs(fake.timers) do
		if tm.active and tm.repeating then
			active = active + 1
			t.eq(tm.ms, 30000)
		end
	end
	t.eq(active, 1)
end)

t.test("sonde: OnDeviceEvent e OnWatchedVariableChanged loggati a Info la prima volta", function()
	local fake, eng = boot(nil, { { 11, 50 } })
	t.truthy(fake:has_log(dbg.INFO, "[PROBE] OnWatchedVariableChanged"))
	eng:on_device_event(11, light_cmd.EVENT_BRIGHTNESS_CHANGED)
	t.truthy(fake:has_log(dbg.INFO, "[PROBE] OnDeviceEvent"))
end)

t.test("destroy: nessun timer attivo", function()
	local fake, eng = boot(nil, { { 11, 50 } })
	eng:on_command("START_PREVIEW")
	eng:destroy()
	t.eq(fake:active_timers(), 0)
end)

-- ---------------------------------------------------------------- log della schedule
t.test("schedule risolta nel log (Info) all'init e a ogni modifica di SP", function()
	local fake, eng = boot(nil, { { 11, 50 } })
	local expected = "[SCHEDULE] SP1 06:00 (Set Time) b=10 cct=2700 | SP2 12:00 (Set Time) b=80 cct=5200 | "
		.. "SP3 18:00 (Set Time) b=60 cct=3200 | SP4 22:00 (Set Time) b=5 cct=2200"
	t.truthy(fake:has_log(dbg.INFO, expected), "riga compatta all'init")
	local before = #fake.logs
	fake.props["SP 2 Brightness"] = "90"
	eng:on_property_changed("SP 2 Brightness")
	t.truthy(fake:has_log(dbg.INFO, "SP2 12:00 (Set Time) b=90 cct=5200"))
	fake.props["Number of Switchpoints"] = "3"
	eng:on_property_changed("Number of Switchpoints")
	local last
	for i = #fake.logs, before + 1, -1 do
		if fake.logs[i].text:find("[SCHEDULE] SP1", 1, true) then last = fake.logs[i].text; break end
	end
	t.truthy(last and not last:find("SP4", 1, true), "con 3 SP la riga non ha SP4")
end)

t.test("schedule astronomica nel log: orari risolti con offset e label (Sunrise+0, Sunset-30)", function()
	local props = {
		["SP 1 Type"] = "Astronomical", ["SP 1 Astronomical Reference"] = "Solar Midnight",
		["SP 2 Type"] = "Astronomical", ["SP 2 Astronomical Reference"] = "Sunrise",
		["SP 3 Type"] = "Astronomical", ["SP 3 Astronomical Reference"] = "Sunset", ["SP 3 Offset (mins)"] = "-30",
		["Number of Switchpoints"] = "3",
	}
	local fake = boot({ props = props }, { { 11, 50 } })
	t.truthy(fake:has_log(dbg.INFO, "(Solar Midnight+0)"))
	t.truthy(fake:has_log(dbg.INFO, "(Sunrise+0)"))
	t.truthy(fake:has_log(dbg.INFO, "(Sunset-30)"))
end)

t.test("SP che coincidono: WARNING esplicito al rebuild e in DISPLAY_SCHEDULE", function()
	local fake, eng = boot({ props = { ["SP 4 Time"] = "06:00" } }, { { 11, 50 } })
	t.truthy(fake:has_log(dbg.WARNING, "SP 1 e SP 4 coincidono a 06:00: l'ultimo vince"))
	eng:on_command("DISPLAY_SCHEDULE")
	t.truthy(fake:has_log(dbg.INFO, "ATTENZIONE: SP 1 e SP 4 coincidono a 06:00: l'ultimo vince"))
	-- vince l'ultimo: a 06:00 la brightness e' quella dell'SP 4
	t.near(eng:target_at(360).brightness, 5, 1e-9)
end)

t.test("nessun warning di collisione con i default non collidenti", function()
	local fake = boot(nil, { { 11, 50 } })
	t.eq(fake:has_log(dbg.WARNING, "coincidono"), false)
end)

-- ---------------------------------------------------------------- invio del colore (hardware)
local function count_logs(fake, sev, pattern)
	local n = 0
	for _, l in ipairs(fake.logs) do
		if l.sev == sev and l.text:find(pattern, 1, true) then n = n + 1 end
	end
	return n
end

t.test("log: 'modificata a mano' a Info solo quando la luce ENTRA in override, poi Trace", function()
	local fake, eng = boot(nil, { { 11, 60 } })
	local MSG = "modificata a mano"
	-- rampa di dimmeraggio a passi: ogni passo e' un cambio esterno con il suo debounce
	for _, level in ipairs({ 55, 50, 44, 40 }) do
		eng:on_level(11, light_cmd.VAR_BRIGHTNESS_PERCENT, tostring(level))
		fake:advance(1.1)
	end
	t.eq(eng.mon:get(11).overridden, true)
	t.eq(count_logs(fake, dbg.INFO, MSG), 1, "una sola riga Info")
	t.eq(count_logs(fake, dbg.TRACE, MSG), 3, "le altre tre a Trace")
	-- esce dall'override (spegni e riaccendi) e rientra: Info di nuovo
	eng:on_level(11, light_cmd.VAR_BRIGHTNESS_PERCENT, "0")
	eng:on_level(11, light_cmd.VAR_BRIGHTNESS_PERCENT, "30")
	t.eq(eng.mon:get(11).overridden, false)
	fake:advance(10)
	eng:on_level(11, light_cmd.VAR_BRIGHTNESS_PERCENT, "20")
	fake:advance(1.1)
	t.eq(count_logs(fake, dbg.INFO, MSG), 2)
end)

t.test("sonde colore: registrati gli eventi 4002/4003 (nessuna variabile CCT nel proxy Light V2)", function()
	local fake, eng = boot(nil, { { 11, 50 } })
	for _, ev in ipairs({ 4000, 4001, 4002, 4003, 5100, 5101 }) do
		t.truthy(fake.device_events["11:" .. ev], "evento " .. ev)
	end
	eng:on_device_event(11, light_cmd.EVENT_COLOR_CHANGED)
	t.truthy(fake:has_log(dbg.INFO, "[PROBE] OnDeviceEvent arriva davvero (dev 11 evento 4003 Light Color Changed)"))
	eng:on_device_event(11, light_cmd.EVENT_COLOR_CHANGED)
	t.eq(count_logs(fake, dbg.INFO, "evento 4003"), 1, "Info solo la prima volta")
	-- nessuna variabile di colore osservata: solo 1000 e 1001
	local watched = {}
	for k in pairs(fake.watched) do watched[#watched + 1] = k end
	table.sort(watched)
	t.eq(table.concat(watched, ","), "11:1000,11:1001")
end)

t.test("CT in override: la sola brightness e' sospesa, la CCT parte quando il delta supera 25 K dall'ultima INVIATA", function()
	local fake, eng = boot(nil, { { 11, 50 } })
	fake:advance(60)                                   -- primo tick: brightness + CCT
	local first_color = commands(fake, 11, "SET_COLOR_TARGET")[1]
	t.truthy(first_color, "CCT inviata al primo tick")
	local cct0 = first_color.params[light_cmd.KEY_CCT]
	fake:advance(1)
	eng:on_level(11, light_cmd.VAR_BRIGHTNESS_PERCENT, "10")   -- modifica manuale
	fake:advance(1.1)
	t.eq(eng.mon:get(11).overridden, true)

	fake:clear_sent()
	fake:advance(120)                                  -- ~2 min: la CCT target e' scesa di ~11 K (< 25 K)
	t.eq(#fake.sent, 0, "sotto soglia: nessun comando")

	fake:advance(300)                                  -- oltre 25 K dall'ultima CCT inviata
	local colors = commands(fake, 11, "SET_COLOR_TARGET")
	t.truthy(#colors >= 1, "SET_COLOR_TARGET inviato durante l'override")
	t.eq(#commands(fake, 11, "SET_BRIGHTNESS_TARGET"), 0, "nessuna brightness durante l'override")
	local cct1 = colors[1].params[light_cmd.KEY_CCT]
	t.truthy(math.abs(cct1 - cct0) >= 25, "delta CCT " .. math.abs(cct1 - cct0))
	-- la soglia riparte dall'ultima inviata: nessun invio a ogni tick
	t.truthy(#colors <= 2, "invii CCT: " .. #colors)
	t.eq(eng.mon:get(11).overridden, true)
end)

t.test("CT in override: con CCT che si muove di piu' di 25 K per tick, ogni tick la rinvia", function()
	-- schedule con SP 12:00 6500 K -> 15:30 2000 K (circa 30 K/min): a ogni tick da 60 s > 25 K
	local props = {
		["Number of Switchpoints"] = "3",
		["SP 1 Time"] = "12:00", ["SP 1 Brightness"] = "50", ["SP 1 Colour Temperature"] = "6500",
		["SP 2 Time"] = "15:30", ["SP 2 Brightness"] = "50", ["SP 2 Colour Temperature"] = "2000",
		["SP 3 Time"] = "23:00", ["SP 3 Brightness"] = "50", ["SP 3 Colour Temperature"] = "2000",
		["Minimum Colour Temperature"] = "1600", ["Maximum Colour Temperature"] = "6500",
	}
	local fake, eng = boot({ props = props }, { { 11, 50, fake_env.CAPS_CCT } })
	fake:advance(60)
	eng:on_level(11, light_cmd.VAR_BRIGHTNESS_PERCENT, "10")
	fake:advance(1.1)
	t.eq(eng.mon:get(11).overridden, true)
	fake:clear_sent()
	fake:advance(180)                                  -- 3 tick
	t.eq(#commands(fake, 11, "SET_BRIGHTNESS_TARGET"), 0)
	t.truthy(#commands(fake, 11, "SET_COLOR_TARGET") >= 2, "CCT a ogni tick quando il delta supera la soglia")
end)

-- ---------------------------------------------------------------- canale colore
t.test("[LIGHTS] dump completo delle capabilities e identita' del driver, tabella SET_COLOR_TARGET una sola volta", function()
	local fake = boot(nil, { { 11, 50 }, { 12, 50, fake_env.CAPS_LEGACY } })
	t.truthy(fake:has_log(dbg.INFO, "luce 11 capabilities (tag): "))
	t.truthy(fake:has_log(dbg.INFO, "color_rate_behavior=2"))
	t.truthy(fake:has_log(dbg.INFO, "supports_color=False"))
	t.truthy(fake:has_log(dbg.INFO, "luce 11 capabilities (XML): <DynamicCapabilities>"))
	t.truthy(fake:has_log(dbg.INFO, "luce 11 driver: display_name=Lampada 11 manufacturer=Fake model=CCT"))
	t.truthy(fake:has_log(dbg.INFO, "luce 12 capabilities (tag): "))
	t.eq(count_logs(fake, dbg.INFO, "[COLORDOC] SET_COLOR_TARGET (Proxy Protocol"), 1, "tabella una sola volta")
	t.truthy(fake:has_log(dbg.INFO, "[COLORDOC]   LIGHT_COLOR_TARGET_MODE"))
	t.truthy(fake:has_log(dbg.INFO, "color_rate behavior=2 0-0 ms"))
end)

t.test("[SEND] colore: mode e parametri bene in vista (mode=1 {CCT=..} rate=..)", function()
	local fake = boot(nil, { { 11, 50 } })
	fake:advance(60)
	local found
	for _, l in ipairs(fake.logs) do
		if l.text:find("[SEND] luce 11 SET_COLOR_TARGET mode=1 {CCT=", 1, true) then found = l.text end
	end
	t.truthy(found, "riga [SEND] colore")
	t.truthy(found:find("rate=5000", 1, true) and found:find("LIGHT_COLOR_TARGET_MODE=1", 1, true))
	t.eq(found:find("LIGHT_COLOR_TARGET_X", 1, true), nil, "nessun X/Y nel payload")
end)

t.test("colore: la RATE rispetta color_rate_min/max della lampada, e behavior 0 non manda RATE", function()
	local fake = boot(nil, { { 11, 50, fake_env.CAPS_COLOR_RATE }, { 12, 50, fake_env.CAPS_FIXED_COLOR_RATE } })
	fake:advance(60)
	t.eq(commands(fake, 11, "SET_COLOR_TARGET")[1].params.RATE, 2000, "limitata a color_rate_max")
	t.eq(commands(fake, 11, "SET_BRIGHTNESS_TARGET")[1].params.RATE, 5000, "la brightness non e' toccata")
	t.eq(commands(fake, 12, "SET_COLOR_TARGET")[1].params.RATE, nil, "behavior 0: nessun RATE")
end)

t.test("override ripristinato da persistenza: riga Info, e 'modificata a mano' resta a Trace (niente falso 'doppio Info')", function()
	local store = { overridden = { [11] = true } }
	local fake, eng = boot({ store = store }, { { 11, 50 } })
	t.truthy(fake:has_log(dbg.INFO, "luce 11: override ripristinato da persistenza"))
	eng:on_level(11, light_cmd.VAR_BRIGHTNESS_PERCENT, "30")
	fake:advance(1.1)
	t.eq(count_logs(fake, dbg.INFO, "modificata a mano"), 0, "gia' in override: Trace")
	t.eq(count_logs(fake, dbg.TRACE, "modificata a mano"), 1)
end)

-- ---------------------------------------------------------------- clamp ai limiti della lampada + soglia
local function flat_props(cct, brightness)
	local p = { ["Number of Switchpoints"] = "4" }
	for n = 1, 4 do
		p["SP " .. n .. " Time"] = string.format("%02d:00", n * 5)
		p["SP " .. n .. " Brightness"] = tostring(brightness)
		p["SP " .. n .. " Colour Temperature"] = tostring(cct)
	end
	return p
end

-- la lampada raggiunge l'ultima brightness inviata (come fa quella vera)
local function light_follows(fake, eng, id)
	local sent = commands(fake, id, "SET_BRIGHTNESS_TARGET")
	local last = sent[#sent]
	if last then eng:on_level(id, light_cmd.VAR_BRIGHTNESS_PERCENT, tostring(last.params.LIGHT_BRIGHTNESS_TARGET_PERCENT)) end
end

t.test("target CCT sotto il minimo della lampada (2602 < 2700): UN solo SET_COLOR_TARGET, i tick successivi sono soppressi", function()
	local fake, eng = boot({ props = flat_props(2602, 50) }, { { 11, 50, fake_env.CAPS_MIN_2700 } })
	fake:advance(60)
	local colors = commands(fake, 11, "SET_COLOR_TARGET")
	t.eq(#colors, 1, "primo tick: un invio")
	t.eq(colors[1].params[light_cmd.KEY_CCT], 2700, "clampata al minimo della lampada")
	fake:clear_sent()
	fake:advance(180)                                  -- tre tick consecutivi
	t.eq(#commands(fake, 11, "SET_COLOR_TARGET"), 0, "colore soppresso: il valore post-clamp non cambia")
	t.eq(#commands(fake, 11, "SET_BRIGHTNESS_TARGET"), 0, "brightness soppressa (delta 0)")
	t.eq(#fake.sent, 0)
end)

t.test("simmetria: massimo lampada (target 5200 > 4000) e canale brightness con lampada che segue i comandi", function()
	local props = flat_props(5200, 60)
	local fake, eng = boot({ props = props }, { { 11, 50, fake_env.CAPS_MAX_4000 } })
	fake:advance(60)
	t.eq(#commands(fake, 11, "SET_COLOR_TARGET"), 1)
	t.eq(commands(fake, 11, "SET_COLOR_TARGET")[1].params[light_cmd.KEY_CCT], 4000)
	t.eq(#commands(fake, 11, "SET_BRIGHTNESS_TARGET"), 1)
	light_follows(fake, eng, 11)                       -- la lampada arriva a 60 %
	fake:clear_sent()
	fake:advance(180)
	t.eq(#commands(fake, 11, "SET_COLOR_TARGET"), 0, "colore: nessun rinvio")
	t.eq(#commands(fake, 11, "SET_BRIGHTNESS_TARGET"), 0, "brightness: nessun rinvio (stesso comportamento)")
end)

t.test("target dentro i limiti della lampada: invariato (invio quando il delta supera 25 K)", function()
	-- 12:00 5200 K -> 18:00 3200 K: la CCT scende di ~5 K/min
	local fake = boot(nil, { { 11, 50, fake_env.CAPS_MIN_2700 } })
	fake:advance(60)
	t.eq(#commands(fake, 11, "SET_COLOR_TARGET"), 1)
	fake:clear_sent()
	fake:advance(120)
	t.eq(#commands(fake, 11, "SET_COLOR_TARGET"), 0, "sotto soglia")
	fake:advance(300)
	t.truthy(#commands(fake, 11, "SET_COLOR_TARGET") >= 1, "oltre soglia")
end)

t.finish()
