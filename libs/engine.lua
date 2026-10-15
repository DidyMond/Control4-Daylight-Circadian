-- ============================================================
-- libs/engine.lua - nucleo del controller
--
-- Lua 5.1 puro, nessun riferimento a C4: tutto cio' che tocca Control4 arriva
-- dal driver tramite la tabella `env`, cosi' il nucleo si testa offline con un
-- ambiente finto (tests/test_engine.lua). driver.lua e' solo l'adattatore.
--
-- Contratto di `env` (tutte funzioni):
--   env.log(severity, text)
--   env.now()                      -> secondi (float, monotono per i debounce)
--   env.clock()                    -> { year, month, day, hour, min, sec } locale
--   env.utc_offset(y, m, d)        -> ore (clock.utc_offset_hours_for_date)
--   env.prop(name)                 -> valore stringa della proprieta' | nil
--   env.update_property(name, value)
--   env.project_latlon()           -> lat, lon (numeri) | nil
--   env.persist_get(key) / env.persist_set(key, value)
--   env.set_timer(ms, fn, repeat)  -> oggetto con metodo :cancel()
--   env.send_to_device(id, command, params)
--   env.get_device_variable(id, var_id) -> stringa | nil
--   env.watch_variable(id, var_id) / env.unwatch_variable(id, var_id)
--   env.watch_device_event(id, event_id)
--   env.device_info(id)            -> tabella nome/manufacturer/... (opzionale, solo per il log)
--   env.device_name()              -> nome di questo controller in Composer (opzionale)
--   env.send_to_webview(text)      -> invia un messaggio JSON alla webview sul binding
--                                     DAYLIGHT_CIRCADIAN_COMMS (opzionale: senza, niente push)
--   env.fire_event(name)
--   env.add_variable(name, value, type) / env.set_variable(name, value)
--   env.device_id()                -> id di questo controller
-- ============================================================

local dbg = require "libs.debug"
local sun = require "libs.sun"
local curve = require "libs.curve"
local schedule = require "libs.schedule"
local monitor = require "libs.monitor"
local light_cmd = require "libs.light_cmd"
local state_machine = require "libs.state_machine"
local persist = require "libs.persist"
local protocol = require "libs.protocol"

local M = {}

local SM = state_machine

M.PREVIEW_DURATION_S = 120
M.PREVIEW_STEPS = 100
M.PREVIEW_RATE_MS = 1000

-- Proprieta' copiabili con COPY_SCHEDULE (nome -> chiave sicura per i parametri)
local COPY_SUFFIXES = { "Type", "Time", "Astronomical Reference", "Offset (mins)", "Brightness", "Colour Temperature" }

local function safe_key(name)
	return (name:gsub("[^%w]", "_"))
end

