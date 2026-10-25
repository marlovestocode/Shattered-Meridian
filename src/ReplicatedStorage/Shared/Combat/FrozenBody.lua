--!strict
--[[
	FrozenBody.lua

	Owns: the one answer to "is this body held still by an admin freeze or the onboarding isolation?". It reads
	the Frozen Humanoid Attribute and nothing else.

	WHY IT EXISTS. Frozen used to pin WalkSpeed (RunSystem) and the parkour client and nothing more, so a frozen
	player could still swing, block and parry -- an admin freeze on a misbehaving player did not hold.
	AttackRequestSystem.CanAct and DefenseSystem's block/evade entry both refuse a frozen body now, and both
	read it here rather than requiring AdminActionSystem, which writes the Attribute and sits above the combat
	layers (cross-system gates are Attribute seams).

	Does not own: writing the Attribute (AdminActionSystem.SetFrozen), or what a refusal looks like to the
	caller -- each gate returns its own reason.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AttributeConstants = require(ReplicatedStorage.Shared.AttributeConstants)

local FrozenBody = {}

function FrozenBody.IsFrozen(humanoid: Humanoid?): boolean
	if humanoid == nil then
		return false
	end
	return humanoid:GetAttribute(AttributeConstants.Frozen) == true
end

return FrozenBody
