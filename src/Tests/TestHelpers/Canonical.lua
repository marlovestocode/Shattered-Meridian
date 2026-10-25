--!strict
--[[
	Canonical.lua

	Owns: one deterministic string for any plain Luau value, and a short digest of it -- for specs that must assert a
	structure is BYTE-IDENTICAL before and after a refactor (the profile round-trip corpus, Tests/PlayerData/
	ProfileRoundTrip.spec.lua) without depending on table iteration order.

	Tables are written with their keys sorted (numbers before strings, then by value), numbers with 17 significant digits
	(so 0.1 and 0.10000000000000002 differ), NaN and +-inf by name, strings length-prefixed (so a string can never be
	mistaken for structure). EnumItems and other userdata are written by their typeof and tostring. A cycle errors.

	Digest is two independent 32-bit rolling hashes of that string, as 16 hex digits: not cryptographic, only a
	fingerprint small enough to store a few hundred of in a fixture. A mismatch says WHICH case drifted, not how; rerun the
	generator against the old commit and diff the Encode output to see how.
]]

local Canonical = {}

local function keyOrder(a: any, b: any): boolean
	local ta, tb = typeof(a), typeof(b)
	if ta ~= tb then
		return ta < tb
	end
	if ta == "number" or ta == "string" then
		return a < b
	end
	return tostring(a) < tostring(b)
end

local function write(value: any, out: { string }, seen: { [any]: boolean }): ()
	local kind = typeof(value)
	if kind == "nil" then
		table.insert(out, "nil")
	elseif kind == "boolean" then
		table.insert(out, if value then "true" else "false")
	elseif kind == "number" then
		if value ~= value then
			table.insert(out, "nan")
		elseif value == math.huge then
			table.insert(out, "inf")
		elseif value == -math.huge then
			table.insert(out, "-inf")
		else
			table.insert(out, string.format("%.17g", value))
		end
	elseif kind == "string" then
		table.insert(out, `s{#value}:{value}`)
	elseif kind == "table" then
		if seen[value] then
			error("Canonical: cycle")
		end
		seen[value] = true
		local keys = {}
		for key in value do
			table.insert(keys, key)
		end
		table.sort(keys, keyOrder)
		table.insert(out, "{")
		for _, key in keys do
			write(key, out, seen)
			table.insert(out, "=")
			write(value[key], out, seen)
			table.insert(out, ",")
		end
		table.insert(out, "}")
		seen[value] = nil
	else
		table.insert(out, `<{kind}:{tostring(value)}>`)
	end
end

function Canonical.Encode(value: any): string
	local out: { string } = {}
	write(value, out, {})
	return table.concat(out)
end

function Canonical.Digest(value: any): string
	local text = Canonical.Encode(value)
	local a, b = 5381, 0
	for index = 1, #text do
		local byte = string.byte(text, index)
		a = (a * 33 + byte) % 4294967296
		b = (b * 65599 + byte + index) % 4294967296
	end
	return string.format("%08x%08x", a, b)
end

-- A deep copy of plain data (tables, primitives), for a spec that feeds the same record to a function that mutates it.
function Canonical.DeepCopy<T>(value: T): T
	if typeof(value) ~= "table" then
		return value
	end
	local copy = {}
	for key, inner in value :: any do
		copy[key] = Canonical.DeepCopy(inner)
	end
	return copy :: any
end

return Canonical
