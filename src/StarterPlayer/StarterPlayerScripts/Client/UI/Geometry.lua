--!strict
--[[
	Geometry.lua

	Owns: small shared geometric constants used by more than one UI component -- today, just the
	four corner points (Vector2, 0-1 scale) every "anchor-at-this-corner" component iterates over
	(Panel.lua's CornerBracket accents, LockOnReticle.lua's ReticleTicks -- see that file's own
	comment for why it reuses "the same anchor-at-corner trick Panel.lua's CornerBracket uses").
	Was a duplicated module-local constant in both files; centralized here so the two stay in sync
	by construction instead of by convention.
]]

local Geometry = {}

Geometry.CORNERS = { Vector2.new(0, 0), Vector2.new(1, 0), Vector2.new(0, 1), Vector2.new(1, 1) }

return Geometry
