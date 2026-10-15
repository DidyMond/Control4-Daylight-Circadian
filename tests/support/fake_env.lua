-- ============================================================
-- tests/support/fake_env.lua - ambiente finto per libs/engine.lua
--
-- Simula orologio, timer, proprieta', persistenza e luci Light V2 senza C4.
-- Il tempo avanza solo con fake:advance(secondi), che esegue i timer scaduti
-- nell'ordine corretto. L'orologio "locale" e' UTC + offset fisso (default 2,
-- Milano d'estate) calcolato su un epoch fisso, indipendente dal PC.
-- ============================================================

local debug_lib = require "libs.debug"

local F = {}

F.EPOCH_2026_06_21_12 = 1782043200 -- 2026-06-21 12:00:00 UTC

-- Capabilities XML (come nella documentazione ufficiale, con tag non chiusi bene)
F.CAPS_CCT = [[<DynamicCapabilities><supports_target>True</supports_target>
<supports_color>False</supports_color>
<supports_color_correlated_temperature>True<supports_color_correlated_temperature>
<color_correlated_temperature_min>2000<color_correlated_temperature_min>
<color_correlated_temperature_max>6500</color_correlated_temperature_max>
<color_rate_behavior>2</color_rate_behavior><color_rate_min>0</color_rate_min>
<color_rate_max>0</color_rate_max><color_trace_tolerance>0.006</color_trace_tolerance>
</DynamicCapabilities>]]
-- lampada con minimo CCT 2700 K (come la lampada reale) e con massimo 4000 K
F.CAPS_MIN_2700 = F.CAPS_CCT:gsub("min>2000<", "min>2700<")
F.CAPS_MAX_4000 = F.CAPS_CCT:gsub("max>6500<", "max>4000<")
-- lampada con rate colore limitata a 200..2000 ms
F.CAPS_COLOR_RATE = F.CAPS_CCT:gsub("<color_rate_min>0<", "<color_rate_min>200<"):gsub("<color_rate_max>0<", "<color_rate_max>2000<")
-- lampada con rate colore non modificabile (behavior 0)
F.CAPS_FIXED_COLOR_RATE = F.CAPS_CCT:gsub("<color_rate_behavior>2<", "<color_rate_behavior>0<")
F.CAPS_LEGACY = [[<DynamicCapabilities><supports_target>False</supports_target>
<supports_color_correlated_temperature>False<supports_color_correlated_temperature>
</DynamicCapabilities>]]

-- Proprieta' di default del controller (come driver.xml), localizzate a Milano
local function default_props()
	local p = {
		["Smart Light Level Monitoring"] = "On",
		["Follow Lights when Schedule Resumed"] = "Yes",
		["Fade Time (s) to Re-align with Schedule"] = "5",
		["Debounce Time (s) on level changed"] = "1",
		["Scheduler Mode"] = "Brightness + Colour Temperature",
		["Update Interval (s)"] = "60",
		["Number of Switchpoints"] = "4",
		["Minimum Colour Temperature"] = "2200",
		["Maximum Colour Temperature"] = "6500",
		["Controlled Devices"] = "",
	}
	-- 4 SP a orario fisso: 06:00 10%/2700K, 12:00 80%/5200K, 18:00 60%/3200K, 22:00 5%/2200K
	local sps = {
		{ "06:00", 10, 2700 }, { "12:00", 80, 5200 }, { "18:00", 60, 3200 }, { "22:00", 5, 2200 },
	}
	for n = 1, 10 do
		local sp = sps[n] or { "00:00", 0, 3000 }
		p["SP " .. n .. " Type"] = "Set Time"
		p["SP " .. n .. " Time"] = sp[1]
		p["SP " .. n .. " Astronomical Reference"] = "Sunrise"
		p["SP " .. n .. " Offset (mins)"] = "0"
		p["SP " .. n .. " Brightness"] = tostring(sp[2])
		p["SP " .. n .. " Colour Temperature"] = tostring(sp[3])
	end
	return p
end

