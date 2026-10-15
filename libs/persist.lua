-- ============================================================
-- libs/persist.lua - wrapper di C4:PersistSetValue / C4:PersistGetValue
--
-- Lua 5.1 puro, nessun riferimento a C4: il backend (get/set) e' iniettato dal
-- driver. Da OS 3.2 le variabili Lua vengono reinizializzate al restart
-- (Janus v205): tutto lo stato durevole passa da qui.
--
-- C4:PersistSetValue accetta numeri, stringhe, booleani e tabelle (annidate)
-- di questi tipi; qualunque altro tipo (funzioni, userdata) lo fa fallire.
-- `set` ripulisce quindi le tabelle da cio' che non e' persistibile.
-- ============================================================

local M = {}

-- Chiavi persistite (nomi stabili: cambiarli rompe il ripristino)
M.KEY_STATE = "state"            -- "IDLE" / "ACTIVE" / "PAUSED" / "PREVIEW"
M.KEY_OVERRIDDEN = "overridden"  -- { [device_id] = true }
M.KEY_ASTRO = "astro_today"      -- dati astronomici del giorno
M.KEY_SCHEDULE = "schedule"      -- snapshot della configurazione (per la webview)

local function clean(value, depth)
	local t = type(value)
	if t == "number" or t == "string" or t == "boolean" then return value end
	if t == "table" and depth < 8 then
		local out = {}
		for k, v in pairs(value) do
			local kt = type(k)
			if kt == "number" or kt == "string" then
				local cv = clean(v, depth + 1)
				if cv ~= nil then out[k] = cv end
			end
		end
		return out
	end
	return nil
end

-- new(backend) con backend = { get = function(key), set = function(key, value) }
function M.new(backend)
	local self = {}

	function self.get(key, default)
		local v = backend.get(key)
		if v == nil then return default end
		return v
	end

	function self.set(key, value)
		backend.set(key, clean(value, 0))
	end

	return self
end

M.clean = function(value) return clean(value, 0) end

return M
