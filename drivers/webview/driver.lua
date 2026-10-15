-- ============================================================
-- driver.lua - ENTRYPOINT di daylight_circadian_webview (singleton, proxy uibutton)
--
-- Adattatore sottile: costruisce l'env del nucleo (libs/hub.lua) e inoltra le callback
-- di Director. Il ponte JS <-> Lua usa l'API WebView ufficiale del proxy UI Button:
--   JS  C4.sendCommand(nome, params, async, true)
--         async = false -> UIRequest(nome, params): ritorna una stringa JSON
--         async = true  -> ExecuteCommand(nome, params)
--   Lua C4:SendDataToUI(...) -> JS onDataToUi(risposta)  (dopo C4.subscribeToDataToUi(true))
-- Controller -> webview: ReceivedFromProxy(1, "DC_MESSAGE", { json = ... })
-- Webview -> controller: C4:SendToDevice(id, "DC_REQUEST", { json = ... })
-- ============================================================

local dbg = require "libs.debug"
local hub_mod = require "libs.hub"
local protocol = require "libs.protocol"

local DRIVER_LABEL = "DaylightCircadianWebview"

-- binding comms col controller (classe DAYLIGHT_CIRCADIAN_COMMS) e proxy UI Button
local COMMS_BINDING = 1
local UIBUTTON_BINDING = 5001
local REFRESH_INTERVAL_MS = 60000

local logger = dbg.new({
	print = function(line) print(line) end,
	log = function(line) C4:ErrorLog(line) end,
	prefix = DRIVER_LABEL .. " ",
})

-- Errori sempre visibili, mai propagati a Director (stesso criterio del controller)
local function safe_call(context, fn, ...)
	local ok, err = pcall(fn, ...)
	if not ok then
		local line = DRIVER_LABEL .. " [ERROR] errore non gestito in " .. context .. " -> " .. tostring(err)
		print(line)
		pcall(function() C4:ErrorLog(line) end)
	end
	return ok, err
end

local function apply_log_properties()
	logger:set_mode(Properties["Log Mode"])
	logger:set_level(Properties["Log Level"])
end

-- ------------------------------------------------------------
-- lingua del progetto: "it" se il locale e' italiano, altrimenti "en"
-- ------------------------------------------------------------
local function project_language()
	local ok, locale = pcall(function() return C4:GetLocale() end)
	if ok and type(locale) == "string" and locale:lower():match("^it") then return "it" end
	return "en"
end

-- ------------------------------------------------------------
-- env del nucleo
-- ------------------------------------------------------------
local env = {}

function env.log(severity, text) logger:log(severity, "%s", text) end

-- { [device_id] = nome } dei controller legati (provider = questo driver, binding 1)
function env.bound_controllers()
	local ok, devices = pcall(function() return C4:GetBoundConsumerDevices(0, COMMS_BINDING) end)
	if ok and type(devices) == "table" then return devices end
	return {}
end

function env.send_to_controller(id, text)
	C4:SendToDevice(id, protocol.COMMAND_REQUEST, { [protocol.PARAM] = text })
end

-- verso la pagina: il testo JSON viaggia nel parametro "json" (la forma finale la
-- decide il Broker; la pagina cerca "json" in modo ricorsivo)
function env.push_to_ui(text)
	C4:SendDataToUI("DC_EVENT", { [protocol.PARAM] = text })
end

function env.language() return project_language() end

-- millisecondi dall'epoch (C4:GetTime, documentata dal 3.2.3; il progetto richiede 3.3.0)
function env.now_ms()
	local ok, ms = pcall(function() return C4:GetTime() end)
	if ok and type(ms) == "number" then return ms end
	return os.time() * 1000
end

local hub = hub_mod.new(env)
local late_init_done = false
local refresh_timer = nil
local url_token = 0

-- ------------------------------------------------------------
-- URL della webview (azioni Rebuild WebView / Clear Touchscreen Cache)
-- ------------------------------------------------------------
local BASE_URL = "controller://driver/daylight_circadian_webview/dist/index.html"

