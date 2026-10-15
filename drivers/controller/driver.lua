-- ============================================================
-- driver.lua - ENTRYPOINT di daylight_circadian_controller
--
-- Adattatore sottile fra Director (callback C4) e il nucleo in libs/engine.lua:
-- qui vive solo il wiring (env iniettato nell'engine, wrapper pcall, logging).
-- Nessuna logica di dominio.
-- ============================================================

-- require SENZA estensione .lua; libs/ sta alla radice del .c4z
local dbg = require "libs.debug"
local clock = require "libs.clock"
local engine_mod = require "libs.engine"
local protocol = require "libs.protocol"

-- binding comms col webview (classe DAYLIGHT_CIRCADIAN_COMMS): id 1 nel driver.xml
local COMMS_BINDING = 1

local DRIVER_LABEL = "DaylightCircadianController"

local logger = dbg.new({
	print = function(line) print(line) end,
	log = function(line) C4:ErrorLog(line) end,
	prefix = DRIVER_LABEL .. " ",
})

-- ------------------------------------------------------------
-- Esegue fn in pcall e logga l'errore invece di lasciarlo propagare:
-- Director invoca queste callback direttamente, e un errore non gestito in un
-- timer ne fermerebbe la catena. L'errore e' sempre visibile, a prescindere
-- da Log Mode.
-- ------------------------------------------------------------
local function safe_call(context, fn, ...)
	local ok, err = pcall(fn, ...)
	if not ok then
		local line = DRIVER_LABEL .. " [ERROR] errore non gestito in " .. context .. " -> " .. tostring(err)
		print(line)
		pcall(function() C4:ErrorLog(line) end)
	end
	return ok
end

local function apply_log_properties()
	logger:set_mode(Properties["Log Mode"])
	logger:set_level(Properties["Log Level"])
end

-- ------------------------------------------------------------
-- env: tutto cio' che l'engine usa di Control4 (contratto in libs/engine.lua)
-- ------------------------------------------------------------
local env = {}

function env.log(severity, text) logger:log(severity, "%s", text) end

function env.now()
	local ok, ms = pcall(function() return C4:GetTime() end) -- ms da epoch (OS >= 3.2.3)
	if ok and ms then return ms / 1000 end
	return os.time()
end

function env.clock() return os.date("*t") end

function env.utc_offset(y, m, d) return clock.utc_offset_hours_for_date(y, m, d) end

function env.prop(name) return Properties[name] end

function env.update_property(name, value) C4:UpdateProperty(name, value) end

-- Latitude/Longitude del progetto (C4:GetProjectProperty). 0/0 = non impostati.
function env.project_latlon()
	local lat = tonumber(C4:GetProjectProperty("Latitude"))
	local lon = tonumber(C4:GetProjectProperty("Longitude"))
	if lat == nil or lon == nil or (lat == 0 and lon == 0) then return nil end
	return lat, lon
end

function env.persist_get(key) return C4:PersistGetValue(key) end

function env.persist_set(key, value)
	if value == nil then return end
	C4:PersistSetValue(key, value)
end

function env.set_timer(ms, fn, repeating)
	local timer = C4:SetTimer(ms, function() safe_call("timer", fn) end, repeating and true or false)
	return { cancel = function() timer:Cancel() end }
end

function env.send_to_device(id, command, params) C4:SendToDevice(id, command, params) end

function env.get_device_variable(id, var_id) return C4:GetDeviceVariable(id, var_id) end

function env.watch_variable(id, var_id) C4:RegisterVariableListener(id, var_id) end

function env.unwatch_variable(id, var_id) C4:UnregisterVariableListener(id, var_id) end

function env.watch_device_event(id, event_id) C4:RegisterDeviceEvent(id, event_id) end

-- Identita' del driver della luce (solo per il log): nome in Composer + tag di devicedata
function env.device_info(id)
	local info = {}
	local ok, name = pcall(function() return C4:GetDeviceDisplayName(id) end)
	if ok and name then info.display_name = name end
	for _, tag in ipairs({ "name", "manufacturer", "model", "version", "creator" }) do
		local tok, value = pcall(function() return C4:GetDeviceData(id, tag) end)
		if tok and value and value ~= "" then info[tag] = value end
	end
	return info
end

function env.fire_event(name) C4:FireEvent(name) end

function env.add_variable(name, value, var_type) C4:AddVariable(name, value, var_type) end

function env.set_variable(name, value) C4:SetVariable(name, value) end

function env.device_id() return C4:GetDeviceID() end

function env.device_name()
	local ok, name = pcall(function() return C4:GetDeviceDisplayName(C4:GetDeviceID()) end)
	return ok and name or nil
end

-- controller -> webview: SendToProxy sul binding comms (il webview e' il provider)
function env.send_to_webview(text)
	C4:SendToProxy(COMMS_BINDING, protocol.COMMAND_MESSAGE, { [protocol.PARAM] = text })
end

local engine = engine_mod.new(env)
local late_init_done = false

-- ------------------------------------------------------------
-- CALLBACK STANDARD DRIVERWORKS
-- ------------------------------------------------------------
local function on_driver_init()
	apply_log_properties()
	local ok, version = pcall(function() return C4:GetDriverConfigInfo("version") end)
	if ok and version and version ~= "" then
		C4:UpdateProperty("Driver Version", tostring(version))
	end
	logger:log(dbg.INFO, "[LIFECYCLE] OnDriverInit (version=%s)", tostring(ok and version or "?"))
	engine:init() -- variabili SCHEDULE_ACTIVE / PREVIEW_ACTIVE: vanno create qui
end

function OnDriverInit()
	safe_call("OnDriverInit", on_driver_init)
end

local function on_driver_late_init()
	logger:log(dbg.INFO, "[LIFECYCLE] OnDriverLateInit")
	engine:late_init()
	late_init_done = true
end

function OnDriverLateInit()
	safe_call("OnDriverLateInit", on_driver_late_init)
end

local function on_driver_destroyed()
	logger:log(dbg.INFO, "[LIFECYCLE] OnDriverDestroyed")
	engine:destroy()
end

function OnDriverDestroyed()
	safe_call("OnDriverDestroyed", on_driver_destroyed)
end

local function on_property_changed(prop)
	if prop == "Log Mode" or prop == "Log Level" then
		apply_log_properties()
		logger:log(dbg.INFO, "[PROPS] log riconfigurato (%s = %s)", prop, tostring(Properties[prop]))
		return
	end
	logger:log(dbg.TRACE, "[PROPS] OnPropertyChanged: %s = %s", tostring(prop), tostring(Properties[prop]))
	-- Director richiama OnPropertyChanged per ogni proprieta' dopo OnDriverInit:
	-- l'engine parte solo a OnDriverLateInit.
	if late_init_done then engine:on_property_changed(prop) end
end

function OnPropertyChanged(strProperty)
	safe_call("OnPropertyChanged(" .. tostring(strProperty) .. ")", on_property_changed, strProperty)
end

function ExecuteCommand(strCommand, tParams)
	safe_call("ExecuteCommand(" .. tostring(strCommand) .. ")", function()
		if not late_init_done then
			logger:log(dbg.WARNING, "[COMMANDS] %s ignorato: driver non ancora inizializzato", tostring(strCommand))
			return
		end
		engine:on_command(strCommand, tParams)
	end)
end

-- Richieste della webview: arrivano come comando DC_REQUEST (SendToDevice -> ExecuteCommand)
-- oppure sul binding comms (SendToProxy -> ReceivedFromProxy).
function ReceivedFromProxy(idBinding, strCommand, tParams)
	logger:log(dbg.TRACE, "[BINDING] ReceivedFromProxy: binding=%s command=%s", tostring(idBinding), tostring(strCommand))
	safe_call("ReceivedFromProxy", function()
		if late_init_done and idBinding == COMMS_BINDING and strCommand == protocol.COMMAND_REQUEST then
			engine:on_webview_request(tParams and tParams[protocol.PARAM])
		end
	end)
end

-- Quando il webview si lega (autobind) il controller si annuncia e manda lo STATE.
function OnBindingChanged(idBinding, strClass, bIsBound, otherDeviceID, otherBindingID)
	logger:log(dbg.INFO, "[BINDING] OnBindingChanged: binding=%s class=%s bound=%s other=%s/%s", tostring(idBinding),
		tostring(strClass), tostring(bIsBound), tostring(otherDeviceID), tostring(otherBindingID))
	safe_call("OnBindingChanged", function()
		if late_init_done and bIsBound and idBinding == COMMS_BINDING then engine:hello() end
	end)
end

function OnWatchedVariableChanged(idDevice, idVariable, strValue)
	safe_call("OnWatchedVariableChanged", function()
		if late_init_done then engine:on_level(idDevice, idVariable, strValue) end
	end)
end

function OnDeviceEvent(idDevice, idEvent)
	safe_call("OnDeviceEvent", function()
		if late_init_done then engine:on_device_event(idDevice, idEvent) end
	end)
end

function TestCondition(strName, tParams)
	local result = false
	safe_call("TestCondition", function() result = engine:test_condition(strName) end)
	return result
end
