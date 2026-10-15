-- ============================================================
-- libs/curve.lua - interpolazione monotone cubic degli switchpoint
--
-- Lua 5.1 puro, nessun riferimento a C4, senza stato globale.
--
-- Metodo: interpolazione cubica di Hermite monotona di Fritsch-Carlson.
--   F. N. Fritsch, R. E. Carlson, "Monotone Piecewise Cubic Interpolation",
--   SIAM J. Numer. Anal. 17(2), 1980.
--   https://en.wikipedia.org/wiki/Monotone_cubic_interpolation
-- Su ogni segmento [x_k, x_k+1], con h = x_k+1 - x_k e s = (x - x_k)/h:
--   y = h00(s)*y_k + h10(s)*h*m_k + h01(s)*y_k+1 + h11(s)*h*m_k+1
--   h00 = 2s^3 - 3s^2 + 1   h10 = s^3 - 2s^2 + s
--   h01 = -2s^3 + 3s^2      h11 = s^3 - s^2
-- Tangenti m_k:
--   1. secanti d_k = (y_k+1 - y_k) / h_k;
--   2. m_k = (d_k-1 + d_k)/2 se d_k-1 e d_k hanno lo stesso segno, altrimenti 0
--      (massimi/minimi locali piatti);
--   3. se d_k = 0 allora m_k = m_k+1 = 0; altrimenti con a = m_k/d_k,
--      b = m_k+1/d_k, se a^2 + b^2 > 9 si scalano m_k, m_k+1 di 3/sqrt(a^2+b^2).
-- Con questi passi la curva e' monotona dove lo sono i dati e non supera mai
-- i valori dei punti vicini (niente overshoot).
--
-- Giornata ciclica: l'ultimo switchpoint si collega al primo del giorno dopo
-- (+1440 min). Le tangenti si calcolano su tre copie dei nodi (-1440, 0,
-- +1440), cosi' ogni nodo reale ha i vicini corretti attraverso la mezzanotte.
--
-- Switchpoint: { t = minuti da mezzanotte, brightness = 0..100, cct = kelvin }.
-- Brightness e CCT hanno ciascuna la propria curva (stesse ascisse).
-- ============================================================

local M = {}

M.DAY_MINUTES = 1440
M.BRIGHTNESS_MIN, M.BRIGHTNESS_MAX = 0, 100
M.CCT_MIN, M.CCT_MAX = 1600, 6500

local floor, sqrt = math.floor, math.sqrt
local DAY = M.DAY_MINUTES

local function wrap(x, period)
	return x - floor(x / period) * period
end

local function clamp(v, lo, hi)
	if v < lo then return lo end
	if v > hi then return hi end
	return v
end

-- Tangenti di Fritsch-Carlson per i nodi (xs, ys) crescenti (n >= 2).
local function tangents(xs, ys)
	local n = #xs
	local d, m = {}, {}
	for k = 1, n - 1 do
		d[k] = (ys[k + 1] - ys[k]) / (xs[k + 1] - xs[k])
	end
	m[1] = d[1]
	m[n] = d[n - 1]
	for k = 2, n - 1 do
		if d[k - 1] * d[k] <= 0 then
			m[k] = 0
		else
			m[k] = (d[k - 1] + d[k]) / 2
		end
	end
	for k = 1, n - 1 do
		if d[k] == 0 then
			m[k], m[k + 1] = 0, 0
		else
			local a, b = m[k] / d[k], m[k + 1] / d[k]
			local s = a * a + b * b
			if s > 9 then
				local tau = 3 / sqrt(s)
				m[k] = tau * a * d[k]
				m[k + 1] = tau * b * d[k]
			end
		end
	end
	return m
end

