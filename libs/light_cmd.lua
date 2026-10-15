-- ============================================================
-- libs/light_cmd.lua - comandi Light V2, capabilities, batch staggered
--
-- Lua 5.1 puro, nessun riferimento a C4.
--
-- Fonte: Control4 DriverWorks Proxy Protocol, sezione Light V2
--   https://control4.github.io/docs-driverworks-proxyprotocol/
--   SET_BRIGHTNESS_TARGET: LIGHT_BRIGHTNESS_TARGET_PERCENT (0..100), RATE (ms)
--   SET_COLOR_TARGET: LIGHT_COLOR_TARGET_X / _Y (CIE 1931),
--                     LIGHT_COLOR_TARGET_MODE (0 colore pieno, 1 CCT), RATE (ms)
--   RAMP_TO_LEVEL {LEVEL, TIME ms}: fallback documentato per luci senza
--   supports_target (SET_LEVEL non esiste in Light V2).
-- La conversione CCT -> x/y la fa C4:ColorCCTtoXY (OS >= 3.3.0): qui arriva
-- gia' calcolata (iniettata dal driver).
-- ============================================================

local M = {}

M.VAR_LIGHT_STATE = 1000       -- "Light State" (booleano)
M.VAR_BRIGHTNESS_PERCENT = 1001 -- "Light Brightness Percent" (0..100)
M.VAR_DYNAMIC_CAPABILITIES = 6661 -- XML <DynamicCapabilities>

-- Eventi di sistema del proxy (documentati; non portano il valore del livello)
M.EVENT_BRIGHTNESS_CHANGING = 4000
M.EVENT_BRIGHTNESS_CHANGED = 4001
M.EVENT_COLOR_CHANGING = 4002
M.EVENT_COLOR_CHANGED = 4003
M.EVENT_LIGHT_ON = 5100
M.EVENT_LIGHT_OFF = 5101

-- Il proxy Light V2 NON ha una variabile per il colore/CCT correnti (variabili
-- documentate: 1000-1010, 1300, 1301, 6661): l'unico segnale lato colore sono gli
-- eventi 4002/4003, senza valore. Si registrano come sonde insieme agli altri.
M.PROBE_EVENTS = {
	M.EVENT_BRIGHTNESS_CHANGING, M.EVENT_BRIGHTNESS_CHANGED,
	M.EVENT_COLOR_CHANGING, M.EVENT_COLOR_CHANGED,
	M.EVENT_LIGHT_ON, M.EVENT_LIGHT_OFF,
}

local EVENT_NAMES = {
	[4000] = "Light Brightness Changing", [4001] = "Light Brightness Changed",
	[4002] = "Light Color Changing", [4003] = "Light Color Changed",
	[5100] = "Light On", [5101] = "Light Off",
}

function M.event_name(id)
	return EVENT_NAMES[id] or "?"
end

-- brightness(caps, percent, rate_ms) -> comando, parametri
function M.brightness(caps, percent, rate_ms)
	percent = math.max(0, math.min(100, math.floor(percent + 0.5)))
	rate_ms = math.max(0, math.floor(rate_ms + 0.5))
	if caps and caps.supports_target == false then
		return "RAMP_TO_LEVEL", { LEVEL = percent, TIME = rate_ms }
	end
	return "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET_PERCENT = percent, RATE = rate_ms }
end

