-- Riferimento esterno per tests/test_sun.lua.
--
-- Fonte: U.S. Naval Observatory, Astronomical Applications API
--   https://aa.usno.navy.mil/api/rstt/oneday?date=<data>&coords=<lat>,<lon>&tz=<offset>
-- (alba "Rise", transito superiore = mezzogiorno solare "Upper Transit",
-- tramonto "Set"), consultata il 2026-10-10. Valori arrotondati al minuto,
-- nel fuso `tz` indicato (ore da UTC). Lo USNO usa lo stesso zenith di
-- alba/tramonto (90.833 gradi: rifrazione 34' + raggio solare 16').
--
-- Nota: un'altra API pubblica provata (sunrise-sunset.org) da' alba/tramonto
-- 1-2 minuti piu' larghi (zenith diverso) e non e' stata usata.
--
-- Orari "HH:MM" -> si convertono in minuti con tests.support.harness.hhmm().
-- `tz` e' sempre l'offset da UTC dell'orologio per quella data (DST incluso).
-- `sunset_wraps = true`: il tramonto cade dopo la mezzanotte (24:04 -> 00:04);
-- lo USNO elenca "Set 00:04" nello stesso giorno (e' il tramonto della sera
-- prima, numericamente identico), quindi il confronto e' circolare.

return {
	-- Milano (coordinate fisse del test: lat 45.0, lon 9.0), UTC e CEST
	{ name = "Milano equinozio marzo (UTC)",   lat = 45.0, lon = 9.0, date = { 2026, 3, 20 },  tz = 0,
	  sunrise = "05:27", noon = "11:31", sunset = "17:36" },
	{ name = "Milano solstizio giugno (UTC)",  lat = 45.0, lon = 9.0, date = { 2026, 6, 21 },  tz = 0,
	  sunrise = "03:37", noon = "11:26", sunset = "19:14" },
	{ name = "Milano solstizio giugno (UTC+2)", lat = 45.0, lon = 9.0, date = { 2026, 6, 21 }, tz = 2,
	  sunrise = "05:37", noon = "13:26", sunset = "21:14" },
	{ name = "Milano equinozio settembre (UTC)", lat = 45.0, lon = 9.0, date = { 2026, 9, 23 }, tz = 0,
	  sunrise = "05:12", noon = "11:16", sunset = "17:20" },
	{ name = "Milano solstizio dicembre (UTC)", lat = 45.0, lon = 9.0, date = { 2026, 12, 21 }, tz = 0,
	  sunrise = "06:59", noon = "11:22", sunset = "15:45" },

	-- Sydney (emisfero sud, longitudine est alta)
	{ name = "Sydney giugno (UTC+10)",    lat = -33.8688, lon = 151.2093, date = { 2026, 6, 21 },  tz = 10,
	  sunrise = "07:00", noon = "11:57", sunset = "16:54" },
	{ name = "Sydney dicembre (UTC+11)",  lat = -33.8688, lon = 151.2093, date = { 2026, 12, 21 }, tz = 11,
	  sunrise = "05:41", noon = "12:53", sunset = "20:05" },

	-- New York (longitudine ovest, offset negativo)
	{ name = "New York giugno (UTC-4)",   lat = 40.7128, lon = -74.0060, date = { 2026, 6, 21 },  tz = -4,
	  sunrise = "05:25", noon = "12:58", sunset = "20:31" },

	-- Reykjavik (64.1N, longitudine ovest). NON e' polar day: oltre ~65.7N serve
	-- per il sole di mezzanotte; qui il sole tramonta alle 24:04 e sorge alle 02:55.
	{ name = "Reykjavik giugno (UTC+0, tramonto dopo mezzanotte)", lat = 64.1466, lon = -21.9426,
	  date = { 2026, 6, 21 }, tz = 0, sunrise = "02:55", noon = "13:30", sunset = "00:04", sunset_wraps = true },
	{ name = "Reykjavik dicembre (UTC+0)", lat = 64.1466, lon = -21.9426, date = { 2026, 12, 21 }, tz = 0,
	  sunrise = "11:22", noon = "13:26", sunset = "15:29" },

	-- Auckland (emisfero sud, longitudine 174.76E, NZDT = UTC+13 con DST attiva)
	{ name = "Auckland ottobre (UTC+13, DST)", lat = -36.85, lon = 174.76, date = { 2026, 10, 10 }, tz = 13,
	  sunrise = "06:44", noon = "13:08", sunset = "19:32" },
}
