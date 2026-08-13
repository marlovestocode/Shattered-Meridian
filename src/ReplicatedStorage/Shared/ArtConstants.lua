--!strict
--[[
	ArtConstants.lua

	Owns: the art trees themselves (what trees exist and who may walk them), the limits every
	authored Art binding is validated against, and this feature's remote names. Its own dedicated
	Shared module rather than a Constants.Art sub-table, following QiConstants/TierConstants/
	BountyConstants for the reason all three document -- see any of their headers.

	WHAT AN ART IS, AND WHY IT IS A MOVE. An Art is not a new kind of combat object. It is a
	Move Creation System move (Shared/MoveTypes.lua) that additionally declares which tree it belongs
	to, what Qi it costs, and what a player must have done to earn it -- MoveTypes.MoveArtBinding.
	That is the whole integration: the Move Editor already authors hitboxes, timing, animation
	timelines, knockback, projectiles and object-stun, and CombatSystem.ThrowCustomMove already
	executes all of it against real combat. Rebuilding any of that under an "ability" banner would
	mean two parallel combat definitions to keep in sync, which the codebase has avoided so far and
	should keep avoiding.

	So: a move with no Art binding is exactly what moves are today (an M1 stage, a test move, an
	admin experiment). A move WITH one is an art -- the same authored move, now placed in a tree,
	priced in Qi, and gated behind tier and a prerequisite.

	THE TREES ARE CONTENT, NOT CODE. ArtTrees below is a data table for the same reason
	QiConstants.MaxQiByTier is: a designer shapes the roster by editing it, and ArtTreeManager reads
	it fresh rather than caching. Which ARTS live in each tree is deliberately NOT listed here --
	that is derived from the move registry at runtime (ArtTreeManager.GetArtsInTree), because the
	moves are authored in the editor and persisted in a DataStore, not written into this file. This
	file owns the trees; the registry owns their contents.

	Does not own: per-player unlock/mastery state (ArtSystem.lua), the tree->arts index
	(ArtTreeManager.lua), the move data an art is built on (MoveTypes/MoveRegistryManager), or the
	Qi an art spends (QiSystem owns the resource; this file only prices it).
]]

local Types = require(script.Parent.Types)

local ArtConstants = {}

ArtConstants.RemoteNames = {
	-- Server -> owning client: the player's full art state (unlocked ids, mastery, equipped slots),
	-- pushed on profile load and on every unlock/mastery change.
	ArtStateUpdated = "Art_StateUpdated",
	-- Client -> server: the catalogue of trees and the arts inside them. Read-only; a player may
	-- always SEE an art they cannot yet use, which is what makes a tree a goal rather than a
	-- surprise.
	GetArtCatalogue = "Art_GetCatalogue",
	-- Client -> server: spend a mastery point / claim an unlock the player has earned. Validated
	-- server-side against the same rules ArtSystem.CanUnlock applies -- never trusts the request.
	UnlockArt = "Art_Unlock",
	-- Client -> server: bind an unlocked art to one of the hotbar slots.
	EquipArt = "Art_Equip",
}

-- The tree roster. Faction gates who may walk a tree at all: nil means open to everyone, which is
-- what makes a starting tree possible for a player FactionManager hasn't assigned yet (it is still
-- a stub -- QiConstants.DefaultQiType documents the same "Unbound is the correct default, not a
-- placeholder" reasoning this leans on).
--
-- Four trees, not one per faction plus filler: three sect paths that express the world-bible's
-- opposed inheritances, and one common foundation every player can walk so a brand-new character
-- has somewhere to spend their first unlock before any faction identity exists.
ArtConstants.ArtTrees = {
	{
		TreeId = "common_foundation",
		DisplayName = "Foundation Forms",
		Faction = nil :: Types.Faction?,
		Description = "The forms every cultivator drills before a sect will look at them.",
	},
	{
		TreeId = "celestial_ascendant_palm",
		DisplayName = "Ascendant Palm",
		Faction = "Celestial" :: Types.Faction?,
		Description = "Ordered, disciplined qi expressed as open-handed precision.",
	},
	{
		TreeId = "demonic_devouring_fist",
		DisplayName = "Devouring Fist",
		Faction = "Demonic" :: Types.Faction?,
		Description = "Aggressive, corrupting qi that takes what it strikes.",
	},
	{
		TreeId = "unbound_wandering_step",
		DisplayName = "Wandering Step",
		Faction = "Unbound" :: Types.Faction?,
		Description = "No sect's forms and no sect's limits -- flexible, and unforgiving of error.",
	},
} :: { { TreeId: string, DisplayName: string, Faction: Types.Faction?, Description: string } }

