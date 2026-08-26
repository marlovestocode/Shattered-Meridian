--!strict
--[[
	EngagementConstants.lua

	Owns: the engagement (combat-tag) layer's tunables. Standalone, and deliberately NOT a section of
	Shared/Constants.lua -- the same choice AttackConstants.lua/DamageConstants.lua/
	DefenseConstants.lua/GrabConstants.lua all make, and for the same reason: this system is a module,
	and a module that can be dropped in or pulled out without editing the game's central constants
	table is the concrete form of that.

	TagDurationSeconds ARRIVED HERE FROM CombatConstants.InCombatDurationSeconds, which had been
	sitting at 5 with ZERO consumers ever since the combat teardown deleted CombatSystem.lua (its only
	reader). Re-homed rather than read in place, so the tunable lives next to the system that is now
	its sole owner; CombatConstants keeps a pointer comment where it used to be. It was moved at its
	inherited 5 and RETUNED TO 30 on 2026-08-26 after the first playtest -- see the constant itself,
	and note that it drives a great deal more than the HUD readout it visibly changes.

	Does not own: what actually refreshes a tag (Server/Combat/Engagement/EngagementSystem.lua -- see
	its header for the trigger list and why a whiffed swing is deliberately not one), what reads the
	resulting Constants.Attributes.InCombat seam (Client/Parkour's combat gate, EmoteSystem), or how
	the engagement is presented (Client/UI/Screens/HUD/EngagementDetail.lua).
]]

local EngagementConstants = {}

-- The tag ------------------------------------------------------------------------------------------

-- How long a combatant stays tagged after their last real exchange. Refreshed by ASSIGNING FORWARD,
-- never math.max'd -- this is a coarser signal than any specific combat lockout, so a fresh trigger
-- should always reset the full duration rather than extend a longer one already running.
--
-- 30 AS OF 2026-08-26, up from the 5 inherited from the deleted CombatSystem. THIS NUMBER IS READ BY
-- MORE THAN THE HUD, and the reach is worth stating where the value lives rather than leaving it to
-- be rediscovered: ParkourConstants.CombatGate.BlockedStates refuses Dash, Slide, Roll, Leap and
-- WallRun for the whole of it, and EmoteSystem refuses every CombatAllowed = false emote. Raising it
-- six-fold therefore lengthens a movement lockout six-fold, not just a label.
--
-- If the tag wants to be long (combat-logging and "am I still in a fight?" both want tens of seconds)
-- while the movement gate wants to be short, that is a SPLIT rather than a compromise value: give the
-- parkour gate its own shorter deadline instead of detuning this one. Nothing here forecloses it --
-- the gate reads an Attribute this module publishes, so a second, shorter Attribute is the shape.
EngagementConstants.TagDurationSeconds = 30

-- Ceiling on CombatEngagement.recentOpponents. That table is maintained and capped but nothing
-- refreshes a tag from it yet -- the proximity refresh the deleted CombatSystem had needed a
-- CombatEngagementRange constant that did not survive the teardown. Kept bounded now so the eventual
-- extension is one function rather than one function plus a leak audit.
EngagementConstants.MaxTrackedOpponents = 8

-- Who counts as an opponent -------------------------------------------------------------------------

-- CollectionService tag marking a rig that must NEVER tag anyone who hits it -- a practice target,
-- not an adversary.
--
-- NOTHING APPLIES THIS TODAY, and that is the current, deliberate state rather than a loose end.
-- Server/Systems/DebugDummySystem.lua briefly did, and it was taken back out: a debug dummy is the
-- only sparring partner a solo tester has, so exempting it made the whole engagement layer
-- unreachable without a second client, and it contradicted that module's own "A DUMMY IS A REAL
-- COMBATANT, NOT A MOCK" principle. See its buildRig for the full reasoning. The tag stays because
-- the case it exists for is real and not hypothetical: a scenery target dummy in a training area that
-- ORDINARY players swing at should not lock them out of five movement states for hitting it.
--
-- A NEGATIVE PREDICATE, DELIBERATELY, and the reversal above is the argument for it. EngagementSystem
-- treats a combatant as taggable UNLESS it carries this tag, rather than requiring
-- Players:GetPlayerFromCharacter(model) ~= nil. Under the positive form, making the dummy tag would
-- have meant editing the engagement layer's own predicate; under this one it was a deletion in the
-- module that owns the rig, with nothing here to change. The same holds for the day a real bot or an
-- NPC boss lands -- something that fights back SHOULD tag you, and it will, for free.
EngagementConstants.DummyTag = "CombatDummy"

-- Network -------------------------------------------------------------------------------------------

EngagementConstants.Network = {
	RemoteNames = {
		-- Server -> the owning player only, on every meaningful change to their own engagement: a
		-- resolved exchange (bounded by hit rate, not frame rate) and the expiry edge. Never a
		-- per-frame push -- the countdown itself is decayed client-side from SecondsRemaining, see
		-- Types.EngagementPayload's own header for why an absolute deadline could not be sent.
		Changed = "Engagement_Changed",
	},
}

-- Debug ---------------------------------------------------------------------------------------------

EngagementConstants.Debug = {
	Enabled = false,
	LogTagged = true,
	LogExpired = true,
	LogCombatLogout = true,
}

return EngagementConstants