local function copy_properties()
	local names = { "Scheduler Mode", "Number of Switchpoints", "Minimum Colour Temperature",
		"Maximum Colour Temperature" }
	for n = 1, schedule.MAX_SP do
		for _, suffix in ipairs(COPY_SUFFIXES) do
			names[#names + 1] = "SP " .. n .. " " .. suffix
		end
	end
	return names
end

local COMMAND_ALIASES = {
	PAUSE_SCHEDULE = "pause",
	RESUME_SCHEDULE = "resume",
	START_PREVIEW = "start_preview",
	PREVIEW_SCHEDULE = "start_preview",
	STOP_PREVIEW = "stop_preview",
	FOLLOW_ALL_LIGHTS = "follow",
	FOLLOW_LIGHTS = "follow",
	DISPLAY_SCHEDULE = "display",
	DISPLAY_STORED_SCHEDULE = "display",
	SHOW_ASTRONOMICAL_DATA = "show_astro",
	RECALCULATE_ASTRONOMICAL_DATA = "recalc_astro",
	RETRIEVE_ASTRONOMICAL_DATA = "recalc_astro",
	COPY_SCHEDULE = "copy",
	RECEIVE_SCHEDULE = "receive",
}

-- "Pause Schedule" / "PAUSE_SCHEDULE" -> "PAUSE_SCHEDULE"
function M.normalize_command(name)
	if type(name) ~= "string" then return "" end
	return (name:upper():gsub("[^%w]+", "_"))
end

-- {B=2, A=1} -> "A=1 B=2" (ordinato, per i log)
function M.format_params(params)
	local keys = {}
	for k in pairs(params or {}) do keys[#keys + 1] = tostring(k) end
	table.sort(keys)
	local parts = {}
	for _, k in ipairs(keys) do parts[#parts + 1] = k .. "=" .. tostring(params[k]) end
	return table.concat(parts, " ")
end

local Engine = {}
Engine.__index = Engine

local function clamp(v, lo, hi)
	if v < lo then return lo end
	if v > hi then return hi end
	return v
end

function M.new(env)
	local self = setmetatable({}, Engine)
	self.env = env
	self.sm = SM.new()
	self.mon = monitor.new()
	self.store = persist.new({ get = env.persist_get, set = env.persist_set })
	self.light_ids = {}
	self.caps = {}
	self.cfg = nil
	self.points = nil
	self.prepared = nil
	self.astro = nil
	self.tick_timer = nil
	self.midnight_timer = nil
	self.preview = nil
	self.probes = {}
	self.timers = {} -- timer one-shot attivi (debounce, batch): per cancellarli
	self.last_push = nil -- ultimo STATE inviato alla webview (evita push identici)
	return self
end

-- ------------------------------------------------------------
-- utilita'
-- ------------------------------------------------------------
function Engine:log(severity, fmt, ...)
	local text = fmt
	if select("#", ...) > 0 then
		local ok, res = pcall(string.format, fmt, ...)
		text = ok and res or (tostring(fmt) .. " (format error)")
	end
	self.env.log(severity, text)
end

function Engine:num_prop(name, default, lo, hi)
	local v = schedule.parse_number(self.env.prop(name))
	if v == nil then return default end
	return clamp(v, lo, hi)
end

function Engine:fade_ms() return self:num_prop("Fade Time (s) to Re-align with Schedule", 5, 1, 10) * 1000 end
function Engine:debounce_s() return self:num_prop("Debounce Time (s) on level changed", 1, 0, 30) end
function Engine:interval_s() return math.floor(self:num_prop("Update Interval (s)", 60, 10, 600)) end
function Engine:monitoring_on() return self.env.prop("Smart Light Level Monitoring") ~= "Off" end
function Engine:preset_off_on() return self.env.prop("Preset Colour While Lights Are Off") == "On" end

function Engine:minute_now()
	local c = self.env.clock()
	return c.hour * 60 + c.min + c.sec / 60
end

function Engine:after(ms, fn)
	local handle
	handle = self.env.set_timer(ms, function()
		if handle then self.timers[handle] = nil end
		fn()
	end, false)
	self.timers[handle] = true
	return handle
end

function Engine:state() return self.sm.state end

-- ------------------------------------------------------------
-- stato, variabili, persistenza
-- ------------------------------------------------------------
local MODE_TEXT = { IDLE = "Idle", ACTIVE = "Active", PAUSED = "Paused" }

function Engine:publish_state()
	local st = self.sm.state
	local text = MODE_TEXT[st]
	if st == SM.PREVIEW then
		text = "Preview: " .. schedule.format_time((self.preview and self.preview.minute) or 0)
	end
	self.env.update_property("Operational Mode", text)
	self.env.set_variable("SCHEDULE_ACTIVE", SM.schedule_active(st) and "1" or "0")
	self.env.set_variable("PREVIEW_ACTIVE", SM.preview_active(st) and "1" or "0")
	self.store.set(persist.KEY_STATE, st)
end

function Engine:transition(event)
	local before = self.sm.state
	local ok, result = self.sm:request(event)
	if not ok then
		self:log(dbg.WARNING, "[STATE] %s rifiutato da %s: %s", event, before, tostring(result))
		return false
	end
	self:log(dbg.INFO, "[STATE] %s -> %s (%s)", before, result, event)
	self:publish_state()
	self:push_state()
	return true
end

function Engine:save_overrides()
	self.store.set(persist.KEY_OVERRIDDEN, self.mon:export_overridden())
	self:push_state()
end

function Engine:test_condition(name)
	local st = self.sm.state
	if name == "SCHEDULE_ACTIVE" then return SM.schedule_active(st) end
	if name == "SCHEDULE_INACTIVE" then return not SM.schedule_active(st) end
	if name == "PREVIEW_ACTIVE" then return SM.preview_active(st) end
	if name == "PREVIEW_INACTIVE" then return not SM.preview_active(st) end
	return false
end

-- ------------------------------------------------------------
-- dati astronomici e curva
-- ------------------------------------------------------------
local function date_string(c)
	return string.format("%04d-%02d-%02d", c.year, c.month, c.day)
end

-- ensure_astro(force) -> true se i dati astronomici di oggi sono disponibili
function Engine:ensure_astro(force)
	local env = self.env
	local c = env.clock()
	local today = date_string(c)
	if not force then
		if self.astro and self.astro.date == today then return true end
		local saved = self.store.get(persist.KEY_ASTRO)
		if type(saved) == "table" and saved.date == today then
			self.astro = saved
			self:log(dbg.INFO, "[ASTRO] dati di oggi ripristinati da persistenza (%s)", today)
			self:rebuild_curve()
			return true
		end
	end

	local lat, lon = env.project_latlon()
	if not lat or not lon then
		self:log(dbg.ERROR, "[ASTRO] latitudine/longitudine del progetto mancanti: impossibile calcolare gli orari astronomici")
		return false
	end
	local offset = env.utc_offset(c.year, c.month, c.day)
	local r, err = sun.calculate(lat, lon, c.year, c.month, c.day, offset)
	if not r then
		self:log(dbg.ERROR, "[ASTRO] calcolo fallito: %s", tostring(err))
		return false
	end
	self.astro = {
		date = today, offset = offset, lat = lat, lon = lon,
		sunrise = r.sunrise, solar_noon = r.solar_noon, sunset = r.sunset,
		solar_midnight = r.solar_midnight, polar = r.polar,
	}
	self.store.set(persist.KEY_ASTRO, self.astro)
	self:log(dbg.INFO, "[ASTRO] %s lat=%.4f lon=%.4f UTC%+g: alba %s, mezzogiorno %s, tramonto %s, mezzanotte %s",
		today, lat, lon, offset, sun.format_minutes(r.sunrise), sun.format_minutes(r.solar_noon),
		sun.format_minutes(r.sunset), sun.format_minutes(r.solar_midnight))
	self:rebuild_curve()
	return true
end

function Engine:rebuild_curve()
	local cfg, warnings = schedule.read_config(self.env.prop)
	local entries, w2 = schedule.resolve(cfg, self.astro)
	local points = schedule.points(entries)
	for _, w in ipairs(warnings) do self:log(dbg.WARNING, "[SCHEDULE] %s", w) end
	for _, w in ipairs(w2) do self:log(dbg.WARNING, "[SCHEDULE] %s", w) end
	-- schedule risolta, verificabile da Composer senza webview
	self:log(dbg.INFO, "[SCHEDULE] %s", schedule.summary(entries))
	self.cfg, self.points = cfg, points
	local prepared, err = curve.prepare(points)
	self.prepared = prepared
	if not prepared then
		self:log(dbg.ERROR, "[SCHEDULE] curva non valida: %s", tostring(err))
		self:push_state()
		return false
	end
	self.store.set(persist.KEY_SCHEDULE, cfg)
	self:push_state() -- la UI si aggiorna senza refresh (modifica da Composer, webview o mezzanotte)
	return true
end

function Engine:target_at(minute)
	if not self.prepared then return nil end
	return schedule.target(self.prepared, self.cfg, minute)
end

-- ------------------------------------------------------------
-- luci
-- ------------------------------------------------------------
function Engine:setup_lights()
	local env = self.env
	local wanted = light_cmd.parse_device_list(env.prop("Controlled Devices"))
	local want = {}
	for _, id in ipairs(wanted) do want[id] = true end

	for id in pairs(self.mon.lights) do
		if not want[id] then
			env.unwatch_variable(id, light_cmd.VAR_LIGHT_STATE)
			env.unwatch_variable(id, light_cmd.VAR_BRIGHTNESS_PERCENT)
			self.mon:remove(id)
			self.caps[id] = nil
			self:log(dbg.INFO, "[LIGHTS] luce %d rimossa", id)
		end
	end

	for _, id in ipairs(wanted) do
		if not self.mon:get(id) then
			self.mon:add(id)
			local ok, xml = pcall(env.get_device_variable, id, light_cmd.VAR_DYNAMIC_CAPABILITIES)
			-- dump COMPLETO: serve a capire che tipo di driver colore e' (nativo OS 3.3+, legacy, terze parti)
			if ok and type(xml) == "string" then
				self:log(dbg.INFO, "[LIGHTS] luce %d capabilities (tag): %s", id, light_cmd.dump_tags(xml))
				self:log(dbg.INFO, "[LIGHTS] luce %d capabilities (XML): %s", id, light_cmd.compact_xml(xml))
			end
			if env.device_info then
				local iok, info = pcall(env.device_info, id)
				if iok and type(info) == "table" then
					local keys = {}
					for k in pairs(info) do keys[#keys + 1] = k end
					table.sort(keys)
					local parts = {}
					for _, k in ipairs(keys) do parts[#parts + 1] = k .. "=" .. tostring(info[k]) end
					self:log(dbg.INFO, "[LIGHTS] luce %d driver: %s", id, table.concat(parts, " "))
				end
			end
			if not self.color_doc_logged then
				self.color_doc_logged = true
				for _, line in ipairs(light_cmd.COLOR_TARGET_DOC) do self:log(dbg.INFO, "[COLORDOC] %s", line) end
			end
			local caps = ok and light_cmd.parse_caps(xml) or nil
			if not caps then
				self:log(dbg.WARNING, "[LIGHTS] luce %d: capabilities non leggibili, assumo supports_target e CCT", id)
				caps = {}
			end
			if caps.supports_cct == false then
				self:log(dbg.WARNING, "[LIGHTS] luce %d: non supporta la CCT, solo brightness", id)
			end
			self.caps[id] = caps
			self:log(dbg.INFO, "[LIGHTS] luce %d aggiunta (target=%s color=%s cct=%s %s-%s K, color_rate behavior=%s %s-%s ms)", id,
				tostring(caps.supports_target), tostring(caps.supports_color), tostring(caps.supports_cct),
				tostring(caps.cct_min), tostring(caps.cct_max),
				tostring(caps.color_rate_behavior), tostring(caps.color_rate_min), tostring(caps.color_rate_max))
			env.watch_variable(id, light_cmd.VAR_LIGHT_STATE)
			env.watch_variable(id, light_cmd.VAR_BRIGHTNESS_PERCENT)
			-- sonda: quali eventi arrivano davvero? (vedi on_device_event)
			for _, ev in ipairs(light_cmd.PROBE_EVENTS) do
				env.watch_device_event(id, ev)
			end
			self:seed_level(id)
		end
	end
	self.light_ids = wanted
	self:push_state()
	self:log(dbg.INFO, "[LIGHTS] %d luci controllate", #wanted)
end

-- Livello iniziale della luce: OnWatchedVariableChanged arriva solo sui CAMBI, quindi senza lettura
-- diretta una luce spenta all'avvio resta "sconosciuta" e la sua prima accensione sarebbe un
-- "init" (niente riallineamento forzato, niente reinvio del colore) invece di "turned_on".
function Engine:seed_level(id)
	local env = self.env
	local oks, state = pcall(env.get_device_variable, id, light_cmd.VAR_LIGHT_STATE)
	local okb, pct = pcall(env.get_device_variable, id, light_cmd.VAR_BRIGHTNESS_PERCENT)
	local level = okb and tonumber(pct) or nil
	if oks and state ~= nil then
		local v = tostring(state):lower()
		if v == "0" or v == "false" then level = 0 end
	end
	if level == nil then
		self:log(dbg.INFO, "[LIGHTS] luce %d livello iniziale non leggibile: lo imparo dal primo evento", id)
		return
	end
	level = clamp(level, 0, 100)
	self.mon:on_level(id, level, env.now(), {})
	self:log(dbg.INFO, "[LIGHTS] luce %d livello iniziale %d", id, level)
end

-- Invio a batch (staggered, Janus v115). items = { {id, cmds = { {command, params} }, brightness, cct} }
function Engine:dispatch(items, rate_ms)
	if #items == 0 then return end
	local env = self.env
	local function send(item)
		for _, c in ipairs(item.cmds) do
			if c[1] == "SET_COLOR_TARGET" then
				self:log(dbg.TRACE, "[SEND] luce %d SET_COLOR_TARGET %s (%s)", item.id,
					light_cmd.describe_color(c[2]), M.format_params(c[2]))
			else
				self:log(dbg.TRACE, "[SEND] luce %d %s %s", item.id, c[1], M.format_params(c[2]))
			end
			env.send_to_device(item.id, c[1], c[2])
		end
		self.mon:sent(item.id, item.brightness, item.cct, env.now(), rate_ms / 1000)
	end
	for _, b in ipairs(light_cmd.stagger(#items)) do
		local function run()
			for i = b.first, b.last do send(items[i]) end
		end
		if b.delay_ms == 0 then run() else self:after(b.delay_ms, run) end
	end
end

-- Dopo un'accensione esterna la lampada puo' riprendere il suo ultimo colore DOPO il nostro
-- comando (log T4: eventi Color Changing, Light On, Color Changing). La CCT reale non e'
-- leggibile (solo eventi senza valore) e la soglia di 25 K e' sull'ultimo valore INVIATO,
-- quindi senza un reinvio il colore sbagliato resterebbe fino a che la curva si sposta di 25 K.
local RECOLOUR_AFTER_ON_MS = { 3000, 8000 }

function Engine:recolour_after_on(id)
	-- col colore preimpostato a luce spenta la lampada si accende gia' al colore giusto (T4: verificato):
	-- i reinvii servono solo a chi tiene l'opzione su Off
	if self:preset_off_on() then return end
	self.on_seq = self.on_seq or {}
	local seq = (self.on_seq[id] or 0) + 1
	self.on_seq[id] = seq -- una nuova accensione annulla i reinvii della precedente
	for _, ms in ipairs(RECOLOUR_AFTER_ON_MS) do
		self:after(ms, function()
			if self.on_seq[id] ~= seq or self.sm.state ~= SM.ACTIVE then return end
			self:log(dbg.TRACE, "[MONITOR] luce %d: reinvio il colore dopo l'accensione (+%d ms)", id, ms)
			self:apply({ force_cct = true, only = { [id] = true } }) -- luce spenta nel frattempo: plan non invia nulla
		end)
	end
end

-- apply{ force, force_cct, rate_ms, minute, only = {id=true} }
function Engine:apply(opts)
	opts = opts or {}
	if not self.prepared then return end
	local minute = opts.minute or self:minute_now()
	local target = self:target_at(minute)
	local monitoring = self:monitoring_on()
	local preset_off = self:preset_off_on()
	local rate_ms = opts.rate_ms or self:fade_ms()
	local items = {}
	for _, id in ipairs(self.light_ids) do
		if not opts.only or opts.only[id] then
			local force = opts.force
			if monitoring and self.mon:check_realign(id, target.brightness) then
				self:log(dbg.INFO, "[MONITOR] luce %d riallineata alla schedule", id)
				self:save_overrides()
				force = true
			end
			local caps = self.caps[id] or {}
			local plan = self.mon:plan(id, target, {
				use_brightness = self.cfg.use_brightness, use_cct = self.cfg.use_cct,
				monitoring = monitoring, force = force, force_cct = opts.force_cct, supports_cct = caps.supports_cct,
				preset_off = preset_off,
				cct_min = caps.cct_min, cct_max = caps.cct_max, -- la soglia usa il valore post-clamp
			})
			local cmds = {}
			if plan.brightness then
				local command, params = light_cmd.brightness(caps, plan.brightness, rate_ms)
				cmds[#cmds + 1] = { command, params }
			end
			if plan.cct then
				-- plan.cct e' gia' nei limiti della lampada (clamp prima della soglia).
				-- Formato dell'app: MODE = 1 + kelvin (niente X/Y), rate nei limiti della lampada
				-- luce spenta: rate 0, il colore viene solo memorizzato per la prossima accensione
				if plan.off then
					self:log(dbg.TRACE, "[APPLY] luce %d spenta: preimposto il colore %d K", id, plan.cct)
				end
				local command, params = light_cmd.color_cct(plan.cct, plan.off and 0 or rate_ms, caps)
				cmds[#cmds + 1] = { command, params }
			end
			if #cmds > 0 then
				items[#items + 1] = { id = id, cmds = cmds, brightness = plan.brightness, cct = plan.cct }
			end
		end
	end
	self:log(dbg.TRACE, "[APPLY] %s brightness=%.1f cct=%d -> %d luci", schedule.format_time(minute),
		target.brightness, target.cct, #items)
	self:dispatch(items, rate_ms)
end

-- ------------------------------------------------------------
-- eventi dalle luci (variabili del proxy Light V2) e sonde
-- ------------------------------------------------------------
local function probe_seen(self, key)
	if self.probes[key] then return false end
	self.probes[key] = true
	return true
end

-- OnWatchedVariableChanged(id_device, id_variable, valore)
function Engine:on_level(id, var, value)
	if not self.mon:get(id) then return end
	if probe_seen(self, "var" .. var) then
		self:log(dbg.INFO, "[PROBE] OnWatchedVariableChanged arriva davvero (dev %d var %d = %s)", id, var, tostring(value))
	end
	local level
	if var == light_cmd.VAR_BRIGHTNESS_PERCENT then
		level = tonumber(value)
	elseif var == light_cmd.VAR_LIGHT_STATE then
		local v = tostring(value):lower()
		if v == "0" or v == "false" then level = 0 else return end -- il livello arriva dalla 1001
	else
		return
	end
	if level == nil then return end
	level = clamp(level, 0, 100)

	local active = (self.sm.state == SM.ACTIVE)
	local ev = self.mon:on_level(id, level, self.env.now(),
		{ monitoring = active and self:monitoring_on(), debounce_s = self:debounce_s() })
	self:log(dbg.TRACE, "[MONITOR] luce %d livello %d -> %s", id, level, ev)

	if ev == "turned_on" then
		self:log(dbg.INFO, "[MONITOR] luce %d accesa dall'esterno: riallineo alla schedule", id)
		self:save_overrides()
		self.on_t = self.on_t or {}
		self.on_t[id] = self.env.now() -- per i ms nei log degli eventi (diagnosi del colore all'accensione)
		if active then
			self:apply({ force = true, only = { [id] = true } })
			self:recolour_after_on(id)
		end
	elseif ev == "init" then
		-- primo livello noto (dopo avvio/restart): allinea subito senza aspettare il tick
		if active and level > 0 then self:apply({ only = { [id] = true } }) end
	elseif ev == "turned_off" then
		self:log(dbg.INFO, "[MONITOR] luce %d spenta", id)
	elseif ev == "external_pending" then
		local debounce_ms = self:debounce_s() * 1000
		if debounce_ms <= 0 then
			self:settle(id)
		else
			self:after(debounce_ms, function() self:settle(id) end)
		end
	end
end

function Engine:settle(id)
	local target = self:target_at(self:minute_now())
	if not target then return end
	local light = self.mon:get(id)
	local was_overridden = light and light.overridden
	local res = self.mon:settle(id, self.env.now(), target.brightness, self:debounce_s())
	if res == "overridden" then
		-- Info solo quando la luce ENTRA in override; ritocchi successivi (es. una rampa
		-- di dimmeraggio a passi) restano a Trace finche' non torna a seguire la schedule
		local severity = was_overridden and dbg.TRACE or dbg.INFO
		self:log(severity, "[MONITOR] luce %d modificata a mano: la schedule non comanda piu' la brightness", id)
		self:save_overrides()
	elseif res == "realigned" then
		self:log(dbg.INFO, "[MONITOR] luce %d: livello uguale al circadiano, riallineata", id)
		self:save_overrides()
		if self.sm.state == SM.ACTIVE then self:apply({ force = true, only = { [id] = true } }) end
	end
end

-- OnDeviceEvent(id_device, id_evento): sonda, il livello non viaggia negli eventi
function Engine:on_device_event(id, event_id)
	local key = "ev" .. event_id
	local name = light_cmd.event_name(event_id)
	local since = ""
	local t0 = self.on_t and self.on_t[id]
	if t0 and self.env.now() - t0 <= 15 then
		since = string.format(" (+%d ms dall'accensione)", math.floor((self.env.now() - t0) * 1000 + 0.5))
	end
	if probe_seen(self, key) then
		self:log(dbg.INFO, "[PROBE] OnDeviceEvent arriva davvero (dev %d evento %d %s)%s", id, event_id, name, since)
	else
		self:log(dbg.TRACE, "[PROBE] OnDeviceEvent dev %d evento %d %s%s", id, event_id, name, since)
	end
end

-- ------------------------------------------------------------
-- timer: tick, mezzanotte
-- ------------------------------------------------------------
function Engine:start_timers()
	if self.tick_timer then self.tick_timer:cancel() end
	local interval = self:interval_s()
	self.tick_timer = self.env.set_timer(interval * 1000, function() self:on_tick() end, true)
	self:log(dbg.INFO, "[TICK] timer avviato: ogni %d s", interval)
	self:schedule_midnight()
end

function Engine:schedule_midnight()
	if self.midnight_timer then self.midnight_timer:cancel() end
	local c = self.env.clock()
	local secs = c.hour * 3600 + c.min * 60 + c.sec
	local ms = (86400 - secs + 5) * 1000
	self.midnight_timer = self.env.set_timer(ms, function() self:on_midnight() end, false)
end

function Engine:on_midnight()
	self:log(dbg.INFO, "[ASTRO] mezzanotte: ricalcolo dati astronomici")
	self:ensure_astro(false)
	self:schedule_midnight()
	if self.sm.state == SM.IDLE then self:try_start() end
	if self.sm.state == SM.ACTIVE then self:apply({}) end
end

function Engine:on_tick()
	self:log(dbg.TRACE, "[TICK] tick")
	self:ensure_astro(false) -- rete di sicurezza se il timer di mezzanotte e' saltato
	if self.sm.state == SM.ACTIVE then self:apply({}) end
end

-- ------------------------------------------------------------
-- ciclo di vita
-- ------------------------------------------------------------
function Engine:init()
	self.env.add_variable("SCHEDULE_ACTIVE", "0", "BOOL")
	self.env.add_variable("PREVIEW_ACTIVE", "0", "BOOL")
end

function Engine:try_start()
	if not self.prepared then
		self:log(dbg.ERROR, "[STATE] avvio impossibile: schedule non valida, resto IDLE")
		return false
	end
	if not self.astro then
		self:log(dbg.ERROR, "[STATE] avvio impossibile: dati astronomici non disponibili (lat/long?), resto IDLE")
		return false
	end
	return self:transition("START")
end

function Engine:late_init()
	local saved = self.store.get(persist.KEY_STATE)
	self.sm:restore(saved)
	self:log(dbg.INFO, "[STATE] stato ripristinato: %s (salvato: %s)", self.sm.state, tostring(saved))

	self:setup_lights()
	self.mon:import_overridden(self.store.get(persist.KEY_OVERRIDDEN))
	for _, id in ipairs(self.light_ids) do
		if self.mon:get(id) and self.mon:get(id).overridden then
			self:log(dbg.INFO, "[MONITOR] luce %d: override ripristinato da persistenza (Follow All Lights lo azzera)", id)
		end
	end
	self:ensure_astro(false)          -- ricostruisce la curva se ha dati
	if not self.cfg then self:rebuild_curve() end -- senza lat/long: solo SP a orario fisso

	if self.sm.state == SM.IDLE then
		self:try_start()
	elseif not (self.prepared and self.astro) then
		self:log(dbg.ERROR, "[STATE] impossibile riprendere %s senza schedule/dati astronomici: IDLE", self.sm.state)
		self.sm:request("STOP")
	end
	self:publish_state()
	self:start_timers()
	if self.sm.state == SM.ACTIVE then self:apply({}) end
	self:hello()
end

function Engine:destroy()
	if self.tick_timer then self.tick_timer:cancel(); self.tick_timer = nil end
	if self.midnight_timer then self.midnight_timer:cancel(); self.midnight_timer = nil end
	if self.preview and self.preview.timer then self.preview.timer:cancel() end
	for handle in pairs(self.timers) do handle:cancel() end
	self.timers = {}
end

function Engine:on_property_changed(name)
	if name == "Controlled Devices" then
		self:setup_lights()
		if self.sm.state == SM.ACTIVE then self:apply({}) end
	elseif name == "Update Interval (s)" then
		if self.tick_timer then self:start_timers() end
	elseif name == "Scheduler Mode" or name == "Number of Switchpoints"
		or name == "Minimum Colour Temperature" or name == "Maximum Colour Temperature"
		or name:match("^SP %d+ ") then
		self:rebuild_curve()
		if self.sm.state == SM.IDLE then self:try_start() end
		if self.sm.state == SM.ACTIVE then self:apply({}) end
	end
end

-- ------------------------------------------------------------
-- webview (protocollo in libs/protocol.lua, binding DAYLIGHT_CIRCADIAN_COMMS)
-- ------------------------------------------------------------
function Engine:send_to_webview(msg)
	if not self.env.send_to_webview then return end
	local ok, text = pcall(protocol.encode, msg)
	if not ok then
		self:log(dbg.ERROR, "[COMMS] messaggio non serializzabile: %s", tostring(text))
		return
	end
	self:log(dbg.TRACE, "[COMMS] -> webview %s (%d byte)", tostring(msg.type), #text)
	self.env.send_to_webview(text)
end

-- STATE: schedule risolta, curva campionata (la STESSA monotone cubic del motore),
-- stato, luci. La webview non reimplementa nulla: disegna questi campioni.
function Engine:snapshot()
	local entries, warnings = {}, {}
	if self.cfg then entries, warnings = schedule.resolve(self.cfg, self.astro) end
	local samples
	if self.prepared and self.cfg then
		samples = self.prepared:samples(protocol.SAMPLE_STEP_MIN)
		for _, smp in ipairs(samples) do
			smp.cct = clamp(smp.cct, self.cfg.ct_min, self.cfg.ct_max) -- come il target reale
		end
	end
	local lights = {}
	for _, id in ipairs(self.light_ids) do
		local l = self.mon:get(id)
		lights[#lights + 1] = { id = id, level = l and l.level or nil, overridden = (l and l.overridden) and true or false }
	end
	return protocol.build_snapshot({
		id = self.env.device_id(),
		name = self.env.device_name and self.env.device_name() or nil,
		state = self.sm.state,
		preview = {
			active = (self.sm.state == SM.PREVIEW),
			minute = self.preview and self.preview.minute or nil,
			duration_s = M.PREVIEW_DURATION_S,
		},
		cfg = self.cfg, entries = entries, warnings = warnings, astro = self.astro,
		samples = samples, lights = lights, monitoring = self:monitoring_on(),
	})
end

-- push dello STATE alla webview; identico al precedente => niente invio
function Engine:push_state()
	if not self.env.send_to_webview then return end
	local ok, text = pcall(protocol.encode, self:snapshot())
	if not ok then
		self:log(dbg.ERROR, "[COMMS] snapshot non serializzabile: %s", tostring(text))
		return
	end
	if text == self.last_push then return end
	self.last_push = text
	self:log(dbg.TRACE, "[COMMS] -> webview STATE (%d byte)", #text)
	self.env.send_to_webview(text)
end

-- annuncio del controller (avvio, binding con la webview)
function Engine:hello()
	if not self.env.send_to_webview then return end
	self:send_to_webview({ v = protocol.VERSION, type = "HELLO", controller = self.env.device_id(),
		name = self.env.device_name and self.env.device_name() or nil })
	self.last_push = nil
	self:push_state()
end

-- Richiesta dalla webview (DC_REQUEST): valida, esegue, risponde con un ACK.
-- Le modifiche alla schedule passano dalle PROPRIETA' del driver (fonte di verita'):
-- UpdateProperty non richiama OnPropertyChanged, quindi la ricostruzione e' esplicita.
function Engine:on_webview_request(text)
	local req, err = protocol.decode(text)
	if not req then
		self:log(dbg.WARNING, "[COMMS] richiesta non valida: %s", tostring(err))
		self:send_to_webview(protocol.ack(nil, "?", false, err))
		return
	end
	local id, op, args = req.id, req.op, req.args
	self:log(dbg.INFO, "[COMMS] <- webview %s id=%s", tostring(op), tostring(id))
	local function reply(ok, e, extra)
		self:log(dbg.INFO, "[COMMS] -> webview ACK id=%s op=%s ok=%s", tostring(id), tostring(op), tostring(ok))
		self:send_to_webview(protocol.ack(id, op, ok, e, extra))
	end

	local writes, werr = protocol.property_writes(op, args)
	if writes and op == "DELETE_SWITCHPOINT" then
		local count = self.cfg and self.cfg.count or 0
		writes, werr = protocol.delete_writes(args, count, self.env.prop)
	end
	if not writes then
		self:log(dbg.WARNING, "[COMMS] %s rifiutata: %s", tostring(op), tostring(werr))
		return reply(false, werr)
	end

	if op == "GET_STATE" then
		return reply(true, nil, { state = self:snapshot() })
	elseif op == "PAUSE" or op == "RESUME" or op == "PREVIEW" or op == "STOP_PREVIEW" or op == "FOLLOW" then
		local ok
		if op == "PAUSE" then ok = self:pause()
		elseif op == "RESUME" then ok = self:resume()
		elseif op == "PREVIEW" then ok = self:start_preview()
		elseif op == "STOP_PREVIEW" then ok = self:stop_preview("richiesta webview")
		else ok = self:follow_all() end
		return reply(ok, (not ok) and ("operazione non consentita nello stato " .. self.sm.state) or nil,
			{ state = self.sm.state })
	else
		for _, w in ipairs(writes) do self.env.update_property(w[1], w[2]) end
		self:on_property_changed(writes[1][1]) -- una sola ricostruzione per l'intera richiesta
		self:log(dbg.INFO, "[COMMS] %s applicata (%d proprieta')", op, #writes)
		return reply(true, nil, { applied = #writes })
	end
end

-- ------------------------------------------------------------
-- comandi e azioni
-- ------------------------------------------------------------
function Engine:pause()
	local ok = self:transition("PAUSE")
	if ok then self.env.fire_event("SCHEDULE_PAUSED") end
	return ok
end

function Engine:resume()
	if not self:transition("RESUME") then return false end
	self.env.fire_event("SCHEDULE_RESUMED")
	local follow = self.env.prop("Follow Lights when Schedule Resumed") ~= "No" -- letto adesso (v204)
	if follow then
		self.mon:reset_override()
		self:save_overrides()
	end
	self:apply({ force = follow })
	return true
end

function Engine:follow_all()
	self.mon:reset_override()
	self:save_overrides()
	if self.sm.state == SM.ACTIVE then
		self:apply({ force = true })
	else
		self:log(dbg.INFO, "[MONITOR] flag azzerati; le luci seguiranno la schedule quando sara' ACTIVE (stato: %s)", self.sm.state)
	end
	return true
end

function Engine:start_preview()
	if not self:transition("PREVIEW_START") then return false end
	self.preview = { step = 0, minute = 0 }
	self.env.fire_event("PREVIEW_STARTED")
	local interval_ms = (M.PREVIEW_DURATION_S * 1000) / M.PREVIEW_STEPS
	self.preview.timer = self.env.set_timer(interval_ms, function() self:preview_step() end, true)
	self:preview_step()
	return true
end

function Engine:preview_step()
	local p = self.preview
	if not p or self.sm.state ~= SM.PREVIEW then return end
	p.minute = (p.step / M.PREVIEW_STEPS) * 1440
	self:apply({ force = true, rate_ms = M.PREVIEW_RATE_MS, minute = p.minute })
	self:publish_state()
	local target = self:target_at(p.minute)
	self:send_to_webview({ v = protocol.VERSION, type = "PREVIEW", controller = self.env.device_id(),
		active = true, minute = p.minute, step = p.step, steps = M.PREVIEW_STEPS,
		duration_s = M.PREVIEW_DURATION_S, -- fattore di accelerazione = 86400 / duration_s
		brightness = math.floor(target.brightness + 0.5),
		cct = math.floor(clamp(target.cct, self.cfg.ct_min, self.cfg.ct_max) + 0.5) })
	if p.step >= M.PREVIEW_STEPS then
		self:stop_preview("completata")
	else
		p.step = p.step + 1
	end
end

function Engine:stop_preview(reason)
	local p = self.preview
	if self.sm.state ~= SM.PREVIEW then
		self:log(dbg.WARNING, "[PREVIEW] nessuna preview in corso (stato %s)", self.sm.state)
		return false
	end
	if p and p.timer then p.timer:cancel() end
	self.preview = nil
	self:log(dbg.INFO, "[PREVIEW] fermata (%s)", reason or "richiesta")
	self:send_to_webview({ v = protocol.VERSION, type = "PREVIEW", controller = self.env.device_id(), active = false })
	if self:transition("PREVIEW_STOP") then
		self.env.fire_event("PREVIEW_STOPPED")
		self:apply({ force = true }) -- riporta le luci alla schedule reale
		return true
	end
	return false
end

function Engine:display_schedule()
	if not self.cfg then
		self:log(dbg.WARNING, "[SCHEDULE] nessuna schedule caricata")
		return
	end
	for _, line in ipairs(schedule.describe(self.cfg, self.astro)) do
		self:log(dbg.INFO, "[SCHEDULE] %s", line)
	end
end

function Engine:show_astro()
	local a = self.astro
	if not a then
		self:log(dbg.WARNING, "[ASTRO] nessun dato disponibile")
		return
	end
	self:log(dbg.INFO, "[ASTRO] %s UTC%+g lat=%.4f lon=%.4f", a.date, a.offset, a.lat, a.lon)
	self:log(dbg.INFO, "[ASTRO] alba %s | mezzogiorno %s | tramonto %s | mezzanotte %s%s",
		sun.format_minutes(a.sunrise), sun.format_minutes(a.solar_noon), sun.format_minutes(a.sunset),
		sun.format_minutes(a.solar_midnight), a.polar and (" | polare: " .. a.polar) or "")
end

function Engine:copy_schedule(targets_text)
	local targets = light_cmd.parse_device_list(targets_text)
	if #targets == 0 then
		self:log(dbg.WARNING, "[COPY] nessun controller di destinazione selezionato")
		return
	end
	local payload = {}
	for _, name in ipairs(copy_properties()) do
		local v = self.env.prop(name)
		if v ~= nil then payload[safe_key(name)] = tostring(v) end
	end
	local me = self.env.device_id()
	for _, id in ipairs(targets) do
		if id ~= me then
			self.env.send_to_device(id, "RECEIVE_SCHEDULE", payload)
			self:log(dbg.INFO, "[COPY] schedule inviata al controller %d", id)
		end
	end
end

function Engine:receive_schedule(params)
	local n = 0
	for _, name in ipairs(copy_properties()) do
		local v = params and params[safe_key(name)]
		if v ~= nil then
			self.env.update_property(name, tostring(v))
			n = n + 1
		end
	end
	self:log(dbg.INFO, "[COPY] schedule ricevuta (%d proprieta')", n)
	self:on_property_changed("Scheduler Mode") -- ricostruisce la curva una volta
end

-- on_command(strCommand, tParams): ExecuteCommand di Director. Le azioni di
-- Composer arrivano come LUA_ACTION con ACTION = nome o comando dell'azione.
function Engine:on_command(command, params)
	if command == protocol.COMMAND_REQUEST then
		return self:on_webview_request(params and params[protocol.PARAM])
	end
	if command == "LUA_ACTION" then
		command = params and params.ACTION or ""
	end
	local key = M.normalize_command(command)
	local what = COMMAND_ALIASES[key]
	self:log(dbg.INFO, "[COMMANDS] %s", key)
	if what == "pause" then self:pause()
	elseif what == "resume" then self:resume()
	elseif what == "start_preview" then self:start_preview()
	elseif what == "stop_preview" then self:stop_preview("richiesta")
	elseif what == "follow" then self:follow_all()
	elseif what == "display" then self:display_schedule()
	elseif what == "show_astro" then self:show_astro()
	elseif what == "recalc_astro" then
		self:ensure_astro(true)
		if self.sm.state == SM.IDLE then self:try_start() end
		if self.sm.state == SM.ACTIVE then self:apply({}) end
	elseif what == "copy" then
		local text = params and (params.Controllers or params.CONTROLLERS)
		if not text and params then
			for k, v in pairs(params) do
				if k ~= "ACTION" and type(v) == "string" and v:match("^[%d,%s]+$") then text = v end
			end
		end
		self:copy_schedule(text)
	elseif what == "receive" then self:receive_schedule(params)
	else
		self:log(dbg.WARNING, "[COMMANDS] comando sconosciuto: %s", tostring(command))
	end
end

return M