-- Validation bounds for an authored MoveTypes.MoveArtBinding. Every one is clamped rather than
-- rejected (the same posture MoveRegistryManager already takes for object-stun fields), so a
-- designer typing an out-of-range number in the editor gets a sane art rather than a save failure.
ArtConstants.Limits = {
	-- Depth within a tree. Node 1 arts are the entry forms -- ArtSystem requires no prerequisite at
	-- node 1 regardless of what was authored, so a tree can never be authored into being unreachable.
	Node = { Min = 1, Max = 8 },
	-- Qi per use. The floor is 0 (a free art is legal -- an entry form may well be), the ceiling is
	-- deliberately under QiConstants.MaxQiByTier[1] (100) so no art is literally uncastable by a
	-- Tier 1 player with a full pool.
	QiCost = { Min = 0, Max = 90 },
	-- Tier gate, bounded by the real ladder (TierConstants.MaxTier is 9).
	RequiredTier = { Min = 1, Max = 9 },
}

-- Mastery earned per confirmed use of an art. Mastery is the "each rank changes a decision, not just
-- a number" currency progression-systems.md describes -- this file only sets the rate at which it
-- accrues; what a rank DOES is ArtSystem's business.
ArtConstants.MasteryPerUse = 1

-- Mastery required on an art before the arts that list it as a prerequisite become unlockable. A
-- deliberate gate on USE, not on time: you advance a tree by actually fighting with the form below,
-- which is the same fight-to-grow rule Meridian XP already follows.
ArtConstants.MasteryToUnlockNext = 10

-- Hotbar slots an art can be equipped to. Matches the five AbilitySlot tiles the HUD already
-- renders and the HotbarSlot1-5 keybinds CombatClient already listens for -- named here rather than
-- re-derived so the server rejects a slot index the client could never legitimately produce.
ArtConstants.EquipSlotCount = 5

-- Rate limit for the three player-facing art remotes, matching Constants.Rivalry's own query budget
-- for the same reason: none of them is expensive, all of them are free to spam otherwise.
ArtConstants.RequestMaxCallsPerSecond = 4

-- Arts a brand-new profile starts with. Empty on purpose: an art is earned, and seeding one would
-- contradict the fight-to-grow pillar. The field exists so the decision is visible rather than
-- implied by an absent table.
ArtConstants.StartingArtIds = {} :: { Types.ArtId }

-- Structural invariant ArtTreeManager depends on -- tree ids must be unique, or "which tree is this
-- art in" stops being answerable. Exported as a function rather than asserted at require time, same
-- reasoning TierConstants.Validate documents: a mis-edited roster should fail a test run, not take
-- a live server's require chain down.
function ArtConstants.Validate(): (boolean, string?)
	local seen: { [string]: boolean } = {}
	for index, tree in ipairs(ArtConstants.ArtTrees) do
		if typeof(tree.TreeId) ~= "string" or tree.TreeId == "" then
			return false, `Tree {index} has no TreeId`
		end
		if seen[tree.TreeId] then
			return false, `Duplicate TreeId "{tree.TreeId}"`
		end
		seen[tree.TreeId] = true
	end
	return true, nil
end

return ArtConstants
