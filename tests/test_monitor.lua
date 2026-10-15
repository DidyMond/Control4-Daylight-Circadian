-- Test di libs/monitor.lua: self-sent vs esterno, debounce, override, re-align, plan
local t = require "tests.support.harness"
local monitor = require "libs.monitor"

local ON = { monitoring = true, debounce_s = 1 }
local PLAN = { use_brightness = true, use_cct = true, monitoring = true }

local function plan_opts(extra)
	local o = {}
	for k, v in pairs(PLAN) do o[k] = v end
	for k, v in pairs(extra or {}) do o[k] = v end
	return o
end

-- luce con livello noto
local function light(level)
	local m = monitor.new()
	m:on_level(1, level, 0, ON) -- "init"
	return m
end

t.test("primo livello: init; livello invariato: unchanged", function()
	local m = monitor.new()
	t.eq(m:on_level(1, 50, 0, ON), "init")
	t.eq(m:on_level(1, 50, 1, ON), "unchanged")
end)

t.test("cambio esterno con luce accesa: pending, poi override dopo il debounce", function()
	local m = light(50)
	t.eq(m:on_level(1, 80, 10, ON), "external_pending")
	t.eq(m:settle(1, 10.5, 55, 1), nil)           -- debounce non ancora trascorso
	t.eq(m:settle(1, 11, 55, 1), "overridden")
	t.eq(m:get(1).overridden, true)
end)

t.test("debounce: un nuovo cambio ravvicinato riparte da capo", function()
	local m = light(50)
	m:on_level(1, 60, 10, ON)
	m:on_level(1, 70, 10.8, ON)
	t.eq(m:settle(1, 11, 50, 1), nil)      -- il primo timer scade ma l'ultimo cambio e' a 10.8
	t.eq(m:settle(1, 11.8, 50, 1), "overridden")
	t.eq(m:get(1).level, 70)
end)

t.test("debounce 0 ammesso (v111): override immediato al settle", function()
	local m = light(50)
	m:on_level(1, 80, 10, { monitoring = true, debounce_s = 0 })
	t.eq(m:settle(1, 10, 55, 0), "overridden")
end)

t.test("re-align (b): dopo il debounce il livello coincide col circadiano => nessun override", function()
	local m = light(50)
	m:on_level(1, 56, 10, ON)
	t.eq(m:settle(1, 11, 55, 1), "realigned") -- 56 vs 55: dentro la tolleranza
	t.eq(m:get(1).overridden, false)
end)

t.test("re-align (b) durante override: luce che torna al circadiano => flag azzerato", function()
	local m = light(50)
	m:on_level(1, 90, 10, ON); m:settle(1, 11, 55, 1)
	t.eq(m:get(1).overridden, true)
	t.eq(m:check_realign(1, 55), false)  -- 90 vs 55
	m:on_level(1, 54, 20, ON)
	m:settle(1, 21, 55, 1)
	t.eq(m:get(1).overridden, false)
end)

t.test("re-align (a): OFF -> ON esterno azzera l'override", function()
	local m = light(50)
	m:on_level(1, 90, 10, ON); m:settle(1, 11, 55, 1)
	t.eq(m:get(1).overridden, true)
	t.eq(m:on_level(1, 0, 20, ON), "turned_off")
	t.eq(m:get(1).overridden, true)        -- lo spegnimento da solo non azzera
	t.eq(m:on_level(1, 60, 30, ON), "turned_on")
	t.eq(m:get(1).overridden, false)
end)

t.test("self-sent: livello pari al target inviato entro la finestra => ignorato", function()
	local m = light(50)
	m:sent(1, 60, 4000, 100, 5)            -- rampa 5 s, from 50 -> 60
	t.eq(m:on_level(1, 60, 103, ON), "self")
	t.eq(m:get(1).overridden, false)
	t.eq(m:get(1).pending, nil)
end)

t.test("self-sent: livelli intermedi della rampa non sono cambi esterni", function()
	local m = light(50)
	m:sent(1, 80, 4000, 100, 5)            -- 50 -> 80
	t.eq(m:on_level(1, 58, 101, ON), "self")
	t.eq(m:on_level(1, 71, 103, ON), "self")
	t.eq(m:on_level(1, 80, 105, ON), "self")
end)

t.test("esterno: livello fuori dall'intervallo della rampa => cambio esterno", function()
	local m = light(50)
	m:sent(1, 60, 4000, 100, 5)            -- 50 -> 60
	t.eq(m:on_level(1, 95, 102, ON), "external_pending")
end)

t.test("esterno: stesso livello ma oltre la finestra (rate + 2*debounce + margine)", function()
	local m = light(50)
	m:sent(1, 60, 4000, 100, 5)            -- finestra = 5 + 2*1 + 2 = 9 s
	t.eq(m:on_level(1, 60, 109.5, ON), "external_pending")
end)

