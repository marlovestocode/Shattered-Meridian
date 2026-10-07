--!strict
--[[
	RunLadder.lua

	Owns: the pure arithmetic of the run ladder -- one tick of the charge clock, which stage a given
	charge amounts to, and what a stage is worth as a speed multiplier. Three small functions with no
	Instance access, no state of their own, and no idea who is calling them.

	WHY PURE, AND WHY SHARED. The stage decides a WalkSpeed multiplier, so the SERVER must be the one
	that resolves it -- Server/Systems/RunSystem.lua drives these functions once per tick and publishes
	the result as AttributeConstants.SprintStage. But the client needs the same answers too, for its
	own presentation (which run clip, which footstep, how deep the FOV pull) and for the parkour
	framework's ground-speed belief. Two implementations of "what stage is this" is exactly the split
	that lets a client show full stride while the server is granting stage 1.

	So the arithmetic lives here, once, and the AUTHORITY lives on the server. The client is welcome to
	call these; it just never gets to decide the inputs. If a client lies to itself about the stage it
	gets a wrong animation and no extra speed at all, which is the correct failure mode.

	THE LADDER IS DATA, NOT BRANCHES. Every function below walks RunConstants.Stages rather than
	testing `stage >= 2` -- which is what makes resizing the ladder a one-line change to that array. The
	original implementation branched on the number in five places across three files, which is why growing
	it to three stages was a rewrite rather than an edit -- and why dropping the third gear back out
	afterwards was a single deleted entry.

	Does not own: any of the numbers (Shared/Run/RunConstants.lua), when a tick happens or what the
	conditions are (Server/Systems/RunSystem.lua resolves those from live state), or anything the
	client does about a stage (Client/Movement/RunController.lua).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RunConstants = require(ReplicatedStorage.Shared.Run.RunConstants)

type StageDefinition = RunConstants.StageDefinition

local RunLadder = {}

-- Stage 0 is not a stage in the ladder -- it is the absence of one. It means "not running", which is
-- keyed off the held intent rather than off the tier gate: a stage that dropped to 0 for the fifth of
-- a second of a swing's commitment lock would make the client tear down and rebuild the entire run
-- presentation mid-fight. The tier gate stops the CHARGE, not the stage.
local NOT_RUNNING = 0

-- One tick of the charge clock. Pure arithmetic; the caller resolves the two booleans, because
-- deciding them needs live Attributes and a Humanoid and this function is meant to be testable
-- without either.
--
--   * `held` (a parkour action currently owns this character's velocity) FREEZES the charge -- neither
--     accruing nor decaying. See RunConstants.Stages' own header for why a vault mid-run must not cost
--     the player their gear. It does not accrue either: a nine-second wall-run is not nine seconds of
--     running.
--   * `accruing` (the run tier is granted AND the character is genuinely moving) builds toward the
--     ladder's ceiling and stops there.
--   * Neither: decay -- at one of TWO rates, chosen by how long this has been going on. See
--     RunConstants.StopGraceSeconds for why a flicker and a stop must not cost the same.
--
-- `notAccruingSeconds` is how long accrual has been off, INCLUDING this tick, and the caller owns that
-- counter (RunSystem keeps one per player). Passed in rather than tracked here so this function stays
-- pure and testable -- the same split every other function in this module keeps.
--
-- A non-positive deltaTime returns the charge untouched rather than integrating backwards, which is
-- what a paused or first-frame tick hands in.
function RunLadder.StepCharge(
	previousCharge: number,
	deltaTime: number,
	accruing: boolean,
	held: boolean,
	notAccruingSeconds: number
): number
	if deltaTime <= 0 or held then
		return previousCharge
	end
	if accruing then
		return math.min(previousCharge + deltaTime, RunConstants.MaxChargeSeconds)
	end
	local multiplier = if notAccruingSeconds > RunConstants.StopGraceSeconds
		then RunConstants.StopDecayMultiplier
		else RunConstants.ChargeDecayMultiplier
	return math.max(previousCharge - deltaTime * multiplier, 0)
end

-- Which stage a given charge amounts to.
--
-- Takes the PREVIOUS stage because every stage above the first is hysteretic: crossing INTO it takes
-- its full ChargeSeconds, but STAYING in it only takes SustainFraction of that. Walking the ladder
-- from the top down and returning the first stage whose requirement is met means a player who has
-- earned stage 2 is tested against stage 2's sustain floor first, and only falls to stage 1 once they
-- are genuinely below it -- rather than being re-tested from the bottom every tick and flickering
-- between two gears at the boundary.
--
-- `sprinting` is the player's held INTENT, and it short-circuits everything: releasing the key drops
-- the stage to 0 immediately, even though the charge itself decays gradually. That pair is deliberate
-- -- it is what lets a player who let go for half a second to round a corner keep the gear they
-- earned, without anything downstream ever reading a stage they are not currently holding.
function RunLadder.ResolveStage(previousStage: number, chargeSeconds: number, sprinting: boolean): number
	if not sprinting then
		return NOT_RUNNING
	end
	local stages = RunConstants.Stages
	for index = #stages, 1, -1 do
		local stage = stages[index]
		-- Held stages are measured against their sustain floor, stages being entered against the full
		-- requirement. `>=` on the comparison so a stage authored at 0 charge (stage 1) is always met.
		local required = if previousStage >= stage.Id
			then stage.ChargeSeconds * stage.SustainFraction
			else stage.ChargeSeconds
		if chargeSeconds >= required then
			return stage.Id
		end
	end
	-- Unreachable with the shipped ladder (stage 1 requires zero charge, so the loop above always
	-- returns), but a ladder retuned to require charge for its first gear would fall through to here.
	-- "Holding the key but has not earned a gear yet" is stage 0, not an error.
	return NOT_RUNNING
end

-- What a stage is worth, as a multiplier on the effective base walk speed. Stage 0 -- and any stage id
-- the ladder does not define, which is what a client running an older build reads off the Attribute --
-- is 1: ordinary walking, no multiplier. Defaulting to "no bonus" rather than to the nearest stage is
-- the safe direction to be wrong in.
function RunLadder.SpeedMultiplier(stage: number): number
	for _, definition in RunConstants.Stages do
		if definition.Id == stage then
			return definition.SpeedMultiplier
		end
	end
	return 1
end

-- The highest stage the ladder defines. Read by the client's presentation layer so it can clamp a
-- stage it has no assets for down to the best it does have, rather than silently presenting nothing.
function RunLadder.MaxStage(): number
	local highest = NOT_RUNNING
	for _, definition in RunConstants.Stages do
		if definition.Id > highest then
			highest = definition.Id
		end
	end
	return highest
end

-- How far through the CURRENT gear's charge requirement the player is, as 0..1, for a HUD stride
-- meter or the debug overlay. Returns 1 while in the top gear (there is nothing left to fill toward)
-- and 0 while not running. Read-only projection -- nothing gates on it.
function RunLadder.ChargeProgress(stage: number, chargeSeconds: number): number
	if stage <= NOT_RUNNING then
		return 0
	end
	local stages = RunConstants.Stages
	for index, definition in stages do
		if definition.Id == stage then
			local nextStage = stages[index + 1]
			if not nextStage then
				return 1
			end
			local floor = definition.ChargeSeconds
			local ceiling = nextStage.ChargeSeconds
			local span = ceiling - floor
			if span <= 0 then
				return 1
			end
			return math.clamp((chargeSeconds - floor) / span, 0, 1)
		end
	end
	return 0
end

return RunLadder
