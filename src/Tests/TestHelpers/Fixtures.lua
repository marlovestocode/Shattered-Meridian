--!strict
--[[
	Fixtures.lua

	Shared fixture-building helper for spec files under src/Tests -- the identical override-merge loop
	MoveTypes.spec.lua and MoveRegistryManager.spec.lua would otherwise each hand-roll: build a
	fully-defaulted base table, then let the caller punch in only the handful of fields THIS test
	cares about, leaving every other field at its harmless default. Kept generic (not typed to
	Types.HitboxAttackDefinition or to any move shape) since nothing about the merge itself is
	specific to either -- only the base table each spec builds is, and that stays owned by the spec
	file's own make* function.

	applyNestedOverrides lived here too, for a base table nesting some of its fields under named
	sub-tables. Its only caller was Movement.spec.lua, and it went with Server/Combat/Movement.lua and
	CombatTypes.lua -- a resolver nothing had driven since the combat rewrite, whose CombatState shape
	was the only thing that ever needed the nesting.
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
