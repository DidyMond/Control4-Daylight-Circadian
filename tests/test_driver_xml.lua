-- Test del manifest drivers/controller/driver.xml: default non collidenti, tooltip, script non cifrato
local t = require "tests.support.harness"
local schedule = require "libs.schedule"
local sun = require "libs.sun"
local refs = require "tests.fixtures.sun_reference"

local f = assert(io.open("drivers/controller/driver.xml", "rb"))
local xml = f:read("*a")
f:close()

-- name -> { default = "...", tooltip = "..." } leggendo i blocchi <property>
local props = {}
for block in xml:gmatch("<property>(.-)</property>") do
	local name = block:match("<name>(.-)</name>")
	if name then
		props[name] = { default = block:match("<default>(.-)</default>"), tooltip = block:match("<tooltip>(.-)</tooltip>") }
	end
end

local function get(name) return props[name] and props[name].default end

t.test("default richiesti: 4 SP astronomici (Midnight 10/2600, Sunrise 70/4000, Noon 100/5500, Sunset 40/3000), offset 0", function()
	t.eq(get("Number of Switchpoints"), "4")
	local expected = {
		{ "Solar Midnight", "10", "2600" }, { "Sunrise", "70", "4000" },
		{ "Solar Noon", "100", "5500" }, { "Sunset", "40", "3000" },
	}
	for n, e in ipairs(expected) do
		t.eq(get("SP " .. n .. " Type"), "Astronomical", "SP " .. n .. " Type")
		t.eq(get("SP " .. n .. " Astronomical Reference"), e[1], "SP " .. n .. " Ref")
		t.eq(get("SP " .. n .. " Brightness"), e[2], "SP " .. n .. " Brightness")
		t.eq(get("SP " .. n .. " Colour Temperature"), e[3], "SP " .. n .. " CCT")
		t.eq(get("SP " .. n .. " Offset (mins)"), "0", "SP " .. n .. " Offset")
	end
end)

t.test("i default non producono coincidenze (4 e 10 SP) in 8 localita'/date di riferimento", function()
	for _, count in ipairs({ 3, 4, 10 }) do
		local cfg, config_warnings = schedule.read_config(function(name)
			if name == "Number of Switchpoints" then return tostring(count) end
			return get(name)
		end)
		t.eq(#config_warnings, 0)
		for _, ref in ipairs(refs) do
			local d = ref.date
			local astro = assert(sun.calculate(ref.lat, ref.lon, d[1], d[2], d[3], ref.tz))
			local entries, warnings = schedule.resolve(cfg, astro)
			t.eq(#warnings, 0, ref.name .. " (" .. count .. " SP): " .. tostring(warnings[1]))
			t.eq(#schedule.points(entries), count, ref.name)
		end
	end
end)

t.test("tooltip su SP n Type/Time/Astronomical Reference/Offset e su Number of Switchpoints", function()
	for n = 1, 10 do
		t.truthy(props["SP " .. n .. " Type"].tooltip:find("Time field is ignored", 1, true), "Type " .. n)
		t.truthy(props["SP " .. n .. " Time"].tooltip:find("Used only when Type = Set Time", 1, true), "Time " .. n)
		t.truthy(props["SP " .. n .. " Astronomical Reference"].tooltip:find("Used only when Type = Astronomical", 1, true))
		t.truthy(props["SP " .. n .. " Offset (mins)"].tooltip:find("Used only when Type = Astronomical", 1, true))
	end
	t.truthy(props["Number of Switchpoints"].tooltip:find("Minimum 3", 1, true))
end)

t.test("Lua non cifrato: encryption=\"0\" esplicito nel tag script", function()
	t.truthy(xml:find('<script file="driver.lua" encryption="0"', 1, true))
end)

t.test("proprieta' di log e azioni attese nel manifest", function()
	t.eq(get("Log Mode"), "Off")
	t.eq(get("Log Level"), "3 - Info")
	for _, cmd in ipairs({ "PAUSE_SCHEDULE", "RESUME_SCHEDULE", "PREVIEW_SCHEDULE", "STOP_PREVIEW",
		"FOLLOW_ALL_LIGHTS", "DISPLAY_SCHEDULE", "SHOW_ASTRONOMICAL_DATA", "RECALCULATE_ASTRONOMICAL_DATA", "COPY_SCHEDULE" }) do
		t.truthy(xml:find("<command>" .. cmd .. "</command>", 1, true), cmd)
	end
end)

t.test("versione: in ogni driver.xml il default di 'Driver Version' coincide con <version>", function()
	for _, path in ipairs({ "drivers/controller/driver.xml", "drivers/webview/driver.xml" }) do
		local fh = assert(io.open(path, "rb"))
		local text = fh:read("*a")
		fh:close()
		local version = text:match("<version>(%d+)</version>")
		local default = text:match("<name>Driver Version</name>%s*<type>STRING</type>%s*<default>(%d+)</default>")
		t.truthy(version and default, path)
		t.eq(default, version, path .. ": default di Driver Version")
	end
end)

t.finish()
