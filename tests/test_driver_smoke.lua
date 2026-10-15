-- Smoke test dell'adattatore drivers/controller/driver.lua con un namespace C4 finto.
-- Verifica solo il cablaggio (callback di Director -> engine -> chiamate C4); la
-- logica e' in tests/test_engine.lua. Il driver vero e la sua interazione con
-- Director si provano a mano su hardware.
local t = require "tests.support.harness"
local fake_env = require "tests.support.fake_env"

local calls = { send = {}, vars = {}, events = {}, props = {}, timers = {}, watch = {}, errors = {}, persist = {}, proxy = {} }

local function make_c4()
	local c4 = {}
	function c4:ErrorLog(line) calls.errors[#calls.errors + 1] = line end
	function c4:GetTime() return 1782043200000 end
	function c4:UpdateProperty(name, value) calls.props[name] = value; Properties[name] = value end
	function c4:GetProjectProperty(name)
		if name == "Latitude" then return "45.4642" end
		if name == "Longitude" then return "9.1900" end
	end
	function c4:PersistGetValue(key) return calls.persist[key] end
	function c4:PersistSetValue(key, value) calls.persist[key] = value end
	function c4:SetTimer(ms, fn, repeating)
		local timer = { ms = ms, fn = fn, repeating = repeating, active = true }
		function timer:Cancel() self.active = false end
		calls.timers[#calls.timers + 1] = timer
		return timer
	end
	function c4:SendToDevice(id, command, params) calls.send[#calls.send + 1] = { id = id, command = command, params = params } end
	function c4:GetDeviceVariable(id, var) if var == 6661 then return fake_env.CAPS_CCT end end
	function c4:RegisterVariableListener(id, var) calls.watch[id .. ":" .. var] = true end
	function c4:UnregisterVariableListener(id, var) calls.watch[id .. ":" .. var] = nil end
	function c4:RegisterDeviceEvent(id, ev) calls.watch["ev" .. id .. ":" .. ev] = true end
	function c4:GetDeviceDisplayName(id) return "Lampada " .. id end
	function c4:GetDeviceData(id, tag) if tag == "model" then return "Fake CCT" end end
	function c4:FireEvent(name) calls.events[#calls.events + 1] = name end
	function c4:AddVariable(name, value, var_type) calls.vars[name] = value end
	function c4:SetVariable(name, value) calls.vars[name] = value end
	function c4:GetDeviceID() return 900 end
	function c4:SendToProxy(binding, command, params) calls.proxy[#calls.proxy + 1] = { binding = binding, command = command, params = params } end
	function c4:GetDriverConfigInfo(what) if what == "version" then return "261010099" end end
	return c4
end

_G.C4 = make_c4()
_G.Properties = fake_env.new().props
Properties["Log Mode"] = "Print"
Properties["Log Level"] = "5 - Debug"
Properties["Controlled Devices"] = "11"
Properties["Driver Version"] = "x"
local printed = {}
local real_print = print
_G.print = function(...) printed[#printed + 1] = table.concat({ ... }, " ") end

dofile("drivers/controller/driver.lua")

local function fire_timers(only_repeating)
	for _, tm in ipairs(calls.timers) do
		if tm.active and (not only_repeating or tm.repeating) then tm.fn() end
	end
end

t.test("il driver espone tutte le callback di Director", function()
	for _, name in ipairs({ "OnDriverInit", "OnDriverLateInit", "OnDriverDestroyed", "OnPropertyChanged",
		"ExecuteCommand", "ReceivedFromProxy", "OnBindingChanged", "OnWatchedVariableChanged",
		"OnDeviceEvent", "TestCondition" }) do
		t.eq(type(_G[name]), "function", name)
	end
end)

t.test("OnDriverInit: versione aggiornata, variabili create, nessun errore", function()
	OnDriverInit()
	t.eq(calls.props["Driver Version"], "261010099")
	t.eq(calls.vars.SCHEDULE_ACTIVE, "0")
	t.eq(calls.vars.PREVIEW_ACTIVE, "0")
	t.eq(#calls.errors, 0)
end)

t.test("OnPropertyChanged prima di LateInit non fa partire l'engine", function()
	OnPropertyChanged("Update Interval (s)")
	t.eq(#calls.timers, 0)
	ExecuteCommand("PAUSE_SCHEDULE", nil) -- ignorato con Warning
	t.eq(TestCondition("SCHEDULE_ACTIVE", {}), false)
end)

t.test("OnDriverLateInit: ACTIVE, luci osservate, timer avviati, stato persistito", function()
	OnDriverLateInit()
	t.eq(calls.vars.SCHEDULE_ACTIVE, "1")
	t.eq(calls.props["Operational Mode"], "Active")
	t.eq(calls.persist.state, "ACTIVE")
	t.truthy(calls.watch["11:1000"] and calls.watch["11:1001"])
	t.truthy(#calls.timers >= 2)
	t.eq(TestCondition("SCHEDULE_ACTIVE", {}), true)
	t.eq(TestCondition("PREVIEW_ACTIVE", {}), false)
	t.eq(#calls.errors, 0, table.concat(calls.errors, " / "))
end)

t.test("livello luce -> comandi Light V2 con parametri nel formato documentato", function()
	OnWatchedVariableChanged(11, 1000, "1")
	OnWatchedVariableChanged(11, 1001, "50")
	local b, c
	for _, s in ipairs(calls.send) do
		if s.command == "SET_BRIGHTNESS_TARGET" then b = s end
		if s.command == "SET_COLOR_TARGET" then c = s end
	end
	t.truthy(b and c, "attesi SET_BRIGHTNESS_TARGET e SET_COLOR_TARGET")
	t.eq(b.id, 11)
	t.eq(type(b.params.LIGHT_BRIGHTNESS_TARGET_PERCENT), "number")
	t.eq(b.params.RATE, 5000)
	t.eq(c.params.LIGHT_COLOR_TARGET_MODE, 1)
	t.truthy(c.params.LIGHT_COLOR_TARGET_COLOR_CORRELATED_TEMPERATURE >= 2200)
	t.eq(c.params.LIGHT_COLOR_TARGET_X, nil)
end)

t.test("tick (timer ripetuto) e callback di timer protette da pcall", function()
	local before = #calls.send
	fire_timers(true)
	t.truthy(#calls.send >= before)
	t.eq(#calls.errors, 0, table.concat(calls.errors, " / "))
end)

t.test("azioni di Composer: nome o comando, Pause/Resume/Preview/Stop con eventi", function()
	ExecuteCommand("LUA_ACTION", { ACTION = "Pause Schedule" })
	t.eq(TestCondition("SCHEDULE_ACTIVE", {}), false)
	t.eq(calls.vars.SCHEDULE_ACTIVE, "0")
	ExecuteCommand("RESUME_SCHEDULE", nil)
	t.eq(TestCondition("SCHEDULE_ACTIVE", {}), true)
	ExecuteCommand("LUA_ACTION", { ACTION = "PREVIEW_SCHEDULE" })
	t.eq(TestCondition("PREVIEW_ACTIVE", {}), true)
	ExecuteCommand("STOP_PREVIEW", nil)
	t.eq(TestCondition("PREVIEW_ACTIVE", {}), false)
	local seen = table.concat(calls.events, ",")
	for _, e in ipairs({ "SCHEDULE_PAUSED", "SCHEDULE_RESUMED", "PREVIEW_STARTED", "PREVIEW_STOPPED" }) do
		t.truthy(seen:find(e, 1, true), "evento " .. e)
	end
	t.eq(#calls.errors, 0, table.concat(calls.errors, " / "))
end)

t.test("un errore nell'engine e' catturato dal wrapper e loggato (non propaga a Director)", function()
	local ok = pcall(function() OnWatchedVariableChanged(11, 1001, {}) end) -- valore assurdo
	t.eq(ok, true)
	local ok2 = pcall(function() ExecuteCommand(nil, nil) end)
	t.eq(ok2, true)
end)

t.test("OnDriverDestroyed ferma i timer", function()
	OnDriverDestroyed()
	for _, tm in ipairs(calls.timers) do
		if tm.repeating then t.eq(tm.active, false) end
	end
end)

t.test("comms con la webview: STATE su SendToProxy(1, DC_MESSAGE), richieste via ExecuteCommand e ReceivedFromProxy, HELLO al bind", function()
	local json = require "libs.json"
	local sentp = calls.proxy
	local n0 = #sentp
	local function req(id, op, args)
		return json.encode({ v = 1, id = id, op = op, args = args or {}, from = 1 })
	end
	ExecuteCommand("DC_REQUEST", { json = req("e1", "GET_STATE") })
	local last = sentp[#sentp]
	t.eq(last.binding, 1); t.eq(last.command, "DC_MESSAGE")
	local ack = json.decode(last.params.json)
	t.eq(ack.type, "ACK"); t.eq(ack.id, "e1"); t.eq(ack.ok, true); t.eq(ack.state.type, "STATE")
	ReceivedFromProxy(1, "DC_REQUEST", { json = req("e2", "PAUSE") })
	t.eq(json.decode(sentp[#sentp].params.json).ok, true)
	t.eq(TestCondition("SCHEDULE_ACTIVE", {}), false)
	ReceivedFromProxy(1, "DC_REQUEST", { json = req("e3", "RESUME") })
	local before = #sentp
	OnBindingChanged(1, "DAYLIGHT_CIRCADIAN_COMMS", true, 55, 1)
	local hello
	for i = before + 1, #sentp do
		local m = json.decode(sentp[i].params.json)
		if m.type == "HELLO" then hello = m end
	end
	t.truthy(hello, "HELLO al bind")
	local ignored = #sentp
	ReceivedFromProxy(2, "DC_REQUEST", { json = req("e4", "PAUSE") })      -- altro binding: ignorato
	t.eq(#sentp, ignored)
	t.eq(#calls.errors, 0, table.concat(calls.errors, " / "))
	t.truthy(#sentp > n0)
end)

_G.print = real_print
t.finish()
