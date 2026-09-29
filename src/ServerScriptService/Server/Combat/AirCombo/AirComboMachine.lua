--!strict
--[[
	AirComboMachine.lua

	Owns: the rules of one air combo's life, as pure functions on a Combo record -- the one shared
	continuation deadline, the in-flight-swing grace, what a press resolves to in the air, how damage scales
	across the route, and which phase each ending publishes. The design is docs/design/air-combat-and-evade.md
	(Part B); every rule below is one of its sentences.

	PURE AND CLOCK-INJECTED, the same discipline as DefenseStateMachine: no Instances, no services, no
	os.clock(). Time is handed in on every call, which is what lets the whole life cycle -- launch, on-beat,
	max delay, late drop, grace, finisher, every end reason -- be driven by a spec on a synthetic clock with
	no rig at all. AirComboSystem owns the bodies, the Attributes and the subscriptions; this owns only the
	decisions.

	ONE DEADLINE. ContinueBy is the only thing the hold, the attacker's commitment and the drop are derived
	from. Each landed air hit resets it to contact + ContinueSeconds, and nothing else moves it -- except the
	grace below, which can only ever EXTEND the hold, and only while a swing that was in time on the
	attacker's own screen is still in flight.

	Does not own: bodies, constraints, Attributes (AirComboSystem), the numbers (AirComboConstants), or
	whether a contact was a parry (DefenseSystem).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AirComboConstants = require(ReplicatedStorage.Shared.AirCombo.AirComboConstants)
local AirComboTypes = require(ReplicatedStorage.Shared.AirCombo.AirComboTypes)

type Combo = AirComboTypes.Combo
type EndReason = AirComboTypes.EndReason
type Phase = AirComboTypes.Phase
type FinisherKind = AirComboTypes.FinisherKind
type MoveRole = AirComboTypes.MoveRole

local TIMING = AirComboConstants.Timing

local AirComboMachine = {}

-- A fresh combo, launched at `now` (the launch CONTACT's own time, not the frame's).
function AirComboMachine.Launch(now: number): Combo
	return {
		LaunchedAt = now,
		Phase = "Rising",
		ContinueBy = now + TIMING.FirstContinueSeconds,
		GraceUntil = 0,
		AirHitsLanded = 0,
		FinisherThrown = false,
		Ended = nil,
		EndedAt = nil,
	}
end

-- The hard cap on the whole combo.
function AirComboMachine.CapAt(combo: Combo): number
	return combo.LaunchedAt + TIMING.MaxComboSeconds
end

-- Until when the victim is held and the attacker committed: the shared deadline, extended by an in-flight
-- in-time swing, never past the hard cap.
function AirComboMachine.HoldUntil(combo: Combo): number
	return math.min(math.max(combo.ContinueBy, combo.GraceUntil), AirComboMachine.CapAt(combo))
end

-- Advances the combo to `now`. Returns the reason it just ended, or nil while it runs. Rising becomes Held
-- after the rise; the cap is Timeout; a hold that has run out is Dropped -- the attacker's fault (a late
-- press, a whiff, bad spacing), never lag, because an in-time swing has already extended it.
function AirComboMachine.Tick(combo: Combo, now: number): EndReason?
	if combo.Ended then
		return nil
	end
	if now >= AirComboMachine.CapAt(combo) then
		return "Timeout"
	end
	if combo.Phase == "Rising" and now >= combo.LaunchedAt + AirComboConstants.Hover.RiseSeconds then
		combo.Phase = "Held"
	end
	if now > AirComboMachine.HoldUntil(combo) then
		return "Dropped"
	end
	return nil
end

-- Whether the attacker may throw an air press at `now`, and why not. The first press waits out
-- FirstPressSeconds (the victim is still leaving the ground); nothing may be thrown once a finisher has
-- been, because a finisher always ends the combo.
function AirComboMachine.CanPress(combo: Combo, now: number): (boolean, string?)
	if combo.Ended then
		return false, "ComboEnded"
	end
	if combo.FinisherThrown then
		return false, "FinisherThrown"
	end
	if now < combo.LaunchedAt + TIMING.FirstPressSeconds then
		return false, "Rising"
	end
	return true, nil
end

-- What a press means in the air (docs B2's grammar):
--   * Basic      -> the next air hit, Air:(landed + 1); after the last one has landed, the Slam, automatically.
--   * Heavy      -> Slam.
--   * Space+Heavy -> Spike.
-- A whiffed air swing does not advance the beat: n counts LANDED hits, so a miss with time left re-throws
-- the same beat.
function AirComboMachine.ResolvePress(combo: Combo, kind: "Basic" | "Heavy", modifierUp: boolean): MoveRole
	if kind == "Heavy" then
		return { Role = "Finisher", Finisher = if modifierUp then "Spike" else "Slam" }
	end
	if combo.AirHitsLanded >= AirComboConstants.StringLength then
		return { Role = "Finisher", Finisher = "Slam" }
	end
	return { Role = "Air", Beat = combo.AirHitsLanded + 1 }
end

-- An air move or finisher was accepted by the attack layer at `acceptedAt`. `rewindSeconds` is
-- min(attacker ping, SwingRewindMaxSeconds), supplied by the caller -- this machine has no network.
--
-- IN-TIME SWINGS ARE HONOURED (docs B5): judged against its REWOUND start, a swing whose hit would land by
-- ContinueBy extends the hold until its active window ends, even if the press reached the server after the
-- deadline's point of no return. One that would not land in time extends nothing -- the hold runs out and
-- the combo drops before it connects, which is exactly "late on your own screen".
function AirComboMachine.NoteSwingAccepted(
	combo: Combo,
	role: MoveRole,
	acceptedAt: number,
	rewindSeconds: number,
	windupSeconds: number,
	activeSeconds: number
): ()
	if combo.Ended then
		return
	end
	local rewind =
		math.clamp(if rewindSeconds == rewindSeconds then rewindSeconds else 0, 0, TIMING.SwingRewindMaxSeconds)
	local landsAt = acceptedAt - rewind + windupSeconds
	if landsAt <= combo.ContinueBy then
		combo.GraceUntil = math.max(combo.GraceUntil, acceptedAt + windupSeconds + activeSeconds)
	end
	if role.Role == "Finisher" then
		combo.FinisherThrown = true
		combo.Phase = "Finishing"
	end
end

-- An air hit landed at `contactAt`: one more beat, and the shared deadline moves on from this contact.
-- The grace that carried the swing here is spent.
function AirComboMachine.NoteAirHit(combo: Combo, contactAt: number): ()
	if combo.Ended then
		return
	end
	combo.AirHitsLanded += 1
	combo.ContinueBy = contactAt + TIMING.ContinueSeconds
	combo.GraceUntil = 0
	if combo.Phase == "Rising" then
		combo.Phase = "Held"
	end
end

-- Ends the combo. Idempotent: the first reason wins, so two endings racing in one frame (a parry and a
-- timeout) cannot publish two different outcomes.
function AirComboMachine.End(combo: Combo, reason: EndReason, now: number): boolean
	if combo.Ended then
		return false
	end
	combo.Ended = reason
	combo.EndedAt = now
	return true
end

-- The phase an ending publishes on the victim. A finish shows which finisher it was.
function AirComboMachine.EndPhaseFor(reason: EndReason, finisher: FinisherKind?): Phase
	if reason == "Finished" then
		return if finisher == "Spike" then "Spiked" else "Slammed"
	elseif reason == "Parried" then
		return "Parried"
	end
	return "Dropped"
end

-- Launch immunity after an ending at `endedAt`.
function AirComboMachine.ImmuneUntil(endedAt: number): number
	return endedAt + TIMING.LaunchImmunitySeconds
end

-- Whether a victim may be launched at `now` given their LaunchImmuneUntil (nil = never launched).
function AirComboMachine.CanLaunch(immuneUntil: number?, now: number): boolean
	return immuneUntil == nil or now >= immuneUntil
end

-- DAMAGE (docs B3). `base` is the move's own resolved damage (authored, weapon-scaled, flat-priced).
-- Air hit k -- k air hits already landed -- is scaled down; a finisher grows with the string behind it.
function AirComboMachine.AirHitDamage(base: number, hitsLanded: number): number
	local rules = AirComboConstants.Damage
	return base * math.max(rules.AirHitFloor, 1 - rules.AirHitFalloffPerHit * hitsLanded)
end

function AirComboMachine.FinisherDamage(base: number, finisher: FinisherKind, hitsLanded: number): number
	local rules = AirComboConstants.Damage.Finishers[finisher]
	return base + rules.PerHitBonus * hitsLanded
end

-- The final damage of a landed move in a live combo, dispatched by role. Anything without an air role (a
-- third party's hit, a hotbar Art thrown into the victim) is returned unchanged.
function AirComboMachine.ScaleDamage(combo: Combo, role: MoveRole?, base: number): number
	if role == nil or base <= 0 then
		return base
	end
	if role.Role == "Air" then
		return AirComboMachine.AirHitDamage(base, combo.AirHitsLanded)
	elseif role.Role == "Finisher" then
		return AirComboMachine.FinisherDamage(base, role.Finisher :: FinisherKind, combo.AirHitsLanded)
	end
	return base
end

return AirComboMachine