-- Navigator non cambia l'URL di una webview GIA' aperta; un URL nuovo (query diversa)
-- forza il ricaricamento alla prossima apertura, bypassando la cache del pannello.
local function publish_url(reason)
	url_token = url_token + 1
	local url = string.format("%s?r=%s-%d", BASE_URL, tostring(Properties["Driver Version"] or "0"), url_token)
	logger:log(dbg.INFO, "[WEBVIEW] URL_CHANGED (%s): %s", reason, url)
	C4:SendToProxy(UIBUTTON_BINDING, "URL_CHANGED", { url = url })
end

local function update_controller_count()
	local n = 0
	for _ in pairs(hub.controllers) do n = n + 1 end
	C4:UpdateProperty("Controllers", tostring(n))
	C4:UpdateProperty("Operational Mode", n > 0 and "Ready" or "No controllers")
end

local function refresh()
	hub:refresh()
	update_controller_count()
end

-- ------------------------------------------------------------
-- CALLBACK STANDARD DRIVERWORKS
-- ------------------------------------------------------------
local function on_driver_init()
	apply_log_properties()
	local ok, version = pcall(function() return C4:GetDriverConfigInfo("version") end)
	if ok and version and version ~= "" then C4:UpdateProperty("Driver Version", tostring(version)) end
	logger:log(dbg.INFO, "[LIFECYCLE] OnDriverInit (version=%s)", tostring(ok and version or "?"))
end

function OnDriverInit() safe_call("OnDriverInit", on_driver_init) end

local function on_driver_late_init()
	logger:log(dbg.INFO, "[LIFECYCLE] OnDriverLateInit")
	local lang = project_language()
	C4:UpdateProperty("Language", lang == "it" and "Italiano (it)" or "English (en)")
	late_init_done = true
	refresh()
	-- il binding puo' completarsi dopo l'avvio: riallinea periodicamente
	refresh_timer = C4:SetTimer(REFRESH_INTERVAL_MS, function() safe_call("refresh", refresh) end, true)
end

function OnDriverLateInit() safe_call("OnDriverLateInit", on_driver_late_init) end

function OnDriverDestroyed()
	safe_call("OnDriverDestroyed", function()
		logger:log(dbg.INFO, "[LIFECYCLE] OnDriverDestroyed")
		if refresh_timer then refresh_timer:Cancel(); refresh_timer = nil end
	end)
end

function OnPropertyChanged(strProperty)
	safe_call("OnPropertyChanged", function()
		if strProperty == "Log Mode" or strProperty == "Log Level" then
			apply_log_properties()
			logger:log(dbg.INFO, "[PROPS] log riconfigurato (%s = %s)", strProperty, tostring(Properties[strProperty]))
		end
	end)
end

-- Un controller si lega/slega: aggiorna il registro (e chiede lo STATE ai nuovi).
function OnBindingChanged(idBinding, strClass, bIsBound, otherDeviceID, otherBindingID)
	logger:log(dbg.INFO, "[BINDING] OnBindingChanged: binding=%s class=%s bound=%s other=%s/%s", tostring(idBinding),
		tostring(strClass), tostring(bIsBound), tostring(otherDeviceID), tostring(otherBindingID))
	safe_call("OnBindingChanged", function()
		if late_init_done and idBinding == COMMS_BINDING then refresh() end
	end)
end

-- Messaggi dei controller (STATE, ACK, PREVIEW, HELLO) sul binding comms.
function ReceivedFromProxy(idBinding, strCommand, tParams)
	logger:log(dbg.TRACE, "[BINDING] ReceivedFromProxy: binding=%s command=%s", tostring(idBinding), tostring(strCommand))
	safe_call("ReceivedFromProxy", function()
		if not late_init_done then return end
		if idBinding == COMMS_BINDING and strCommand == protocol.COMMAND_MESSAGE then
			hub:on_message(tParams and tParams[protocol.PARAM])
			update_controller_count()
		end
	end)
end

-- Comandi della pagina (DC_*). Verificato su T4/app: con sendToProtocol=true Navigator invoca
-- sia UIRequest sia ExecuteCommand per lo stesso comando, e il valore di ritorno di UIRequest
-- NON torna alla pagina (onDataToUi riceve solo un ack del Broker con "$t" vuoto). Quindi:
--   * la risposta viaggia come DATA_TO_UI (C4:SendDataToUI), che la pagina ascolta;
--   * l'id "rid" (scelto dalla pagina, unico anche fra ricaricamenti) scarta il doppione, cosi'
--     un DC_CMD non gira due volte.
local seen_rid, seen_order = {}, {}
local MAX_SEEN_RID = 64

