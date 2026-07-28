--!strict
--[[
	HitStop.lua

	Owns: the short freeze-frame ("hit-stop") on every server-validated combat impact -- the "impact
	emphasis" that makes a landed hit read as CONTACT rather than two bodies passing through each
	other. Selects the freeze duration per role/weight (Constants.FX.HitStop) and throttles rapid
	repeats, then delegates the actual pose freeze to CombatAnimator.FreezeActiveCombatTrack.
	CombatClient.lua's Combat_FeedbackEvent handler is the only caller, so a freeze only ever fires
	on a resolution the server already confirmed.

	Scope (plan decision (d)): BOTH involved players freeze -- the attacker gets a crisp short
	contact hold on their swing, the victim a slightly longer one on their hit-reaction -- but NEVER
	spectators (a fight they're not in shouldn't hitch their screen). "Both parties" is achieved for
	free by each client freezing its OWN local tracks off its own copy of the FeedbackEvent; the
	frozen pose then replicates outward so onlookers still SEE the hitch without their own camera or
	animation being touched. Server timing (cooldowns, windows, the Heartbeat tick) is never paused,
	so there is nothing to desync. MinIntervalSeconds throttles back-to-back freezes so a swing that
	hits several targets can't chain them into unintended slow motion.

	Also owns the (much lighter, purely cosmetic) landing-impact freeze for the dev-menu flight
	feature (FreezeFlightLanding) -- Client/DevMenu/FlightController.lua is that one's only caller.
	Kept on its OWN throttle clock and delegates to Client/FX/FlightAnimator.FreezeActiveFlightTrack
	instead of CombatAnimator.FreezeActiveCombatTrack, per that module's own header on why combat and
	flight animation tracks stay deliberately separate -- a flight landing should never freeze a
	combat swing pose or share a throttle window with one.

	Does not own: the actual track manipulation (CombatAnimator.FreezeActiveCombatTrack/
	FlightAnimator.FreezeActiveFlightTrack), deciding WHICH resolution/landing happened, or the
	camera shake / hit-flash that accompany a freeze (CameraShake.lua / HitFlash.lua). Purely local,
	purely presentation.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Constants = require(ReplicatedStorage.Shared.Constants)
local Logger = require(ReplicatedStorage.Shared.Logger)

local CombatAnimator = require(script.Parent.CombatAnimator)
local FlightAnimator = require(script.Parent.FlightAnimator)

local logger = Logger.scope("HitStop")

local CONFIG = Constants.FX.HitStop

local HitStop = {}

-- Builds a throttled freeze function: at most one call through to `delegate` per
-- CONFIG.MinIntervalSeconds, everything in between silently dropped -- the shared shape
-- HitStop.freeze/freezeFlight used to each duplicate on their own module-level clock variable. Each
-- factory call closes over its OWN `lastClock` upvalue, so the resulting function owns an independent
-- throttle window -- this is what gives combat freezes and the flight-landing freeze their own
-- SEPARATE clocks (an unrelated domain event landing close in time to the other shouldn't suppress
-- either one) without two hand-written copies of the same now/compare/stamp logic. `delegate` is the
-- actual track-freeze call (CombatAnimator.FreezeActiveCombatTrack / FlightAnimator.
-- FreezeActiveFlightTrack); `logLabel` only distinguishes the two domains' debug log lines.
local function makeThrottledFreeze(delegate: (number) -> (), logLabel: string): (number) -> ()
	local lastClock = 0
	return function(seconds: number): ()
		local now = os.clock()
		if now - lastClock < CONFIG.MinIntervalSeconds then
			return
		end
		lastClock = now
		delegate(seconds)
		logger:debug(logLabel, { seconds = seconds })
	end
end

local freeze = makeThrottledFreeze(CombatAnimator.FreezeActiveCombatTrack, "Hit-stop")
local freezeFlight = makeThrottledFreeze(FlightAnimator.FreezeActiveFlightTrack, "Flight hit-stop")

-- The attacker's own contact freeze on a hit they landed. HeavyBonus lengthens it so a heavy hit
-- lands with more weight than a jab.
function HitStop.FreezeAttacker(isHeavy: boolean): ()
	freeze(CONFIG.AttackerSeconds + (if isHeavy then CONFIG.HeavyBonusSeconds else 0))
end

-- The victim's freeze on their own hit-reaction -- slightly longer than the attacker's, the
-- standard asymmetry that sells "the one taking the hit is rocked harder than the one dealing it."
function HitStop.FreezeVictim(isHeavy: boolean): ()
	freeze(CONFIG.VictimSeconds + (if isHeavy then CONFIG.HeavyBonusSeconds else 0))
end

-- The heavier freeze both parties share on a parry -- a clash beat, weightier than a plain hit.
function HitStop.FreezeParry(): ()
	freeze(CONFIG.ParrySeconds)
end

-- The heaviest freeze, on a posture break -- the biggest single moment in the exchange.
function HitStop.FreezePostureBreak(): ()
	freeze(CONFIG.PostureBreakSeconds)
end

-- The dev-menu flight feature's landing-impact freeze -- Hard is a real, heavier hitch (closer to
-- PostureBreakSeconds' weight); Soft barely more than a single frame. Purely cosmetic, no combat
-- implication -- see this file's own header for why it's on a separate throttle/track domain.
function HitStop.FreezeFlightLanding(isHard: boolean): ()
	freezeFlight(if isHard then CONFIG.FlightLandingHardSeconds else CONFIG.FlightLandingSoftSeconds)
end

return HitStop
