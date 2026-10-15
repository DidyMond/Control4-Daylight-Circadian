-- ============================================================
-- libs/schedule.lua - dalle proprieta' del driver agli switchpoint per curve.lua
--
-- Lua 5.1 puro, nessun riferimento a C4: legge le proprieta' tramite una
-- funzione `get(nome) -> stringa|nil` (nel driver: Properties[nome]).
--
-- Proprieta' lette (nomi del driver.xml): "Scheduler Mode",
-- "Number of Switchpoints", "Minimum/Maximum Colour Temperature" e, per
-- ogni SP n: "SP n Type" ("Set Time" | "Astronomical"), "SP n Time" (HH:MM),
-- "SP n Astronomical Reference", "SP n Offset (mins)", "SP n Brightness",
-- "SP n Colour Temperature".
-- ============================================================

local curve = require "libs.curve"

local M = {}

M.MODE_BOTH = "Brightness + Colour Temperature"
M.MODE_BRIGHTNESS = "Brightness Only"
M.MODE_CCT = "Colour Temperature Only"

M.MIN_SP, M.MAX_SP = 3, 10

local ASTRO_KEYS = {
	["Sunrise"] = "sunrise",
	["Solar Noon"] = "solar_noon",
	["Sunset"] = "sunset",
	["Solar Midnight"] = "solar_midnight",
}

local function wrap(x, period)
	return x - math.floor(x / period) * period
end

local function clamp(v, lo, hi)
	if v < lo then return lo end
	if v > hi then return hi end
	return v
end

-- Numero da stringa con '.' o ',' come separatore decimale (Janus v114).
function M.parse_number(text)
	if type(text) == "number" then return text end
	if type(text) ~= "string" then return nil end
	local s = text:gsub("^%s+", ""):gsub("%s+$", ""):gsub(",", ".")
	return tonumber(s)
end

-- "HH:MM" (anche "H:MM", spazi ammessi) -> minuti da mezzanotte, nil se non valido
function M.parse_time(text)
	if type(text) ~= "string" then return nil end
	local h, m = text:match("^%s*(%d%d?):(%d%d)%s*$")
	if not h then return nil end
	h, m = tonumber(h), tonumber(m)
	if h > 23 or m > 59 then return nil end
	return h * 60 + m
end

function M.format_time(minutes)
	local total = math.floor(wrap(minutes, 1440) + 0.5) % 1440
	return string.format("%02d:%02d", math.floor(total / 60), total % 60)
end

