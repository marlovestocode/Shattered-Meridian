--!strict
--[[
	VesselContacts.lua

	Owns: counting which players are touching a hull right now. `VesselContacts.Watch(trove, hullParts, contacts)` wires every hull
	part's Touched/TouchEnded into `contacts` ({ [Player]: number }, a per-player count of touching limbs), with every connection
	in `trove`, so the hull's own teardown releases them.

	WHY. BlimpSystem and BoatSystem each carried the same two handlers and the same wiring loop, line for line (coworking plan W15).
	The count is what keeps a body standing on a moving deck "aboard" for the contact-speed clamp (VesselSafety) and the
	abandoned-hull check; the two vehicles must agree on it, so there is one copy.

	Wired on every hull part, not just the root: a big hull is touched anywhere along its length, and Touched is per-BasePart even
	though every part moves rigidly together. `otherPart` is any limb of a rig; FindFirstAncestorOfClass("Model") walks up to the
	character, and a hull part or another vessel resolves to a Model that owns no Player, so both are filtered out for free.

	Does not own: what the count means to a vehicle (its own record reads `contacts`), or releasing an entry when a player leaves
	the server (the vehicle's own release paths).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Trove = require(ReplicatedStorage.Shared.Trove)

local VesselContacts = {}

local function playerOf(otherPart: BasePart): Player?
	local character = otherPart:FindFirstAncestorOfClass("Model")
	return if character then Players:GetPlayerFromCharacter(character) else nil
end

function VesselContacts.Touched(contacts: { [Player]: number }, otherPart: BasePart): ()
	local player = playerOf(otherPart)
	if player then
		contacts[player] = (contacts[player] or 0) + 1
	end
end

function VesselContacts.TouchEnded(contacts: { [Player]: number }, otherPart: BasePart): ()
	local player = playerOf(otherPart)
	if not player then
		return
	end
	local count = contacts[player]
	if not count then
		return
	end
	if count <= 1 then
		contacts[player] = nil
	else
		contacts[player] = count - 1
	end
end

function VesselContacts.Watch(trove: Trove.TroveInstance, hullParts: { BasePart }, contacts: { [Player]: number }): ()
	for _, part in hullParts do
		trove:Connect(part.Touched, function(otherPart: BasePart)
			VesselContacts.Touched(contacts, otherPart)
		end)
		trove:Connect(part.TouchEnded, function(otherPart: BasePart)
			VesselContacts.TouchEnded(contacts, otherPart)
		end)
	end
end

return VesselContacts
