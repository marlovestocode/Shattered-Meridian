--!strict
--[[
	Schema.lua

	Owns: declarative decoding of data this code did not produce -- a remote argument, a DataStore record, an
	authored-content payload. A shape says what is acceptable; `Schema.Decode(shape, raw)` returns the decoded value
	or the reason it was refused. It is the layer ABOVE Shared/Sanitize.lua: every number goes through
	`Sanitize.ClampNumber` and every string through `Sanitize.BoundedString`, so the NaN trap that module documents is
	closed by construction -- a shape cannot be written that lets a NaN through.

	WHY (coworking plan, 2026-10-25, F1). The server held ~290 hand-written `typeof` checks and 68 hand-written NaN
	checks, one set per validator, because the primitives existed and the assembly did not. Each validator rediscovered
	the same decisions (reject or clamp? first error or all? what is the error called?). Here they are the shape.

	THE COMBINATORS.
	  Boolean, Number(min, max), String(maxLength), NonEmptyString(maxLength?), Enum({ "A", "B" }),
	  EnumItem(Enum.KeyCode), Optional(shape), Default(shape, fallback), Array(shape, maxLength?),
	  Map(keyShape, valueShape, maxEntries?), Record({ { "Field", shape }, ... }), WithReason("Code", shape),
	  Custom(function(raw) -> (value, reason?)), and FieldValue({ Name = shape, ... }) for the one-remote-many-fields
	  pattern (a field NAME and its value, both untrusted).
	Number CLAMPS an out-of-range value and REJECTS a non-number or NaN, exactly `Sanitize.ClampNumber`; String
	TRUNCATES a long string and REJECTS a non-string, exactly `Sanitize.BoundedString` without its fallback. Those two
	choices are the ones every existing validator already made (MoveRegistryManager's "hard-reject on structure, clamp
	on numbers"), so a conversion keeps its answers.

	RECORD FIELDS ARE AN ORDERED LIST, not a map, because the first refusal wins and validators here are specific about
	which one that is (`InvalidAbilityId` before `InvalidAbilityKind`). A Record ignores keys it does not name, so the
	decoded value never carries an unvalidated field. A field whose shape yields nil (an absent Optional) is left out.

	REASONS. A refusal inside a Record or Array is prefixed with its path (`Parkour.SprintMode: expected one of
	Hold, Toggle`). `WithReason("InvalidEffectKind", shape)` replaces that with a fixed code and is not prefixed
	further, for the validators whose callers switch on a stable string.

	TABLES THAT ARE NOT PLAIN DATA ARE REFUSED. A Record, Map or Array fed a table with a metatable is rejected: no
	remote payload or DataStore record can carry one, so one is always a spec or an exploit. Arrays are walked with
	`ipairs` (a hole ends the array, as every existing decoder did); a Map walks `pairs`.

	LAYERING. Requires only Sanitize. Safe for the client (Spine 3 needs it there). Server-only knowledge -- which
	remote, which profile -- lives in Server/Network/Endpoint and Server/Data/ProfileSlice, never here.

	LENIENT READS. A few decoders do not validate, they tolerate -- a legacy record's field is read if it is a number
	and otherwise ignored (MoveRecordCodec). `Schema.IsTable/IsString/IsNumber/IsBoolean/IsFunction/IsVector3` and `NumberOr/StringOr` are
	those reads, named once so the server's `typeof` checks live here and nowhere else. They do not exclude NaN
	(`IsNumber` is `typeof(v) == "number"`); a caller that must should use `Number(...)`.

	Does not own: what a field's bounds are, which fields a domain has, or any Roblox datatype beyond EnumItem.
]]

local Sanitize = require(script.Parent.Sanitize)

local Schema = {}

-- A refusal travelling up: a path-prefixable string, or a fixed code that is passed through untouched.
type Fixed = { Code: string }
type Reason = string | Fixed

export type Shape<T> = (raw: unknown) -> (T?, Reason?)

local function isPlainTable(raw: unknown): boolean
	return typeof(raw) == "table" and getmetatable(raw :: any) == nil
end

local function prefixed(path: string, reason: Reason): Reason
	if typeof(reason) == "table" then
		return reason
	end
	return `{path}.{reason}`
end

local function text(reason: Reason): string
	if typeof(reason) == "table" then
		return (reason :: Fixed).Code
	end
	return reason :: string
end

-- Decode `raw` against `shape`: (value, nil) or (nil, reason). A successful Optional absence is (nil, nil).
function Schema.Decode<T>(shape: Shape<T>, raw: unknown): (T?, string?)
	local value, reason = shape(raw)
	if reason ~= nil then
		return nil, text(reason)
	end
	return value, nil
end

-- Lenient reads --------------------------------------------------------------------------------------------

function Schema.IsTable(value: unknown): boolean
	return typeof(value) == "table"
end

function Schema.IsString(value: unknown): boolean
	return typeof(value) == "string"
end

function Schema.IsNumber(value: unknown): boolean
	return typeof(value) == "number"
end

function Schema.IsBoolean(value: unknown): boolean
	return typeof(value) == "boolean"
end

function Schema.IsFunction(value: unknown): boolean
	return typeof(value) == "function"
end

function Schema.IsVector3(value: unknown): boolean
	return typeof(value) == "Vector3"
end

function Schema.NumberOr(value: unknown, fallback: number): number
	return if typeof(value) == "number" then value :: number else fallback
end

function Schema.StringOr(value: unknown, fallback: string): string
	return if typeof(value) == "string" then value :: string else fallback
end

-- Primitives -----------------------------------------------------------------------------------------------

function Schema.Boolean(raw: unknown): (boolean?, Reason?)
	if typeof(raw) ~= "boolean" then
		return nil, "expected boolean"
	end
	return raw :: boolean, nil
end

function Schema.Number(min: number, max: number): Shape<number>
	return function(raw: unknown): (number?, Reason?)
		local value = Sanitize.ClampNumber(raw, min, max)
		if value == nil then
			return nil, "expected a real number"
		end
		return value, nil
	end
end

function Schema.String(maxLength: number): Shape<string>
	return function(raw: unknown): (string?, Reason?)
		if typeof(raw) ~= "string" then
			return nil, "expected string"
		end
		return Sanitize.BoundedString(raw, maxLength), nil
	end
end

-- A non-empty string, judged BEFORE truncation (truncation cannot empty it), then bounded when `maxLength` is given.
function Schema.NonEmptyString(maxLength: number?): Shape<string>
	return function(raw: unknown): (string?, Reason?)
		if typeof(raw) ~= "string" or (raw :: string) == "" then
			return nil, "expected non-empty string"
		end
		if maxLength then
			return Sanitize.BoundedString(raw, maxLength), nil
		end
		return raw :: string, nil
	end
end

function Schema.Enum(values: { string }): Shape<string>
	local set: { [string]: boolean } = {}
	for _, value in values do
		set[value] = true
	end
	local message = `expected one of {table.concat(values, ", ")}`
	return function(raw: unknown): (string?, Reason?)
		if typeof(raw) ~= "string" or not set[raw :: string] then
			return nil, message
		end
		return raw :: string, nil
	end
end

function Schema.EnumItem(enumType: Enum): Shape<EnumItem>
	return function(raw: unknown): (EnumItem?, Reason?)
		if typeof(raw) ~= "EnumItem" or (raw :: EnumItem).EnumType ~= enumType then
			return nil, `expected {tostring(enumType)}`
		end
		return raw :: EnumItem, nil
	end
end

-- Combinators ----------------------------------------------------------------------------------------------

-- nil passes through as an absent value; anything else must satisfy `shape`.
function Schema.Optional<T>(shape: Shape<T>): Shape<T>
	return function(raw: unknown): (T?, Reason?)
		if raw == nil then
			return nil, nil
		end
		return shape(raw)
	end
end

-- `fallback` when the value is absent OR does not satisfy `shape`: the NORMALISING counterpart of rejecting.
function Schema.Default<T>(shape: Shape<T>, fallback: T): Shape<T>
	return function(raw: unknown): (T?, Reason?)
		local value, reason = shape(raw)
		if reason ~= nil or value == nil then
			return fallback, nil
		end
		return value, nil
	end
end

-- A refusal from `shape` is reported as the fixed `code` instead of a path.
function Schema.WithReason<T>(code: string, shape: Shape<T>): Shape<T>
	local fixed: Fixed = { Code = code }
	return function(raw: unknown): (T?, Reason?)
		local value, reason = shape(raw)
		if reason ~= nil then
			return nil, fixed
		end
		return value, nil
	end
end

-- The refusal a `Custom` shape returns when it defers to a validator that has its own stable error codes: carried up
-- unchanged (never path-prefixed) and surfaced by Decode as the code itself.
function Schema.Failure(code: string): Reason
	return { Code = code }
end

-- A Record for the validators whose answer to "this is not even a table" is a code of their own (`InvalidShape`,
-- `InvalidAbility`, ...) rather than a path: that refusal, and a metatabled table's, are reported as `code`; a field's
-- own fixed code passes through; anything else keeps its path. The shape of nearly every hand-written `Validate` here.
function Schema.CodedRecord(code: string, fields: { { any } }): Shape<{ [string]: any }>
	local record = Schema.Record(fields)
	local fixed: Fixed = { Code = code }
	return function(raw: unknown): ({ [string]: any }?, Reason?)
		if not Schema.IsTable(raw) then
			return nil, fixed
		end
		local value, reason = record(raw)
		if reason ~= nil then
			return nil, if reason == "expected table" then fixed else reason
		end
		return value, nil
	end
end

function Schema.Custom<T>(fn: (raw: unknown) -> (T?, Reason?)): Shape<T>
	return fn
end

function Schema.Array<T>(shape: Shape<T>, maxLength: number?): Shape<{ T }>
	return function(raw: unknown): ({ T }?, Reason?)
		if not isPlainTable(raw) then
			return nil, "expected array"
		end
		local out: { T } = {}
		for index, element in ipairs(raw :: { unknown }) do
			if maxLength and index > maxLength then
				return nil, `more than {maxLength} entries`
			end
			local value, reason = shape(element)
			if reason ~= nil then
				return nil, prefixed(tostring(index), reason)
			end
			table.insert(out, value :: T)
		end
		return out, nil
	end
end

function Schema.Map<K, V>(keyShape: Shape<K>, valueShape: Shape<V>, maxEntries: number?): Shape<{ [K]: V }>
	return function(raw: unknown): ({ [K]: V }?, Reason?)
		if not isPlainTable(raw) then
			return nil, "expected map"
		end
		local out: { [K]: V } = {}
		local count = 0
		for key, element in pairs(raw :: { [unknown]: unknown }) do
			count += 1
			if maxEntries and count > maxEntries then
				return nil, `more than {maxEntries} entries`
			end
			local decodedKey, keyReason = keyShape(key)
			if keyReason ~= nil then
				return nil, prefixed(tostring(key), keyReason)
			end
			local value, reason = valueShape(element)
			if reason ~= nil then
				return nil, prefixed(tostring(key), reason)
			end
			out[decodedKey :: K] = value :: V
		end
		return out, nil
	end
end

-- Fields in order; the first refusal wins. Unnamed keys are dropped.
function Schema.Record(fields: { { any } }): Shape<{ [string]: any }>
	return function(raw: unknown): ({ [string]: any }?, Reason?)
		if not isPlainTable(raw) then
			return nil, "expected table"
		end
		local source = raw :: { [string]: unknown }
		local out: { [string]: any } = {}
		for _, field in fields do
			local name = field[1] :: string
			local shape = field[2] :: Shape<any>
			local value, reason = shape(source[name])
			if reason ~= nil then
				return nil, prefixed(name, reason)
			end
			out[name] = value
		end
		return out, nil
	end
end

-- A (field, value) pair where the field name is untrusted and picks the shape the value is judged by -- the payload
-- of a remote that writes "one of a closed set of preferences". Returns `(field, value, nil)` or `(nil, nil, reason)`.
-- A field absent from `fields` cannot be written whatever a client sends, so retiring one is a deletion there.
function Schema.FieldValue(
	fields: { [string]: Shape<any> }
): (rawField: unknown, rawValue: unknown) -> (string?, any?, string?)
	return function(rawField: unknown, rawValue: unknown): (string?, any?, string?)
		if typeof(rawField) ~= "string" then
			return nil, nil, "non-string field"
		end
		local name = rawField :: string
		local shape = fields[name]
		if shape == nil then
			return nil, nil, `unknown field {name}`
		end
		local value, reason = shape(rawValue)
		if reason ~= nil then
			return nil, nil, `{name}: {text(reason)}`
		end
		return name, value, nil
	end
end

return Schema
