-- Test di libs/debug.lua (Log Mode / Log Level)
local t = require "tests.support.harness"
local dbg = require "libs.debug"

-- logger con sink che raccolgono le righe emesse
local function make(mode, level)
	local printed, logged = {}, {}
	local logger = dbg.new({
		print = function(line) printed[#printed + 1] = line end,
		log = function(line) logged[#logged + 1] = line end,
		prefix = "T ",
	})
	logger:set_mode(mode)
	logger:set_level(level)
	return logger, printed, logged
end

t.test("parse_level: valori LIST '0 - Alert' .. '5 - Debug'", function()
	local items = { "0 - Alert", "1 - Error", "2 - Warning", "3 - Info", "4 - Trace", "5 - Debug" }
	for i, item in ipairs(items) do
		t.eq(dbg.parse_level(item), i - 1, item)
	end
end)

t.test("parse_level: numero, default Info, clamp", function()
	t.eq(dbg.parse_level(4), 4)
	t.eq(dbg.parse_level(nil), dbg.INFO)
	t.eq(dbg.parse_level("boh"), dbg.INFO)
	t.eq(dbg.parse_level(99), 5)
	t.eq(dbg.parse_level(-3), 0)
end)

t.test("soglia: emesso solo se severita' <= Log Level", function()
	local logger, printed = make("Print", "3 - Info")
	logger:log(dbg.ALERT, "a")
	logger:log(dbg.ERROR, "e")
	logger:log(dbg.WARNING, "w")
	logger:log(dbg.INFO, "i")
	logger:log(dbg.TRACE, "t")
	logger:log(dbg.DEBUG, "d")
	t.eq(#printed, 4)
end)

t.test("Log Level 0 - Alert: solo gli alert", function()
	local logger, printed = make("Print", "0 - Alert")
	logger:log(dbg.ALERT, "a")
	logger:log(dbg.ERROR, "e")
	t.eq(#printed, 1)
end)

t.test("Log Level 5 - Debug: tutto", function()
	local logger, printed = make("Print", "5 - Debug")
	for s = 0, 5 do logger:log(s, "x") end
	t.eq(#printed, 6)
end)

t.test("Log Mode Off: niente, a nessun livello", function()
	local logger, printed, logged = make("Off", "5 - Debug")
	logger:log(dbg.ALERT, "a")
	t.eq(#printed + #logged, 0)
end)

t.test("Log Mode: Print / Log / Print and Log", function()
	local l1, p1, g1 = make("Print", 5)
	l1:log(dbg.INFO, "x")
	t.eq(#p1, 1); t.eq(#g1, 0)
	local l2, p2, g2 = make("Log", 5)
	l2:log(dbg.INFO, "x")
	t.eq(#p2, 0); t.eq(#g2, 1)
	local l3, p3, g3 = make("Print and Log", 5)
	l3:log(dbg.INFO, "x")
	t.eq(#p3, 1); t.eq(#g3, 1)
end)

t.test("Log Mode sconosciuto => Off", function()
	local logger, printed, logged = make("Boh", 5)
	logger:log(dbg.ALERT, "x")
	t.eq(#printed + #logged, 0)
end)

t.test("formato riga: prefisso, severita', testo formattato", function()
	local logger, printed = make("Print", 5)
	logger:log(dbg.INFO, "[TICK] tick #%d", 7)
	t.eq(printed[1], "T [INFO] [TICK] tick #7")
end)

t.test("format error non solleva eccezioni", function()
	local logger, printed = make("Print", 5)
	logger:log(dbg.INFO, "valore %d", "non numerico")
	t.eq(#printed, 1)
end)

t.test("formattazione saltata se il messaggio e' filtrato", function()
	local logger = make("Print", 0)
	local called = false
	local bomb = setmetatable({}, { __tostring = function() called = true; return "x" end })
	logger:log(dbg.DEBUG, "%s", bomb)
	t.eq(called, false)
end)

t.finish()
