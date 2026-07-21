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

return Fixtures