-- read_config(get) -> cfg, warnings
--   cfg = { mode, use_brightness, use_cct, count, ct_min, ct_max, sps = { ... } }
--   sp  = { n, type, time, ref, offset, brightness, cct }
-- Valori mancanti o fuori range vengono riportati nei limiti (con warning).
function M.read_config(get)
	local warnings = {}
	local function warn(fmt, ...) warnings[#warnings + 1] = string.format(fmt, ...) end

	local mode = get("Scheduler Mode")
	if mode ~= M.MODE_BOTH and mode ~= M.MODE_BRIGHTNESS and mode ~= M.MODE_CCT then
		if mode ~= nil then warn("Scheduler Mode sconosciuto '%s': uso '%s'", tostring(mode), M.MODE_BOTH) end
		mode = M.MODE_BOTH
	end

	local count = M.parse_number(get("Number of Switchpoints"))
	if not count then
		count = 4
	else
		count = math.floor(count)
		if count < M.MIN_SP or count > M.MAX_SP then
			warn("Number of Switchpoints %d fuori range %d..%d: limitato", count, M.MIN_SP, M.MAX_SP)
			count = clamp(count, M.MIN_SP, M.MAX_SP)
		end
	end

	local ct_min = M.parse_number(get("Minimum Colour Temperature")) or curve.CCT_MIN
	local ct_max = M.parse_number(get("Maximum Colour Temperature")) or curve.CCT_MAX
	if ct_min > ct_max then
		warn("CT minima %d > massima %d: scambiate", ct_min, ct_max)
		ct_min, ct_max = ct_max, ct_min
	end

	local sps = {}
	for n = 1, count do
		local function p(suffix) return get("SP " .. n .. " " .. suffix) end
		local sp = {
			n = n,
			type = (p("Type") == "Astronomical") and "Astronomical" or "Set Time",
			ref = p("Astronomical Reference") or "Sunrise",
			offset = clamp(M.parse_number(p("Offset (mins)")) or 0, -180, 180),
			brightness = clamp(M.parse_number(p("Brightness")) or 0, 0, 100),
			cct = clamp(M.parse_number(p("Colour Temperature")) or 3000, curve.CCT_MIN, curve.CCT_MAX),
		}
		if sp.type == "Set Time" then
			sp.time = M.parse_time(p("Time"))
			if not sp.time then
				warn("SP %d: orario '%s' non valido (HH:MM), switchpoint ignorato", n, tostring(p("Time")))
			end
		elseif not ASTRO_KEYS[sp.ref] then
			warn("SP %d: riferimento astronomico '%s' sconosciuto, switchpoint ignorato", n, tostring(sp.ref))
			sp.invalid = true
		end
		sps[n] = sp
	end

	return {
		mode = mode,
		use_brightness = (mode ~= M.MODE_CCT),
		use_cct = (mode ~= M.MODE_BRIGHTNESS),
		count = count,
		ct_min = ct_min,
		ct_max = ct_max,
		sps = sps,
	}, warnings
end

-- resolve(cfg, astro) -> entries, warnings
--   entries[i] = { n, label, t, brightness, cct }  (uno per SP, in ordine di n)
--   t = minuto del giorno ARROTONDATO AL MINUTO (0..1439) oppure nil se l'SP non
--   e' risolvibile; label = "Set Time" o "<Riferimento>+<offset>" (es. "Sunset-30").
--   astro = { sunrise, solar_noon, sunset, solar_midnight } in minuti dell'orologio
--   locale (sun.calculate con offset); puo' mancare (nil) o avere campi nil
--   (casi polari): gli SP astronomici non risolvibili sono saltati con warning.
--   Collisioni: due SP che risolvono allo stesso minuto producono un warning e
--   nella curva vince l'ultimo (numero SP piu' alto).
function M.resolve(cfg, astro)
	local entries, warnings = {}, {}
	local seen = {}
	for _, sp in ipairs(cfg.sps) do
		local e = { n = sp.n, brightness = sp.brightness, cct = sp.cct }
		local t
		if sp.type == "Set Time" then
			e.label = "Set Time"
			t = sp.time
		else
			local off = math.floor(sp.offset + 0.5)
			e.label = string.format("%s%+d", sp.ref, off)
			if not sp.invalid then
				local base = astro and astro[ASTRO_KEYS[sp.ref]]
				if base then
					t = base + sp.offset
				else
					warnings[#warnings + 1] = string.format("SP %d: %s non disponibile oggi, switchpoint saltato", sp.n, sp.ref)
				end
			end
		end
		if t then
			t = math.floor(wrap(t, 1440) + 0.5) % 1440
			e.t = t
			if seen[t] then
				warnings[#warnings + 1] = string.format("SP %d e SP %d coincidono a %s: l'ultimo vince",
					seen[t], sp.n, M.format_time(t))
			end
			seen[t] = sp.n
		end
		entries[#entries + 1] = e
	end
	return entries, warnings
end

-- Punti per curve.lua dalle entries risolte (SP non risolvibili esclusi).
function M.points(entries)
	local points = {}
	for _, e in ipairs(entries) do
		if e.t then
			points[#points + 1] = { t = e.t, brightness = e.brightness, cct = e.cct, n = e.n }
		end
	end
	return points
end

-- build_points(cfg, astro) -> points, warnings (comodo: resolve + points)
function M.build_points(cfg, astro)
	local entries, warnings = M.resolve(cfg, astro)
	return M.points(entries), warnings
end

-- Riga compatta per il log (livello Info) a ogni ricostruzione della schedule:
--   SP1 00:00 (Solar Midnight+0) b=20 cct=2700 | SP2 07:00 (Set Time) b=...
function M.summary(entries)
	local parts = {}
	for _, e in ipairs(entries) do
		parts[#parts + 1] = string.format("SP%d %s (%s) b=%d cct=%d", e.n,
			e.t and M.format_time(e.t) or "--:--", e.label,
			math.floor(e.brightness + 0.5), math.floor(e.cct + 0.5))
	end
	return table.concat(parts, " | ")
end

-- Valori target a `minute` sulla curva preparata: { brightness, cct } con la
-- CCT riportata nei CT Limits.
function M.target(prepared, cfg, minute)
	local v = prepared:evaluate(minute)
	return {
		brightness = v.brightness,
		cct = clamp(v.cct, cfg.ct_min, cfg.ct_max),
	}
end

-- Righe leggibili della schedule (DISPLAY_SCHEDULE), con gli eventuali warning
-- (SP che coincidono, SP non risolvibili).
function M.describe(cfg, astro)
	local entries, warnings = M.resolve(cfg, astro)
	local lines = { string.format("Scheduler Mode: %s, %d switchpoint, CT limits %d-%d K",
		cfg.mode, cfg.count, cfg.ct_min, cfg.ct_max) }
	local sorted = {}
	for _, e in ipairs(entries) do
		if e.t then sorted[#sorted + 1] = e end
	end
	table.sort(sorted, function(a, b)
		if a.t ~= b.t then return a.t < b.t end
		return a.n < b.n
	end)
	for _, e in ipairs(sorted) do
		lines[#lines + 1] = string.format("  %s  SP %d (%s)  brightness %d%%  %d K",
			M.format_time(e.t), e.n, e.label, math.floor(e.brightness + 0.5), math.floor(e.cct + 0.5))
	end
	for _, w in ipairs(warnings) do
		lines[#lines + 1] = "  ATTENZIONE: " .. w
	end
	return lines
end

return M
