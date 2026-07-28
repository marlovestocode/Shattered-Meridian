--!strict
--[[
	Fixtures.lua

	Shared fixture-building helper for spec files under src/Tests -- currently just the identical
	override-merge loop HitResolution.spec.lua's makeDefinition and Movement.spec.lua's makeState
	each hand-rolled independently: build a fully-defaulted base table, then let the caller punch in
	only the handful of fields THIS test cares about, leaving every other field at its harmless
	default. Kept generic (not typed to either Types.HitboxAttackDefinition or CombatTypes.
	CombatState) since nothing about the merge itself is specific to either shape -- only the base
	table each spec builds is, and that stays owned by the spec file's own make* function.
]]

local Fixtures = {}

-- Mutates `base` in place with every key/value in `overrides` (when provided) and returns the SAME
-- table reference back -- matches both existing call sites exactly: neither ever treated the result
-- as a fresh copy, only used it as the same base table with overrides layered on top.
function Fixtures.applyOverrides<T>(base: T, overrides: { [string]: any }?): T
	if overrides then
		for key, value in pairs(overrides) do
			(base :: any)[key] = value
		end
	end
	return base
end

-- Same job as applyOverrides, but for a base table that nests some of its fields under named
-- sub-tables (e.g. CombatState.Vitals/.Movement/.AirCombo, post-decomposition) -- lets a spec's own
-- make* function keep accepting FLAT override keys (e.g. { dashWindowExpiry = 200 }) even after a
-- field moved from the top level into a nested sub-state, so no individual test call site needs to
-- learn the new nesting. `groups` lists, in order, which known field names redirect into which
-- already-present sub-table on `base`; any override key not claimed by any group is written directly
-- onto `base` instead, exactly like applyOverrides. Still generic (doesn't know CombatState
-- specifically) -- the caller's own make* function supplies both the base table's nested defaults
-- and the groups list, same "own the base table" split applyOverrides already establishes.
function Fixtures.applyNestedOverrides<T>(
	base: T,
	overrides: { [string]: any }?,
	groups: { { SubtableKey: string, Fields: { [string]: boolean } } }
): T
	if not overrides then
		return base
	end
	for key, value in pairs(overrides) do
		local routed = false
		for _, group in ipairs(groups) do
			if group.Fields[key] then
				(base :: any)[group.SubtableKey][key] = value
				routed = true
				break
			end
		end
		if not routed then
			(base :: any)[key] = value
		end
	end
	return base
end

return Fixtures
