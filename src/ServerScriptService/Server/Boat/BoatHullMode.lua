--!strict
--[[
	BoatHullMode.lua

	Owns: the one question "who is sailing this hull right now, and with what" -- the state machine over
	BoatTypes.HullMode, and the resolution of that mode plus a sail rung plus a helmsman's rudder into
	the single DriveIntent the integrator is handed each tick.

	WHY THIS IS A MACHINE AND NOT A PILE OF FLAGS -- the identical argument BlimpFlightMode.lua's header
	makes, and it is worth reading there in full. Three booleans on the record (adrift, beached,
	abandoned) admit states that mean nothing, and every reader downstream then has to independently
	invent a precedence rule for them. They disagree, and the disagreement shows up as a boat that
	furls her sails while her skipper is holding full canvas. One value cannot be in two modes, so
	nothing downstream has to decide.

	TOUCHES NO INSTANCE, the same contract Server/Boat/BoatDrive.lua sets out next door and for the same
	payoff: "does an abandoned boat give up her sails", "does a passenger boarding stop the abandon
	clock", "can a beached skipper still work the helm to back off" are all answerable in the TestEZ
	suite by advancing a table. Whether there is water under the hull arrives as a plain boolean from the
	caller -- Server/Boat/BoatWater.lua owns the tag walk that produces it -- so this module never learns
	what CollectionService is.

	BEACHED OUTRANKS EVERYTHING, INCLUDING A PILOT, and that ordering is the one non-obvious thing in the
	file. A hull aground with a skipper at the wheel is Beached, not Piloted: aground is a fact about her
	contact with the world and it is what the panel has to say, whereas "somebody is steering" is still
	true and still gets its effect, because ResolveIntent hands a beached hull's pilot their full rudder
	and their full rung anyway. The mode is the HEADLINE, not the permission -- and BoatDrive.Step is
	what actually refuses her forward drive, because that is a fact about the ground rather than about
	who is holding the wheel.

	A BEACHED HULL NEVER REACHES Anchored, even after everybody leaves, and that is deliberate rather
	than an oversight in the ordering. "Anchored" is a claim that she is lying safely; a boat up on a
	shoal is not, and saying so would be the panel lying to the next player who walks past. The abandon
	clock keeps running underneath, so the moment a tide, a builder or a shove floats her off she goes
	straight to Anchored without a grace period she has already served.

	THE ASYMMETRY WORTH KNOWING, and it is the same one the blimp has: a hull with people aboard is
	ALWAYS in a mode a player chose (Piloted, Adrift or Moored), and a hull with nobody aboard is NEVER
	under sail. An empty hull goes Moored the same tick the last person steps off -- she carries her way
	off and lies to -- and then, after the grace, Anchored. That is the safety property the whole file
	exists for: a latched sail setting with nobody aboard would otherwise be a runaway hull reaching for
	the edge of the map until the server restarts.

	Does not own: the tunables (Shared/Boat/BoatConstants.Adrift/Beaching), the sail ladder itself
	(Shared/Boat/BoatSailLadder.lua), the integration (BoatDrive.lua), or any Instance touch
	(Server/Systems/BoatSystem.lua and Server/Boat/BoatWater.lua).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BoatConstants = require(ReplicatedStorage.Shared.Boat.BoatConstants)
local BoatTypes = require(ReplicatedStorage.Shared.Boat.BoatTypes)

local BoatHullMode = {}

-- Seconds. Same clamp, same reasoning, as BoatDrive's own: a tick longer than this is a server hitch,
-- and banking it whole would blow straight through the abandon grace in one frame.
local MAX_STEP_SECONDS = 0.25

-- Everything the machine is allowed to know about the world this tick. Assembled by the caller from
-- facts it already has.
export type Context = {
	-- Somebody is holding the helm. Implies OccupantCount > 0.
	HasPilot: boolean,
	-- Everybody aboard, helm and handholds alike. Passengers count: a boat with four people on her rails
	-- is not abandoned just because nobody is steering.
	OccupantCount: number,
	-- The Adrift latch, as last set from the helm. Note this is the pilot's ARMED flag, not a mode --
	-- whether it actually does anything is this machine's decision, not the flag's.
	AdriftArmed: boolean,
	-- Whether Server/Boat/BoatWater.lua found any tagged plane under the hull this tick.
	WaterSupported: boolean,
}

export type State = {
	Mode: BoatTypes.HullMode,
	-- Seconds since the last occupant left. Reset by anyone boarding, not by the mode changing.
	UnoccupiedSeconds: number,
}

function BoatHullMode.NewState(): State
	return {
		Mode = "Moored",
		UnoccupiedSeconds = 0,
	}
end

-- One tick. Pure: `state` is never mutated, the successor is returned -- the same contract, for the same
-- reasons, as BoatDrive.Step immediately next door.
function BoatHullMode.Step(state: State, context: Context, deltaTime: number): State
	local dt = math.clamp(deltaTime, 0, MAX_STEP_SECONDS)
	local occupied = context.OccupantCount > 0

	-- Somebody is aboard: the abandon clock is not merely paused, it is RESET. A boat that was two
	-- seconds from giving up and then had a passenger climb aboard gets the full grace again the next
	-- time she empties, rather than the two seconds she had left.
	local unoccupiedSeconds = if occupied then 0 else state.UnoccupiedSeconds + dt

	local mode: BoatTypes.HullMode
	if not context.WaterSupported then
		-- Outranks everything -- see this file's header on why the headline is the ground and not the
		-- helm, and on why an abandoned aground hull is never called Anchored.
		mode = "Beached"
	elseif context.HasPilot then
		mode = "Piloted"
	elseif occupied then
		mode = if context.AdriftArmed then "Adrift" else "Moored"
	elseif unoccupiedSeconds >= BoatConstants.Adrift.AbandonGraceSeconds then
		mode = "Anchored"
	else
		mode = "Moored"
	end

	return {
		Mode = mode,
		UnoccupiedSeconds = unoccupiedSeconds,
	}
end

-- The one DriveIntent the integrator sees, for this mode. `sailFraction` is the latched rung's own
-- canvas fraction (BoatSailLadder.ThrottleAt) and `helm` is the pilot's last received rudder.
--
-- FOUR OF THE FIVE MODES ARE ONE LINE EACH and the fifth is the interesting one:
--   Piloted  -- a human's rung and a human's rudder. The ordinary case.
--   Adrift   -- the rung the pilot left latched, and NO rudder. She holds her course because
--               BoatDrive.Step's yaw rate decays to zero on a neutral helm all by itself, not because
--               anything here is steering. See BoatConstants.Adrift on why that is the whole feature.
--   Moored   -- sails in, helm centred. She carries her way off and lies to.
--   Anchored -- identical to Moored in what it COMMANDS, and a separate mode anyway, because the two
--               are different claims about the boat and a panel that could not tell them apart would
--               be unable to say whether anyone is expected back.
--   Beached  -- her skipper keeps everything, if she has one. Backing off a shoal needs the rung and
--               it needs the rudder, and refusing either would strand a player with no recovery at all.
--               BoatDrive.Step is what actually declines the forward half.
function BoatHullMode.ResolveIntent(
	mode: BoatTypes.HullMode,
	context: Context,
	sailFraction: number,
	helm: BoatTypes.HelmInput
): BoatTypes.DriveIntent
	if mode == "Piloted" then
		return { Sail = sailFraction, Steer = helm.Steer }
	end
	if mode == "Adrift" then
		return { Sail = sailFraction, Steer = 0 }
	end
	if mode == "Beached" then
		if context.HasPilot then
			return { Sail = sailFraction, Steer = helm.Steer }
		end
		return { Sail = 0, Steer = 0 }
	end
	return { Sail = 0, Steer = 0 }
end

-- The multiple applied to the hull's deceleration this tick -- 1 ordinarily, and
-- BoatConstants.Beaching.DecelerationMultiple while aground. Its own function rather than a branch at
-- the call site so "what does being aground actually DO to her" has exactly one answer, next to the
-- mode that decided it.
function BoatHullMode.DecelerationMultiple(mode: BoatTypes.HullMode): number
	if mode == "Beached" then
		return BoatConstants.Beaching.DecelerationMultiple
	end
	return 1
end

return BoatHullMode
