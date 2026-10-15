-- ============================================================
-- libs/json.lua - codec JSON minimale (RFC 8259), Lua 5.1 puro, senza C4
--
-- Perche' non C4:JsonEncode: le libs devono restare pure e testabili offline, e la
-- documentazione Control4 avverte che tostring/tonumber dipendono dal locale del
-- controller (virgola decimale): qui i numeri sono scritti e letti a mano, sempre
-- con il punto.
--
-- encode(value) -> stringa
--   * tabelle con chiavi 1..n consecutive => array; altrimenti oggetto (chiavi
--     stringa ordinate, per output deterministico); tabella vuota => "[]"
--     (usa json.object() per un oggetto vuoto)
--   * numeri non finiti (NaN/inf) => null; funzioni/userdata => errore
-- decode(testo) -> valore | nil, "errore"
--   * array => tabelle con chiavi 1..n; null => json.null (sentinella)
-- ============================================================

local M = {}

M.null = setmetatable({}, { __tostring = function() return "null" end })

local OBJECT_MT = {}
local ARRAY_MT = {}

-- oggetto vuoto esplicito / array vuoto esplicito
function M.object(t) return setmetatable(t or {}, OBJECT_MT) end
function M.array(t) return setmetatable(t or {}, ARRAY_MT) end

