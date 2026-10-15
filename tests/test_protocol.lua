-- Test di libs/protocol.lua (codec, validazione, mappa sulle proprieta', snapshot) e della
-- parte controller del protocollo in libs/engine.lua (richieste dalla webview, push)
local t = require "tests.support.harness"
local protocol = require "libs.protocol"
local json = require "libs.json"
local engine = require "libs.engine"
local fake_env = require "tests.support.fake_env"
local light_cmd = require "libs.light_cmd"
local dbg = require "libs.debug"

-- ---------------------------------------------------------------- libs/protocol.lua
t.test("decode: oggetto con v = 1; versione sbagliata o JSON non valido => nil + errore", function()
	local msg = assert(protocol.decode('{"v":1,"id":"7","op":"GET_STATE"}'))
	t.eq(msg.op, "GET_STATE")
	t.eq((protocol.decode('{"v":2}')), nil)
	t.eq((protocol.decode('{"op":"X"}')), nil)
	t.eq((protocol.decode("[1]")), nil)
	t.eq((protocol.decode("{")), nil)
	t.eq((protocol.decode(nil)), nil)
end)

t.test("request/ack: forma dei messaggi e roundtrip JSON", function()
	local req = protocol.request("42", "SET_MODE", { mode = "both" }, 900)
	local back = assert(protocol.decode(protocol.encode(req)))
	t.eq(back.id, "42"); t.eq(back.op, "SET_MODE"); t.eq(back.from, 900); t.eq(back.args.mode, "both")
	local ack = protocol.ack("42", "SET_MODE", false, "boom", { state = "ACTIVE" })
	t.eq(ack.type, "ACK"); t.eq(ack.ok, false); t.eq(ack.error, "boom"); t.eq(ack.state, "ACTIVE"); t.eq(ack.v, 1)
	t.eq(protocol.ack("1", "X", true).error, nil)
end)

t.test("property_writes SET_SWITCHPOINT: nomi del driver.xml, valori come li scrive Composer", function()
	local w = assert(protocol.property_writes("SET_SWITCHPOINT",
		{ n = 3, type = "Astronomical", time = "7:05", astroRef = "Solar Noon", offset = -30, brightness = 80.4, cct = 4000 }))
	local m = {}
	for _, kv in ipairs(w) do m[kv[1]] = kv[2] end
	t.eq(m["SP 3 Type"], "Astronomical")
	t.eq(m["SP 3 Time"], "07:05")
	t.eq(m["SP 3 Astronomical Reference"], "Solar Noon")
	t.eq(m["SP 3 Offset (mins)"], "-30")
	t.eq(m["SP 3 Brightness"], "80")
	t.eq(m["SP 3 Colour Temperature"], "4000")
	t.eq(#w, 6)
end)

t.test("property_writes SET_SWITCHPOINT: solo i campi presenti; alias e numeri come stringa", function()
	local w = assert(protocol.property_writes("SET_SWITCHPOINT", { n = "2", brightness = "55", type = "astro", astroRef = "solar_noon" }))
	local m = {}
	for _, kv in ipairs(w) do m[kv[1]] = kv[2] end
	t.eq(m["SP 2 Brightness"], "55"); t.eq(m["SP 2 Type"], "Astronomical"); t.eq(m["SP 2 Astronomical Reference"], "Solar Noon")
	t.eq(#w, 3)
	t.eq(assert(protocol.property_writes("SET_SWITCHPOINT", { n = 1, type = "time" }))[1][2], "Set Time")
end)

t.test("property_writes: rifiuta valori fuori range, tipi sbagliati, campi mancanti", function()
	local bad = {
		{ "SET_SWITCHPOINT", {} }, { "SET_SWITCHPOINT", { n = 0, brightness = 1 } }, { "SET_SWITCHPOINT", { n = 11, brightness = 1 } },
		{ "SET_SWITCHPOINT", { n = 1 } }, { "SET_SWITCHPOINT", { n = 1, brightness = 101 } },
		{ "SET_SWITCHPOINT", { n = 1, brightness = -1 } }, { "SET_SWITCHPOINT", { n = 1, cct = 1500 } },
		{ "SET_SWITCHPOINT", { n = 1, cct = 6600 } }, { "SET_SWITCHPOINT", { n = 1, offset = 181 } },
		{ "SET_SWITCHPOINT", { n = 1, time = "25:00" } }, { "SET_SWITCHPOINT", { n = 1, time = "7.30" } },
		{ "SET_SWITCHPOINT", { n = 1, type = "boh" } }, { "SET_SWITCHPOINT", { n = 1, astroRef = "Moonrise" } },
		{ "SET_SWITCHPOINT", { n = 1, brightness = "abc" } }, { "SET_SWITCHPOINT", { n = 1, brightness = true } },
		{ "SET_CT_LIMITS", { min = 5000, max = 3000 } }, { "SET_CT_LIMITS", { min = 1000, max = 3000 } },
		{ "SET_CT_LIMITS", { min = 2000 } }, { "SET_MODE", { mode = "boh" } }, { "SET_MODE", {} },
		{ "SET_NUM_SP", { count = 2 } }, { "SET_NUM_SP", { count = 11 } }, { "SET_NUM_SP", {} },
		{ "BOH", {} },
	}
	for i, c in ipairs(bad) do
		local w, err = protocol.property_writes(c[1], c[2])
		t.eq(w, nil, "caso " .. i .. " " .. c[1])
		t.truthy(type(err) == "string" and #err > 0, "messaggio caso " .. i)
	end
end)

t.test("property_writes: SET_CT_LIMITS, SET_MODE (alias), SET_NUM_SP; op senza proprieta'", function()
	local w = assert(protocol.property_writes("SET_CT_LIMITS", { min = 2200, max = 6500 }))
	t.eq(w[1][1], "Minimum Colour Temperature"); t.eq(w[1][2], "2200")
	t.eq(w[2][1], "Maximum Colour Temperature"); t.eq(w[2][2], "6500")
	t.eq(assert(protocol.property_writes("SET_MODE", { mode = "brightness" }))[1][2], "Brightness Only")
	t.eq(assert(protocol.property_writes("SET_MODE", { mode = "cct" }))[1][2], "Colour Temperature Only")
	t.eq(assert(protocol.property_writes("SET_MODE", { mode = "Brightness + Colour Temperature" }))[1][2], "Brightness + Colour Temperature")
	t.eq(assert(protocol.property_writes("SET_NUM_SP", { count = 5 }))[1][2], "5")
	for _, op in ipairs({ "GET_STATE", "PAUSE", "RESUME", "PREVIEW", "STOP_PREVIEW", "FOLLOW" }) do
		t.eq(#assert(protocol.property_writes(op, {})), 0, op)
	end
end)

-- ---------------------------------------------------------------- engine: richieste e push
local function boot(opts, lights)
	opts = opts or {}
	opts.props = opts.props or {}
	local ids = {}
	for _, l in ipairs(lights or {}) do ids[#ids + 1] = tostring(l[1]) end
	opts.props["Controlled Devices"] = table.concat(ids, ",")
	local fake = fake_env.new(opts)
	local eng = engine.new(fake.env)
	eng:init()
	eng:late_init()
	for _, l in ipairs(lights or {}) do
		eng:on_level(l[1], light_cmd.VAR_LIGHT_STATE, l[2] > 0 and "1" or "0")
		eng:on_level(l[1], light_cmd.VAR_BRIGHTNESS_PERCENT, tostring(l[2]))
	end
	return fake, eng
end

-- messaggi inviati alla webview, decodificati
local function sent(fake)
	local out = {}
	for _, text in ipairs(fake.webview) do out[#out + 1] = assert(protocol.decode(text)) end
	return out
end

local function last_of(fake, msg_type)
	local all = sent(fake)
	for i = #all, 1, -1 do if all[i].type == msg_type then return all[i] end end
end

local function request(eng, id, op, args)
	eng:on_command("DC_REQUEST", { json = protocol.encode(protocol.request(id, op, args, 900)) })
end

t.test("avvio: HELLO seguito da STATE (schedule risolta, curva campionata, stato)", function()
	local fake = boot(nil, { { 11, 50 } })
	local msgs = sent(fake)
	local hello
	for _, m in ipairs(msgs) do if m.type == "HELLO" then hello = m end end
	t.truthy(hello, "HELLO inviato")
	t.eq(hello.controller, 900)
	t.eq(msgs[#msgs].type, "STATE", "l'ultimo messaggio e' lo STATE (dopo HELLO)")
	local state = last_of(fake, "STATE")
	t.truthy(state, "STATE inviato")
	t.eq(state.controller, 900)
	t.eq(state.state, "ACTIVE")
	t.eq(state.mode, "Brightness + Colour Temperature")
	t.eq(state.count, 4)
	t.eq(state.ct.min, 2200); t.eq(state.ct.max, 6500)
	t.eq(#state.switchpoints, 4)
	t.eq(state.switchpoints[1].n, 1)
	t.eq(state.switchpoints[1].type, "Set Time")
	t.eq(state.switchpoints[1].time, "06:00")
	t.eq(state.switchpoints[1].at, "06:00")
	t.eq(state.switchpoints[1].t, 360)
	t.eq(state.switchpoints[2].brightness, 80)
	t.eq(#state.curve.samples, 144)
	t.eq(state.curve.step, 10)
	t.eq(state.monitoring, true)
	t.eq(state.lights[1].id, 11)
	t.truthy(state.astro and state.astro.date == "2026-06-21")
end)

t.test("la curva dello STATE coincide con quella del motore (stessi valori di evaluate + CT limits)", function()
	local fake, eng = boot(nil, { { 11, 50 } })
	local state = last_of(fake, "STATE")
	for _, smp in ipairs(state.curve.samples) do
		local target = eng:target_at(smp[1])
		t.near(smp[2], target.brightness, 0.051, "brightness a t=" .. smp[1])
		t.near(smp[3], target.cct, 0.51, "cct a t=" .. smp[1])
	end
	-- CCT dei campioni nei CT limits
	for _, smp in ipairs(state.curve.samples) do t.truthy(smp[3] >= 2200 and smp[3] <= 6500) end
end)

t.test("GET_STATE: ACK con lo snapshot completo", function()
	local fake, eng = boot(nil, { { 11, 50 } })
	fake.webview = {}
	request(eng, "r1", "GET_STATE")
	local ack = last_of(fake, "ACK")
	t.eq(ack.id, "r1"); t.eq(ack.op, "GET_STATE"); t.eq(ack.ok, true)
	t.eq(ack.state.type, "STATE")
	t.eq(#ack.state.curve.samples, 144)
end)

t.test("SET_SWITCHPOINT: scrive le proprieta' del controller, ricostruisce UNA volta, ACK + STATE aggiornato", function()
	local fake, eng = boot(nil, { { 11, 50 } })
	fake.webview = {}
	local rebuilds = 0
	local before = #fake.logs
	request(eng, "r2", "SET_SWITCHPOINT", { n = 2, brightness = 100, cct = 6000, time = "11:30" })
	t.eq(fake.props["SP 2 Brightness"], "100")
	t.eq(fake.props["SP 2 Colour Temperature"], "6000")
	t.eq(fake.props["SP 2 Time"], "11:30")
	t.eq(fake.updated["SP 2 Brightness"], "100", "scritta con UpdateProperty")
	for i = before + 1, #fake.logs do
		if fake.logs[i].text:find("[SCHEDULE] SP1", 1, true) then rebuilds = rebuilds + 1 end
	end
	t.eq(rebuilds, 1, "una sola ricostruzione per richiesta")
	local ack = last_of(fake, "ACK")
	t.eq(ack.ok, true); t.eq(ack.applied, 3)
	local state = last_of(fake, "STATE")
	t.eq(state.switchpoints[2].brightness, 100)
	t.eq(state.switchpoints[2].at, "11:30")
	t.near(eng:target_at(690).brightness, 100, 1e-6, "il motore usa subito il nuovo SP (11:30)")
end)

t.test("richiesta non valida: ACK ok=false con errore, nessuna proprieta' toccata, nessun rebuild", function()
	local fake, eng = boot(nil, { { 11, 50 } })
	fake.webview = {}
	fake.updated = {}
	request(eng, "r3", "SET_SWITCHPOINT", { n = 2, brightness = 500 })
	local ack = last_of(fake, "ACK")
	t.eq(ack.ok, false); t.truthy(ack.error:find("brightness", 1, true))
	t.eq(next(fake.updated), nil)
	eng:on_command("DC_REQUEST", { json = "non json" })
	t.eq(last_of(fake, "ACK").ok, false)
	eng:on_command("DC_REQUEST", nil)
	request(eng, "r4", "BOH")
	t.eq(last_of(fake, "ACK").ok, false)
end)

t.test("SET_CT_LIMITS / SET_MODE / SET_NUM_SP: applicati, STATE riflette i nuovi valori", function()
	local fake, eng = boot(nil, { { 11, 50 } })
	request(eng, "a", "SET_CT_LIMITS", { min = 3000, max = 5000 })
	request(eng, "b", "SET_MODE", { mode = "brightness" })
	request(eng, "c", "SET_NUM_SP", { count = 3 })
	local state = last_of(fake, "STATE")
	t.eq(state.ct.min, 3000); t.eq(state.ct.max, 5000)
	t.eq(state.mode, "Brightness Only")
	t.eq(state.count, 3)
	t.eq(#state.switchpoints, 3)
	for _, smp in ipairs(state.curve.samples) do t.truthy(smp[3] >= 3000 and smp[3] <= 5000) end
end)

t.test("PAUSE / RESUME / PREVIEW / STOP_PREVIEW / FOLLOW: ACK con lo stato, transizioni vietate => ok=false", function()
	local fake, eng = boot(nil, { { 11, 50 } })
	request(eng, "p1", "PAUSE")
	local ack = last_of(fake, "ACK")
	t.eq(ack.ok, true); t.eq(ack.state, "PAUSED")
	t.eq(last_of(fake, "STATE").state, "PAUSED")
	request(eng, "p2", "PREVIEW")                         -- vietata da PAUSED
	ack = last_of(fake, "ACK")
	t.eq(ack.ok, false); t.truthy(ack.error:find("PAUSED", 1, true))
	request(eng, "p3", "RESUME")
	t.eq(last_of(fake, "ACK").ok, true)
	request(eng, "p4", "PREVIEW")
	t.eq(last_of(fake, "ACK").state, "PREVIEW")
	request(eng, "p5", "PAUSE")                           -- vietata da PREVIEW
	t.eq(last_of(fake, "ACK").ok, false)
	request(eng, "p6", "STOP_PREVIEW")
	t.eq(last_of(fake, "ACK").ok, true)
	t.eq(eng:state(), "ACTIVE")
	request(eng, "p7", "FOLLOW")
	t.eq(last_of(fake, "ACK").ok, true)
	request(eng, "p8", "STOP_PREVIEW")                    -- nessuna preview in corso
	t.eq(last_of(fake, "ACK").ok, false)
end)

t.test("preview: messaggi PREVIEW di avanzamento (minute/step) e chiusura active=false", function()
	local fake, eng = boot(nil, { { 11, 50 } })
	fake.webview = {}
	request(eng, "q", "PREVIEW")
	fake:advance(6)
	local progress = {}
	for _, m in ipairs(sent(fake)) do if m.type == "PREVIEW" then progress[#progress + 1] = m end end
	t.truthy(#progress >= 4, "avanzamento durante la preview")
	t.eq(progress[1].active, true); t.eq(progress[1].step, 0); t.eq(progress[1].minute, 0)
	t.truthy(progress[3].minute > progress[2].minute)
	request(eng, "q2", "STOP_PREVIEW")
	local m = last_of(fake, "PREVIEW")
	t.eq(m.active, false)
end)

t.test("push: modifica da Composer (OnPropertyChanged) => nuovo STATE senza richiesta; STATE identici non si ripetono", function()
	local fake, eng = boot(nil, { { 11, 50 } })
	fake.webview = {}
	fake.props["SP 4 Brightness"] = "33"
	eng:on_property_changed("SP 4 Brightness")
	local state = last_of(fake, "STATE")
	t.truthy(state, "push dopo la modifica")
	t.eq(state.switchpoints[4].brightness, 33)
	local n = #fake.webview
	eng:on_property_changed("SP 4 Brightness")           -- stessa configurazione: niente nuovo push
	t.eq(#fake.webview, n)
end)

t.test("push: cambio di stato, override e luci", function()
	local fake, eng = boot(nil, { { 11, 50 } })
	fake.webview = {}
	eng:on_command("PAUSE_SCHEDULE")
	t.eq(last_of(fake, "STATE").state, "PAUSED")
	eng:on_command("RESUME_SCHEDULE")
	fake.webview = {}
	eng:on_level(11, light_cmd.VAR_BRIGHTNESS_PERCENT, "10")
	fake:advance(1.1)                                    -- override dopo il debounce
	local state = last_of(fake, "STATE")
	t.truthy(state, "STATE dopo l'override")
	t.eq(state.lights[1].overridden, true)
end)

t.test("senza webview (env.send_to_webview assente) l'engine funziona come prima", function()
	local fake = fake_env.new({ props = { ["Controlled Devices"] = "11" } })
	fake.env.send_to_webview = nil
	local eng = engine.new(fake.env)
	eng:init(); eng:late_init()
	eng:on_level(11, light_cmd.VAR_BRIGHTNESS_PERCENT, "50")
	fake:advance(61)
	t.eq(eng:state(), "ACTIVE")
	eng:on_command("DC_REQUEST", { json = protocol.encode(protocol.request("x", "PAUSE", {}, 1)) })
	t.eq(eng:state(), "PAUSED")
end)

t.test("snapshot di un controller IDLE (senza lat/long): ancora valido, senza astro", function()
	local fake = boot({ latlon = false }, { { 11, 50 } })
	local state = last_of(fake, "STATE")
	t.eq(state.state, "IDLE")
	t.eq(state.astro, nil)
	t.eq(#state.switchpoints, 4)
end)

t.test("DELETE_SWITCHPOINT: gli SP successivi scalano, il conteggio cala, UNA ricostruzione; sotto il minimo rifiuta", function()
	local fake, eng = boot(nil, { { 11, 50 } })
	local before = {}
	for n = 1, 4 do
		before[n] = { fake.props["SP " .. n .. " Brightness"], fake.props["SP " .. n .. " Colour Temperature"], fake.props["SP " .. n .. " Time"] }
	end
	fake.webview = {}
	local log_from = #fake.logs
	request(eng, "d1", "DELETE_SWITCHPOINT", { n = 2 })
	local rebuilds = 0
	for i = log_from + 1, #fake.logs do
		if fake.logs[i].text:find("[SCHEDULE] SP1", 1, true) then rebuilds = rebuilds + 1 end
	end
	t.eq(rebuilds, 1, "una sola ricostruzione per l'intera eliminazione")
	local ack = last_of(fake, "ACK")
	t.eq(ack.ok, true)
	t.eq(fake.props["Number of Switchpoints"], "3")
	t.eq(fake.props["SP 2 Brightness"], before[3][1], "SP3 -> SP2")
	t.eq(fake.props["SP 2 Colour Temperature"], before[3][2])
	t.eq(fake.props["SP 3 Brightness"], before[4][1], "SP4 -> SP3")
	t.eq(fake.props["SP 1 Brightness"], before[1][1], "SP1 intatto")
	local state = last_of(fake, "STATE")
	t.eq(state.count, 3); t.eq(#state.switchpoints, 3)
	-- al minimo (3) non si elimina piu'
	fake.updated = {}
	request(eng, "d2", "DELETE_SWITCHPOINT", { n = 1 })
	local nack = last_of(fake, "ACK")
	t.eq(nack.ok, false); t.truthy(nack.error:find("minimo", 1, true), nack.error)
	t.eq(next(fake.updated), nil, "nessuna proprieta' toccata")
end)

t.test("delete_writes: validazione di n e lista vuota di sicurezza", function()
	local get = function(name) return "v:" .. name end
	t.eq(protocol.delete_writes({ n = 11 }, 5, get), nil)
	t.eq(protocol.delete_writes({}, 5, get), nil)
	t.eq(protocol.delete_writes({ n = 6 }, 5, get), nil)             -- n oltre il conteggio
	local w = assert(protocol.delete_writes({ n = 5 }, 5, get))       -- l'ultimo: solo il conteggio
	t.eq(#w, 1); t.eq(w[1][1], "Number of Switchpoints"); t.eq(w[1][2], "4")
	local mid = assert(protocol.delete_writes({ n = 3 }, 5, get))
	t.eq(mid[1][1], "SP 3 Type"); t.eq(mid[1][2], "v:SP 4 Type")
	t.eq(mid[#mid][1], "Number of Switchpoints")
	t.eq(select(2, protocol.property_writes("DELETE_SWITCHPOINT", { n = 0 })) ~= nil, true)
end)

t.test("PREVIEW: i messaggi portano durata (fattore di accelerazione), luminosita' e CCT del passo; lo STATE la durata", function()
	local fake, eng = boot(nil, { { 11, 50 } })
	fake.webview = {}
	request(eng, "p1", "PREVIEW")
	fake:advance(30)
	local pv = last_of(fake, "PREVIEW")
	t.eq(pv.active, true)
	t.eq(pv.duration_s, engine.PREVIEW_DURATION_S)
	t.eq(86400 / pv.duration_s, 720, "fattore reale: 24h in 120 s")
	t.truthy(type(pv.brightness) == "number" and pv.brightness >= 0 and pv.brightness <= 100)
	t.truthy(type(pv.cct) == "number" and pv.cct >= 2200 and pv.cct <= 6500, "CCT nei CT limits")
	t.near(pv.brightness, eng:target_at(pv.minute).brightness, 0.51)
	local st = last_of(fake, "STATE")
	t.eq(st.preview.active, true); t.eq(st.preview.duration_s, engine.PREVIEW_DURATION_S)
	request(eng, "p2", "STOP_PREVIEW")
	t.eq(last_of(fake, "PREVIEW").active, false)
end)

t.finish()