-- Costruisce i dati della curva (usata da M.prepare). Punti non ordinati: si ordinano internamente (l'input non e' modificato).
-- t fuori da [0, 1440) viene riportato nel giorno. Due punti con lo stesso t
-- (dopo il riporto) si fondono: vince l'ultimo nell'ordine di input.
local function build(points)
	if type(points) ~= "table" or #points == 0 then
		return nil, "nessuno switchpoint"
	end

	local by_t, ts = {}, {}
	for i = 1, #points do
		local p = points[i]
		if type(p) ~= "table" or type(p.t) ~= "number"
			or type(p.brightness) ~= "number" or type(p.cct) ~= "number" then
			return nil, "switchpoint " .. i .. " non valido (servono t, brightness, cct numerici)"
		end
		local t = wrap(p.t, DAY)
		if by_t[t] == nil then ts[#ts + 1] = t end
		by_t[t] = { brightness = p.brightness, cct = p.cct }
	end
	table.sort(ts)

	local n = #ts
	local curve = { n = n }

	if n == 1 then -- un solo punto: curva costante
		local p = by_t[ts[1]]
		curve.constant = {
			brightness = clamp(p.brightness, M.BRIGHTNESS_MIN, M.BRIGHTNESS_MAX),
			cct = clamp(p.cct, M.CCT_MIN, M.CCT_MAX),
		}
		return curve
	end

	-- tre copie: [-1440, 0, +1440]
	local xs, yb, yc = {}, {}, {}
	for copy = 0, 2 do
		for i = 1, n do
			local idx = copy * n + i
			local p = by_t[ts[i]]
			xs[idx] = ts[i] + (copy - 1) * DAY
			yb[idx] = p.brightness
			yc[idx] = p.cct
		end
	end

	curve.xs, curve.yb, curve.yc = xs, yb, yc
	curve.mb, curve.mc = tangents(xs, yb), tangents(xs, yc)
	curve.first = ts[1]
	return curve
end

local function hermite(x0, x1, y0, y1, m0, m1, x)
	local h = x1 - x0
	local s = (x - x0) / h
	local s2 = s * s
	local s3 = s2 * s
	return (2 * s3 - 3 * s2 + 1) * y0
		+ (s3 - 2 * s2 + s) * h * m0
		+ (-2 * s3 + 3 * s2) * y1
		+ (s3 - s2) * h * m1
end

-- curve:evaluate(t) -> { brightness, cct }, t in minuti (qualsiasi valore:
-- e' riportato nel giorno). Valori clampati in 0..100 e 1600..6500.
local function evaluate_prepared(curve, t)
	if curve.constant then
		return { brightness = curve.constant.brightness, cct = curve.constant.cct }
	end

	local n, xs = curve.n, curve.xs
	local x = curve.first + wrap(t - curve.first, DAY) -- in [first, first + 1440)

	-- segmento nella copia centrale: nodi n+1 .. 2n+1
	local k = n + 1
	while k < 2 * n and xs[k + 1] <= x do
		k = k + 1
	end

	local b = hermite(xs[k], xs[k + 1], curve.yb[k], curve.yb[k + 1], curve.mb[k], curve.mb[k + 1], x)
	local c = hermite(xs[k], xs[k + 1], curve.yc[k], curve.yc[k + 1], curve.mc[k], curve.mc[k + 1], x)
	return {
		brightness = clamp(b, M.BRIGHTNESS_MIN, M.BRIGHTNESS_MAX),
		cct = clamp(c, M.CCT_MIN, M.CCT_MAX),
	}
end

-- Metodo sulle curve preparate: curve:evaluate(t)
M.Curve = { evaluate = evaluate_prepared }
M.Curve.__index = M.Curve

-- curve:samples([step_min]) -> { {t, brightness, cct}, ... }
-- Campioni della curva a passo fisso sull'intera giornata, t = 0, step, 2*step, ... < 1440
-- (default 10 min = 144 campioni). E' quello che la webview disegna: UI e motore usano
-- la STESSA monotone cubic, senza reimplementarla in JS. Ogni campione e' esattamente
-- curve:evaluate(t).
function M.Curve.samples(curve, step_min)
	step_min = step_min or 10
	if type(step_min) ~= "number" or step_min <= 0 then return nil, "passo non valido" end
	local out = {}
	local t = 0
	while t < DAY - 1e-9 do
		local v = curve:evaluate(t)
		out[#out + 1] = { t = t, brightness = v.brightness, cct = v.cct }
		t = t + step_min
	end
	return out
end

-- prepare(points) -> curva pronta per evaluate (da riusare a ogni tick), oppure
-- nil, "messaggio" se i punti non sono validi.
function M.prepare(points)
	local curve, err = build(points)
	if not curve then return nil, err end
	return setmetatable(curve, M.Curve)
end

-- evaluate(points, t) -> { brightness, cct } oppure nil, "messaggio".
-- Comodo per chiamate singole; nel tick usa prepare() una volta e poi
-- curve:evaluate(t).
function M.evaluate(points, t)
	local curve, err = M.prepare(points)
	if not curve then return nil, err end
	return curve:evaluate(t)
end

return M
