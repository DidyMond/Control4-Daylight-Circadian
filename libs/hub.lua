-- ============================================================
-- libs/hub.lua - nucleo del driver webview (daylight_circadian_webview)
--
-- Lua 5.1 puro, nessun riferimento a C4: tutto cio' che tocca Control4 arriva da `env`
-- (come per libs/engine.lua). Fa da ponte fra la pagina (JS, via C4.sendCommand) e i
-- controller (binding DAYLIGHT_CIRCADIAN_COMMS): tiene un registro dei controller
-- legati con l'ultimo STATE, inoltra i comandi, gira i messaggi dei controller alla UI.
--
-- Contratto di `env`:
--   env.log(severity, text)
--   env.bound_controllers()      -> { [device_id] = nome }   (C4:GetBoundConsumerDevices(0, 1))
--   env.send_to_controller(id, text)   richiesta JSON (C4:SendToDevice(id, "DC_REQUEST", ...))
--   env.push_to_ui(text)         messaggio JSON verso la pagina (C4:SendDataToUI)
--   env.language()               -> "it" | "en"
--   env.now_ms()                 -> millisecondi (opzionale: C4:GetTime); abilita i "ms" nei log di diagnosi   (opzionale)
--
-- Comandi della pagina (C4.sendCommand(nome, JSON-params, async, false)):
--   DC_PING                    diagnostica: versione, lingua, n. controller
--   DC_LIST                    elenco controller con l'ultimo STATE noto
--   DC_GET_STATE {controller?} STATE in cache (subito) + richiesta di STATE fresco (push)
--   DC_CMD {controller, op, args}   inoltra un'operazione del protocollo (SET_*, PAUSE, ...)
-- Ogni comando risponde con una stringa JSON { v, ok, ... }.
-- ============================================================

local dbg = require "libs.debug"
local json = require "libs.json"
local protocol = require "libs.protocol"

local M = {}

M.UI_COMMANDS = { "DC_PING", "DC_LIST", "DC_GET_STATE", "DC_CMD" }

local Hub = {}
Hub.__index = Hub

function M.new(env)
	local self = setmetatable({}, Hub)
	self.env = env
	self.controllers = {} -- [id] = { id, name, state = snapshot|nil, preview = msg|nil }
	self.pending = {}     -- [request id] = { controller, op, rid, t0 }
	self.counter = 0
	return self
end

function Hub:log(severity, fmt, ...)
	local text = fmt
	if select("#", ...) > 0 then
		local ok, res = pcall(string.format, fmt, ...)
		text = ok and res or (tostring(fmt) .. " (format error)")
	end
	self.env.log(severity, text)
end

