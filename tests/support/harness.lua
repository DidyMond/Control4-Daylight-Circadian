-- ============================================================
-- tests/support/harness.lua - mini harness per i test offline (Lua 5.1)
--
-- Uso (ogni file tests/test_*.lua parte dalla radice del repo):
--   local t = require "tests.support.harness"
--   t.test("nome", function() t.eq(a, b) end)
--   t.finish()   -- stampa il riepilogo, exit code != 0 se qualcosa e' fallito
-- ============================================================

-- print originale: alcuni test sostituiscono print (es. smoke test del driver)
local print = print

local H = {}

local passed, failed = 0, 0

function H.test(name, fn)
	local ok, err = pcall(fn)
	if ok then
		passed = passed + 1
		print("  PASS " .. name)
	else
		failed = failed + 1
		print("  FAIL " .. name .. " -> " .. tostring(err))
	end
end

function H.eq(actual, expected, msg)
	if actual ~= expected then
		error(string.format("%satteso %s, ottenuto %s", msg and (msg .. ": ") or "",
			tostring(expected), tostring(actual)), 2)
	end
end

function H.truthy(value, msg)
	if not value then error(msg or "atteso valore vero", 2) end
end

-- confronto numerico con tolleranza (per i test su curva/sole)
function H.near(actual, expected, tol, msg)
	if type(actual) ~= "number" or math.abs(actual - expected) > tol then
		error(string.format("%satteso %s +/- %s, ottenuto %s", msg and (msg .. ": ") or "",
			tostring(expected), tostring(tol), tostring(actual)), 2)
	end
end

-- confronto fra orari del giorno (minuti): differenza circolare modulo 1440
function H.near_clock(actual, expected, tol, msg)
	local d = math.abs(actual - expected) % 1440
	if type(actual) ~= "number" or math.min(d, 1440 - d) > tol then
		error(string.format("%satteso %s +/- %s (circolare), ottenuto %s", msg and (msg .. ": ") or "",
			tostring(expected), tostring(tol), tostring(actual)), 2)
	end
end

-- "HH:MM" -> minuti da mezzanotte
function H.hhmm(text)
	local h, m = text:match("^(%d+):(%d+)$")
	return tonumber(h) * 60 + tonumber(m)
end

function H.finish()
	print(string.format("  -- %d PASS, %d FAIL", passed, failed))
	os.exit(failed == 0 and 0 or 1)
end

return H
