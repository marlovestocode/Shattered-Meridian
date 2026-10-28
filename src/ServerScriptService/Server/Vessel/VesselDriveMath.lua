--!strict
--[[
	VesselDriveMath.lua

	Owns: the pure drive arithmetic a crewed vehicle's server System shares. Today that is ClampLead.

	WHY. BlimpDrive and BoatDrive each carried a byte-identical copy (coworking plan W15). The debt-discharge problem it
	bounds is in BlimpDrive's header: the chase target is integrated every tick, so a hull held back by a collision lets the
	target run ahead, and when the hull frees the constraint would discharge that whole debt as one lurch. This is the
	bound. The rest of each drive stays vehicle-specific (the integrator and the mode machine -- see CLAUDE.md, "build a
	crewed vehicle").

	Pure: no Instances beyond the CFrame/Vector3 values it is handed, no clock, no state.
]]

local VesselDriveMath = {}

-- Bounds how far `target` may lead `actualPosition`, clamping only the DISTANCE between them along the straight line that
-- already separates them -- the direction and `target`'s own rotation are untouched.
--
-- Returns `target` UNCHANGED (the same value, not an equal copy) when it is already within the bound, which is every tick of a
-- clean path -- the caller relies on that to know whether it needs to write anything back into its state at all.
function VesselDriveMath.ClampLead(target: CFrame, actualPosition: Vector3, maxLeadStuds: number): CFrame
	local offset = target.Position - actualPosition
	local distance = offset.Magnitude
	if distance <= maxLeadStuds then
		return target
	end
	-- distance > maxLeadStuds >= 0 here, so `offset` cannot be the zero vector and dividing by `distance` is safe.
	-- `target.Rotation` is target's own rotation about the origin -- adding the clamped position back onto it keeps the
	-- yaw ClampLead was handed and touches nothing else about the pose.
	local clampedPosition = actualPosition + (offset / distance) * maxLeadStuds
	return target.Rotation + clampedPosition
end

return VesselDriveMath
