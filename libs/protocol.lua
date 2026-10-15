-- ============================================================
-- libs/protocol.lua - protocollo controller <-> webview (binding DAYLIGHT_CIRCADIAN_COMMS)
--
-- Lua 5.1 puro, nessun riferimento a C4. Schema completo in docs/ARCHITECTURE.md,
-- sezione "Comms protocol". Ogni messaggio e' un oggetto JSON con v = 1, passato in
-- UN SOLO parametro stringa ("json") dei comandi Control4: i parametri dei comandi
-- sono tabelle piatte di stringhe, il JSON evita di mangiare i tipi e l'annidamento.
--
--   webview -> controller   C4:SendToDevice(id, "DC_REQUEST", { json = <richiesta> })
--   controller -> webview   C4:SendToProxy(1, "DC_MESSAGE",  { json = <messaggio> })
--
-- Richiesta : { v, id, op, args, from }
-- Messaggi  : { v, type = "ACK" | "STATE" | "PREVIEW" | "HELLO", controller, ... }
-- ============================================================

local json = require "libs.json"
local schedule = require "libs.schedule"

local M = {}

M.VERSION = 1
M.COMMAND_REQUEST = "DC_REQUEST"
M.COMMAND_MESSAGE = "DC_MESSAGE"
M.PARAM = "json"
M.SAMPLE_STEP_MIN = 10

M.OPS = {
	"GET_STATE", "SET_SWITCHPOINT", "DELETE_SWITCHPOINT", "SET_CT_LIMITS", "SET_MODE", "SET_NUM_SP",
	"PAUSE", "RESUME", "PREVIEW", "STOP_PREVIEW", "FOLLOW",
}
local OP_SET = {}
for _, op in ipairs(M.OPS) do OP_SET[op] = true end

M.ASTRO_REFS = { "Sunrise", "Solar Noon", "Sunset", "Solar Midnight" }
M.SP_TYPES = { "Set Time", "Astronomical" }
M.MODES = { schedule.MODE_BOTH, schedule.MODE_BRIGHTNESS, schedule.MODE_CCT }

-- normalizza "solar_noon", "Solar Noon", "SOLARNOON" -> "solarnoon"
local function norm(s)
	return (tostring(s):lower():gsub("[^%w]", ""))
end

local function lookup(list, aliases, value)
	local key = norm(value)
	for _, item in ipairs(list) do
		if norm(item) == key then return item end
	end
	return aliases and aliases[key] or nil
end

local TYPE_ALIASES = { time = "Set Time", fixed = "Set Time", astro = "Astronomical" }
local MODE_ALIASES = {
	both = schedule.MODE_BOTH, brightnesscct = schedule.MODE_BOTH,
	brightness = schedule.MODE_BRIGHTNESS, cct = schedule.MODE_CCT, ct = schedule.MODE_CCT,
	colourtemperature = schedule.MODE_CCT,
}

-- ---------------------------------------------------------------- codec
function M.encode(message)
	return json.encode(message)
end

-- decode(text) -> messaggio | nil, errore  (controlla oggetto e versione)
function M.decode(text)
	local value, err = json.decode(text)
	if value == nil then return nil, err end
	if type(value) ~= "table" or json.is_null(value) then return nil, "messaggio non e' un oggetto" end
	if value.v ~= M.VERSION then return nil, "versione protocollo non supportata: " .. tostring(value.v) end
	return value
end

function M.request(id, op, args, from)
	return { v = M.VERSION, id = id, op = op, args = args or json.object({}), from = from }
end

-- ack(req_id, op, ok [, err [, extra]]) -> messaggio ACK
function M.ack(req_id, op, ok, err, extra)
	local msg = { v = M.VERSION, type = "ACK", id = req_id, op = op, ok = ok and true or false }
	if err then msg.error = err end
	for k, v in pairs(extra or {}) do msg[k] = v end
	return msg
end

-- ---------------------------------------------------------------- validazione e mappa sulle proprieta'
local function num(v)
	if type(v) == "number" then return v end
	if type(v) == "string" then return schedule.parse_number(v) end
	return nil
end

