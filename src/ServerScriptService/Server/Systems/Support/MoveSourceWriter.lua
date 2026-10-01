--!strict
--[[
	MoveSourceWriter.lua

	Owns: turning a stored move record (MoveRecordCodec's -- the exact table Save writes to the DataStore)
	into the text of a Lua ModuleScript that returns it, for the Move Editor's Studio-only "Write to
	source". The file lands under Server/Combat/AuthoredMoves/, Rojo syncs it in, and it ships with the
	build and lives in git (Server/Combat/AuthoredMoveLibrary.lua loads it at boot).

	DETERMINISTIC, BYTE FOR BYTE. The same record always produces the same text -- keys sorted, arrays in
	index order, one number format -- so re-writing a move nobody changed produces no git diff, and a diff
	that does appear is a real change. Formatting follows the repo's stylua style (tabs, trailing commas);
	the local helper also runs stylua over the file when it is on PATH, which this output already
	satisfies.

	STRINGS ARE ESCAPED BY HAND, not with %q: %q writes a newline as a backslash followed by a REAL line
	break, which is valid Lua but splits one value across lines in the file and in every diff of it. Here
	every control character becomes an escape on one line.

	PURE: no Instances, no services. Specced in Tests/MoveEditor/MoveSourceWriter.spec.lua.
]]

local MoveSourceWriter = {}

-- Keys that may be written bare (`Damage = 10`); anything else is bracketed (`["odd key"] = 10`).
local IDENTIFIER = "^[%a_][%w_]*$"

-- Luau keywords can never be bare keys.
local KEYWORDS: { [string]: boolean } = {}
for _, word in
	{
		"and",
		"break",
		"continue",
		"do",
		"else",
		"elseif",
		"end",
		"export",
		"false",
		"for",
		"function",
		"if",
		"in",
		"local",
		"nil",
		"not",
		"or",
		"repeat",
		"return",
		"then",
		"true",
		"type",
		"typeof",
		"until",
		"while",
	}
do
	KEYWORDS[word] = true
end

local ESCAPES: { [string]: string } = {
	["\\"] = "\\\\",
	['"'] = '\\"',
	["\n"] = "\\n",
	["\r"] = "\\r",
	["\t"] = "\\t",
}

function MoveSourceWriter.QuoteString(value: string): string
	local escaped = string.gsub(value, '[%c\\"]', function(character: string): string
		return ESCAPES[character] or string.format("\\%03d", string.byte(character))
	end)
	return `"{escaped}"`
end

function MoveSourceWriter.FormatNumber(value: number): string
	if value ~= value then
		return "0 / 0"
	elseif value == math.huge then
		return "math.huge"
	elseif value == -math.huge then
		return "-math.huge"
	elseif value == math.floor(value) and math.abs(value) < 2 ^ 53 then
		return string.format("%d", value)
	end
	-- Six significant figures: MoveTypes.Fingerprint's own precision, so a move written to source and
	-- loaded back reads as the same move, never as an unsaved edit.
	return string.format("%.6g", value)
end

local function isArray(value: { [any]: any }): boolean
	local count = 0
	for _ in pairs(value) do
		count += 1
	end
	return count == #value
end

local function formatKey(key: any): string
	if typeof(key) == "string" and string.match(key, IDENTIFIER) and not KEYWORDS[key] then
		return key
	end
	if typeof(key) == "number" then
		return `[{MoveSourceWriter.FormatNumber(key)}]`
	end
	return `[{MoveSourceWriter.QuoteString(tostring(key))}]`
end

local function sortedKeys(value: { [any]: any }): { any }
	local keys = {}
	for key in pairs(value) do
		table.insert(keys, key)
	end
	table.sort(keys, function(a, b)
		-- Numbers before strings, each in its natural order -- total and stable whatever the mix.
		local aNumber, bNumber = typeof(a) == "number", typeof(b) == "number"
		if aNumber ~= bNumber then
			return aNumber
		end
		if aNumber then
			return a < b
		end
		return tostring(a) < tostring(b)
	end)
	return keys
end

local formatValue: (value: any, depth: number) -> string

local function formatTable(value: { [any]: any }, depth: number): string
	if next(value) == nil then
		return "{}"
	end
	local indent = string.rep("\t", depth + 1)
	local lines: { string } = { "{" }
	if isArray(value) then
		for _, item in ipairs(value) do
			table.insert(lines, `{indent}{formatValue(item, depth + 1)},`)
		end
	else
		for _, key in sortedKeys(value) do
			table.insert(lines, `{indent}{formatKey(key)} = {formatValue(value[key], depth + 1)},`)
		end
	end
	table.insert(lines, string.rep("\t", depth) .. "}")
	return table.concat(lines, "\n")
end

formatValue = function(value: any, depth: number): string
	local kind = typeof(value)
	if kind == "number" then
		return MoveSourceWriter.FormatNumber(value)
	elseif kind == "string" then
		return MoveSourceWriter.QuoteString(value)
	elseif kind == "boolean" then
		return if value then "true" else "false"
	elseif kind == "table" then
		return formatTable(value, depth)
	end
	-- A record is JSON-shaped (it is what a DataStore stores), so nothing else can appear. Written as nil
	-- rather than raising, so one odd field cannot block writing the rest of a move.
	return "nil"
end

-- The file's whole text: a header saying where it came from, and a module returning the record.
function MoveSourceWriter.ToLua(record: { [string]: any }): string
	return table.concat({
		"--!strict",
		"-- GENERATED by the Move Editor (Studio: Tools > Source). Schema v3 -- see Shared/MoveTypes.lua.",
		"-- Safe to hand-edit; writing the move from the editor again replaces this file.",
		"return " .. formatTable(record, 0),
		"",
	}, "\n")
end

-- The file a move is written to: its id with every character outside [A-Za-z0-9-] replaced by "_"
-- ("default:Sword:Basic:1" -> "default_Sword_Basic_1.lua"). The real id is inside the file; this is only
-- a name. scripts/move-writer.py applies the same rule, and refuses anything else.
function MoveSourceWriter.FileName(moveId: string): string
	local sanitised = string.gsub(moveId, "[^%w%-]", "_")
	return sanitised .. ".lua"
end

return MoveSourceWriter
