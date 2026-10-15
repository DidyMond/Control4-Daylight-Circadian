-- Matrice op -> risposta: OGNI operazione che la pagina puo' mandare, su OGNI percorso di consegna,
-- attraverso il vero adattatore del driver webview, il vero hub e il vero motore del controller.
--
-- Navigator invoca sia UIRequest sia ExecuteCommand per lo stesso comando (docs/ARCHITECTURE.md
-- §3b). Per ogni op si provano i 4 modi (UIRequest da solo, ExecuteCommand da solo, e i due ordini
-- del doppione) e due trasporti fra i driver: "sync" (la risposta del controller torna DENTRO la
-- chiamata, cioe' l'ACK precede la risposta dell'hub: l'ordine peggiore per la pagina) e
-- "deferred" (consegne in coda, come fra due driver reali). In ogni caso:
--   * esattamente UNA risposta con il rid della pagina (negativa o positiva, ma una risposta);
--   * per DC_CMD: esattamente UN ACK del controller con l'id annunciato dalla risposta;
--   * il controller esegue la richiesta UNA volta sola (il doppione e' scartato).
local t = require "tests.support.harness"
local json = require "libs.json"
local protocol = require "libs.protocol"
local engine = require "libs.engine"
local fake_env = require "tests.support.fake_env"
local light_cmd = require "libs.light_cmd"

-- ---------------------------------------------------------------- C4 finto (webview) con l'anello
local ring = { mode = "sync", queue = {}, controller_requests = 0, ui = {}, ms = 1000000 }
local printed = {}
local current -- { fake, eng }

local function deliver(fn)
	if ring.mode == "sync" then fn() else ring.queue[#ring.queue + 1] = fn end
end
local function flush()
	local guard = 0
	while #ring.queue > 0 and guard < 1000 do
		guard = guard + 1
		table.remove(ring.queue, 1)()
	end
end

_G.C4 = {}
function C4:ErrorLog(line) printed[#printed + 1] = "ERRORLOG " .. tostring(line) end
function C4:UpdateProperty(name, value) _G.Properties[name] = value end
function C4:GetDriverConfigInfo() return "1" end
function C4:GetLocale() return "it_IT" end
function C4:GetBoundConsumerDevices(device, binding) if device == 0 and binding == 1 then return { [900] = "Controller 900" } end end
function C4:GetTime() ring.ms = ring.ms + 7; return ring.ms end
function C4:SetTimer(ms, fn, rep) local timer = { active = true }; function timer:Cancel() self.active = false end; return timer end
function C4:SendToProxy() end
function C4:SendDataToUI(command, params) ring.ui[#ring.ui + 1] = assert(protocol.decode(params.json)) end
function C4:SendToDevice(id, command, params)
	assert(id == 900 and command == "DC_REQUEST", "SendToDevice inatteso: " .. tostring(command))
	deliver(function()
		ring.controller_requests = ring.controller_requests + 1
		current.eng:on_command("DC_REQUEST", params)
	end)
end
_G.Properties = { ["Log Mode"] = "Print", ["Log Level"] = "4 - Trace", ["Driver Version"] = "x" }
local real_print = print
_G.print = function(...)
	local parts = {}
	for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
	printed[#printed + 1] = table.concat(parts, " ")
end

local function new_controller()
	local fake = fake_env.new({ props = { ["Controlled Devices"] = "31" }, device_id = 900 })
	local eng = engine.new(fake.env)
	fake.env.send_to_webview = function(text)
		deliver(function() ReceivedFromProxy(1, "DC_MESSAGE", { json = text }) end)
	end
	current = { fake = fake, eng = eng }
	eng:init(); eng:late_init()
	eng:on_level(31, light_cmd.VAR_BRIGHTNESS_PERCENT, "50")
	return current
end

dofile("drivers/webview/driver.lua")
OnDriverInit()
new_controller()
OnDriverLateInit()
flush()

-- ---------------------------------------------------------------- le op, estratte dal codice della pagina
local function read(path)
	local f = assert(io.open(path, "rb")); local s = f:read("*a"); f:close(); return s
end

local PAGE_JS = { "bridge", "main", "context-sheet", "curve-renderer", "widgets" }

-- Ogni identificatore MAIUSCOLO fra apici nei JS della pagina che sia un'op del protocollo o un
-- comando DC_* e' un'op che la pagina puo' inviare: la matrice li deve coprire TUTTI.
local function ops_in_page()
	local universe = { DC_PING = true, DC_LIST = true, DC_GET_STATE = true, DC_CMD = true }
	for _, op in ipairs(protocol.OPS) do universe[op] = true end
	local found = {}
	for _, name in ipairs(PAGE_JS) do
		local text = read("drivers/webview/www/dist/js/" .. name .. ".js")
		for token in text:gmatch("'([A-Z][A-Z0-9_]+)'") do
			if universe[token] then found[token] = true end
		end
	end
	return found
end

-- op -> argomenti validi (GET_STATE non e' inviata dalla pagina come DC_CMD: la copriamo comunque)
local CMD_OPS = {
	{ op = "SET_SWITCHPOINT", args = '{"n":2,"brightness":77}' },
	{ op = "DELETE_SWITCHPOINT", args = '{"n":4}' },
	{ op = "SET_CT_LIMITS", args = '{"min":2400,"max":6000}' },
	{ op = "SET_MODE", args = '{"mode":"Brightness Only"}' },
	{ op = "SET_NUM_SP", args = '{"count":5}' },
	{ op = "PAUSE", args = "{}" },
	{ op = "RESUME", args = "{}" },          -- in ACTIVE e' vietata: l'ACK NEGATIVO e' comunque una risposta
	{ op = "FOLLOW", args = "{}" },
	{ op = "PREVIEW", args = "{}" },
	{ op = "STOP_PREVIEW", args = "{}" },    -- senza preview in corso: ACK negativo
	{ op = "GET_STATE", args = "{}" },
}
local POLL_OPS = { "DC_PING", "DC_LIST", "DC_GET_STATE" }

t.test("la matrice copre OGNI op che la pagina puo' inviare (e solo op che il protocollo conosce)", function()
	local found = ops_in_page()
	local covered = { DC_CMD = true }
	for _, c in ipairs(CMD_OPS) do covered[c.op] = true end
	for _, p in ipairs(POLL_OPS) do covered[p] = true end
	for op in pairs(found) do t.truthy(covered[op], "op inviata dalla pagina ma NON coperta dalla matrice: " .. op) end
	-- e viceversa: tutte le op di azione (non interne) compaiono davvero nel codice della pagina
	for _, c in ipairs(CMD_OPS) do
		if c.op ~= "GET_STATE" then t.truthy(found[c.op], "op nella matrice ma mai inviata dalla pagina: " .. c.op) end
	end
	for _, p in ipairs(POLL_OPS) do t.truthy(found[p], "comando mai inviato dalla pagina: " .. p) end
end)

-- ---------------------------------------------------------------- un giro
local serial = 0
local function filter(list, pred)
	local out = {}
	for _, m in ipairs(list) do if pred(m) then out[#out + 1] = m end end
	return out
end
local function printed_has(fragment)
	for _, l in ipairs(printed) do if l:find(fragment, 1, true) then return true end end
	return false
end

-- come Navigator: la pagina chiama C4.sendCommand(nome, params, false, true) e il driver riceve
-- UIRequest e/o ExecuteCommand con gli stessi parametri (tutti stringhe)
local function page_send(command, params, path)
	if path == "ui_only" then UIRequest(command, params)
	elseif path == "exec_only" then ExecuteCommand(command, params)
	elseif path == "ui_first" then UIRequest(command, params); ExecuteCommand(command, params)
	elseif path == "exec_first" then ExecuteCommand(command, params); UIRequest(command, params)
	end
end

local function round(command, op, args, path, mode)
	ring.mode = mode
	new_controller(); flush()
	ring.ui = {}; ring.controller_requests = 0; printed = {}
	serial = serial + 1
	local rid = "m-" .. serial
	local params = { rid = rid }
	if command == "DC_CMD" then params.controller = "900"; params.op = op; params.args = args end
	if command == "DC_GET_STATE" then params.controller = "900" end
	page_send(command, params, path)
	flush()
	local label = string.format("%s/%s [%s, %s]", command, op or "-", path, mode)

	local replies = filter(ring.ui, function(m) return m.rid == rid end)
	t.eq(#replies, 1, "UNA risposta con rid per " .. label)
	local reply = replies[1]
	if command == "DC_CMD" then
		t.eq(reply.ok, true, "risposta dell'hub " .. label)
		t.eq(reply.queued, true, label)
		t.truthy(reply.id, "id per collegare l'ACK " .. label)
		local acks = filter(ring.ui, function(m) return m.type == "ACK" and m.id == reply.id end)
		t.eq(#acks, 1, "UN ACK del controller per " .. label)
		t.eq(acks[1].op, op, label)
		t.eq(ring.controller_requests, 1, "il controller esegue UNA volta " .. label)
		-- diagnosi: i quattro salti lasciano traccia con rid / id / op
		t.truthy(printed_has("richiesta ricevuta rid=" .. rid .. " op=" .. op), "log pagina->driver " .. label)
		t.truthy(printed_has("-> controller 900 id=" .. reply.id .. " rid=" .. rid .. " op=" .. op), "log driver->controller " .. label)
		t.truthy(printed_has("<- controller ACK id=" .. reply.id .. " rid=" .. rid .. " op=" .. op), "log controller->driver " .. label)
		t.truthy(printed_has("ACK -> pagina id=" .. reply.id .. " rid=" .. rid .. " op=" .. op), "log driver->pagina " .. label)
		t.truthy(printed_has("risposta inviata rid=" .. rid .. " op=" .. op .. " ms="), "log risposta con ms " .. label)
	else
		t.eq(reply.ok, true, label)
		t.truthy(printed_has("risposta inviata rid=" .. rid .. " op=" .. command), "log risposta " .. label)
		if command == "DC_GET_STATE" then t.eq(ring.controller_requests, 1, "GET_STATE una volta " .. label) end
		if command ~= "DC_GET_STATE" then t.eq(ring.controller_requests, 0, label) end
	end
	if path == "ui_first" or path == "exec_first" then
		t.truthy(printed_has("doppione scartato rid=" .. rid), "il doppione e' scartato e si vede nel log " .. label)
	end
end

local PATHS = { "ui_only", "exec_only", "ui_first", "exec_first" }
local MODES = { "sync", "deferred" }

t.test("matrice DC_CMD: ogni op, 4 percorsi x 2 trasporti => 1 risposta con rid, 1 ACK, 1 esecuzione", function()
	for _, c in ipairs(CMD_OPS) do
		for _, path in ipairs(PATHS) do
			for _, mode in ipairs(MODES) do round("DC_CMD", c.op, c.args, path, mode) end
		end
	end
end)

t.test("matrice poll (DC_PING, DC_LIST, DC_GET_STATE): una risposta con rid su ogni percorso", function()
	for _, command in ipairs(POLL_OPS) do
		for _, path in ipairs(PATHS) do
			for _, mode in ipairs(MODES) do round(command, nil, nil, path, mode) end
		end
	end
end)

t.test("rid assente (pagina vecchia): la richiesta viene eseguita e risponde comunque", function()
	ring.mode = "deferred"; new_controller(); flush(); ring.ui = {}; ring.controller_requests = 0
	UIRequest("DC_CMD", { controller = "900", op = "PAUSE", args = "{}" })
	flush()
	t.eq(ring.controller_requests, 1)
	t.eq(#filter(ring.ui, function(m) return m.type == "ACK" and m.op == "PAUSE" end), 1)
end)

_G.print = real_print
t.finish()
