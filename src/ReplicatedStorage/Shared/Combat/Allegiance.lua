--!strict
--[[
	Allegiance.lua

	Owns: the one answer to "are these two combatants on the same side?", and the target filter built on
	it (who a realm's effect or rule may touch).

	THERE IS NO PARTY OR TEAM SYSTEM YET, and this module is honest about that rather than inventing one.
	Shattered Meridian's PvP is open: the hitbox engine hits every registered body but its owner, and
	nothing in the combat stack has ever asked about sides. FactionManager is a stub, and a faction is not
	an alliance anyway -- two Demonic cultivators still fight each other. So today two bodies are allies
	only when both are players sharing a real Roblox Team (a neutral player is on nobody's side), which
	is exactly the hook a future party/sect system would stand up. When one lands, THIS is the function it
	changes; every domain filter follows with no other edit.

	Does not own: what an ally may or may not do to another (nothing in combat reads this yet but the
	domain filters), or who is a combatant at all (HitboxEngine's registry and its Combatant tag).
]]

local Players = game:GetService("Players")

local Allegiance = {}

export type TargetFilter = "Enemies" | "Allies" | "Owner" | "OwnerAndAllies" | "EveryoneButOwner" | "Everyone"
export type TargetType = "Any" | "Players" | "NonPlayers"

function Allegiance.AreAllies(a: Model, b: Model): boolean
	if a == b then
		return true
	end
	local playerA = Players:GetPlayerFromCharacter(a)
	local playerB = Players:GetPlayerFromCharacter(b)
	if playerA == nil or playerB == nil then
		return false
	end
	if playerA.Neutral or playerB.Neutral then
		return false
	end
	return playerA.Team ~= nil and playerA.Team == playerB.Team
end

-- Whether `target` is one of the bodies `filter` names, relative to `owner`.
function Allegiance.Matches(filter: TargetFilter, owner: Model, target: Model): boolean
	local isOwner = target == owner
	if filter == "Everyone" then
		return true
	elseif filter == "EveryoneButOwner" then
		return not isOwner
	elseif filter == "Owner" then
		return isOwner
	elseif filter == "OwnerAndAllies" then
		return isOwner or Allegiance.AreAllies(owner, target)
	elseif filter == "Allies" then
		return not isOwner and Allegiance.AreAllies(owner, target)
	end
	-- Enemies
	return not isOwner and not Allegiance.AreAllies(owner, target)
end

function Allegiance.MatchesType(targetType: TargetType, target: Model): boolean
	if targetType == "Any" then
		return true
	end
	local isPlayer = Players:GetPlayerFromCharacter(target) ~= nil
	return if targetType == "Players" then isPlayer else not isPlayer
end

return Allegiance
