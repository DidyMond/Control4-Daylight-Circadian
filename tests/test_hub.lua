-- Test di libs/hub.lua (webview) e dell'anello completo UI -> hub -> controller -> hub -> UI
local t = require "tests.support.harness"
local hub_mod = require "libs.hub"
local json = require "libs.json"
local protocol = require "libs.protocol"
local engine = require "libs.engine"
local fake_env = require "tests.support.fake_env"
local light_cmd = require "libs.light_cmd"

-- env finto della webview
local function new_hub(bound)
	local fake = { bound = bound or {}, to_controller = {}, to_ui = {}, logs = {}, lang = "it" }
	local env = {
		log = function(sev, text) fake.logs[#fake.logs + 1] = { sev = sev, text = text } end,
		bound_controllers = function() return fake.bound end,
		send_to_controller = function(id, text) fake.to_controller[#fake.to_controller + 1] = { id = id, text = text } end,
		push_to_ui = function(text) fake.to_ui[#fake.to_ui + 1] = text end,
		language = function() return fake.lang end,
	}
	fake.env = env
	return fake, hub_mod.new(env)
end

local function state_msg(id, name, extra)
	local msg = { v = 1, type = "STATE", controller = id, name = name, state = "ACTIVE", count = 4,
		switchpoints = json.array({}), warnings = json.array({}), lights = json.array({}) }
	for k, v in pairs(extra or {}) do msg[k] = v end
	return json.encode(msg)
end

t.test("refresh: registra i controller legati e chiede GET_STATE a ciascuno", function()
	local fake, hub = new_hub({ [11] = "Soggiorno", [12] = "Camera" })
	t.eq(hub:refresh(), 2)
	t.eq(#fake.to_controller, 2)
	for _, sent in ipairs(fake.to_controller) do
		local req = assert(protocol.decode(sent.text))
		t.eq(req.op, "GET_STATE")
		t.truthy(req.id:match("^w%d+$"))
	end
	local list = hub:list()
	t.eq(#list, 2)
	t.eq(list[1].id, 11); t.eq(list[1].name, "Soggiorno"); t.eq(list[1].bound, true)
end)

t.test("refresh: non richiede di nuovo lo STATE a chi ce l'ha; segnala controller non piu' legati", function()
	local fake, hub = new_hub({ [11] = "A" })
	hub:refresh()
	hub:on_message(state_msg(11, "A"))
	fake.to_controller = {}
	hub:refresh()
	t.eq(#fake.to_controller, 0)
	fake.bound = {}
	hub:refresh()
	t.eq(hub:list()[1].bound, false)
end)

t.test("on_message: STATE aggiorna il registro e viene girato alla pagina", function()
	local fake, hub = new_hub({ [11] = "A" })
	hub:refresh()
	hub:on_message(state_msg(11, "Soggiorno"))
	local c = hub:list()[1]
	t.eq(c.name, "Soggiorno"); t.eq(c.state.state, "ACTIVE")
	t.eq(#fake.to_ui, 1)
	local pushed = assert(protocol.decode(fake.to_ui[1]))
	t.eq(pushed.type, "STATE"); t.eq(pushed.controller, 11)
end)

t.test("on_message: HELLO da un controller non ancora legato lo aggiunge; PREVIEW e ACK con STATE", function()
	local fake, hub = new_hub({})
	hub:on_message(json.encode({ v = 1, type = "HELLO", controller = 20, name = "Nuovo" }))
	t.eq(hub:list()[1].id, 20); t.eq(hub:list()[1].name, "Nuovo")
	hub:on_message(json.encode({ v = 1, type = "PREVIEW", controller = 20, active = true, minute = 120, step = 8 }))
	t.eq(hub.controllers[20].preview.minute, 120)
	hub:on_message(json.encode({ v = 1, type = "ACK", id = "zz", op = "GET_STATE", ok = true, controller = 20,
		state = { v = 1, type = "STATE", controller = 20, state = "PAUSED" } }))
	t.eq(hub.controllers[20].state.state, "PAUSED")
	t.eq(#fake.to_ui, 3)
end)

t.test("on_message: ACK senza 'controller' lo riceve dalla richiesta in sospeso; messaggio non valido ignorato", function()
	local fake, hub = new_hub({ [11] = "A" })
	hub:refresh()
	local req_id = assert(protocol.decode(fake.to_controller[1].text)).id
	hub:on_message(json.encode({ v = 1, type = "ACK", id = req_id, op = "GET_STATE", ok = false, error = "boh" }))
	local pushed = assert(protocol.decode(fake.to_ui[1]))
	t.eq(pushed.controller, 11)
	t.eq(hub.pending[req_id], nil)
	local n = #fake.to_ui
	hub:on_message("non json")
	hub:on_message('{"v":9}')
	t.eq(#fake.to_ui, n)
end)

t.test("ui_request DC_PING / DC_LIST: sempre JSON valido { v, ok }", function()
	local fake, hub = new_hub({ [11] = "A" })
	local ping = assert(json.decode(hub:ui_request("DC_PING", {})))
	t.eq(ping.ok, true); t.eq(ping.v, 1); t.eq(ping.language, "it"); t.eq(ping.protocol, 1)
	local list = assert(json.decode(hub:ui_request("DC_LIST", {})))
	t.eq(list.ok, true); t.eq(#list.controllers, 1); t.eq(list.controllers[1].id, 11)
	t.eq(assert(json.decode(hub:ui_request("BOH", {}))).ok, false)
	t.eq(assert(json.decode(hub:ui_request("DC_LIST", nil))).ok, true)
end)

t.test("ui_request DC_GET_STATE: STATE in cache subito + richiesta di STATE fresco", function()
	local fake, hub = new_hub({ [11] = "A", [12] = "B" })
	hub:refresh()
	hub:on_message(state_msg(11, "A"))
	fake.to_controller = {}
	local res = assert(json.decode(hub:ui_request("DC_GET_STATE", { controller = "11" })))
	t.eq(res.ok, true); t.eq(#res.controllers, 1); t.eq(res.controllers[1].state.state, "ACTIVE")
	t.eq(#fake.to_controller, 1); t.eq(fake.to_controller[1].id, 11)
	fake.to_controller = {}
	local all = assert(json.decode(hub:ui_request("DC_GET_STATE", {})))
	t.eq(#all.controllers, 2); t.eq(#fake.to_controller, 2)
	t.eq(assert(json.decode(hub:ui_request("DC_GET_STATE", { controller = 99 }))).ok, false)
end)

t.test("ui_request DC_CMD: valida, inoltra DC_REQUEST al controller giusto; args come tabella o come stringa JSON", function()
	local fake, hub = new_hub({ [11] = "A" })
	hub:refresh()
	fake.to_controller = {}
	local res = assert(json.decode(hub:ui_request("DC_CMD", { controller = 11, op = "SET_SWITCHPOINT",
		args = { n = 2, brightness = 90 } })))
	t.eq(res.ok, true); t.eq(res.queued, true); t.eq(res.controller, 11); t.eq(res.op, "SET_SWITCHPOINT")
	local req = assert(protocol.decode(fake.to_controller[1].text))
	t.eq(fake.to_controller[1].id, 11)
	t.eq(req.op, "SET_SWITCHPOINT"); t.eq(req.args.n, 2); t.eq(req.args.brightness, 90); t.eq(req.id, res.id)
	hub:ui_request("DC_CMD", { controller = 11, op = "SET_MODE", args = '{"mode":"brightness"}' })
	t.eq(assert(protocol.decode(fake.to_controller[2].text)).args.mode, "brightness")
	hub:ui_request("DC_CMD", { controller = 11, op = "PAUSE" })
	t.eq(assert(protocol.decode(fake.to_controller[3].text)).op, "PAUSE")
end)

t.test("ui_request DC_CMD: controller sconosciuto, op sconosciuta e args non validi rifiutati senza inoltro", function()
	local fake, hub = new_hub({ [11] = "A" })
	hub:refresh()
	fake.to_controller = {}
	for _, p in ipairs({
		{ controller = 99, op = "PAUSE" },
		{ controller = 11, op = "BOH" },
		{ controller = 11, op = "SET_SWITCHPOINT", args = { n = 2, brightness = 500 } },
		{ controller = 11, op = "SET_MODE", args = {} },
		{ op = "PAUSE" },
	}) do
		local res = assert(json.decode(hub:ui_request("DC_CMD", p)))
		t.eq(res.ok, false); t.truthy(type(res.error) == "string")
	end
	t.eq(#fake.to_controller, 0)
end)

t.test("describe: righe per il log", function()
	local _, hub = new_hub({ [11] = "A" })
	t.truthy(hub:describe()[1]:find("nessun controller", 1, true))
	hub:refresh()
	hub:on_message(state_msg(11, "A"))
	t.truthy(hub:describe()[1]:find("controller 11 (A) legato stato=ACTIVE 4 SP", 1, true))
end)

-- ---------------------------------------------------------------- anello completo
-- controller (engine + fake env) <-> hub, con i trasporti collegati fra loro
local function wire()
	local cfake = fake_env.new({ props = { ["Controlled Devices"] = "31" } })
	local engine_inst = engine.new(cfake.env)
	local hfake, hub = new_hub({ [900] = "Controller 900" })
	-- controller -> hub
	cfake.env.send_to_webview = function(text) hub:on_message(text) end
	-- hub -> controller
	hfake.env.send_to_controller = function(id, text)
		engine_inst:on_command("DC_REQUEST", { json = text })
	end
	engine_inst:init()
	engine_inst:late_init()
	engine_inst:on_level(31, light_cmd.VAR_BRIGHTNESS_PERCENT, "50")
	return cfake, engine_inst, hfake, hub
end

local function ui_msgs(hfake, mtype)
	local out = {}
	for _, text in ipairs(hfake.to_ui) do
		local m = assert(protocol.decode(text))
		if not mtype or m.type == mtype then out[#out + 1] = m end
	end
	return out
end

t.test("anello: la UI chiede la lista, riceve STATE con la curva del motore", function()
	local cfake, eng, hfake, hub = wire()
	local list = assert(json.decode(hub:ui_request("DC_LIST", {})))
	t.eq(list.ok, true)
	t.eq(#list.controllers, 1)
	local state = list.controllers[1].state
	t.truthy(state, "STATE gia' noto dopo il primo giro")
	t.eq(state.controller, 900)
	t.eq(#state.curve.samples, 144)
	t.eq(state.count, 4)
	t.eq(state.name, "Controller 900")
end)

t.test("anello: DC_CMD SET_SWITCHPOINT => proprieta' del controller, ACK e STATE aggiornato fino alla UI", function()
	local cfake, eng, hfake, hub = wire()
	hub:ui_request("DC_LIST", {})
	hfake.to_ui = {}
	local res = assert(json.decode(hub:ui_request("DC_CMD", { controller = 900, op = "SET_SWITCHPOINT",
		args = { n = 3, brightness = 95, cct = 5800 } })))
	t.eq(res.ok, true)
	t.eq(cfake.props["SP 3 Brightness"], "95")
	t.eq(cfake.props["SP 3 Colour Temperature"], "5800")
	local acks = ui_msgs(hfake, "ACK")
	t.eq(#acks, 1); t.eq(acks[1].ok, true); t.eq(acks[1].controller, 900); t.eq(acks[1].id, res.id)
	local states = ui_msgs(hfake, "STATE")
	t.truthy(#states >= 1)
	t.eq(states[#states].switchpoints[3].brightness, 95)
	t.eq(hub:list()[1].state.switchpoints[3].cct, 5800)
end)

t.test("anello: modifica da Composer => push alla UI senza richieste", function()
	local cfake, eng, hfake, hub = wire()
	hub:ui_request("DC_LIST", {})
	hfake.to_ui = {}
	cfake.props["SP 1 Brightness"] = "12"
	eng:on_property_changed("SP 1 Brightness")
	local states = ui_msgs(hfake, "STATE")
	t.eq(#states, 1)
	t.eq(states[1].switchpoints[1].brightness, 12)
end)

t.test("anello: PREVIEW dalla UI => avanzamento e stato, e PAUSE vietata torna come ACK ok=false", function()
	local cfake, eng, hfake, hub = wire()
	hub:ui_request("DC_LIST", {})
	hfake.to_ui = {}
	hub:ui_request("DC_CMD", { controller = 900, op = "PREVIEW" })
	cfake:advance(5)
	t.truthy(#ui_msgs(hfake, "PREVIEW") >= 3)
	hfake.to_ui = {}
	hub:ui_request("DC_CMD", { controller = 900, op = "PAUSE" })
	local ack = ui_msgs(hfake, "ACK")[1]
	t.eq(ack.ok, false); t.truthy(ack.error:find("PREVIEW", 1, true))
	hub:ui_request("DC_CMD", { controller = 900, op = "STOP_PREVIEW" })
	t.eq(eng:state(), "ACTIVE")
end)

t.test("ui_request: ogni risposta riporta il rid della pagina (richiesta e risposta si collegano), anche gli errori", function()
	local fake, hub = new_hub({ [11] = "Ctrl" })
	hub:refresh()
	local ok = assert(json.decode(hub:ui_request("DC_CMD", { rid = "abc-1", controller = 11, op = "PAUSE" })))
	t.eq(ok.rid, "abc-1"); t.eq(ok.queued, true); t.truthy(ok.id, "id hub per collegare l'ACK del controller")
	local bad = assert(json.decode(hub:ui_request("DC_CMD", { rid = 42, controller = 99, op = "PAUSE" })))
	t.eq(bad.ok, false); t.eq(bad.rid, "42")
	t.eq(assert(json.decode(hub:ui_request("DC_PING", { rid = "p" }))).rid, "p")
	t.eq(assert(json.decode(hub:ui_request("DC_PING", {}))).rid, nil, "senza rid: nessun campo")
end)

t.finish()
