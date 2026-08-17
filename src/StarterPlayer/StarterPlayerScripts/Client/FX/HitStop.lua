--!strict
--[[
	HitStop.lua

	Owns: the (lightweight, purely cosmetic) landing-impact freeze for the dev-menu flight feature
	(FreezeFlightLanding) -- Client/DevMenu/FlightController.lua is the only caller. Delegates to
	Client/FX/FlightAnimator.FreezeActiveFlightTrack and throttles rapid repeats on its own clock, so
	two landings close in time can't stack into unintended slow motion.

	This module used to also own the combat hit-stop freeze (FreezeAttacker/FreezeVictim/FreezeParry/
	FreezePostureBreak, delegating to CombatAnimator.FreezeActiveCombatTrack) -- both removed alongside
	the rest of the combat system. CombatAnimator.lua no longer even exposes
	FreezeActiveCombatTrack -- see that module's own header. What survives here is exactly the flight
	half, which was always independent (its own throttle clock, its own track family
	FlightAnimator.FreezeActiveFlightTrack, per this file's own long-standing "combat and flight
	animation tracks stay deliberately separate" design) and has nothing to do with combat.

	Does not own: the actual track manipulation (FlightAnimator.FreezeActiveFlightTrack), deciding
	WHICH landing happened, or the camera shake that might accompany one (CameraShake.lua). Purely
	local, purely presentation.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Constants = require(ReplicatedStorage.Shared.Constants)
local Logger = require(ReplicatedStorage.Shared.Logger)

local FlightAnimator = require(script.Parent.FlightAnimator)

local logger = Logger.scope("HitStop")

local CONFIG = Constants.FX.HitStop

local HitStop = {}

-- Builds a throttled freeze function: at most one call through to `delegate` per
-- CONFIG.MinIntervalSeconds, everything in between silently dropped. Closes over its own `lastClock`
-- upvalue so each factory call's resulting function owns an independent throttle window -- kept as
-- its own factory (rather than a single inlined freezeFlight) since a second, unrelated freeze domain
-- landing on this same throttle clock would be a hidden coupling if one were ever added back.
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

local freezeFlight = makeThrottledFreeze(FlightAnimator.FreezeActiveFlightTrack, "Flight hit-stop")

-- The dev-menu flight feature's landing-impact freeze -- Hard is a real, heavier hitch; Soft barely
-- more than a single frame. Purely cosmetic, no combat implication.
function HitStop.FreezeFlightLanding(isHard: boolean): ()
	freezeFlight(if isHard then CONFIG.FlightLandingHardSeconds else CONFIG.FlightLandingSoftSeconds)
end

return HitStop
