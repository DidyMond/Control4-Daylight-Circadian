-- Test di libs/json.lua
local t = require "tests.support.harness"
local json = require "libs.json"

t.test("encode: scalari, stringhe con escape, controlli", function()
	t.eq(json.encode(1), "1")
	t.eq(json.encode(-12), "-12")
	t.eq(json.encode(0.5), "0.5")
	t.eq(json.encode(true), "true")
	t.eq(json.encode("a\"b\\c\n"), '"a\\"b\\\\c\\n"')
	t.eq(json.encode("\1"), '"\\u0001"')
	t.eq(json.encode("è"), '"è"')                -- UTF-8 passa invariato
	t.eq(json.encode(json.null), "null")
	t.eq(json.encode(0 / 0), "null")             -- NaN
	t.eq(json.encode(math.huge), "null")
end)

t.test("encode: array, oggetti (chiavi ordinate), vuoti espliciti, annidamento", function()
	t.eq(json.encode({ 1, 2, 3 }), "[1,2,3]")
	t.eq(json.encode({ b = 1, a = { 1, { x = true } } }), '{"a":[1,{"x":true}],"b":1}')
	t.eq(json.encode({}), "[]")
	t.eq(json.encode(json.object({})), "{}")
	t.eq(json.encode(json.array({})), "[]")
	t.eq(json.encode({ list = json.array({}), meta = json.object({}) }), '{"list":[],"meta":{}}')
end)

t.test("encode: numeri con punto decimale anche con locale a virgola; interi senza .0", function()
	t.eq(json.encode(3), "3")
	t.eq(json.encode(3.0), "3")
	t.eq(json.encode(0.3333333333333333), "0.33333333333333")
	t.eq(json.encode(1e20), "1e+20")
	t.eq(json.encode(-0.000125), "-0.000125")
end)

t.test("encode: errori su tipi non serializzabili e chiavi non stringa", function()
	t.eq(pcall(json.encode, { f = print }), false)
	t.eq(pcall(json.encode, { [1] = 1, [3] = 3 }), false)
end)

t.test("decode: scalari, array, oggetti, annidamento", function()
	t.eq(json.decode("42"), 42)
	t.eq(json.decode(" -7 "), -7)
	t.near(json.decode("2.5"), 2.5, 1e-12)
	t.near(json.decode("-3e2"), -300, 1e-9)
	t.near(json.decode("1E-2"), 0.01, 1e-12)
	t.eq(json.decode("true"), true)
	t.eq(json.decode("false"), false)
	t.eq(json.is_null(json.decode("null")), true)
	t.eq(json.decode('"x"'), "x")
	local v = assert(json.decode('{"a":[1,2,{"b":"c"}],"d":{}}'))
	t.eq(v.a[1], 1); t.eq(v.a[3].b, "c"); t.eq(next(v.d), nil)
	local arr = assert(json.decode("[]"))
	t.eq(#arr, 0)
end)

t.test("decode: escape e \\u con coppie surrogate (UTF-8)", function()
	t.eq(json.decode('"a\\n\\t\\"\\\\\\/"'), 'a\n\t"\\/')
	t.eq(json.decode('"\\u00e8"'), "è")
	t.eq(json.decode('"\\u20ac"'), "€")
	t.eq(json.decode('"\\ud83d\\ude00"'), "\240\159\152\128") -- U+1F600
end)

t.test("roundtrip: encode(decode(x)) e decode(encode(x))", function()
	local doc = { v = 1, name = "Camera \"Zeta\"", pts = { { 0, 10.5, 2700 }, { 600, 80, 5200 } }, ok = true,
		nested = { a = { b = { c = "d" } } }, empty = json.array({}) }
	local text = json.encode(doc)
	local back = assert(json.decode(text))
	t.eq(back.name, doc.name)
	t.near(back.pts[1][2], 10.5, 1e-12)
	t.eq(json.encode(back), text)
end)

t.test("decode: errori (JSON non valido) => nil + messaggio, mai eccezioni", function()
	for _, bad in ipairs({ "", "{", "[1,]", "{\"a\"}", "{a:1}", "01", "1-2", "1.", "\"abc", "[1 2]", "tru",
		"{\"a\":1,}", "\"\\x\"", "\"\\u12\"", "[1] x", "nul", "-" }) do
		local v, err = json.decode(bad)
		t.eq(v, nil, "input: " .. bad)
		t.truthy(type(err) == "string", "messaggio per: " .. bad)
	end
	t.eq(json.decode(nil), nil)
	t.eq(json.decode(42), nil)
end)

t.test("decode: limiti (profondita', dimensione)", function()
	local deep = string.rep("[", 60) .. string.rep("]", 60)
	t.eq(json.decode(deep), nil)
	local ok = string.rep("[", 30) .. string.rep("]", 30)
	t.truthy(json.decode(ok) ~= nil)
	t.eq(json.decode(string.rep("1", 10), 5), nil)
end)

t.test("decode non dipende dal locale: nessun tonumber sui decimali (frazioni lunghe esatte)", function()
	t.near(json.decode("0.1234567890123"), 0.1234567890123, 1e-15)
	t.near(json.decode("123.456"), 123.456, 1e-12)
end)

t.finish()
