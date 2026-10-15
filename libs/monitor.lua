-- ============================================================
-- libs/monitor.lua - Smart Light Level Monitoring (logica pura, tempo iniettato)
--
-- Lua 5.1 puro, nessun riferimento a C4. Il tempo (`now`, secondi) e' sempre
-- passato dal chiamante, cosi' tutto e' deterministico nei test.
--
-- Per ogni luce tiene: livello noto (0..100), flag `overridden` (l'utente l'ha
-- cambiata a mano: non mandare piu' la brightness, la CCT continua), ultimo
-- comando inviato e cambio esterno in attesa di debounce.
--
-- Distinzione "self-sent" / "esterno": prima di ogni invio il chiamante registra
-- `sent()`. Un cambio di livello e' "self" se arriva entro la finestra
--     rate + 2*debounce + margine
-- dall'invio e il livello sta nell'intervallo [da, a] (da = livello prima
-- dell'invio, a = target) +/- soglia: durante una rampa arrivano anche livelli
-- intermedi, che altrimenti sembrerebbero cambi esterni. Fuori finestra o
-- fuori intervallo il cambio e' esterno.
--
-- Regole (docs/EDGE_CASES.md):
--   * mai accendere una luce spenta (v117) e niente comandi a luce spenta (v200);
--   * cambio esterno OFF -> ON: reset del flag, riallineamento immediato (v109);
--   * cambio esterno ON: dopo il debounce -> `overridden`, salvo che il livello
--     coincida col circadiano entro la tolleranza (re-align, v106);
--   * monitoring Off: si comanda sempre (v203);
--   * debounce 0 ammesso (v111).
-- ============================================================

local M = {}

M.DEFAULTS = {
	threshold_pct = 2,   -- tolleranza self-sent e re-align (leniency, v106)
	margin_s = 2,        -- margine aggiunto alla finestra self-sent
	brightness_delta = 1, -- invia brightness solo se |target - livello| >= delta (%)
	cct_delta = 25,      -- invia CCT solo se |target - ultimo inviato| >= delta (K)
}

local Monitor = {}
Monitor.__index = Monitor

function M.new(opts)
	local cfg = {}
	for k, v in pairs(M.DEFAULTS) do cfg[k] = v end
	if opts then for k, v in pairs(opts) do cfg[k] = v end end
	return setmetatable({ cfg = cfg, lights = {} }, Monitor)
end

-- CCT a multipli di 10 K (Janus v201)
function M.round_cct(k)
	return math.floor(k / 10 + 0.5) * 10
end

function Monitor:add(id)
	if not self.lights[id] then
		self.lights[id] = { id = id, level = nil, overridden = false, last_sent = nil, pending = nil }
	end
	return self.lights[id]
end

function Monitor:remove(id)
	self.lights[id] = nil
end

function Monitor:get(id)
	return self.lights[id]
end

function Monitor:is_on(id)
	local l = self.lights[id]
	return l ~= nil and l.level ~= nil and l.level > 0
end

local function window_s(self, last, debounce_s)
	return last.rate_s + 2 * debounce_s + self.cfg.margin_s
end

local function is_self_sent(self, l, level, now, debounce_s)
	local ls = l.last_sent
	if not ls or ls.brightness == nil then return false end
	if now - ls.time > window_s(self, ls, debounce_s) then return false end
	local thr = self.cfg.threshold_pct
	local lo = math.min(ls.from or ls.brightness, ls.brightness) - thr
	local hi = math.max(ls.from or ls.brightness, ls.brightness) + thr
	return level >= lo and level <= hi
end

-- on_level(id, level, now, opts) -> evento
--   opts = { monitoring = bool (Smart Monitoring On e stato ACTIVE),
--            debounce_s = numero }
--   evento: "init" | "unchanged" | "self" | "turned_on" | "turned_off" |
--           "external_pending" | "external_ignored"
function Monitor:on_level(id, level, now, opts)
	local l = self:add(id)
	opts = opts or {}
	local prev = l.level
	l.level = level
	if prev == nil then return "init" end
	if level == prev then return "unchanged" end

	if is_self_sent(self, l, level, now, opts.debounce_s or 0) then
		return "self"
	end

	-- cambio esterno
	if prev == 0 and level > 0 then
		l.overridden = false
		l.pending = nil
		return "turned_on"
	end
	if level == 0 then
		l.pending = nil
		return "turned_off"
	end
	if opts.monitoring then
		l.pending = { level = level, since = now }
		return "external_pending"
	end
	return "external_ignored"
end

-- Il livello e' stabile da `debounce_s`? (chiamato dal timer di debounce)
-- settle(id, now, target_brightness, debounce_s) ->
--   nil (niente da fare) | "overridden" | "realigned"
function Monitor:settle(id, now, target_brightness, debounce_s)
	local l = self.lights[id]
	if not l or not l.pending then return nil end
	if now - l.pending.since < (debounce_s or 0) - 1e-6 then return nil end -- nuovo cambio: aspetta
	l.pending = nil
	if l.level and l.level > 0
		and math.abs(l.level - target_brightness) <= self.cfg.threshold_pct then
		l.overridden = false
		return "realigned"
	end
	l.overridden = true
	return "overridden"
end

-- Luci in override il cui livello coincide col circadiano: reset (re-align).
-- check_realign(id, target_brightness) -> true se il flag e' stato azzerato
function Monitor:check_realign(id, target_brightness)
	local l = self.lights[id]
	if l and l.overridden and l.level and l.level > 0
		and math.abs(l.level - target_brightness) <= self.cfg.threshold_pct then
		l.overridden = false
		return true
	end
	return false
end

-- reset_override([id]): Follow Lights (tutte se id e' nil)
function Monitor:reset_override(id)
	if id then
		local l = self.lights[id]
		if l then l.overridden = false; l.pending = nil end
	else
		for _, l in pairs(self.lights) do l.overridden = false; l.pending = nil end
	end
end

-- Registra cosa e' stato inviato (brightness e/o cct possono essere nil).
function Monitor:sent(id, brightness, cct, now, rate_s)
	local l = self:add(id)
	local ls = l.last_sent or {}
	if brightness ~= nil then
		ls.brightness = brightness
		ls.from = l.level or brightness
		ls.time = now
		ls.rate_s = rate_s or 0
	end
	if cct ~= nil then ls.cct = cct end
	l.last_sent = ls
	-- un invio nostro cancella un debounce in sospeso: il livello cambiera' per noi
	if brightness ~= nil then l.pending = nil end
end

-- plan(id, target, opts) -> { brightness = int|nil, cct = int|nil }
--   target = { brightness, cct } (CCT gia' nei limiti)
--   opts = { use_brightness, use_cct, monitoring, force, force_cct, preset_off, supports_cct, cct_min, cct_max }
--   preset_off: a luce SPENTA (livello noto = 0) invia la sola CCT (mai la brightness): il proxy Light V2
--   la salva e la applica alla prossima accensione dal sistema (docs Proxy Protocol, "Setting Color
--   while the Light is Off"). Il risultato porta off = true.
--   force_cct: rimanda la CCT anche se uguale all'ultima inviata (senza toccare la brightness)
--   cct_min/cct_max = limiti della lampada: la CCT viene riportata nei limiti PRIMA del
--   confronto con l'ultima inviata (e' il valore che verrebbe davvero inviato), come la
--   brightness confronta il valore finale: altrimenti un target sotto il minimo della
--   lampada (es. 2602 K con min 2700 K) risulterebbe sempre "diverso" dall'ultimo inviato
--   (2700 K) e verrebbe rimandato a ogni tick.
-- Mai su luci spente/sconosciute. Brightness 0 con luce accesa => 0 (spegne),
-- ma non accende mai.
local function plan_cct(self, l, target, opts)
	local c = M.round_cct(target.cct)
	if opts.cct_min and c < opts.cct_min then c = opts.cct_min end
	if opts.cct_max and c > opts.cct_max then c = opts.cct_max end
	local ls = l.last_sent
	if opts.force or opts.force_cct or not ls or ls.cct == nil or math.abs(c - ls.cct) >= self.cfg.cct_delta then
		return c
	end
	return nil
end

function Monitor:plan(id, target, opts)
	local out = {}
	local l = self.lights[id]
	if not l or l.level == nil then return out end
	if l.level <= 0 then
		-- luce spenta: niente brightness, mai; la CCT solo se richiesto (colore preimpostato)
		if opts.preset_off and opts.use_cct and opts.supports_cct ~= false then
			out.cct = plan_cct(self, l, target, opts)
			out.off = out.cct ~= nil
		end
		return out
	end

	if opts.use_brightness and not (opts.monitoring and l.overridden) then
		local b = math.floor(target.brightness + 0.5)
		-- Alcune lampade riportano 1 % in meno di quanto comandato (T4: comandato 48, riportato 47):
		-- se il valore e' uguale all'ULTIMO INVIATO e il livello riportato ne dista al piu' 1 %,
		-- e' quantizzazione della lampada, non una deviazione: niente reinvio a ogni tick.
		local ls = l.last_sent
		local quantized = ls ~= nil and ls.brightness == b and math.abs(l.level - b) <= 1
		if opts.force or (math.abs(b - l.level) >= self.cfg.brightness_delta and not quantized) then
			out.brightness = b
		end
	end

	if opts.use_cct and opts.supports_cct ~= false then
		out.cct = plan_cct(self, l, target, opts)
	end
	return out
end

-- Flag overridden persistibili: { [id] = true }
function Monitor:export_overridden()
	local out = {}
	for id, l in pairs(self.lights) do
		if l.overridden then out[id] = true end
	end
	return out
end

function Monitor:import_overridden(map)
	for id, v in pairs(map or {}) do
		local l = self.lights[id]
		if l and v then l.overridden = true end
	end
end

return M
