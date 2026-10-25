--!strict
--[[
	MovementAllowance.lua

	Owns: the one WRITE of AttributeConstants.KnockbackUntil -- the server's statement that this body's movement
	may legitimately look like a launch or a teleport until a given os.clock() deadline. MovementGuard and
	ParkourSystem read it so an honest server-side move is not counted toward the suspected-cheater flag.

	WHY ONE WRITER. Four sites stamped it with a bare SetAttribute (DamageSystem's launch, DomainSystem's pull and
	correction, AdminActionSystem's teleport), each to `now + its own allowance`. A launch grants 2 s and a realm
	correction 0.6 s, so a correction landing in the middle of a launch OVERWROTE the 2 s deadline with one 1.4 s
	nearer: the rest of an honest launch then read as a speed hack. RootControl is the precedent -- five writers of
	one flag, and the first release unlocked a body another still held.

	Stamp only ever EXTENDS, the same rule DamageSystem's extendDeadline gives HitstunUntil, because a deadline
	that a later, shorter claim can pull back is a bug that depends on which two systems met.

	Does not own: what the allowance is worth (MovementGuard / ParkourSystem decide that), how long each cause
	grants (DamageConstants.Knockback, DomainConstants.ContainmentAllowanceSeconds, AdminActionSystem), or moving
	the body.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AttributeConstants = require(ReplicatedStorage.Shared.AttributeConstants)

local MovementAllowance = {}

-- Extends this body's allowance to `untilClock` (an os.clock() value). A deadline already further out stays.
-- Returns the deadline now in force.
function MovementAllowance.Stamp(humanoid: Humanoid, untilClock: number): number
	local existing = humanoid:GetAttribute(AttributeConstants.KnockbackUntil)
	local current = if typeof(existing) == "number" then existing else 0
	if untilClock > current then
		humanoid:SetAttribute(AttributeConstants.KnockbackUntil, untilClock)
		return untilClock
	end
	return current
end

-- The deadline in force, 0 when the body has none.
function MovementAllowance.Until(humanoid: Humanoid): number
	local value = humanoid:GetAttribute(AttributeConstants.KnockbackUntil)
	return if typeof(value) == "number" then value else 0
end

return MovementAllowance