-- ---------------------------------------------------------------------------
-- SET_COLOR_TARGET
--
-- Tabella documentata (Proxy Protocol > Light V2 Commands > SET_COLOR_TARGET):
--   LIGHT_COLOR_TARGET_X      coordinata x CIE 1931
--   LIGHT_COLOR_TARGET_Y      coordinata y CIE 1931
--   LIGHT_COLOR_TARGET_MODE   0 = colore pieno, 1 = CCT (default 0; nessun altro valore)
--   RATE                      ms, opzionale (default del driver se assente)
-- La tabella NON elenca ne' parametri HSV ne' un parametro kelvin. Nella tabella
-- delle notify LIGHT_COLOR_CHANGING/CHANGED il nome e' invece ..._COLOR_MODE.
--
-- Formato reale per la CCT (fuori dalla tabella ufficiale):
--   * il client pyControl4 (traffico dell'app) manda per la CCT
--       LIGHT_COLOR_TARGET_MODE = 1 + LIGHT_COLOR_TARGET_COLOR_CORRELATED_TEMPERATURE = kelvin
--     SENZA X/Y, e per il colore pieno MODE = 0 + X/Y;
--   * i driver protocollo finitelabs (tplink/esphome) ricevono dal proxy kelvin, X, Y,
--     MODE e leggono il kelvin per primo; la rate la leggono da
--     LIGHT_COLOR_TARGET_COLOR_RATE, LIGHT_COLOR_TARGET_RATE o RATE.
-- Mandare MODE = 1 con X/Y (come facevamo) non e' il formato dell'app: il proxy
-- risponde (evento 4002) ma la lampada non vira.
-- ---------------------------------------------------------------------------
M.KEY_CCT = "LIGHT_COLOR_TARGET_COLOR_CORRELATED_TEMPERATURE"

-- Righe della tabella, loggate una tantum a Info (nomi esatti, prosa parafrasata).
M.COLOR_TARGET_DOC = {
	"SET_COLOR_TARGET (Proxy Protocol, Light V2 Commands): parametri documentati",
	"  LIGHT_COLOR_TARGET_X     = x CIE 1931",
	"  LIGHT_COLOR_TARGET_Y     = y CIE 1931",
	"  LIGHT_COLOR_TARGET_MODE  = intero: 0 colore pieno, 1 CCT (default 0); altri valori non documentati",
	"  RATE                     = ms di rampa, opzionale",
	"  nessun parametro HSV/kelvin nella tabella; le notify usano LIGHT_COLOR_TARGET_COLOR_MODE",
	"Formato usato dall'app (pyControl4): CCT = MODE 1 + " .. M.KEY_CCT .. " (senza X/Y); colore pieno = MODE 0 + X/Y",
}

-- color_rate(caps, rate_ms) -> rate (ms) | nil
-- Rispetta le capabilities colore della lampada (color_rate_behavior/min/max): le
-- docs le indicano come limiti per le rate specificate da programmazione/agenti.
--   behavior 0 = rate non modificabile => nessun parametro RATE;
--   min/max (se max > 0) => rate riportata nell'intervallo.
function M.color_rate(caps, rate_ms)
	rate_ms = math.max(0, math.floor(rate_ms + 0.5))
	if not caps then return rate_ms end
	if caps.color_rate_behavior == 0 then return nil end
	local lo, hi = caps.color_rate_min, caps.color_rate_max
	if hi and hi > 0 then
		if lo and rate_ms < lo then rate_ms = lo end
		if rate_ms > hi then rate_ms = hi end
	end
	return rate_ms
end

-- color_cct(kelvin, rate_ms [, caps]) -> comando, parametri
-- Payload ESATTO: MODE = 1, kelvin, RATE (se applicabile). Mai X/Y.
function M.color_cct(kelvin, rate_ms, caps)
	local params = {
		LIGHT_COLOR_TARGET_MODE = 1,
		[M.KEY_CCT] = math.floor(kelvin + 0.5),
	}
	local rate = M.color_rate(caps, rate_ms)
	if rate ~= nil then params.RATE = rate end
	return "SET_COLOR_TARGET", params
end

-- color_xy(x, y, rate_ms [, caps]) -> comando, parametri (colore pieno)
-- Payload ESATTO: MODE = 0, X, Y, RATE (se applicabile). Mai kelvin.
function M.color_xy(x, y, rate_ms, caps)
	local params = {
		LIGHT_COLOR_TARGET_MODE = 0,
		LIGHT_COLOR_TARGET_X = x,
		LIGHT_COLOR_TARGET_Y = y,
	}
	local rate = M.color_rate(caps, rate_ms)
	if rate ~= nil then params.RATE = rate end
	return "SET_COLOR_TARGET", params
end

-- "mode=1 {CCT=3024} rate=5000" per i log [SEND]: si vede a colpo se il mode matcha i parametri
function M.describe_color(params)
	local parts = {}
	if params[M.KEY_CCT] ~= nil then parts[#parts + 1] = "CCT=" .. tostring(params[M.KEY_CCT]) end
	if params.LIGHT_COLOR_TARGET_X ~= nil then
		parts[#parts + 1] = string.format("X=%.5f", params.LIGHT_COLOR_TARGET_X)
	end
	if params.LIGHT_COLOR_TARGET_Y ~= nil then
		parts[#parts + 1] = string.format("Y=%.5f", params.LIGHT_COLOR_TARGET_Y)
	end
	return string.format("mode=%s {%s} rate=%s", tostring(params.LIGHT_COLOR_TARGET_MODE),
		table.concat(parts, " "), tostring(params.RATE or "-"))
end

-- Tutti i tag <nome>valore dell'XML di capabilities (parser tollerante: nella
-- documentazione ufficiale alcuni tag non sono chiusi correttamente). Il valore e'
-- il testo fino al "<" successivo; i tag contenitore (valore vuoto) sono saltati.
function M.all_tags(xml)
	local tags = {}
	if type(xml) ~= "string" then return tags end
	local pos = 1
	while true do
		local s, e, name = xml:find("<([%w_]+)>", pos)
		if not s then break end
		local nxt = xml:find("<", e + 1, true)
		local value = xml:sub(e + 1, (nxt or (#xml + 1)) - 1):match("^%s*(.-)%s*$")
		if value ~= "" and tags[name] == nil then tags[name] = value end
		pos = e + 1
	end
	return tags
end

-- "k=v k=v ..." ordinato, per il dump a Info
function M.dump_tags(xml)
	local tags = M.all_tags(xml)
	local keys = {}
	for k in pairs(tags) do keys[#keys + 1] = k end
	table.sort(keys)
	local parts = {}
	for _, k in ipairs(keys) do parts[#parts + 1] = k .. "=" .. tags[k] end
	return table.concat(parts, " ")
end

-- XML su una riga sola
function M.compact_xml(xml)
	if type(xml) ~= "string" then return "" end
	return (xml:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""))
end

-- Capabilities dall'XML della variabile 6661. Campi mancanti => nil; l'insieme
-- e' nil se l'XML non e' una stringa.
function M.parse_caps(xml)
	if type(xml) ~= "string" or xml == "" then return nil end
	local tags = M.all_tags(xml)
	local function bool(name)
		local v = tags[name]
		if v == nil then return nil end
		v = v:lower()
		return v == "true" or v == "1"
	end
	return {
		supports_target = bool("supports_target"),
		supports_cct = bool("supports_color_correlated_temperature"),
		supports_color = bool("supports_color"),
		cct_min = tonumber(tags.color_correlated_temperature_min),
		cct_max = tonumber(tags.color_correlated_temperature_max),
		color_rate_behavior = tonumber(tags.color_rate_behavior),
		color_rate_min = tonumber(tags.color_rate_min),
		color_rate_max = tonumber(tags.color_rate_max),
		color_trace_tolerance = tonumber(tags.color_trace_tolerance),
	}
end

-- "13,16, 18" -> {13, 16, 18} (ordinati, senza duplicati); valori non numerici scartati
function M.parse_device_list(text)
	local seen, out = {}, {}
	if type(text) ~= "string" then return out end
	for token in text:gmatch("[^,]+") do
		local id = tonumber((token:gsub("%s", "")))
		if id and not seen[id] then
			seen[id] = true
			out[#out + 1] = id
		end
	end
	table.sort(out)
	return out
end

-- Staggered control (Janus v115): oltre `threshold` luci, a batch di `size`
-- con `delay_ms` fra un batch e l'altro. Ritorna { {delay_ms, first, last}, ... }
-- (indici 1-based inclusivi). Con n <= threshold: un solo batch a ritardo 0.
function M.stagger(n, threshold, size, delay_ms)
	threshold = threshold or 10
	size = size or 5
	delay_ms = delay_ms or 50
	local batches = {}
	if n <= 0 then return batches end
	if n <= threshold then
		batches[1] = { delay_ms = 0, first = 1, last = n }
		return batches
	end
	local first, i = 1, 0
	while first <= n do
		local last = math.min(first + size - 1, n)
		batches[#batches + 1] = { delay_ms = i * delay_ms, first = first, last = last }
		first = last + 1
		i = i + 1
	end
	return batches
end

return M
