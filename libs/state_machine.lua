-- ============================================================
-- libs/state_machine.lua - stati del controller: IDLE / ACTIVE / PAUSED / PREVIEW
--
-- Lua 5.1 puro, nessun riferimento a C4.
--
-- Transizioni consentite (evento -> nuovo stato):
--   IDLE    : START -> ACTIVE
--   ACTIVE  : PAUSE -> PAUSED, PREVIEW_START -> PREVIEW, STOP -> IDLE
--   PAUSED  : RESUME -> ACTIVE, STOP -> IDLE
--   PREVIEW : PREVIEW_STOP -> ACTIVE, STOP -> IDLE
-- VIETATE, con motivo esplicito (bug Janus v207: pausa durante la preview):
--   PREVIEW + PAUSE          -> prima ferma la preview
--   PAUSED  + PREVIEW_START  -> prima riprendi la schedule
-- Ogni altra combinazione e' rifiutata con un motivo generico. Un rifiuto non
-- cambia stato.
-- ============================================================

local M = {}

M.IDLE, M.ACTIVE, M.PAUSED, M.PREVIEW = "IDLE", "ACTIVE", "PAUSED", "PREVIEW"

local TRANSITIONS = {
	IDLE = { START = "ACTIVE" },
	ACTIVE = { PAUSE = "PAUSED", PREVIEW_START = "PREVIEW", STOP = "IDLE" },
	PAUSED = { RESUME = "ACTIVE", STOP = "IDLE" },
	PREVIEW = { PREVIEW_STOP = "ACTIVE", STOP = "IDLE" },
}

local FORBIDDEN_REASON = {
	PREVIEW = { PAUSE = "pause during preview is not allowed: stop the preview first" },
	PAUSED = { PREVIEW_START = "preview while paused is not allowed: resume the schedule first" },
}

local Machine = {}
Machine.__index = Machine

-- new([initial]) -> macchina (default IDLE)
function M.new(initial)
	local self = setmetatable({}, Machine)
	self.state = TRANSITIONS[initial] and initial or M.IDLE
	return self
end

-- machine:request(event) -> true, nuovo_stato | false, motivo
function Machine:request(event)
	local row = TRANSITIONS[self.state]
	local target = row and row[event]
	if not target then
		local forbidden = FORBIDDEN_REASON[self.state] and FORBIDDEN_REASON[self.state][event]
		return false, forbidden or ("transition " .. tostring(event) .. " not allowed from " .. self.state)
	end
	self.state = target
	return true, target
end

-- restore(saved): ripristino dopo restart. ACTIVE e PAUSED si conservano;
-- PREVIEW (volatile), IDLE e valori sconosciuti tornano IDLE.
function Machine:restore(saved)
	if saved == M.ACTIVE or saved == M.PAUSED then
		self.state = saved
	else
		self.state = M.IDLE
	end
	return self.state
end

-- SCHEDULE_ACTIVE: vero se non PAUSED e non IDLE (quindi anche in PREVIEW)
function M.schedule_active(state)
	return state == M.ACTIVE or state == M.PREVIEW
end

function M.preview_active(state)
	return state == M.PREVIEW
end

return M