t.test("self-sent con debounce 0: finestra = rate + margine, non zero", function()
	local m = light(50)
	m:sent(1, 60, 4000, 100, 5)
	t.eq(m:on_level(1, 60, 103, { monitoring = true, debounce_s = 0 }), "self")
end)

t.test("monitoring Off: cambio esterno ignorato (nessun pending), OFF->ON resta un reset", function()
	local m = light(50)
	t.eq(m:on_level(1, 80, 10, { monitoring = false, debounce_s = 1 }), "external_ignored")
	t.eq(m:get(1).pending, nil)
end)

t.test("plan: luce spenta o sconosciuta => nessun comando (mai accendere, v117/v200)", function()
	local m = monitor.new()
	m:add(1)
	t.eq(next(m:plan(1, { brightness = 50, cct = 3000 }, plan_opts())), nil)  -- sconosciuta
	m:on_level(1, 0, 0, ON)
	t.eq(next(m:plan(1, { brightness = 50, cct = 3000 }, plan_opts({ force = true }))), nil)
	t.eq(next(m:plan(99, { brightness = 50, cct = 3000 }, plan_opts())), nil)  -- luce non gestita
end)

t.test("plan: lampada che riporta 1% in meno del comandato => niente reinvio a ogni tick", function()
	local m = light(50)
	m:sent(1, 48, 3000, 1, 5)
	m:on_level(1, 47, 2, ON)                  -- riportato 47 per un comando 48 (self-sent)
	local p = m:plan(1, { brightness = 48.4, cct = 3000 }, plan_opts())
	t.eq(p.brightness, nil, "uguale all'ultimo inviato, livello entro 1 %")
	p = m:plan(1, { brightness = 49.4, cct = 3000 }, plan_opts())
	t.eq(p.brightness, 49, "target cambiato: si invia")
	m:on_level(1, 40, 30, ON)                 -- deviazione vera (> 1 %), anche con target uguale all'ultimo inviato
	p = m:plan(1, { brightness = 48.4, cct = 3000 }, plan_opts())
	t.eq(p.brightness, 48, "deviazione di 8 %: si invia")
	m:on_level(1, 47, 31, ON)
	p = m:plan(1, { brightness = 48.4, cct = 3000 }, plan_opts({ force = true }))
	t.eq(p.brightness, 48, "force (Segui luci, accensione): si invia sempre")
end)

t.test("plan: brightness solo oltre la soglia dell'1%, CCT arrotondata a 10 K", function()
	local m = light(50)
	local p = m:plan(1, { brightness = 50.4, cct = 3004 }, plan_opts())
	t.eq(p.brightness, nil)                -- |50 - 50| < 1
	t.eq(p.cct, 3000)                      -- primo invio CCT: sempre
	m:sent(1, nil, 3000, 1, 5)
	p = m:plan(1, { brightness = 52.4, cct = 3020 }, plan_opts())
	t.eq(p.brightness, 52)
	t.eq(p.cct, nil)                       -- delta 20 < 25 K
	p = m:plan(1, { brightness = 52.4, cct = 3030 }, plan_opts())
	t.eq(p.cct, 3030)                      -- delta 30 >= 25 K
end)

t.test("plan: brightness 0 con luce accesa => 0 (spegne), mai ON", function()
	local m = light(40)
	t.eq(m:plan(1, { brightness = 0, cct = 3000 }, plan_opts()).brightness, 0)
end)

t.test("plan: luce in override => solo CCT, finche' monitoring e' On", function()
	local m = light(50)
	m:on_level(1, 90, 10, ON); m:settle(1, 11, 55, 1)
	local p = m:plan(1, { brightness = 55, cct = 3500 }, plan_opts())
	t.eq(p.brightness, nil)
	t.eq(p.cct, 3500)
	-- monitoring Off: si comanda comunque (v203)
	p = m:plan(1, { brightness = 55, cct = 3500 }, plan_opts({ monitoring = false }))
	t.eq(p.brightness, 55)
end)

t.test("plan: modalita' Brightness Only / CT Only / luce senza CCT", function()
	local m = light(50)
	local target = { brightness = 70, cct = 4000 }
	local p = m:plan(1, target, plan_opts({ use_cct = false }))
	t.eq(p.brightness, 70); t.eq(p.cct, nil)
	p = m:plan(1, target, plan_opts({ use_brightness = false }))
	t.eq(p.brightness, nil); t.eq(p.cct, 4000)
	p = m:plan(1, target, plan_opts({ supports_cct = false }))
	t.eq(p.cct, nil)
end)