local function sorted_ids(map)
	local ids = {}
	for id in pairs(map) do ids[#ids + 1] = id end
	table.sort(ids)
	return ids
end

function Hub:next_id()
	self.counter = self.counter + 1
	return "w" .. self.counter
end

function Hub:now()
	return self.env.now_ms and self.env.now_ms() or nil
end

-- ms trascorsi da t0 (o "?" se non c'e' un orologio)
function Hub:since(t0)
	local now = self:now()
	return (now and t0) and string.format("%d", now - t0) or "?"
end

-- Invia una richiesta a un controller e ricorda a chi appartiene l'ACK.
-- rid/t0 (opzionali): la richiesta della pagina che l'ha originata, per la diagnosi sul campo.
-- I log di questi passaggi (INFO se nasce da un'azione dell'utente, TRACE per i giri interni)
-- permettono di capire in quale dei quattro salti muore una risposta
-- (pagina->driver, driver->controller, controller->driver, driver->pagina).
function Hub:request(controller_id, op, args, rid, t0)
	local id = self:next_id()
	self.pending[id] = { controller = controller_id, op = op, rid = rid, t0 = t0 or self:now() }
	local text = protocol.encode(protocol.request(id, op, args))
	self:log(rid and dbg.INFO or dbg.TRACE, "[HUB] -> controller %s id=%s rid=%s op=%s",
		tostring(controller_id), id, tostring(rid), op)
	self.env.send_to_controller(controller_id, text)
	return id
end

-- Allinea il registro ai controller legati al binding; ai nuovi chiede lo STATE
-- (salvo no_request: lo chiede il chiamante).
function Hub:refresh(no_request)
	local bound = self.env.bound_controllers() or {}
	for id, name in pairs(bound) do
		local entry = self.controllers[id]
		if not entry then
			entry = { id = id, name = name }
			self.controllers[id] = entry
			self:log(dbg.INFO, "[HUB] controller %s (%s) legato", tostring(id), tostring(name))
		end
		entry.name = entry.name or name
		entry.bound = true
		if not entry.state and not no_request then self:request(id, "GET_STATE") end
	end
	for id, entry in pairs(self.controllers) do
		if not bound[id] and entry.bound then
			entry.bound = false
			self:log(dbg.INFO, "[HUB] controller %s non piu' legato", tostring(id))
		end
	end
	return #sorted_ids(bound)
end

-- Messaggio dal controller (JSON) -> registro + inoltro alla pagina.
function Hub:on_message(text)
	local msg, err = protocol.decode(text)
	if not msg then
		self:log(dbg.WARNING, "[HUB] messaggio dal controller non valido: %s", tostring(err))
		return
	end
	local mtype = msg.type
	local ack_rid, ack_t0 -- rid/t0 della richiesta della pagina a cui questo ACK risponde (solo per i log)
	if mtype == "ACK" then
		local p = msg.id and self.pending[msg.id]
		if p then
			msg.controller = msg.controller or p.controller
			self.pending[msg.id] = nil
			self:log(p.rid and dbg.INFO or dbg.TRACE, "[HUB] <- controller ACK id=%s rid=%s op=%s ok=%s ms=%s",
				tostring(msg.id), tostring(p.rid), tostring(msg.op), tostring(msg.ok), self:since(p.t0))
			ack_rid, ack_t0 = p.rid, p.t0
		else
			self:log(dbg.WARNING, "[HUB] ACK senza richiesta in sospeso id=%s op=%s", tostring(msg.id), tostring(msg.op))
		end
		if msg.ok == false then
			self:log(dbg.WARNING, "[HUB] %s rifiutata da %s: %s", tostring(msg.op), tostring(msg.controller), tostring(msg.error))
		end
	end
	local cid = msg.controller
	if cid ~= nil then
		local entry = self.controllers[cid]
		if not entry then
			entry = { id = cid, bound = true }
			self.controllers[cid] = entry
		end
		if msg.name then entry.name = msg.name end
		if mtype == "STATE" then
			entry.state = msg
			if msg.name then entry.name = msg.name end
		elseif mtype == "ACK" and type(msg.state) == "table" and msg.state.type == "STATE" then
			entry.state = msg.state
		elseif mtype == "PREVIEW" then
			entry.preview = msg
		end
	end
	self.env.push_to_ui(protocol.encode(msg))
	if mtype == "ACK" then
		self:log(ack_rid and dbg.INFO or dbg.TRACE, "[HUB] ACK -> pagina id=%s rid=%s op=%s ms=%s",
			tostring(msg.id), tostring(ack_rid), tostring(msg.op), self:since(ack_t0))
	else
		self:log(dbg.TRACE, "[HUB] controller %s -> UI %s", tostring(cid), tostring(mtype))
	end
end

local function reply_raw(ok, fields, err)
	local out = { v = protocol.VERSION, ok = ok and true or false }
	if err then out.error = err end
	for k, v in pairs(fields or {}) do out[k] = v end
	return json.encode(out)
end

function Hub:list()
	local items = {}
	for _, id in ipairs(sorted_ids(self.controllers)) do
		local c = self.controllers[id]
		items[#items + 1] = { id = id, name = c.name, bound = c.bound and true or false, state = c.state }
	end
	return items
end

-- I parametri arrivano da Director come tabella (JSON della pagina gia' decodificato):
-- gli oggetti annidati possono essere tabelle oppure stringhe JSON.
local function as_table(v)
	if type(v) == "table" then return v end
	if type(v) == "string" and v ~= "" then
		local t = json.decode(v)
		if type(t) == "table" then return t end
	end
	return {}
end

-- UI -> hub. Ritorna SEMPRE una stringa JSON (UIRequest ne ha bisogno).
function Hub:ui_request(command, params)
	params = type(params) == "table" and params or {}
	-- ogni risposta riporta il "rid" scelto dalla pagina: cosi' collega richiesta e risposta
	-- (la risposta torna come push, non come valore di ritorno di UIRequest)
	local function reply(ok, fields, err)
		fields = fields or {}
		if params.rid ~= nil then fields.rid = tostring(params.rid) end
		return reply_raw(ok, fields, err)
	end
	if command == "DC_PING" then
		return reply(true, {
			controllers = #sorted_ids(self.controllers),
			language = self.env.language and self.env.language() or "en",
			protocol = protocol.VERSION,
		})
	elseif command == "DC_LIST" then
		self:refresh()
		return reply(true, { controllers = json.array(self:list()) })
	elseif command == "DC_GET_STATE" then
		self:refresh(true)
		local wanted = tonumber(params.controller)
		local items = {}
		for _, c in ipairs(self:list()) do
			if not wanted or c.id == wanted then
				items[#items + 1] = c
				self:request(c.id, "GET_STATE") -- lo STATE fresco arriva come push
			end
		end
		if wanted and #items == 0 then return reply(false, nil, "controller sconosciuto: " .. tostring(params.controller)) end
		return reply(true, { controllers = json.array(items), cached = true })
	elseif command == "DC_CMD" then
		local cid = tonumber(params.controller)
		if not cid or not self.controllers[cid] then
			return reply(false, nil, "controller sconosciuto: " .. tostring(params.controller))
		end
		local op = params.op
		local args = as_table(params.args)
		-- diagnostica: come arrivano gli argomenti annidati dal Broker (tabella, stringa JSON o niente)
		self:log(dbg.INFO, "[HUB] DC_CMD controller=%s op=%s args(%s)=%s", tostring(cid), tostring(op),
			type(params.args), json.encode(args))
		local writes, err = protocol.property_writes(op, args) -- validazione anche lato hub
		if not writes then
			self:log(dbg.WARNING, "[HUB] DC_CMD %s rifiutato: %s", tostring(op), tostring(err))
			return reply(false, nil, err)
		end
		local id = self:request(cid, op, args, params.rid, self:now())
		return reply(true, { queued = true, id = id, controller = cid, op = op })
	end
	return reply(false, nil, "comando sconosciuto: " .. tostring(command))
end

-- riga per il log (azione LIST_CONTROLLERS)
function Hub:describe()
	local lines = {}
	for _, c in ipairs(self:list()) do
		local st = c.state
		lines[#lines + 1] = string.format("controller %s (%s) %s stato=%s %s SP",
			tostring(c.id), tostring(c.name), c.bound and "legato" or "NON legato",
			st and tostring(st.state) or "?", st and tostring(st.count) or "?")
	end
	if #lines == 0 then lines[1] = "nessun controller legato" end
	return lines
end

return M
