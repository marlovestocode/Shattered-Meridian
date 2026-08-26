--!strict
--[[
	ComboEscalation.lua

	Owns: how deep into an unbroken string each attacker currently is, and when that string lapses.

	LANDING-BASED, AND THAT IS THE WHOLE DISTINCTION. This counter advances only on a hit that actually
	connected past a defence -- never on a whiff, never on a blocked hit. It is NOT "which move throws
	next," which is a request-side question answered before the engine has any opinion about the
	outcome, advances on every accepted throw whether it hits or not, and belongs to the attack layer's
	own sequencer.

	The deleted CombatTypes.lua kept exactly this split (basicSwingIndex, throw-based, drove which
	animation played; basicComboLanded, landing-based, gated the finisher) and its header said plainly
	why they were two counters and never one: a player must see their string cycle even while missing,
	or the move set feels broken -- but missing must not earn the payoff that landing does. Fusing them
	gives you one of those two properties and silently loses the other.

	NOT A STATE MACHINE, and the contrast with DefenseStateMachine is the reason. That machine keeps a
	segment history because DefenseSystem's pass 1 has to answer "what was your posture at an arbitrary
	past SampleTime" -- it classifies an incoming contact against a window that may have opened and
	closed within the frame being resolved. Nothing here is ever queried retroactively: this is an
	OUTPUT effect, applied once per already-resolved outcome, and read fresh at the next hit. A flat
	record with an expiry timestamp is the proportionate amount of machinery, and building the heavier
	shape would be solving a problem this state does not have.

	TIME COMES FROM THE CALLER on every entry point, the same rule DefenseStateMachine,
	AttackStateMachine and GuardMeter all keep -- so the specs drive it on a synthetic clock and no
	two modules can disagree about what "now" was.

	Does not own: what a stage is WORTH (DamageResolver applies the multiplier), when a hit counts as
	landed (DamageResolver decides, from DefenseSystem's outcome), or which move throws next.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DamageConstants = require(ReplicatedStorage.Shared.Damage.DamageConstants)
local DamageTypes = require(ReplicatedStorage.Shared.Damage.DamageTypes)

type ComboEscalationState = DamageTypes.ComboEscalationState

local ComboEscalation = {}

-- Keyed by attacker. COMBO STATE IS PER-ATTACKER AND NEVER SHARED: two players fighting each other
-- each own an independent record, so "who gets the combo" is never an arbitration between two claims
-- on one resource. The only way one combatant's string is ever perturbed by another is by being
-- interrupted -- which is hitstun's job, not this table's.
local states: { [Model]: ComboEscalationState } = {}

local STAGE_ONE: ComboEscalationState = { Stage = 1, WindowExpiresAt = 0 }

-- The stage a hit landed RIGHT NOW would be at. Expiry is evaluated on read rather than swept on a
-- timer: a lapsed record and an absent one mean the same thing, so there is no moment where the two
-- could disagree, and no Heartbeat pass is needed to keep them honest.
function ComboEscalation.GetStage(attacker: Model, now: number): number
	local state = states[attacker]
	if not state or now >= state.WindowExpiresAt then
		return 1
	end
	return state.Stage
end

-- The live record, or a stage-1 stand-in when the string has lapsed. Returned by value so a caller
-- cannot mutate the table this module is holding.
function ComboEscalation.GetState(attacker: Model, now: number): ComboEscalationState
	local state = states[attacker]
	if not state or now >= state.WindowExpiresAt then
		return { Stage = STAGE_ONE.Stage, WindowExpiresAt = STAGE_ONE.WindowExpiresAt }
	end
	return { Stage = state.Stage, WindowExpiresAt = state.WindowExpiresAt }
end

-- One landed hit. Advances the stage and pushes the window out, returning the stage the hit itself
-- counts as.
--
-- THE RETURNED STAGE IS THE ONE AFTER ADVANCEMENT, so the first hit of a string is stage 1 rather
-- than stage 0 and the damage multiplier for it is exactly 1x. Off-by-one here would silently make
-- every first hit of every combo weaker or stronger than its authored damage.
--
-- The window is pushed to `now + WindowSeconds` rather than max'd against what was there, because a
-- landed hit is the freshest possible evidence that the string is alive -- and it can only ever move
-- forward anyway, since the record was either expired (and reset below) or its expiry is in the
-- future by less than a full window.
function ComboEscalation.Advance(attacker: Model, now: number): number
	local state = states[attacker]
	if not state or now >= state.WindowExpiresAt then
		state = { Stage = 1, WindowExpiresAt = 0 }
		states[attacker] = state
	else
		-- Clamped rather than left to grow: an unbounded stage is one long string away from a
		-- multiplier nobody modelled. Past the ceiling, further hits keep the string ALIVE (the window
		-- still extends below) but earn no more growth.
		state.Stage = math.min(state.Stage + 1, DamageConstants.Combo.MaxStage)
	end
	state.WindowExpiresAt = now + DamageConstants.Combo.WindowSeconds
	return state.Stage
end

-- There is no Clear(attacker). There used to be, for "teardown -- a character being removed, a spec
-- clearing between cases", and nothing ever called it: ReclaimStale below already drops every record
-- whose attacker has left the world, which is the same teardown arriving on its own schedule. Keeping
-- both meant two ways to end a string and one of them unexercised.

-- Drops every record whose attacker has left the world, and every record whose window has long since
-- lapsed. Called from DamageSystem's Heartbeat.
--
-- This is the whole reason this module needs no registration call and no PlayerRemoving hook: a record
-- is created by landing a hit and reclaimed either by expiring or by its model being destroyed, so a
-- bot, a dummy and a player are handled identically with nobody having to remember to register any of
-- them. `now` gates the expiry sweep so a live-but-idle attacker's record does not survive the fight
-- it was made in.
function ComboEscalation.Sweep(now: number): ()
	for attacker, state in states do
		if attacker.Parent == nil or now >= state.WindowExpiresAt then
			states[attacker] = nil
		end
	end
end

-- Spec-only, so one case cannot serve another its state -- the same role HitboxEngine.Reset and
-- DefenseSystem.Reset play for their own modules.
function ComboEscalation.Reset(): ()
	table.clear(states)
end

return ComboEscalation