t.test("plan: force invia comunque (Follow / re-align)", function()
	local m = light(70)
	m:sent(1, 70, 4000, 1, 5)
	local p = m:plan(1, { brightness = 70, cct = 4000 }, plan_opts({ force = true }))
	t.eq(p.brightness, 70); t.eq(p.cct, 4000)
end)

t.test("round_cct: multipli di 10 K (v201)", function()
	t.eq(monitor.round_cct(2704), 2700)
	t.eq(monitor.round_cct(2705), 2710)
	t.eq(monitor.round_cct(6500), 6500)
end)

t.test("reset_override: singola luce e tutte (Follow All Lights)", function()
	local m = monitor.new()
	for id = 1, 3 do m:on_level(id, 50, 0, ON); m:on_level(id, 90, 10, ON); m:settle(id, 11, 55, 1) end
	t.eq(m:get(1).overridden and m:get(2).overridden and m:get(3).overridden, true)
	m:reset_override(2)
	t.eq(m:get(2).overridden, false); t.eq(m:get(1).overridden, true)
	m:reset_override()
	t.eq(m:get(1).overridden or m:get(3).overridden, false)
end)

t.test("export/import dei flag overridden (persistenza)", function()
	local m = light(50)
	m:on_level(1, 90, 10, ON); m:settle(1, 11, 55, 1)
	local saved = m:export_overridden()
	t.eq(saved[1], true)
	local m2 = monitor.new()
	m2:add(1); m2:add(2)
	m2:import_overridden(saved)
	t.eq(m2:get(1).overridden, true)
	t.eq(m2:get(2).overridden, false)
	m2:import_overridden({ [77] = true })  -- luce non piu' gestita: ignorata
	t.eq(m2:get(77), nil)
end)

t.test("override: la soglia CCT usa l'ultima CCT INVIATA, indipendentemente dalla brightness", function()
	local m = light(50)
	m:on_level(1, 90, 10, ON); m:settle(1, 11, 55, 1)   -- override
	t.eq(m:get(1).overridden, true)
	m:sent(1, nil, 4000, 20, 5)                         -- inviata solo CCT 4000 K
	local p = m:plan(1, { brightness = 55, cct = 4020 }, plan_opts())
	t.eq(p.brightness, nil); t.eq(p.cct, nil)           -- delta 20 < 25
	p = m:plan(1, { brightness = 55, cct = 4025 }, plan_opts())
	t.eq(p.brightness, nil); t.eq(p.cct, 4030)           -- 4025 arrotondata a 4030: delta 30 >= 25
	-- il confronto non si sposta con i soli "apply" senza invio: sempre rispetto all'ultima inviata
	p = m:plan(1, { brightness = 55, cct = 4010 }, plan_opts())
	t.eq(p.cct, nil)
	m:sent(1, nil, 4030, 30, 5)
	p = m:plan(1, { brightness = 55, cct = 4050 }, plan_opts())
	t.eq(p.cct, nil)                                    -- 4050 vs 4030 inviata
end)

-- ---------------------------------------------------------------- clamp lampada prima della soglia
t.test("plan: CCT riportata nei limiti della lampada PRIMA della soglia (niente rinvio ridondante)", function()
	local m = light(50)
	local opts = plan_opts({ cct_min = 2700, cct_max = 6000 })
	local p = m:plan(1, { brightness = 50, cct = 2602 }, opts)
	t.eq(p.cct, 2700, "primo invio: clampato")
	m:sent(1, nil, p.cct, 10, 5)
	-- stesso target sotto il minimo: il valore post-clamp coincide con l'ultimo inviato
	t.eq(m:plan(1, { brightness = 50, cct = 2602 }, opts).cct, nil)
	t.eq(m:plan(1, { brightness = 50, cct = 2400 }, opts).cct, nil, "ancora sotto il minimo")
	-- simmetria sul massimo
	local m2 = light(50)
	local p2 = m2:plan(1, { brightness = 50, cct = 6400 }, opts)
	t.eq(p2.cct, 6000)
	m2:sent(1, nil, p2.cct, 10, 5)
	t.eq(m2:plan(1, { brightness = 50, cct = 6400 }, opts).cct, nil)
	t.eq(m2:plan(1, { brightness = 50, cct = 6050 }, opts).cct, nil)
	-- dentro i limiti il comportamento e' invariato (soglia 25 K)
	t.eq(m:plan(1, { brightness = 50, cct = 2700 }, opts).cct, nil)
	t.eq(m:plan(1, { brightness = 50, cct = 2740 }, opts).cct, 2740)
	-- senza limiti (caps ignote): nessun clamp
	t.eq(light(50):plan(1, { brightness = 50, cct = 2602 }, plan_opts()).cct, 2600)
end)

t.finish()