local function int_in(v, lo, hi, label)
	local n = num(v)
	if n == nil or n ~= n then return nil, label .. ": numero richiesto" end
	n = math.floor(n + 0.5)
	if n < lo or n > hi then return nil, string.format("%s: fuori range %d..%d", label, lo, hi) end
	return n
end

local function sp_prop(n, suffix) return "SP " .. n .. " " .. suffix end

-- property_writes(op, args) -> { {name, value}, ... } | nil, errore
-- I nomi sono quelli del driver.xml del controller; i valori sono stringhe come le
-- scriverebbe Composer. Gli op senza proprieta' (PAUSE, ...) ritornano lista vuota.
function M.property_writes(op, args)
	if not OP_SET[op] then return nil, "op sconosciuta: " .. tostring(op) end
	args = type(args) == "table" and args or {}
	local writes = {}

	if op == "SET_SWITCHPOINT" then
		local n, err = int_in(args.n, 1, schedule.MAX_SP, "n")
		if not n then return nil, err end
		local changed = false
		if args.type ~= nil then
			local v = lookup(M.SP_TYPES, TYPE_ALIASES, args.type)
			if not v then return nil, "type: atteso 'Set Time' o 'Astronomical'" end
			writes[#writes + 1] = { sp_prop(n, "Type"), v }
			changed = true
		end
		if args.time ~= nil then
			local minutes = schedule.parse_time(tostring(args.time))
			if not minutes then return nil, "time: formato HH:MM (00:00-23:59) richiesto" end
			writes[#writes + 1] = { sp_prop(n, "Time"), schedule.format_time(minutes) }
			changed = true
		end
		if args.astroRef ~= nil then
			local v = lookup(M.ASTRO_REFS, nil, args.astroRef)
			if not v then return nil, "astroRef: atteso Sunrise, Solar Noon, Sunset o Solar Midnight" end
			writes[#writes + 1] = { sp_prop(n, "Astronomical Reference"), v }
			changed = true
		end
		if args.offset ~= nil then
			local v, e = int_in(args.offset, -180, 180, "offset")
			if not v then return nil, e end
			writes[#writes + 1] = { sp_prop(n, "Offset (mins)"), tostring(v) }
			changed = true
		end
		if args.brightness ~= nil then
			local v, e = int_in(args.brightness, 0, 100, "brightness")
			if not v then return nil, e end
			writes[#writes + 1] = { sp_prop(n, "Brightness"), tostring(v) }
			changed = true
		end
		if args.cct ~= nil then
			local v, e = int_in(args.cct, 1600, 6500, "cct")
			if not v then return nil, e end
			writes[#writes + 1] = { sp_prop(n, "Colour Temperature"), tostring(v) }
			changed = true
		end
		if not changed then return nil, "nessun campo da modificare" end

	elseif op == "DELETE_SWITCHPOINT" then
		-- solo validazione: le scritture (spostamento degli SP successivi) le calcola
		-- M.delete_writes, che conosce il numero e i valori correnti
		local n, err = int_in(args.n, 1, schedule.MAX_SP, "n")
		if not n then return nil, err end

	elseif op == "SET_CT_LIMITS" then
		local lo, e1 = int_in(args.min, 1600, 6500, "min")
		if not lo then return nil, e1 end
		local hi, e2 = int_in(args.max, 1600, 6500, "max")
		if not hi then return nil, e2 end
		if lo > hi then return nil, "min deve essere <= max" end
		writes[1] = { "Minimum Colour Temperature", tostring(lo) }
		writes[2] = { "Maximum Colour Temperature", tostring(hi) }

	elseif op == "SET_MODE" then
		local v = args.mode ~= nil and lookup(M.MODES, MODE_ALIASES, args.mode) or nil
		if not v then return nil, "mode: atteso 'Brightness + Colour Temperature', 'Brightness Only' o 'Colour Temperature Only'" end
		writes[1] = { "Scheduler Mode", v }

	elseif op == "SET_NUM_SP" then
		local v, e = int_in(args.count, schedule.MIN_SP, schedule.MAX_SP, "count")
		if not v then return nil, e end
		writes[1] = { "Number of Switchpoints", tostring(v) }
	end

	return writes
end

-- Campi per switchpoint (suffissi delle proprieta' "SP n <campo>" del driver.xml)
local SP_FIELDS = { "Type", "Time", "Astronomical Reference", "Offset (mins)", "Brightness", "Colour Temperature" }

-- delete_writes(args, count, get) -> { {name, value}, ... } | nil, errore
-- Elimina lo switchpoint n: gli SP successivi scalano di una posizione e "Number of
-- Switchpoints" cala di 1 (le proprieta' oltre il nuovo conteggio restano, ignorate).
-- get(nome) ritorna il valore corrente (stringa) della proprieta' o nil.
function M.delete_writes(args, count, get)
	args = type(args) == "table" and args or {}
	local n, err = int_in(args.n, 1, schedule.MAX_SP, "n")
	if not n then return nil, err end
	if count <= schedule.MIN_SP then
		return nil, string.format("minimo %d switchpoint: impossibile eliminare", schedule.MIN_SP)
	end
	if n > count then return nil, string.format("n: lo switchpoint %d non esiste (ce ne sono %d)", n, count) end
	local writes = {}
	for i = n, count - 1 do
		for _, field in ipairs(SP_FIELDS) do
			local v = get(sp_prop(i + 1, field))
			if v ~= nil then writes[#writes + 1] = { sp_prop(i, field), v } end
		end
	end
	writes[#writes + 1] = { "Number of Switchpoints", tostring(count - 1) }
	return writes
end

-- ---------------------------------------------------------------- snapshot
local function round(x, decimals)
	local m = 10 ^ (decimals or 0)
	return math.floor(x * m + 0.5) / m
end

-- build_snapshot(d) -> tabella STATE.
--   d = { id, name, state, preview = {active, minute}, cfg, entries, warnings, astro,
--         samples = { {t, brightness, cct}, ... }, lights = { {id, level, overridden}, ... },
--         monitoring }
-- Campi vuoti/assenti sono omessi (null non serve alla UI).
function M.build_snapshot(d)
	local sps = {}
	local raw = {}
	for _, sp in ipairs(d.cfg and d.cfg.sps or {}) do raw[sp.n] = sp end
	for _, e in ipairs(d.entries or {}) do
		local sp = raw[e.n] or {}
		local item = {
			n = e.n,
			type = sp.type,
			astroRef = sp.ref,
			offset = sp.offset,
			brightness = e.brightness,
			cct = e.cct,
			label = e.label,
		}
		if sp.time then item.time = schedule.format_time(sp.time) end
		if e.t then
			item.t = e.t
			item.at = schedule.format_time(e.t)
		end
		sps[#sps + 1] = item
	end

	local snap = {
		v = M.VERSION,
		type = "STATE",
		controller = d.id,
		name = d.name,
		state = d.state,
		preview = {
			active = d.preview and d.preview.active or false,
			minute = d.preview and d.preview.minute or nil,
			duration_s = d.preview and d.preview.duration_s or nil, -- fattore di accelerazione = 86400 / duration_s
		},
		monitoring = d.monitoring,
		mode = d.cfg and d.cfg.mode,
		count = d.cfg and d.cfg.count,
		ct = d.cfg and { min = d.cfg.ct_min, max = d.cfg.ct_max } or nil,
		switchpoints = json.array(sps),
		warnings = json.array(d.warnings or {}),
		lights = json.array(d.lights or {}),
	}
	if d.astro then
		snap.astro = {
			date = d.astro.date, offset = d.astro.offset,
			sunrise = d.astro.sunrise and round(d.astro.sunrise, 1),
			solar_noon = d.astro.solar_noon and round(d.astro.solar_noon, 1),
			sunset = d.astro.sunset and round(d.astro.sunset, 1),
			solar_midnight = d.astro.solar_midnight and round(d.astro.solar_midnight, 1),
			polar = d.astro.polar,
		}
	end
	if d.samples then
		local pts = {}
		for i, s in ipairs(d.samples) do
			pts[i] = json.array({ s.t, round(s.brightness, 1), math.floor(s.cct + 0.5) })
		end
		snap.curve = { step = M.SAMPLE_STEP_MIN, samples = json.array(pts) }
	end
	return snap
end

return M
