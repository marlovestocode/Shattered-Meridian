--!strict
--[[
	BlimpFlightMode.lua

	Owns: the one question "who is flying this hull right now, and with what" -- the state machine over
	BlimpTypes.HullMode, and the resolution of that mode plus a telegraph rung plus a pilot's held axes
	into the single DriveIntent the integrator is handed each tick.

	WHY THIS IS A MACHINE AND NOT THREE BOOLEANS ON THE RECORD. The first sketch of autopilot and
	unattended landing put `Autopilot: boolean` and `Landing: boolean` next to the existing `Pilot:
	Player?` on BlimpRecord and let the tick read all three. That admits states that mean nothing --
	landing while on autopilot, autopilot with a pilot aboard, neither-with-nobody-aboard -- and every
	reader downstream then has to independently invent a precedence rule for them. They disagree, and
	the disagreement shows up as a blimp that descends while its pilot holds full climb. One value
	cannot be in two modes, so nothing downstream has to decide.

	TOUCHES NO INSTANCE, the same contract Server/Blimp/BlimpDrive.lua sets out next door and for the
	same payoff: "does an abandoned ship actually give up its autopilot", "does a passenger boarding a
	descending hull stop the descent", "does a hull that clips a treetop on the way down latch Grounded
	a hundred studs up" are all answerable in the TestEZ suite by advancing a table. In particular the
	height above ground arrives as a plain number from the caller -- Server/Systems/BlimpSystem.lua owns
	the raycast that produces it -- so this module never learns what a raycast is.

	THE ONE ASYMMETRY WORTH KNOWING: a hull with people aboard is ALWAYS in a mode a player chose
	(Piloted, Autopilot or Moored), and a hull with nobody aboard is NEVER under power. An empty hull
	goes Moored the same tick the last person steps off -- it coasts to a stop and hovers -- and then,
	after the hover window, Landing. That is the safety property the whole file exists for: an armed
	autopilot with nobody aboard would otherwise be a runaway hull flying a straight line into the
	altitude ceiling until the server restarts.

	AUTOPILOT IS A THING YOU LEAVE RUNNING FOR THE PEOPLE STILL ABOARD, not a thing that outlives them.
	It holds the rung while the helm is empty AND somebody is still on the ship -- a pilot walking the
	deck to load coal, which is the entire feature. The moment the ship is empty the latch stops
	mattering here, and Server/Systems/BlimpSystem.Dismount clears it outright so a returning pilot's
	gauge agrees with what the ship is actually doing.

	Does not own: the tunables (Shared/Blimp/BlimpConstants.Autopilot/Landing), the telegraph itself
	(Shared/Blimp/BlimpSpeedLadder.lua), the integration (BlimpDrive.lua), the raycast or any other
	Instance touch (Server/Systems/BlimpSystem.lua).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BlimpConstants = require(ReplicatedStorage.Shared.Blimp.BlimpConstants)
local BlimpTypes = require(ReplicatedStorage.Shared.Blimp.BlimpTypes)

local BlimpFlightMode = {}

-- Seconds. Same clamp, same reasoning, as BlimpDrive's own: a tick longer than this is a server hitch,
-- and banking it whole would blow straight through the abandon grace in one frame.
local MAX_STEP_SECONDS = 0.25

-- Everything the machine is allowed to know about the world this tick. Assembled by the caller from
-- facts it already has -- there is nothing here it has to go and look up specially except
-- HeightAboveGround, which is the probe.
export type Context = {
	-- Somebody is holding the helm. Implies OccupantCount > 0.
	HasPilot: boolean,
	-- Everybody aboard, helm and handholds alike. Passengers count: a ship with four people hanging
	-- off the rails is not abandoned just because nobody is steering.
	OccupantCount: number,
	-- The autopilot latch, as last set from the helm. Note this is the pilot's ARMED flag, not a mode
	-- -- whether it actually does anything is this machine's decision, not the flag's.
	AutopilotArmed: boolean,
	-- Fuel-gated. Does not change the MODE (a depleted piloted hull is still Piloted -- its pilot is
	-- still standing there, and telling them they have been demoted to Moored explains nothing); it
	-- gates the resulting intent instead, in ApplyFuelGate below.
	Depleted: boolean,
	-- Studs from the hull's centre down to whatever the probe last hit, or nil when there has been no
	-- probe yet. nil is honestly different from "very high up": a landing hull with no reading must
	-- keep descending rather than latch Grounded on a number nobody measured.
	HeightAboveGround: number?,
}

export type State = {
	Mode: BlimpTypes.HullMode,
	-- Seconds since the last occupant left. Reset by anyone boarding, not by the mode changing.
	UnoccupiedSeconds: number,
	-- Seconds spent continuously within touchdown tolerance of the ground. Reset the instant the hull
	-- rises back out of it -- see BlimpConstants.Landing.SettleSeconds for what that protects against.
	SettledSeconds: number,
}

function BlimpFlightMode.NewState(): State
	return {
		Mode = "Moored",
		UnoccupiedSeconds = 0,
		SettledSeconds = 0,
	}
end

-- One tick. Pure: `state` is never mutated, the successor is returned -- the same contract, for the
-- same reasons, as BlimpDrive.Step immediately next door.
function BlimpFlightMode.Step(state: State, context: Context, deltaTime: number): State
	local dt = math.clamp(deltaTime, 0, MAX_STEP_SECONDS)

	if context.OccupantCount > 0 then
		-- Somebody is aboard: the abandon clock is not merely paused, it is reset. A ship that was
		-- eight seconds from giving up and then had a passenger climb aboard gets the full grace again
		-- the next time it empties, rather than the two seconds it had left.
		local mode: BlimpTypes.HullMode = if context.HasPilot
			then "Piloted"
			elseif context.AutopilotArmed then "Autopilot"
			else "Moored"
		return {
			Mode = mode,
			UnoccupiedSeconds = 0,
			SettledSeconds = 0,
		}
	end

	local unoccupied = state.UnoccupiedSeconds + dt

	if state.Mode == "Grounded" then
		-- Terminal while empty. Deliberately does not re-check the height: a grounded hull is holding
		-- station at its own touchdown floor, and a probe that momentarily misses (a vehicle driving
		-- underneath it, a part streaming out) must not bounce it back into Landing.
		return {
			Mode = "Grounded",
			UnoccupiedSeconds = unoccupied,
			SettledSeconds = state.SettledSeconds,
		}
	end

	if state.Mode == "Landing" then
		local landing = BlimpConstants.Landing
		local height = context.HeightAboveGround
		-- A nil height keeps descending rather than settling -- see Context.HeightAboveGround.
		local resting = height ~= nil and height <= landing.TouchdownClearanceStuds + landing.TouchdownToleranceStuds
		local settled = if resting then state.SettledSeconds + dt else 0
		return {
			Mode = if settled >= landing.SettleSeconds then "Grounded" else "Landing",
			UnoccupiedSeconds = unoccupied,
			SettledSeconds = settled,
		}
	end

	if unoccupied >= BlimpConstants.Autopilot.AbandonGraceSeconds then
		return {
			Mode = "Landing",
			UnoccupiedSeconds = unoccupied,
			SettledSeconds = 0,
		}
	end

	-- Inside the hover window, with nobody aboard. MOORED REGARDLESS OF THE LATCH -- an empty ship
	-- never keeps making way, whatever the pilot armed before they left. It coasts down its own
	-- deceleration ramp and holds altitude, so a pilot who died at the wheel and is sprinting back
	-- finds their ship stopped, at the height they left it, rather than a receding dot.
	--
	-- Written as an unconditional Moored rather than relying on Dismount having cleared the latch:
	-- that clear is what keeps the returning pilot's GAUGE honest, and this is what keeps the SHIP
	-- honest. Neither should be the other's only line of defence.
	return {
		Mode = "Moored",
		UnoccupiedSeconds = unoccupied,
		SettledSeconds = 0,
	}
end

-- Whether this hull needs its downward probe run at all. Every occupied hull answers no, which is the
-- overwhelming majority of the time a blimp is interesting -- the probe is a raycast per hull, and the
-- only consumer of its answer is a landing nobody aboard could have asked for.
--
-- True through the whole grace window rather than only once Landing begins, deliberately: the probe
-- runs at BlimpConstants.Landing.ProbeIntervalSeconds, so a hull that started probing only at the
-- moment of transition would spend its first descent frames with a nil height, which
-- Step reads (correctly) as "keep going" and which the drive reads as "no floor".
function BlimpFlightMode.WantsGroundProbe(context: Context): boolean
	return context.OccupantCount <= 0
end

-- The floor BlimpDrive.Step should be given this tick, or nil to use the hull's own MinAltitude.
--
-- A MOVING FLOOR IS THE ONLY WAY A LANDING WORKS AT ALL. Drive.MinAltitude is an absolute world Y
-- whose job is to stop a pilot burying the hull in terrain; a ship descending onto a mountain would
-- stop dead in mid-air at that altitude and hang there forever. Returns nil rather than a guess when
-- there is no probe reading, which lets the hull carry on descending under the normal floor's rules
-- until one arrives.
function BlimpFlightMode.ResolveFloor(mode: BlimpTypes.HullMode, groundY: number?): number?
	if mode ~= "Landing" and mode ~= "Grounded" then
		return nil
	end
	if not groundY then
		return nil
	end
	return groundY + BlimpConstants.Landing.TouchdownClearanceStuds
end

-- The single place that answers "what three axes does the integrator get". `throttle` is the current
-- telegraph rung's own throttle (BlimpSpeedLadder.ThrottleAt) -- the same number whether a pilot is
-- standing there or the autopilot is holding it, which is precisely what "keeps flying at the speed
-- the pilot left it at" means.
--
-- `helm` is the pilot's held rudder/elevator, or nil when nobody is at the wheel. Note that Autopilot
-- takes NEITHER even when a helm input is somehow present: an unattended ship holds its heading
-- because a neutral steer axis lets BlimpDrive's own yaw rate decay to zero, and honouring a stale
-- axis from a pilot who has walked away is how a ship ends up circling.
function BlimpFlightMode.ResolveIntent(
	mode: BlimpTypes.HullMode,
	throttle: number,
	helm: BlimpTypes.HelmInput?
): BlimpTypes.DriveIntent
	if mode == "Piloted" and helm then
		return { Throttle = throttle, Steer = helm.Steer, Lift = helm.Lift }
	end
	if mode == "Autopilot" then
		return { Throttle = throttle, Steer = 0, Lift = 0 }
	end
	if mode == "Landing" then
		return { Throttle = 0, Steer = 0, Lift = BlimpConstants.Landing.DescentLiftAxis }
	end
	-- Moored, Grounded, and the degenerate Piloted-with-no-input case: coast down the deceleration ramp
	-- rather than stopping dead, which is the behaviour a pilotless hull has always had.
	return { Throttle = 0, Steer = 0, Lift = 0 }
end

-- Fuel gating, applied AFTER ResolveIntent rather than folded into it, because the two answer
-- different questions: what does this ship want to do, and what can it still afford. Keeping them
-- apart is what lets a depleted hull still report Mode = "Piloted" to its pilot's HUD alongside a
-- separate Depleted flag -- so a pilot whose telegraph says FLANK while the ship sits still is told
-- which of those two facts is winning.
--
-- DESCENT SURVIVES DEPLETION, which is a deliberate departure from the previous "a depleted hull is
-- stepped with a wholly neutral intent" rule. Coming down costs no fuel in any model of this that
-- makes sense, and under the old rule an abandoned hull that ran dry mid-flight could never land: it
-- would hang at altitude forever with its landing sequence commanding a descent the gate zeroed. Climb
-- is still refused, and so are throttle and steering.
function BlimpFlightMode.ApplyFuelGate(intent: BlimpTypes.DriveIntent, depleted: boolean): BlimpTypes.DriveIntent
	if not depleted then
		return intent
	end
	return {
		Throttle = 0,
		Steer = 0,
		Lift = math.min(intent.Lift, 0),
	}
end

return BlimpFlightMode
