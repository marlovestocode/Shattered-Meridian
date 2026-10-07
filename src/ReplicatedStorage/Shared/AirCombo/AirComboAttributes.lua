--!strict
--[[
	AirComboAttributes.lua

	Owns: READING the air combo's published deadlines off a Humanoid -- is this body held in a combo, is it
	a combo's attacker, is it lying in a slam's intangible knockdown. The one definition every reader uses,
	server and client: DefenseSystem, ParkourSystem's report gate, the parkour controller's park, the
	training bot's body drive, and the attacker's follow.

	WHY A MODULE FOR THREE COMPARISONS. The deadlines are in workspace:GetServerTimeNow() time, not os.clock()
	(AttributeConstants' air-combo note), and every other deadline Attribute in this codebase is os.clock.
	A reader that compared one of these against os.clock() would be wrong by the server's uptime -- silently,
	and forever. One reader cannot get the clock wrong in five places.

	Writes nothing. Server/Combat/AirCombo/AirComboSystem.lua is the only writer.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local AttributeConstants = require(ReplicatedStorage.Shared.AttributeConstants)

local AirComboAttributes = {}

local function live(humanoid: Humanoid, attribute: string): boolean
	local untilTime = humanoid:GetAttribute(attribute)
	return typeof(untilTime) == "number" and Workspace:GetServerTimeNow() < untilTime
end

-- Held in the air by a combo right now.
function AirComboAttributes.IsHeld(humanoid: Humanoid): boolean
	return live(humanoid, AttributeConstants.AirHeldUntil)
end

-- A live combo's attacker right now.
function AirComboAttributes.IsAttacker(humanoid: Humanoid): boolean
	return live(humanoid, AttributeConstants.AirComboAttackerUntil)
end

-- Either side of a live combo -- the body belongs to the combat stack, not to parkour.
function AirComboAttributes.IsParticipant(humanoid: Humanoid): boolean
	return AirComboAttributes.IsHeld(humanoid) or AirComboAttributes.IsAttacker(humanoid)
end

-- Lying in a slam's hard knockdown: every contact resolves Evaded.
function AirComboAttributes.IsIntangible(humanoid: Humanoid): boolean
	return live(humanoid, AttributeConstants.AirComboIntangibleUntil)
end

return AirComboAttributes
