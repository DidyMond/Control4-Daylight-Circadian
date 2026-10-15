-- Test di libs/state_machine.lua: transizioni valide, vietate, restore
local t = require "tests.support.harness"
local sm = require "libs.state_machine"

local function machine(state) return sm.new(state) end

t.test("stato iniziale IDLE", function()
	t.eq(machine().state, "IDLE")
	t.eq(machine("boh").state, "IDLE")
end)

t.test("transizioni valide", function()
	local cases = {
		{ "IDLE", "START", "ACTIVE" },
		{ "ACTIVE", "PAUSE", "PAUSED" },
		{ "PAUSED", "RESUME", "ACTIVE" },
		{ "ACTIVE", "PREVIEW_START", "PREVIEW" },
		{ "PREVIEW", "PREVIEW_STOP", "ACTIVE" },
		{ "ACTIVE", "STOP", "IDLE" },
		{ "PAUSED", "STOP", "IDLE" },
		{ "PREVIEW", "STOP", "IDLE" },
	}
	for _, c in ipairs(cases) do
		local m = machine(c[1])
		local ok, new = m:request(c[2])
		t.truthy(ok, c[1] .. " + " .. c[2])
		t.eq(new, c[3], c[1] .. " + " .. c[2])
		t.eq(m.state, c[3])
	end
end)

t.test("VIETATA: PAUSE durante PREVIEW (bug Janus v207), stato invariato, motivo esplicito", function()
	local m = machine("PREVIEW")
	local ok, reason = m:request("PAUSE")
	t.eq(ok, false)
	t.truthy(reason:find("stop the preview first", 1, true), reason)
	t.eq(m.state, "PREVIEW")
end)

t.test("VIETATA: PREVIEW_START da PAUSED, stato invariato, motivo esplicito", function()
	local m = machine("PAUSED")
	local ok, reason = m:request("PREVIEW_START")
	t.eq(ok, false)
	t.truthy(reason:find("resume the schedule first", 1, true), reason)
	t.eq(m.state, "PAUSED")
end)

t.test("altre transizioni non previste rifiutate senza cambiare stato", function()
	local cases = {
		{ "IDLE", "PAUSE" }, { "IDLE", "RESUME" }, { "IDLE", "PREVIEW_START" }, { "IDLE", "PREVIEW_STOP" },
		{ "ACTIVE", "START" }, { "ACTIVE", "RESUME" }, { "ACTIVE", "PREVIEW_STOP" },
		{ "PAUSED", "PAUSE" }, { "PAUSED", "START" }, { "PAUSED", "PREVIEW_STOP" },
		{ "PREVIEW", "START" }, { "PREVIEW", "RESUME" }, { "PREVIEW", "PREVIEW_START" },
		{ "ACTIVE", "BOH" },
	}
	for _, c in ipairs(cases) do
		local m = machine(c[1])
		local ok, reason = m:request(c[2])
		t.eq(ok, false, c[1] .. " + " .. c[2])
		t.truthy(type(reason) == "string" and #reason > 0)
		t.eq(m.state, c[1])
	end
end)

t.test("ciclo completo: START, PAUSE, RESUME, PREVIEW_START, PREVIEW_STOP", function()
	local m = machine()
	for _, e in ipairs({ "START", "PAUSE", "RESUME", "PREVIEW_START", "PREVIEW_STOP" }) do
		t.truthy(m:request(e), e)
	end
	t.eq(m.state, "ACTIVE")
end)

t.test("restore: ACTIVE e PAUSED si conservano, PREVIEW/IDLE/sconosciuto => IDLE", function()
	local m = machine()
	t.eq(m:restore("ACTIVE"), "ACTIVE")
	t.eq(m:restore("PAUSED"), "PAUSED")
	t.eq(m:restore("PREVIEW"), "IDLE")
	t.eq(m:restore("IDLE"), "IDLE")
	t.eq(m:restore(nil), "IDLE")
	t.eq(m:restore(42), "IDLE")
end)

t.test("SCHEDULE_ACTIVE: vero se non PAUSED e non IDLE; PREVIEW_ACTIVE", function()
	t.eq(sm.schedule_active("IDLE"), false)
	t.eq(sm.schedule_active("ACTIVE"), true)
	t.eq(sm.schedule_active("PAUSED"), false)
	t.eq(sm.schedule_active("PREVIEW"), true)
	t.eq(sm.preview_active("PREVIEW"), true)
	t.eq(sm.preview_active("ACTIVE"), false)
end)

t.finish()
