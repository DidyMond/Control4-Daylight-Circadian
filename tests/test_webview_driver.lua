-- Manifest e adattatore di drivers/webview (daylight_circadian_webview) con un C4 finto.
-- Il comportamento con Navigator/T4 reale si prova a mano su hardware.
local t = require "tests.support.harness"
local json = require "libs.json"
local protocol = require "libs.protocol"

local function read(path)
	local f = assert(io.open(path, "rb"))
	local text = f:read("*a")
	f:close()
	return text
end

local function exists(path)
	local f = io.open(path, "rb")
	if f then f:close() end
	return f ~= nil
end

-- ---------------------------------------------------------------- manifest
local xml = read("drivers/webview/driver.xml")

t.test("driver.xml: proxy uibutton 5001, SINGLETON_ID solo nel webview, Lua non cifrato", function()
	t.truthy(xml:find('proxybindingid="5001"', 1, true))
	t.truthy(xml:find(">uibutton</proxy>", 1, true))
	t.truthy(xml:find("<SINGLETON_ID>daylight_circadian_webview</SINGLETON_ID>", 1, true))
	t.truthy(xml:find('<script file="driver.lua" encryption="0"', 1, true))
	t.truthy(xml:find("<driver_name>daylight_circadian_webview</driver_name>", 1, true))
	t.eq(read("drivers/controller/driver.xml"):find("SINGLETON_ID", 1, true), nil, "il controller NON e' singleton")
end)

t.test("driver.xml: connessione 1 comms (consumer False, autobind, classe) e 5001 UIBUTTON type 2", function()
	local comms = xml:match("<connection>%s*<id>1</id>(.-)</connection>")
	t.truthy(comms, "connessione 1")
	t.truthy(comms:find("<consumer>False</consumer>", 1, true))
	t.truthy(comms:find("<classname>DAYLIGHT_CIRCADIAN_COMMS</classname>", 1, true))
	t.truthy(comms:find("<autobind>True</autobind>", 1, true))
	local ctrl = read("drivers/controller/driver.xml"):match("<connection>%s*<id>1</id>(.-)</connection>")
	t.truthy(ctrl:find("<consumer>True</consumer>", 1, true))
	t.truthy(ctrl:find("<classname>DAYLIGHT_CIRCADIAN_COMMS</classname>", 1, true))
	local ui = xml:match("<connection>%s*<id>5001</id>(.-)</connection>")
	t.truthy(ui and ui:find("<type>2</type>", 1, true) and ui:find("<classname>UIBUTTON</classname>", 1, true))
end)

t.test("driver.xml: web_view_url, mobile_web_view_enabled, icone 300/70/90 che esistono davvero in www/icons", function()
	t.truthy(xml:find('<web_view_url proxybindingid="5001">controller://driver/daylight_circadian_webview/dist/index.html</web_view_url>', 1, true))
	t.truthy(xml:find("<mobile_web_view_enabled>true</mobile_web_view_enabled>", 1, true))
	for _, size in ipairs({ 300, 70, 90 }) do
		local url = string.format('width="%d" height="%d">controller://driver/daylight_circadian_webview/icons/icon_%d.png<', size, size, size)
		t.truthy(xml:find(url, 1, true), "icona " .. size)
		t.truthy(exists("drivers/webview/www/icons/icon_" .. size .. ".png"), "file icon_" .. size .. ".png")
	end
	t.truthy(exists("drivers/webview/www/icons/icon_16.gif") and exists("drivers/webview/www/icons/icon_32.gif"))
	t.truthy(exists("drivers/webview/www/dist/index.html"))
end)

t.test("driver.xml: azioni Rebuild WebView / Clear Touchscreen Cache (DEVICE_SELECTOR pannelli) e proprieta' Language readonly", function()
	t.truthy(xml:find("<command>REBUILD_WEBVIEW</command>", 1, true))
	t.truthy(xml:find("<command>RESET_TS</command>", 1, true))
	t.truthy(xml:find("<type>DEVICE_SELECTOR</type>", 1, true))
	t.truthy(xml:find("uidevice_ts_t4_inwall10.c4i", 1, true) and xml:find("uidevice_glassedge10.c4i", 1, true))
	local lang = xml:match("<property>%s*<name>Language</name>(.-)</property>")
	t.truthy(lang and lang:find("<readonly>true</readonly>", 1, true))
end)

