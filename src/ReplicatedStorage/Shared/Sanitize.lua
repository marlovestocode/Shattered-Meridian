--!strict
--[[
	Sanitize.lua

	Owns: the two primitives every validator in this codebase needs before it can trust a number or a
	string it did not produce -- a NaN-safe clamp and a length-bounded string.

	WHY THIS EXISTS, AND WHY IT IS THE NaN CHECK THAT EARNS IT. Five modules held a copy of the clamp
	and three held the string bound. That alone would be ordinary duplication; what makes it worth a
	module is that every one of the five had to independently DISCOVER and then re-explain the same
	trap in its own comment:

		NaN passes `typeof(value) == "number"` and SURVIVES `math.clamp` unchanged, because every
		comparison involving NaN is false and math.clamp is written in terms of comparisons.

	A NaN that gets through does not error. It flows into geometry and makes every containment test
	silently return false -- an attack that swings and never hits anything -- or into a WalkSpeed and
	pins a character in place with nothing anywhere to explain it. Shared/HitboxEngine/HitboxTypes.lua
	spells its own comparisons as `not (value >= min)` for exactly this reason, which is the same
	guard reached by a different route. Five separate rediscoveries of one trap is the signal that it
	belongs somewhere a sixth validator will find it without having to be bitten first.

	TWO CLAMP SHAPES, DELIBERATELY, because there are genuinely two jobs. A validator that HARD
	REJECTS a bad field wants to know that it was bad (ClampNumber -> nil); a validator that
	NORMALISES wants a usable value and never a nil branch (ClampNumberOr -> fallback). Collapsing
	them into one would force every caller of the second kind to write `or default` at the call site,
	which is the boilerplate this is removing.

	Does not own: what any particular field's bounds ARE (each domain's own constants), whether a
	field is required (each validator's own policy), or any type beyond number and string -- a
	Vector3/CFrame/enum needs a domain-specific answer, not a generic one.
]]

local Sanitize = {}

-- Clamped `value`, or nil when it is not a usable number at all -- for a validator whose answer to a
-- bad field is to REJECT it. See this file's header on why the NaN branch is not paranoia.
function Sanitize.ClampNumber(value: unknown, min: number, max: number): number?
	if typeof(value) ~= "number" then
		return nil
	end
	local number = value :: number
	if number ~= number then
		return nil
	end
	return math.clamp(number, min, max)
end

-- Clamped `value`, or `fallback` when it is not a usable number -- for a validator that NORMALISES
-- rather than rejects. `fallback` is returned as given and is NOT itself clamped: it comes from the
-- field's own authored default, which is already in range by construction, and clamping it here
-- would quietly mask an authoring mistake in that default instead of letting it show.
function Sanitize.ClampNumberOr(value: unknown, min: number, max: number, fallback: number): number
	local clamped = Sanitize.ClampNumber(value, min, max)
	if clamped == nil then
		return fallback
	end
	return clamped
end

-- `value` truncated to `maxLength`, or `fallback` (default "") when it is not a string.
--
-- Truncates rather than rejects, deliberately: a name one character over a limit is an author being
-- slightly verbose, not an attack, and losing their whole entry over it is a worse answer than
-- shortening it. The bound exists so a pasted essay cannot bloat a DataStore record.
function Sanitize.BoundedString(value: unknown, maxLength: number, fallback: string?): string
	if typeof(value) ~= "string" then
		return fallback or ""
	end
	local text = value :: string
	if #text > maxLength then
		return text:sub(1, maxLength)
	end
	return text
end

return Sanitize