local function duplicate_request(params)
	local rid = type(params) == "table" and params.rid or nil
	if rid == nil then return false end
	rid = tostring(rid)
	if seen_rid[rid] then return true end
	seen_rid[rid] = true
	seen_order[#seen_order + 1] = rid
	if #seen_order > MAX_SEEN_RID then seen_rid[table.remove(seen_order, 1)] = nil end
	return false
end

local function page_op(command, params)
	if command == "DC_CMD" and type(params) == "table" and params.op then return tostring(params.op) end
	return command
end

-- DC_PING / DC_LIST / DC_GET_STATE sono poll in background: log TRACE; le azioni dell'utente INFO
local function page_severity(command)
	if command == "DC_PING" or command == "DC_LIST" or command == "DC_GET_STATE" then return dbg.TRACE end
	return dbg.INFO
end

-- Ritorna sempre una stringa JSON (anche se Navigator oggi la ignora).
-- via = "UIRequest" | "ExecuteCommand": Navigator le invoca entrambe per lo stesso comando.
-- Diagnosi sul campo: ogni richiesta lascia "ricevuta", "risposta inviata" (con i ms) o
-- "doppione scartato", sempre con rid e op.
local function page_command(command, params, via)
	local rid = type(params) == "table" and params.rid or nil
	local op, sev = page_op(command, params), page_severity(command)
	if duplicate_request(params) then
		logger:log(sev, "[HUB] doppione scartato rid=%s op=%s via=%s", tostring(rid), op, tostring(via))
		return '{"v":1,"ok":true,"duplicate":true}'
	end
	local t0 = env.now_ms()
	logger:log(sev, "[HUB] richiesta ricevuta rid=%s op=%s via=%s", tostring(rid), op, tostring(via))
	local result = hub:ui_request(command, params)
	env.push_to_ui(result)
	logger:log(sev, "[HUB] risposta inviata rid=%s op=%s ms=%d", tostring(rid), op, env.now_ms() - t0)
	return result
end

-- Richieste sincrone della pagina (C4.sendCommand(nome, params, false, true): true = al protocollo).
function UIRequest(strCommand, tParams)
	local result = '{"v":1,"ok":false,"error":"driver non pronto"}'
	safe_call("UIRequest(" .. tostring(strCommand) .. ")", function()
		if not late_init_done then return end
		logger:log(dbg.TRACE, "[UI] UIRequest %s", tostring(strCommand))
		result = page_command(strCommand, tParams, "UIRequest")
	end)
	return result
end

-- Azioni di Composer (LUA_ACTION) e comandi asincroni della pagina (async = true).
function ExecuteCommand(strCommand, tParams)
	safe_call("ExecuteCommand(" .. tostring(strCommand) .. ")", function()
		local command = strCommand
		if command == "LUA_ACTION" then command = tParams and tParams.ACTION or "" end
		local key = tostring(command):upper():gsub("[^%w]+", "_")
		-- i comandi della pagina (DC_*) li registra page_command con rid e op
		logger:log(key:sub(1, 3) == "DC_" and dbg.TRACE or dbg.INFO, "[COMMANDS] %s", key)
		if key == "REBUILD_WEBVIEW" then
			publish_url("Rebuild WebView")
		elseif key == "RESET_TS" or key == "CLEAR_TOUCHSCREEN_CACHE" then
			-- Nota: nessuna API documentata per svuotare la cache di un pannello;
			-- un URL con query nuova forza il ricaricamento della pagina.
			local selected = tParams and (tParams["Touch Screen"] or tParams.TOUCH_SCREEN or "")
			logger:log(dbg.INFO, "[WEBVIEW] Clear Touchscreen Cache per i pannelli: %s", tostring(selected))
			publish_url("Clear Touchscreen Cache")
		elseif key == "LIST_CONTROLLERS" then
			refresh()
			for _, line in ipairs(hub:describe()) do logger:log(dbg.INFO, "[HUB] %s", line) end
		elseif late_init_done then
			-- comando della pagina (DC_*), anche come doppione di UIRequest: la risposta e' un push
			page_command(key, tParams, "ExecuteCommand")
		end
	end)
end
