-- Test di libs/curve.lua (monotone cubic Fritsch-Carlson, giornata ciclica)
local t = require "tests.support.harness"
local curve = require "libs.curve"
local cases = require "tests.fixtures.curve_cases"

local function ev(points, minute)
	return assert(curve.evaluate(points, minute))
end

t.test("valori a meta' segmento calcolati a mano (3 punti, brightness e CCT)", function()
	local c = cases.three_point
	for _, e in ipairs(c.expected) do
		local r = ev(c.points, e.t)
		t.near(r.brightness, e.brightness, 1e-9, "brightness a t=" .. e.t)
		t.near(r.cct, e.cct, 1e-6, "cct a t=" .. e.t)
	end
end)

t.test("passa esattamente per gli switchpoint", function()
	for _, set in ipairs({ cases.three_point.points, cases.default_day }) do
		for _, p in ipairs(set) do
			local r = ev(set, p.t)
			t.near(r.brightness, p.brightness, 1e-9)
			t.near(r.cct, p.cct, 1e-9)
		end
	end
end)

t.test("monotonia: input crescenti => output non decrescente", function()
	-- include salti ripidi e tratti piatti (esercita il limitatore di Fritsch-Carlson)
	local pts = {
		{ t = 60,  brightness = 0,   cct = 1600 },
		{ t = 120, brightness = 0,   cct = 1700 },
		{ t = 130, brightness = 100, cct = 6500 },
		{ t = 600, brightness = 100, cct = 6500 },
		{ t = 900, brightness = 100, cct = 6500 },
	}
	local c = assert(curve.prepare(pts))
	local prev_b, prev_c = -1, -1
	for minute = 60, 900 do
		local r = c:evaluate(minute)
		t.truthy(r.brightness >= prev_b - 1e-9, "brightness cala a t=" .. minute)
		t.truthy(r.cct >= prev_c - 1e-9, "cct cala a t=" .. minute)
		prev_b, prev_c = r.brightness, r.cct
	end
end)

t.test("monotonia sul giorno di default (tratto crescente 00:30 -> 13:00)", function()
	local c = assert(curve.prepare(cases.default_day))
	local prev = -1
	for minute = 30, 780 do
		local r = c:evaluate(minute)
		t.truthy(r.brightness >= prev - 1e-9, "brightness cala a t=" .. minute)
		prev = r.brightness
	end
	-- e decrescente da 13:00 a 20:00
	prev = 101
	for minute = 780, 1200 do
		local r = c:evaluate(minute)
		t.truthy(r.brightness <= prev + 1e-9, "brightness sale a t=" .. minute)
		prev = r.brightness
	end
end)

t.test("niente overshoot: sempre dentro [min, max] dei punti", function()
	local set = cases.default_day
	local lo, hi = math.huge, -math.huge
	for _, p in ipairs(set) do
		lo, hi = math.min(lo, p.brightness), math.max(hi, p.brightness)
	end
	local c = assert(curve.prepare(set))
	for minute = 0, 1439 do
		local r = c:evaluate(minute)
		t.truthy(r.brightness >= lo - 1e-9 and r.brightness <= hi + 1e-9, "fuori range a t=" .. minute)
	end
end)

t.test("wrap-around: continuita' a mezzanotte e periodicita'", function()
	local pts = cases.default_day
	local a, b = ev(pts, 0), ev(pts, 1440)
	t.near(a.brightness, b.brightness, 1e-9)
	local before, after = ev(pts, 1439), ev(pts, 1440 + 1)
	t.truthy(math.abs(before.brightness - after.brightness) < 1, "salto a mezzanotte")
	t.near(ev(pts, 600).brightness, ev(pts, 600 + 1440).brightness, 1e-9)
	t.near(ev(pts, 600).brightness, ev(pts, 600 - 1440).brightness, 1e-9)
	t.near(ev(pts, 1430).cct, ev(pts, -10).cct, 1e-9)
end)