-- Tutti i file che la pagina carica: index.html + ogni src/href (relativo) + i font citati dai CSS
local function page_files()
	local base = "drivers/webview/www/dist/"
	local html = read(base .. "index.html")
	local files = { { name = "index.html", text = html } }
	local refs = {}
	for ref in html:gmatch('[%s<]src="([^"]+)"') do refs[#refs + 1] = ref end
	for ref in html:gmatch('[%s<]href="([^"]+)"') do refs[#refs + 1] = ref end
	for _, ref in ipairs(refs) do
		t.eq(ref:find("://", 1, true), nil, "riferimento assoluto: " .. ref)
		t.truthy(ref:sub(1, 1) ~= "/", "riferimento dalla radice: " .. ref)
		local path = ref:gsub("%?.*$", "")
		t.truthy(exists(base .. path), "file mancante: " .. path)
		local text = read(base .. path)
		files[#files + 1] = { name = path, text = text, ref = ref }
		if path:match("%.css$") then
			for url in text:gmatch("url%(%s*[\"']?([^)\"']+)") do
				t.eq(url:find("://", 1, true), nil, "url() assoluto in " .. path .. ": " .. url)
				local rel = path:gsub("[^/]*$", "") .. url
				-- risolve "../" rispetto alla cartella del CSS
				local dir = path:gsub("[^/]*$", "")
				while url:sub(1, 3) == "../" do url = url:sub(4); dir = dir:gsub("[^/]+/$", "") end
				t.truthy(exists(base .. dir .. url), "font/risorsa mancante: " .. dir .. url)
			end
		end
	end
	return files, refs
end

t.test("pagina: nessuna risorsa remota (CDN/font/framework), tutto dentro il pacchetto, asset versionati", function()
	local files, refs = page_files()
	t.truthy(#refs >= 10, "css + js caricati dalla pagina: " .. #refs)
	for _, f in ipairs(files) do
		local clean = f.text:gsub("http://www%.w3%.org/2000/svg", "") -- namespace SVG: un identificatore, non una risorsa
		t.eq(clean:find("https?://[%w%.%-]+%.[a-z]+", 1), nil, "URL assoluto in " .. f.name)
		t.eq(clean:find("@import", 1, true), nil, "@import in " .. f.name)
		if f.ref and f.name ~= "index.html" then
			t.truthy(f.ref:find("?v=__BUILD__", 1, true), "asset senza ?v=__BUILD__: " .. f.ref) -- build.ps1 lo sostituisce
		end
	end
	local html = files[1].text
	t.truthy(html:find('name="viewport"', 1, true))
	t.eq(html:find("react", 1, true), nil); t.eq(html:find("jquery", 1, true), nil)
	t.truthy(exists("drivers/webview/www/dist/fonts/LICENSE.txt"), "licenza OFL accanto ai font")
end)

t.test("pagina: usa l'API C4 ufficiale (sendCommand verso il protocollo, subscribeToDataToUi, onDataToUi) e protocollo v1", function()
	local bridge = read("drivers/webview/www/dist/js/bridge.js")
	t.truthy(bridge:find("subscribeToDataToUi(true)", 1, true), "iscrizione ai DATA_TO_UI del protocollo")
	t.truthy(bridge:find("sendCommand(cmd, JSON.stringify(p), false, true)", 1, true), "sendToProtocol = true")
	t.truthy(bridge:find("window.onDataToUi", 1, true))
	t.truthy(bridge:find("p.rid = rid", 1, true), "ogni richiesta porta il rid")
	-- le op che la UI invia esistono nel protocollo del controller
	local main = read("drivers/webview/www/dist/js/main.js") .. read("drivers/webview/www/dist/js/context-sheet.js")
	local known = {}
	for _, op in ipairs(protocol.OPS) do known[op] = true end
	local used = 0
	for op in main:gmatch("command%('([A-Z_]+)'") do
		used = used + 1
		t.truthy(known[op], "op sconosciuta al protocollo: " .. op)
	end
	for op in main:gmatch("this%.hooks%.command%('([A-Z_]+)'") do
		t.truthy(known[op], "op sconosciuta al protocollo: " .. op)
	end
	t.truthy(used >= 5, "op trovate nel codice: " .. used)
end)

-- ---------------------------------------------------------------- adattatore
local calls = { to_device = {}, to_ui = {}, proxy = {}, props = {}, errors = {}, timers = {} }
local bound = { [900] = "Controller Soggiorno" }
local locale = "it_IT"

_G.C4 = {}
function C4:ErrorLog(line) calls.errors[#calls.errors + 1] = line end
function C4:UpdateProperty(name, value) calls.props[name] = value; Properties[name] = value end
function C4:GetDriverConfigInfo(what) if what == "version" then return "261010088" end end
function C4:GetLocale() return locale end
function C4:GetBoundConsumerDevices(device, binding) if device == 0 and binding == 1 then return bound end end
function C4:SendToDevice(id, command, params) calls.to_device[#calls.to_device + 1] = { id = id, command = command, params = params } end
function C4:SendDataToUI(command, params) calls.to_ui[#calls.to_ui + 1] = { command = command, params = params } end
function C4:SendToProxy(binding, command, params) calls.proxy[#calls.proxy + 1] = { binding = binding, command = command, params = params } end
function C4:SetTimer(ms, fn, repeating)
	local timer = { ms = ms, fn = fn, repeating = repeating, active = true }
	function timer:Cancel() self.active = false end
	calls.timers[#calls.timers + 1] = timer
	return timer
end
_G.Properties = { ["Log Mode"] = "Print", ["Log Level"] = "5 - Debug", ["Driver Version"] = "x" }
local real_print = print
_G.print = function() end

dofile("drivers/webview/driver.lua")

local function state_json(id)
	return json.encode({ v = 1, type = "STATE", controller = id, name = bound[id], state = "ACTIVE", count = 4,
		mode = "Brightness + Colour Temperature", ct = { min = 2200, max = 6500 },
		switchpoints = json.array({}), warnings = json.array({}), lights = json.array({}) })
end

t.test("callback di Director presenti; prima di LateInit UIRequest risponde 'non pronto' (JSON valido)", function()
	for _, name in ipairs({ "OnDriverInit", "OnDriverLateInit", "OnDriverDestroyed", "OnPropertyChanged", "ExecuteCommand",
		"UIRequest", "ReceivedFromProxy", "OnBindingChanged" }) do
		t.eq(type(_G[name]), "function", name)
	end
	OnDriverInit()
	local res = assert(json.decode(UIRequest("DC_LIST", {})))
	t.eq(res.ok, false)
end)

t.test("LateInit: lingua dal locale, controller trovati via GetBoundConsumerDevices(0, 1), GET_STATE inviato", function()
	OnDriverLateInit()
	t.eq(calls.props.Language, "Italiano (it)")
	t.eq(calls.props.Controllers, "1")
	t.eq(calls.props["Operational Mode"], "Ready")
	t.eq(#calls.to_device, 1)
	local sent = calls.to_device[1]
	t.eq(sent.id, 900); t.eq(sent.command, "DC_REQUEST")
	local req = assert(protocol.decode(sent.params.json))
	t.eq(req.op, "GET_STATE")
	t.truthy(#calls.timers >= 1 and calls.timers[1].repeating, "timer di riallineamento")
	t.eq(#calls.errors, 0, table.concat(calls.errors, " / "))
end)

t.test("messaggio del controller (DC_MESSAGE sul binding 1) => registro + SendDataToUI verso la pagina", function()
	ReceivedFromProxy(1, "DC_MESSAGE", { json = state_json(900) })
	t.eq(#calls.to_ui, 1)
	t.eq(calls.to_ui[1].command, "DC_EVENT")
	local pushed = assert(protocol.decode(calls.to_ui[1].params.json))
	t.eq(pushed.type, "STATE"); t.eq(pushed.controller, 900)
	ReceivedFromProxy(5001, "SELECT", {})                         -- altri binding/comandi: ignorati
	ReceivedFromProxy(1, "ALTRO", { json = "x" })
	t.eq(#calls.to_ui, 1)
end)

t.test("UIRequest: DC_PING / DC_LIST ritornano stringhe JSON; DC_LIST ha lo STATE in cache", function()
	local ping = assert(json.decode(UIRequest("DC_PING", {})))
	t.eq(ping.ok, true); t.eq(ping.language, "it"); t.eq(ping.controllers, 1)
	local list = assert(json.decode(UIRequest("DC_LIST", {})))
	t.eq(list.controllers[1].id, 900)
	t.eq(list.controllers[1].state.state, "ACTIVE")
	t.eq(assert(json.decode(UIRequest("BOH", {}))).ok, false)
end)

t.test("UIRequest DC_CMD: inoltra DC_REQUEST al controller giusto (SendToDevice), valida gli argomenti", function()
	local n = #calls.to_device
	local res = assert(json.decode(UIRequest("DC_CMD", { controller = "900", op = "SET_MODE", args = { mode = "brightness" } })))
	t.eq(res.ok, true); t.eq(res.queued, true)
	t.eq(#calls.to_device, n + 1)
	local last = calls.to_device[#calls.to_device]
	t.eq(last.id, 900); t.eq(last.command, "DC_REQUEST")
	t.eq(assert(protocol.decode(last.params.json)).args.mode, "brightness")
	local bad = assert(json.decode(UIRequest("DC_CMD", { controller = 900, op = "SET_MODE", args = { mode = "boh" } })))
	t.eq(bad.ok, false)
	t.eq(#calls.to_device, n + 1, "nessun invio per richieste non valide")
end)

t.test("DC_CMD con args come stringa JSON (forma che sopravvive al Broker): SET_SWITCHPOINT arriva al controller", function()
	local n = #calls.to_device
	local res = assert(json.decode(UIRequest("DC_CMD", { rid = "sp-1", controller = "900", op = "SET_SWITCHPOINT",
		args = '{"n":1,"brightness":15}' })))
	t.eq(res.ok, true)
	t.eq(#calls.to_device, n + 1)
	local req = assert(protocol.decode(calls.to_device[#calls.to_device].params.json))
	t.eq(req.op, "SET_SWITCHPOINT"); t.eq(req.args.n, 1); t.eq(req.args.brightness, 15)
	-- oggetto annidato perso dal Broker: rifiutato (come visto su hardware), nessun invio, risposta d'errore alla pagina
	local ui = #calls.to_ui
	local bad = assert(json.decode(UIRequest("DC_CMD", { rid = "sp-2", controller = "900", op = "SET_SWITCHPOINT", args = {} })))
	t.eq(bad.ok, false); t.eq(#calls.to_device, n + 1)
	t.eq(#calls.to_ui, ui + 1)
	t.eq(assert(json.decode(calls.to_ui[#calls.to_ui].params.json)).ok, false)
end)

t.test("la risposta a un comando della pagina viaggia anche come DATA_TO_UI (il ritorno di UIRequest non arriva alla pagina)", function()
	local n = #calls.to_ui
	UIRequest("DC_LIST", { rid = "push-1" })
	t.eq(#calls.to_ui, n + 1)
	t.eq(calls.to_ui[#calls.to_ui].command, "DC_EVENT")
	local pushed = assert(json.decode(calls.to_ui[#calls.to_ui].params.json))
	t.eq(pushed.ok, true); t.eq(pushed.controllers[1].id, 900)
end)

t.test("UIRequest + ExecuteCommand con lo stesso rid: il comando gira UNA volta sola (DC_CMD non duplicato)", function()
	local n_dev, n_ui = #calls.to_device, #calls.to_ui
	local params = { rid = "dup-1", controller = "900", op = "PAUSE", args = {} }
	UIRequest("DC_CMD", params)
	ExecuteCommand("DC_CMD", params)                                -- il doppione di Navigator
	t.eq(#calls.to_device, n_dev + 1, "una sola DC_REQUEST al controller")
	t.eq(#calls.to_ui, n_ui + 1, "una sola risposta alla pagina")
	local again = assert(json.decode(UIRequest("DC_CMD", params)))
	t.eq(again.duplicate, true)
	UIRequest("DC_CMD", { rid = "dup-2", controller = "900", op = "PAUSE", args = {} }) -- altro rid: passa
	t.eq(#calls.to_device, n_dev + 2)
end)

t.test("ExecuteCommand: Rebuild WebView / Clear Touchscreen Cache => URL_CHANGED con query nuova; List Controllers", function()
	ExecuteCommand("LUA_ACTION", { ACTION = "REBUILD_WEBVIEW" })
	local u1 = calls.proxy[#calls.proxy]
	t.eq(u1.binding, 5001); t.eq(u1.command, "URL_CHANGED")
	t.truthy(u1.params.url:find("^controller://driver/daylight_circadian_webview/dist/index.html%?r="))
	ExecuteCommand("LUA_ACTION", { ACTION = "Clear Touchscreen Cache", ["Touch Screen"] = "12,13" })
	local u2 = calls.proxy[#calls.proxy]
	t.truthy(u2.params.url ~= u1.params.url, "URL diverso: forza il ricaricamento")
	ExecuteCommand("LUA_ACTION", { ACTION = "List Controllers" })
	ExecuteCommand("DC_PING", {})                                   -- comando asincrono della pagina
	t.eq(#calls.errors, 0, table.concat(calls.errors, " / "))
end)

t.test("OnBindingChanged sul binding 1: registro riallineato; nuovo controller => GET_STATE", function()
	bound[901] = "Controller Camera"
	local n = #calls.to_device
	OnBindingChanged(1, "DAYLIGHT_CIRCADIAN_COMMS", true, 901, 1)
	t.eq(calls.props.Controllers, "2")
	t.eq(#calls.to_device, n + 1)
	t.eq(calls.to_device[#calls.to_device].id, 901)
end)

t.test("lingua: locale non italiano => en", function()
	locale = "C"
	local ping = assert(json.decode(UIRequest("DC_PING", {})))
	t.eq(ping.language, "en")
end)

t.test("errori nell'adattatore non propagano a Director", function()
	t.eq(pcall(function() ReceivedFromProxy(1, "DC_MESSAGE", { json = "non json" }) end), true)
	t.eq(pcall(function() UIRequest(nil, nil) end), true)
	t.eq(pcall(function() ExecuteCommand(nil, nil) end), true)
	OnDriverDestroyed()
	t.eq(calls.timers[1].active, false)
end)

_G.print = real_print
t.finish()
