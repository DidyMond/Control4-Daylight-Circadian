-- ============================================================
-- libs/sun.lua - alba, mezzogiorno solare, tramonto, mezzanotte solare
--
-- Lua 5.1 puro, nessun riferimento a C4, deterministico e senza stato.
--
-- Algoritmo: NOAA Solar Calculator (semplificato), a sua volta basato su
-- Jean Meeus, "Astronomical Algorithms" (2a ed.), cap. 7, 12, 22, 25, 28.
--   Dettagli: https://gml.noaa.gov/grad/solcalc/calcdetails.html
--   Formule:  https://gml.noaa.gov/grad/solcalc/solareqns.PDF
--
-- Passi:
--   1. Giorno giuliano JD e secoli giuliani T = (JD - 2451545) / 36525.
--   2. Longitudine media L0 e anomalia media M del sole, eccentricita' e
--      dell'orbita, equazione del centro C -> longitudine apparente.
--   3. Obliquita' corretta -> declinazione solare: sin(d) = sin(eps)*sin(lambda).
--   4. Equazione del tempo (minuti):
--        E = 4*deg( y*sin2L0 - 2e*sinM + 4e*y*sinM*cos2L0
--                   - 0.5*y^2*sin4L0 - 1.25*e^2*sin2M ),   y = tan^2(eps/2)
--   5. Angolo orario alba/tramonto (zenith 90.833 gradi = 90 + 50' di
--      rifrazione e raggio solare):
--        cos(H) = cos(zenith)/(cos(lat)*cos(d)) - tan(lat)*tan(d)
--   6. Tempi in minuti UTC (longitudine positiva a EST):
--        mezzogiorno  = 720 - 4*lon - E
--        alba         = 720 - 4*(lon + H) - E
--        tramonto     = 720 - 4*(lon - H) - E
--      con 2-3 iterazioni: declinazione e E vengono ricalcolate all'istante
--      dell'evento (come fa il calcolatore NOAA) per restare entro ~1 minuto.
--
-- Uscita: minuti da mezzanotte, in [0, 1440). Due modalita':
--   1. calculate(lat, lon, anno, mese, giorno)
--        senza offset: TEMPO SOLARE MEDIO del sito (offset = lon/15), senza
--        fuso ne' DST; il mezzogiorno solare cade vicino alle 12:00 (720 - E).
--   2. calculate(lat, lon, anno, mese, giorno, utc_offset_hours)
--        ORA DELL'OROLOGIO LOCALE: i minuti sono letti sull'orologio con
--        quell'offset da UTC (fuso + DST di quel giorno, ore, anche frazionarie:
--        +2, -4, +5.5, +13). E' la modalita' da usare nel controller, perche'
--        deve coincidere con l'orologio del sistema Control4.
--        Esempio (Milano, 21 giugno, CEST): calculate(45.0, 9.0, 2026, 6, 21, 2)
--        -> mezzogiorno solare ~13:26. Senza offset sarebbe ~12:02.
--      L'offset del sistema si ricava con libs/clock.lua
--      (clock.utc_offset_hours_for_date). Un offset "0" significa UTC, non
--      "senza offset": per il tempo solare medio si omette l'argomento.
--   Se l'evento cade oltre la mezzanotte dell'orologio (es. tramonto delle
--   24:04 a 64N in giugno con offset UTC+0) il valore e' riportato nel giorno
--   (00:04): la curva e' ciclica e ordina i punti da se'.
-- ============================================================

local M = {}

M.ZENITH = 90.833 -- gradi

local rad, deg = math.rad, math.deg
local sin, cos, tan = math.sin, math.cos, math.tan
local floor = math.floor

local function wrap(x, period)
	return x - floor(x / period) * period
end

-- Giorno giuliano alle 0h UT del giorno gregoriano dato (formula NOAA / Meeus).
local function julian_day(year, month, day)
	if month <= 2 then
		year = year - 1
		month = month + 12
	end
	local a = floor(year / 100)
	local b = 2 - a + floor(a / 4)
	return floor(365.25 * (year + 4716)) + floor(30.6001 * (month + 1)) + day + b - 1524.5
end

-- Declinazione (radianti) ed equazione del tempo (minuti) al giorno giuliano jd.
local function sun_params(jd)
	local t = (jd - 2451545.0) / 36525.0

	local l0 = wrap(280.46646 + t * (36000.76983 + t * 0.0003032), 360)
	local m = 357.52911 + t * (35999.05029 - 0.0001537 * t)
	local e = 0.016708634 - t * (0.000042037 + 0.0000001267 * t)

	local mr = rad(m)
	local c = sin(mr) * (1.914602 - t * (0.004817 + 0.000014 * t))
		+ sin(2 * mr) * (0.019993 - 0.000101 * t)
		+ sin(3 * mr) * 0.000289

	local true_long = l0 + c
	local omega = 125.04 - 1934.136 * t
	local app_long = true_long - 0.00569 - 0.00478 * sin(rad(omega))

	local mean_obliq = 23 + (26 + (21.448 - t * (46.815 + t * (0.00059 - t * 0.001813))) / 60) / 60
	local obliq = mean_obliq + 0.00256 * cos(rad(omega))

	local decl = math.asin(sin(rad(obliq)) * sin(rad(app_long)))

	local y = tan(rad(obliq) / 2)
	y = y * y
	local l0r = rad(l0)
	local eqtime = 4 * deg(
		y * sin(2 * l0r)
		- 2 * e * sin(mr)
		+ 4 * e * y * sin(mr) * cos(2 * l0r)
		- 0.5 * y * y * sin(4 * l0r)
		- 1.25 * e * e * sin(2 * mr))

	return decl, eqtime