-- new(opts): opts.props (sovrascrive), opts.store (persistenza condivisa),
-- opts.epoch, opts.utc_offset, opts.latlon ({lat, lon} | false), opts.device_id
function F.new(opts)
	opts = opts or {}
	local fake = {
		props = default_props(),
		store = opts.store or {},
		epoch = opts.epoch or F.EPOCH_2026_06_21_12,
		offset = opts.utc_offset or 2,
		latlon = (opts.latlon == nil) and { 45.4642, 9.1900 } or opts.latlon,
		device_id = opts.device_id or 900,
		elapsed = 0,        -- secondi simulati dall'avvio
		timers = {},
		sent = {},          -- { {id, command, params, t} }
		logs = {},          -- { {sev, text} }
		events = {},        -- eventi sparsi
		variables = {},     -- variabili del controller
		updated = {},       -- proprieta' aggiornate dall'engine
		watched = {},       -- "id:var"
		device_events = {}, -- "id:event"
		webview = {},       -- messaggi JSON inviati alla webview
		caps = {},          -- id -> xml
	}
	for k, v in pairs(opts.props or {}) do fake.props[k] = v end

	local env = {}
	fake.env = env

	function env.log(sev, text) fake.logs[#fake.logs + 1] = { sev = sev, text = text } end
	function env.now() return fake.elapsed end
	function env.clock()
		local t = os.date("!*t", fake.epoch + fake.elapsed + fake.offset * 3600)
		return { year = t.year, month = t.month, day = t.day, hour = t.hour, min = t.min, sec = t.sec }
	end
	function env.utc_offset() return fake.offset end
	function env.prop(name) return fake.props[name] end
	function env.update_property(name, value)
		fake.props[name] = value
		fake.updated[name] = value
	end
	function env.project_latlon()
		if not fake.latlon then return nil end
		return fake.latlon[1], fake.latlon[2]
	end
	function env.persist_get(key)
		local v = fake.store[key]
		return v
	end
	function env.persist_set(key, value) fake.store[key] = value end
	function env.set_timer(ms, fn, repeating)
		local timer = { due = fake.elapsed + ms / 1000, ms = ms, fn = fn, repeating = repeating, active = true }
		function timer:cancel() self.active = false end
		fake.timers[#fake.timers + 1] = timer
		return timer
	end
	function env.send_to_device(id, command, params)
		fake.sent[#fake.sent + 1] = { id = id, command = command, params = params, t = fake.elapsed }
	end
	function env.get_device_variable(id, var_id)
		if var_id == 6661 then return fake.caps[id] or F.CAPS_CCT end
		return fake.var_values and fake.var_values[id .. ":" .. var_id] or nil
	end
	function env.watch_variable(id, var_id) fake.watched[id .. ":" .. var_id] = true end
	function env.unwatch_variable(id, var_id) fake.watched[id .. ":" .. var_id] = nil end
	function env.watch_device_event(id, ev) fake.device_events[id .. ":" .. ev] = true end
	function env.device_info(id) return { display_name = "Lampada " .. id, manufacturer = "Fake", model = "CCT" } end
	function env.fire_event(name) fake.events[#fake.events + 1] = name end
	function env.add_variable(name, value) fake.variables[name] = value end
	function env.set_variable(name, value) fake.variables[name] = value end
	function env.device_id() return fake.device_id end
	function env.device_name() return "Controller " .. fake.device_id end
	function env.send_to_webview(text) fake.webview[#fake.webview + 1] = text end

	-- avanza il tempo eseguendo i timer scaduti in ordine
	function fake:advance(seconds)
		local target = self.elapsed + seconds
		while true do
			local next_timer
			for _, t in ipairs(self.timers) do
				if t.active and t.due <= target + 1e-9 and (not next_timer or t.due < next_timer.due) then
					next_timer = t
				end
			end
			if not next_timer then break end
			self.elapsed = math.max(self.elapsed, next_timer.due)
			if next_timer.repeating then
				next_timer.due = next_timer.due + next_timer.ms / 1000
			else
				next_timer.active = false
			end
			next_timer.fn()
		end
		self.elapsed = target
	end

	-- helper di ispezione
	function fake:clear_sent() self.sent = {} end
	function fake:sent_to(id, command)
		local out = {}
		for _, s in ipairs(self.sent) do
			if s.id == id and (not command or s.command == command) then out[#out + 1] = s end
		end
		return out
	end
	function fake:has_log(sev, pattern)
		for _, l in ipairs(self.logs) do
			if (sev == nil or l.sev == sev) and l.text:find(pattern, 1, true) then return true end
		end
		return false
	end
	function fake:count_events(name)
		local n = 0
		for _, e in ipairs(self.events) do if e == name then n = n + 1 end end
		return n
	end
	function fake:active_timers()
		local n = 0
		for _, t in ipairs(self.timers) do if t.active then n = n + 1 end end
		return n
	end

	return fake
end

F.dbg = debug_lib

return F
