--!strict
--[[
	LocalAnimator.lua

	Owns: the ONE AnimationManager for the local player's character -- constructed once, bound once per life --
	and the names of the layers its claimants use. Emote and flight clips are claims on it (EmoteAnimator,
	FlightAnimator), so they share one track pool, one death gate and one Step watchdog instead of each
	hand-rolling a tracks dict, a BindCharacter and a Heartbeat. AnimationManager's header describes the model;
	this file is only the place the local player's instance lives.

	BIND IS IDEMPOTENT PER CHARACTER. Each claimant's BindCharacter is called from its own controller's
	PlayerLifecycle hook for the same new character, in no guaranteed order. AnimationManager.Bind starts a new
	life every call (it drops every track and claim), so a second claimant's bind must not wipe the first's
	claims: Bind here is a no-op while the manager is already bound to that character.

	NOT YET ON THIS MANAGER, and deliberately: DefenseClient, AttackInputClient and ParkourAnimator each construct
	their own manager, and CombatAnimator hand-rolls its tracks. Moving them here is what turns the layers into one
	arbitration; each is its own migration (CombatAnimator the largest, see docs/architecture/
	2026-10-27-w11-migration-list.md). Two managers on one Animator do not arbitrate with each other, which is the
	gap that exists today for those four.

	Does not own: what any layer plays or when (the claimants), or the character lifecycle (their controllers).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AnimationManager = require(ReplicatedStorage.Shared.Animation.AnimationManager)

local LocalAnimator = {}

-- Layer names are exclusive slots: one claim plays per layer. Emote and Flight keep the separate layers they
-- always had (an emote does not cancel a flight clip; the server decides whether the two may overlap), and the
-- flight loops (mutually exclusive) are apart from the flight one-shots (which play over them).
LocalAnimator.Layers = {
	Emote = "Emote",
	FlightLoop = "FlightLoop",
	FlightOneShot = "FlightOneShot",
}

local manager = AnimationManager.new({ Name = "LocalAnimator" })
local boundCharacter: Model? = nil

function LocalAnimator.Manager(): AnimationManager.AnimationManagerInstance
	return manager
end

-- Binds the manager to `character` unless it already is. Returns whether it is bound to it afterwards.
function LocalAnimator.Bind(character: Model): boolean
	if boundCharacter == character and manager:GetPhase() ~= "Unbound" then
		return true
	end
	boundCharacter = nil
	if manager:Bind(character) then
		boundCharacter = character
		return true
	end
	return false
end

return LocalAnimator
