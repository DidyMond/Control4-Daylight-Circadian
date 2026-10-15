-- Casi per tests/test_curve.lua (minuti da mezzanotte).

return {
	-- 3 punti con valori lineari. Con la giornata ciclica i due estremi hanno
	-- tangente 0 (massimo/minimo locale) e il nodo centrale ha tangente pari
	-- alla secante: i valori a meta' segmento si calcolano a mano con Hermite
	-- (s = 0.5: h00 = h01 = 0.5, h10 = 0.125, h11 = -0.125):
	--   segmento 0->480:     y = 0.5*0   + 0.5*50  - 0.125*480*(50/480) = 18.75
	--   segmento 480->960:   y = 0.5*50  + 0.5*100 + 0.125*480*(50/480) = 81.25
	--   segmento 960->1440:  tangenti 0 ai due capi -> media = 50
	-- La CCT (2000, 4000, 6000 K) e' la stessa forma scalata: 2000 + 40*b.
	three_point = {
		points = {
			{ t = 0,   brightness = 0,   cct = 2000 },
			{ t = 480, brightness = 50,  cct = 4000 },
			{ t = 960, brightness = 100, cct = 6000 },
		},
		expected = {
			{ t = 240, brightness = 18.75, cct = 2750 },
			{ t = 720, brightness = 81.25, cct = 5250 },
			{ t = 1200, brightness = 50,   cct = 4000 },
		},
	},

	-- Valori di default del manifest pubblico Janus (solo orari fissi):
	-- 00:30 10%/2600K, 07:00 20/2900, 08:00 50/4000, 13:00 80/5200, 20:00 60/3200.
	default_day = {
		{ t = 30,   brightness = 10, cct = 2600 },
		{ t = 420,  brightness = 20, cct = 2900 },
		{ t = 480,  brightness = 50, cct = 4000 },
		{ t = 780,  brightness = 80, cct = 5200 },
		{ t = 1200, brightness = 60, cct = 3200 },
	},
}