local ESCAPES = {
	['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f",
	["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t",
}

local function escape_string(s)
	return '"' .. s:gsub('[%c"\\]', function(c)
		return ESCAPES[c] or string.format("\\u%04x", c:byte())
	end) .. '"'
end

local function encode_number(n)
	if n ~= n or n == math.huge or n == -math.huge then return "null" end
	if n == math.floor(n) and math.abs(n) < 1e15 then
		return string.format("%d", n)
	end
	-- virgola decimale dei locale non C => punto
	return (string.format("%.14g", n):gsub(",", "."))
end

local function is_array(t)
	local mt = getmetatable(t)
	if mt == ARRAY_MT then return true end
	if mt == OBJECT_MT then return false end
	local n = 0
	for k in pairs(t) do
		if type(k) ~= "number" or k < 1 or k ~= math.floor(k) then return false end
		n = n + 1
	end
	if n == 0 then return true end
	for i = 1, n do
		if t[i] == nil then return false end
	end
	return true
end

local function encode_value(v, depth, out)
	if depth > 40 then error("json: struttura troppo profonda") end
	local t = type(v)
	if v == M.null or v == nil then
		out[#out + 1] = "null"
	elseif t == "boolean" then
		out[#out + 1] = v and "true" or "false"
	elseif t == "number" then
		out[#out + 1] = encode_number(v)
	elseif t == "string" then
		out[#out + 1] = escape_string(v)
	elseif t == "table" then
		if is_array(v) then
			out[#out + 1] = "["
			for i = 1, #v do
				if i > 1 then out[#out + 1] = "," end
				encode_value(v[i], depth + 1, out)
			end
			out[#out + 1] = "]"
		else
			local keys = {}
			for k in pairs(v) do
				if type(k) ~= "string" then error("json: chiave non stringa nell'oggetto") end
				keys[#keys + 1] = k
			end
			table.sort(keys)
			out[#out + 1] = "{"
			for i, k in ipairs(keys) do
				if i > 1 then out[#out + 1] = "," end
				out[#out + 1] = escape_string(k)
				out[#out + 1] = ":"
				encode_value(v[k], depth + 1, out)
			end
			out[#out + 1] = "}"
		end
	else
		error("json: tipo non serializzabile: " .. t)
	end
end

function M.encode(value)
	local out = {}
	encode_value(value, 0, out)
	return table.concat(out)
end

-- ---------------------------------------------------------------- decode
local function utf8_char(cp)
	if cp < 0x80 then return string.char(cp) end
	if cp < 0x800 then
		return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
	end
	if cp < 0x10000 then
		return string.char(0xE0 + math.floor(cp / 0x1000), 0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
	end
	return string.char(0xF0 + math.floor(cp / 0x40000), 0x80 + math.floor(cp / 0x1000) % 0x40,
		0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
end

local function fail(pos, msg)
	error({ json_error = msg .. " alla posizione " .. pos }, 0)
end

local function skip_ws(s, pos)
	return s:find("[^ \t\r\n]", pos) or (#s + 1)
end

-- numero senza tonumber sui decimali (locale): parte intera/frazione/esponente a mano
local function parse_number(s, pos)
	local start = pos
	local sign = ""
	if s:sub(pos, pos) == "-" then sign = "-"; pos = pos + 1 end
	local int = s:match("^%d+", pos)
	if not int then fail(start, "numero non valido") end
	if int:len() > 1 and int:sub(1, 1) == "0" then fail(start, "zero iniziale non valido") end
	pos = pos + #int
	local frac = ""
	if s:sub(pos, pos) == "." then
		frac = s:match("^%d+", pos + 1)
		if not frac then fail(start, "frazione non valida") end
		pos = pos + 1 + #frac
	end
	local exp
	local e = s:match("^[eE][+-]?%d+", pos)
	if e then
		exp = tonumber((e:sub(2):gsub("^%+", "")))
		pos = pos + #e
	end
	local value = tonumber(int)
	if frac ~= "" then value = value + tonumber(frac) / (10 ^ #frac) end
	if exp then value = value * (10 ^ exp) end
	if sign == "-" then value = -value end
	return value, pos
end

local parse_value

local function parse_string(s, pos)
	local out, i = {}, pos + 1
	while true do
		local j = s:find('["\\%c]', i)
		if not j then fail(pos, "stringa non chiusa") end
		out[#out + 1] = s:sub(i, j - 1)
		local c = s:sub(j, j)
		if c == '"' then return table.concat(out), j + 1 end
		if c ~= "\\" then fail(j, "carattere di controllo in stringa") end
		local e = s:sub(j + 1, j + 1)
		local simple = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }
		if simple[e] then
			out[#out + 1] = simple[e]
			i = j + 2
		elseif e == "u" then
			local hex = s:sub(j + 2, j + 5)
			if not hex:match("^%x%x%x%x$") then fail(j, "escape \\u non valido") end
			local cp = tonumber(hex, 16)
			i = j + 6
			if cp >= 0xD800 and cp <= 0xDBFF then
				local low = s:match("^\\u(%x%x%x%x)", i)
				if low and tonumber(low, 16) >= 0xDC00 and tonumber(low, 16) <= 0xDFFF then
					cp = 0x10000 + (cp - 0xD800) * 0x400 + (tonumber(low, 16) - 0xDC00)
					i = i + 6
				end
			end
			out[#out + 1] = utf8_char(cp)
		else
			fail(j, "escape non valido")
		end
	end
end

local function parse_array(s, pos, depth)
	local arr, i = M.array({}), skip_ws(s, pos + 1)
	if s:sub(i, i) == "]" then return arr, i + 1 end
	while true do
		local v
		v, i = parse_value(s, i, depth + 1)
		arr[#arr + 1] = v
		i = skip_ws(s, i)
		local c = s:sub(i, i)
		if c == "]" then return arr, i + 1 end
		if c ~= "," then fail(i, "atteso ',' o ']'") end
		i = skip_ws(s, i + 1)
	end
end

local function parse_object(s, pos, depth)
	local obj, i = {}, skip_ws(s, pos + 1)
	if s:sub(i, i) == "}" then return M.object(obj), i + 1 end
	while true do
		if s:sub(i, i) ~= '"' then fail(i, "attesa chiave stringa") end
		local k
		k, i = parse_string(s, i)
		i = skip_ws(s, i)
		if s:sub(i, i) ~= ":" then fail(i, "atteso ':'") end
		local v
		v, i = parse_value(s, skip_ws(s, i + 1), depth + 1)
		obj[k] = v
		i = skip_ws(s, i)
		local c = s:sub(i, i)
		if c == "}" then return obj, i + 1 end
		if c ~= "," then fail(i, "atteso ',' o '}'") end
		i = skip_ws(s, i + 1)
	end
end

function parse_value(s, pos, depth)
	if depth > 40 then fail(pos, "struttura troppo profonda") end
	local c = s:sub(pos, pos)
	if c == "{" then return parse_object(s, pos, depth) end
	if c == "[" then return parse_array(s, pos, depth) end
	if c == '"' then return parse_string(s, pos) end
	if c == "-" or c:match("%d") then return parse_number(s, pos) end
	if s:sub(pos, pos + 3) == "true" then return true, pos + 4 end
	if s:sub(pos, pos + 4) == "false" then return false, pos + 5 end
	if s:sub(pos, pos + 3) == "null" then return M.null, pos + 4 end
	fail(pos, "valore inatteso")
end

-- decode(text [, max_bytes]) -> value | nil, errore
function M.decode(text, max_bytes)
	if type(text) ~= "string" then return nil, "input non stringa" end
	if #text > (max_bytes or 1048576) then return nil, "input troppo grande" end
	local ok, value, pos = pcall(function()
		local v, p = parse_value(text, skip_ws(text, 1), 0)
		p = skip_ws(text, p)
		if p <= #text then fail(p, "testo dopo il valore") end
		return v, p
	end)
	if ok then return value end
	if type(value) == "table" and value.json_error then return nil, value.json_error end
	return nil, tostring(value)
end

function M.is_null(v) return v == M.null end

return M