end

-- Angolo orario (gradi) all'alba/tramonto; nil + "day"/"night" se il sole non
-- attraversa l'orizzonte (sole di mezzanotte / notte polare).
local function hour_angle(lat_rad, decl)
	local denom = cos(lat_rad) * cos(decl)
	local cosh = cos(rad(M.ZENITH)) / denom - tan(lat_rad) * tan(decl)
	if cosh > 1 then return nil, "night" end
	if cosh < -1 then return nil, "day" end
	return deg(math.acos(cosh))
end

local DAYS_IN_MONTH = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }

local function valid_date(year, month, day)
	if month ~= floor(month) or day ~= floor(day) or year ~= floor(year) then return false end
	if month < 1 or month > 12 or day < 1 then return false end
	local dim = DAYS_IN_MONTH[month]
	if month == 2 and (year % 4 == 0 and (year % 100 ~= 0 or year % 400 == 0)) then
		dim = 29
	end
	return day <= dim
end

-- calculate(lat, lon, year, month, day [, utc_offset_hours])
--   lat in gradi (+N), lon in gradi (+E), data gregoriana.
-- Ritorna { sunrise, solar_noon, sunset, solar_midnight, polar } oppure
-- nil, "messaggio" se gli argomenti non sono validi.
--   * valori in minuti da mezzanotte, in [0, 1440), nel fuso scelto (vedi
--     intestazione: senza `utc_offset_hours` = tempo solare medio del sito,
--     con `utc_offset_hours` = ora dell'orologio locale);
--   * solar_midnight = mezzogiorno - 720 (se negativo + 1440): e' la mezzanotte
--     solare piu' vicina a inizio giornata;
--   * sunrise/sunset sono nil e `polar` e' "day" (sole di mezzanotte) o "night"
--     (notte polare) alle latitudini estreme; altrimenti `polar` e' nil.
function M.calculate(lat, lon, year, month, day, utc_offset_hours)
	if type(lat) ~= "number" or type(lon) ~= "number"
		or type(year) ~= "number" or type(month) ~= "number" or type(day) ~= "number" then
		return nil, "argomenti numerici richiesti"
	end
	if lat < -90 or lat > 90 then return nil, "latitudine fuori range (-90..90)" end
	if lon < -180 or lon > 180 then return nil, "longitudine fuori range (-180..180)" end
	if not valid_date(year, month, day) then return nil, "data non valida" end
	if utc_offset_hours ~= nil and type(utc_offset_hours) ~= "number" then
		return nil, "utc_offset_hours deve essere un numero"
	end

	local offset_min = (utc_offset_hours or (lon / 15)) * 60
	-- ai poli esatti cos(lat) = 0: resta un valore finito
	local lat_rad = rad(math.max(-89.9999, math.min(89.9999, lat)))
	local jd0 = julian_day(year, month, day)

	-- mezzogiorno solare (minuti UTC)
	local noon = 720 - 4 * lon
	for _ = 1, 3 do
		local _, eq = sun_params(jd0 + noon / 1440)
		noon = 720 - 4 * lon - eq
	end

	local function event(sign)
		local t = noon
		for _ = 1, 3 do
			local decl, eq = sun_params(jd0 + t / 1440)
			local h, polar = hour_angle(lat_rad, decl)
			if not h then return nil, polar end
			t = 720 - 4 * (lon + sign * h) - eq
		end
		return t
	end

	local rise, polar = event(1)
	local set = event(-1)

	local noon_local = wrap(noon + offset_min, 1440)
	local midnight = noon_local - 720
	if midnight < 0 then midnight = midnight + 1440 end

	return {
		sunrise = rise and wrap(rise + offset_min, 1440) or nil,
		solar_noon = noon_local,
		sunset = set and wrap(set + offset_min, 1440) or nil,
		solar_midnight = midnight,
		polar = (not rise) and polar or nil,
	}
end

-- Minuti da mezzanotte -> "HH:MM" (arrotondato al minuto), per log e test.
function M.format_minutes(minutes)
	if minutes == nil then return "--:--" end
	local total = floor(wrap(minutes, 1440) + 0.5) % 1440
	return string.format("%02d:%02d", floor(total / 60), total % 60)
end

return M
