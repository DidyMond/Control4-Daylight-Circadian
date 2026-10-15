-- ============================================================
-- libs/debug.lua - logging con Log Mode / Log Level
--
-- Lua 5.1 puro, nessun riferimento a C4: i "sink" (print/log) arrivano per
-- iniezione da driver.lua, cosi' il modulo si testa con un interprete locale.
--
-- Severita' (0 = piu' grave):
--   0 Alert | 1 Error | 2 Warning | 3 Info | 4 Trace | 5 Debug
-- Un messaggio di severita' S e' emesso solo se S <= Log Level.
-- Log Mode: "Off" | "Print" | "Log" | "Print and Log"
-- Log Level e' il valore della proprieta' LIST ("0 - Alert" ... "5 - Debug")
-- oppure direttamente un numero 0..5.
-- ============================================================

local M = {}

M.ALERT = 0
M.ERROR = 1
M.WARNING = 2
M.INFO = 3
M.TRACE = 4
M.DEBUG = 5

local NAMES = { [0] = "ALERT", "ERROR", "WARNING", "INFO", "TRACE", "DEBUG" }
local DEFAULT_LEVEL = M.INFO

-- Estrae la severita' da "3 - Info" o da un numero; default INFO se illeggibile.
function M.parse_level(value)
	local n = tonumber(value)
	if not n and type(value) == "string" then
		n = tonumber(value:match("^%s*(%d+)"))
	end
	if not n then return DEFAULT_LEVEL end
	n = math.floor(n)
	if n < 0 then n = 0 end
	if n > 5 then n = 5 end
	return n
end

function M.level_name(severity)
	return NAMES[severity] or tostring(severity)
end

local Logger = {}
Logger.__index = Logger

-- sinks = { print = function(line), log = function(line), prefix = "..." }
function M.new(sinks)
	sinks = sinks or {}
	return setmetatable({
		mode = "Off",
		level = DEFAULT_LEVEL,
		print_fn = sinks.print,
		log_fn = sinks.log,
		prefix = sinks.prefix or "",
	}, Logger)
end

function Logger:set_mode(mode)
	if mode == "Print" or mode == "Log" or mode == "Print and Log" then
		self.mode = mode
	else
		self.mode = "Off"
	end
end

function Logger:set_level(value)
	self.level = M.parse_level(value)
end

function Logger:enabled(severity)
	return self.mode ~= "Off" and severity <= self.level
end

-- log(M.INFO, "tick #%d", n): formatta solo se il messaggio verra' emesso.
function Logger:log(severity, fmt, ...)
	if not self:enabled(severity) then return end
	local text = fmt
	if select("#", ...) > 0 then
		local ok, res = pcall(string.format, fmt, ...)
		text = ok and res or (tostring(fmt) .. " (format error)")
	end
	local line = string.format("%s[%s] %s", self.prefix, M.level_name(severity), tostring(text))
	if (self.mode == "Print" or self.mode == "Print and Log") and self.print_fn then
		self.print_fn(line)
	end
	if (self.mode == "Log" or self.mode == "Print and Log") and self.log_fn then
		self.log_fn(line)
	end
end

return M