t.test("wrap-around: segmento che attraversa la mezzanotte", function()
	local pts = {
		{ t = 60,   brightness = 10, cct = 2200 },
		{ t = 720,  brightness = 90, cct = 6000 },
		{ t = 1380, brightness = 30, cct = 2700 }, -- 23:00 -> 01:00 del giorno dopo
	}
	local r = ev(pts, 0)
	t.truthy(r.brightness > 10 and r.brightness < 30, "brightness a 00:00 fra i due punti: " .. r.brightness)
	t.truthy(r.cct > 2200 and r.cct < 2700)
	-- Calcolo a mano a 00:00 (meta' del segmento 1380 -> 1500, h = 120):
	--   secanti: 720->1380 = (30-90)/660, 1380->1500 = (10-30)/120
	--   m(1380) = media delle due (stesso segno) = -0.128788; m(1500) = 0 (min locale)
	--   y = 0.5*30 + 0.125*120*m(1380) + 0.5*10 = 18.0682
	local m1380 = ((30 - 90) / 660 + (10 - 30) / 120) / 2
	t.near(r.brightness, 0.5 * 30 + 0.125 * 120 * m1380 + 0.5 * 10, 1e-9)
end)

t.test("punti non ordinati: stesso risultato dei punti ordinati, input non modificato", function()
	local sorted = cases.default_day
	local shuffled = { sorted[4], sorted[1], sorted[5], sorted[3], sorted[2] }
	local snapshot = {}
	for i, p in ipairs(shuffled) do snapshot[i] = p.t end
	for minute = 0, 1439, 7 do
		t.near(ev(shuffled, minute).brightness, ev(sorted, minute).brightness, 1e-9)
		t.near(ev(shuffled, minute).cct, ev(sorted, minute).cct, 1e-9)
	end
	for i, p in ipairs(shuffled) do t.eq(p.t, snapshot[i], "input modificato") end
end)

t.test("3 punti e 10 punti", function()
	local pts10 = {}
	for i = 1, 10 do
		pts10[i] = { t = i * 140, brightness = (i * 37) % 101, cct = 1600 + (i * 479) % 4900 }
	end
	local c10 = assert(curve.prepare(pts10))
	for _, p in ipairs(pts10) do
		local r = c10:evaluate(p.t)
		t.near(r.brightness, p.brightness, 1e-9)
		t.near(r.cct, p.cct, 1e-9)
	end
	for minute = 0, 1439 do
		local r = c10:evaluate(minute)
		t.truthy(r.brightness >= 0 and r.brightness <= 100)
		t.truthy(r.cct >= 1600 and r.cct <= 6500)
	end
	t.truthy(curve.prepare(cases.three_point.points) ~= nil)
end)

t.test("due punti identici: fusi, nessuna divisione per zero", function()
	local pts = {
		{ t = 300, brightness = 40, cct = 3000 },
		{ t = 300, brightness = 40, cct = 3000 },
		{ t = 900, brightness = 80, cct = 5000 },
	}
	for minute = 0, 1439, 5 do
		local r = ev(pts, minute)
		t.truthy(r.brightness == r.brightness, "NaN a t=" .. minute) -- NaN ~= NaN
		t.truthy(r.brightness >= 40 - 1e-9 and r.brightness <= 80 + 1e-9)
	end
	-- stesso t con valori diversi: vince l'ultimo
	local r = ev({ { t = 300, brightness = 10, cct = 2000 }, { t = 300, brightness = 70, cct = 4000 },
		{ t = 900, brightness = 70, cct = 4000 } }, 300)
	t.near(r.brightness, 70, 1e-9)
	-- 1440 coincide con 0
	local r2 = ev({ { t = 0, brightness = 20, cct = 2000 }, { t = 1440, brightness = 60, cct = 3000 },
		{ t = 720, brightness = 60, cct = 3000 } }, 0)
	t.near(r2.brightness, 60, 1e-9)
end)

t.test("un solo punto: curva costante; due punti: ok", function()
	local r = ev({ { t = 500, brightness = 42, cct = 3300 } }, 1234)
	t.near(r.brightness, 42, 1e-9)
	t.near(r.cct, 3300, 1e-9)
	local two = { { t = 360, brightness = 10, cct = 2000 }, { t = 1080, brightness = 90, cct = 6000 } }
	for minute = 0, 1439, 10 do
		local x = ev(two, minute)
		t.truthy(x.brightness >= 10 - 1e-9 and x.brightness <= 90 + 1e-9)
	end
	t.near(ev(two, 360).brightness, 10, 1e-9)
	t.near(ev(two, 1080).brightness, 90, 1e-9)
end)

t.test("clamp di brightness (0..100) e CCT (1600..6500)", function()
	local pts = {
		{ t = 0,   brightness = -20, cct = 900 },
		{ t = 600, brightness = 150, cct = 9000 },
	}
	t.near(ev(pts, 0).brightness, 0, 1e-9)
	t.near(ev(pts, 0).cct, 1600, 1e-9)
	t.near(ev(pts, 600).brightness, 100, 1e-9)
	t.near(ev(pts, 600).cct, 6500, 1e-9)
	for minute = 0, 1439, 3 do
		local r = ev(pts, minute)
		t.truthy(r.brightness >= 0 and r.brightness <= 100)
		t.truthy(r.cct >= 1600 and r.cct <= 6500)
	end
end)

t.test("input non valido => nil + messaggio", function()
	local r, err = curve.evaluate({}, 0)
	t.eq(r, nil); t.truthy(type(err) == "string")
	t.eq((curve.evaluate(nil, 0)), nil)
	t.eq((curve.evaluate({ { t = 1, brightness = 1 } }, 0)), nil)
	t.eq((curve.prepare({ { t = "x", brightness = 1, cct = 2000 } })), nil)
end)

t.test("velocita': 20000 valutazioni su curva preparata in meno di 1 s", function()
	local c = assert(curve.prepare(cases.default_day))
	local start = os.clock()
	for i = 1, 20000 do c:evaluate(i % 1440) end
	local elapsed = os.clock() - start
	t.truthy(elapsed < 1, "tempo: " .. elapsed .. " s")
end)

-- ---------------------------------------------------------------- samples (la webview disegna la STESSA curva)
t.test("samples: 144 campioni a passo 10 min, t = 0..1430, identici a evaluate()", function()
	local c = assert(curve.prepare(cases.default_day))
	local samples = assert(c:samples(10))
	t.eq(#samples, 144)
	t.eq(samples[1].t, 0)
	t.eq(samples[144].t, 1430)
	for i, smp in ipairs(samples) do
		t.eq(smp.t, (i - 1) * 10)
		local v = c:evaluate(smp.t)
		t.eq(smp.brightness, v.brightness, "brightness a t=" .. smp.t)
		t.eq(smp.cct, v.cct, "cct a t=" .. smp.t)
	end
end)

t.test("samples: passo di default 10, altri passi, passo non valido", function()
	local c = assert(curve.prepare(cases.three_point.points))
	t.eq(#assert(c:samples()), 144)
	t.eq(#assert(c:samples(15)), 96)
	t.eq(#assert(c:samples(60)), 24)
	t.eq(#assert(c:samples(7)), 206)        -- ceil(1440 / 7)
	t.eq((c:samples(0)), nil)
	t.eq((c:samples(-5)), nil)
	t.eq((c:samples("x")), nil)
end)

t.test("samples: passa dai valori noti (3 punti a mano) e vale anche per una curva costante", function()
	local c = assert(curve.prepare(cases.three_point.points))
	local smp = assert(c:samples(10))
	-- t = 240 e 720 hanno i valori calcolati a mano nelle fixture
	t.near(smp[25].brightness, 18.75, 1e-9)   -- t = 240
	t.near(smp[73].brightness, 81.25, 1e-9)   -- t = 720
	local flat = assert(curve.prepare({ { t = 500, brightness = 42, cct = 3300 } }))
	for _, x in ipairs(assert(flat:samples(10))) do
		t.near(x.brightness, 42, 1e-9)
	end
end)

t.finish()
