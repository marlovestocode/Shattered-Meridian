--!strict
--[[
	ObstacleClassifier.lua

	Owns: the single decision "given something in front of the character, what -- if anything --
	should the parkour system do about it?" Answers with one of Step / Hop / Vault / Mantle / None,
	plus a stable machine-readable REASON string in every case, including the successful ones.

	The reason string is not decoration. Client/Parkour/ParkourDebug.lua displays it verbatim, which
	is what makes the design's "why a parkour action was or was not allowed" requirement actually
	answerable at runtime -- the difference between "the game didn't vault" and "TooTall: 4.9 >
	VaultMaxHeight 4.2" is the difference between a ten-minute and a two-day debugging session. Every
	early return below therefore names its own refusal rather than falling through to a generic one.

	Pure and Instance-free, same contract as Shared/Parkour/ParkourMath.lua: the caller
	(Client/Parkour/EnvironmentProbe.lua) does the raycasting and hands in plain numbers, and the
	tuning table arrives as a parameter rather than being required, so a spec can drive this with a
	synthetic config and a real caller can pass ParkourConstants.Obstacle. That separation is what
	makes the height-band logic -- the part most likely to be retuned repeatedly -- testable without
	a running game.

	Does not own: measuring the obstacle (EnvironmentProbe.lua), executing the resulting traversal
	(States/Vaulting.lua, States/Mantling.lua), or the designer overrides that force an allow/deny
	(Shared/Parkour/ParkourTagging.lua resolves those into the VaultAllowed/MantleAllowed booleans
	this module simply reads).
]]

local ObstacleClassifier = {}

-- What the classifier decided. "Step" is a real, deliberate answer, not a synonym for None: it
-- means "there IS an obstacle, it is small enough that Roblox's own character controller will walk
-- over it, and the parkour system must therefore do nothing" -- the design's "small obstacles might
-- be stepped over." Returning None for that case would be indistinguishable from "nothing there,"
-- and the debug overlay would lose the ability to show that a curb was seen and correctly ignored.
export type ObstacleAction = "None" | "Step" | "Hop" | "Vault" | "Mantle"

-- What the caller measured. Heights are measured from the character's FOOT plane, distances are
-- horizontal, and both Height and Depth may legitimately be math.huge (a wall with no top found
-- inside the sampled band; a surface with no far edge found inside the sampled depth) -- the bands
-- below are written so infinity falls out correctly rather than needing its own branch.
export type ObstacleMeasurement = {
	Found: boolean,
	Height: number,
	Depth: number,
	Distance: number,
	-- Planar speed of the character right now.
	Speed: number,
	-- Whether the character is on the ground. An airborne character never vaults or steps -- an
	-- obstacle encountered mid-air is a ledge or a wall, and belongs to those systems.
	Grounded: boolean,
	HasLandingSpace: boolean,
	HasStandingSpace: boolean,
	-- Designer overrides already resolved from tags/attributes -- see ParkourTagging.lua.
	VaultAllowed: boolean,
	MantleAllowed: boolean,
}

-- The subset of ParkourConstants.Obstacle this module reads. Declared as its own type rather than
-- typing the parameter as the whole constants table, so a spec can construct a minimal config and
-- the compiler still checks it.
export type ClassifierConfig = {
	StepMaxHeight: number,
	HopMaxHeight: number,
	VaultMaxHeight: number,
	MantleMaxHeight: number,
	VaultMaxDepth: number,
	VaultMinSpeed: number,
	MantleMaxReach: number,
}

export type Classification = {
	Action: ObstacleAction,
	Reason: string,
}

-- Allocated once per outcome shape and reused -- this runs every frame the character is moving
-- toward geometry, and a fresh table per call would be a per-frame allocation in the hot path for
-- no benefit (callers read the two fields immediately and never retain the table; the contract is
-- documented on Classify below).
local RESULTS: { [string]: Classification } = {}
local function result(action: ObstacleAction, reason: string): Classification
	local key = action .. "/" .. reason
	local existing = RESULTS[key]
	if existing then
		return existing
	end
	local created: Classification = { Action = action, Reason = reason }
	RESULTS[key] = created
	return created
end

-- Decides what to do about the measured obstacle.
--
-- IMPORTANT CALLER CONTRACT: the returned table is shared and must be read immediately, never
-- retained or mutated. See the RESULTS cache above for why.
--
-- Order of checks is deliberate and is itself the specification of the mechanic:
--   1. Nothing there / airborne          -> None. Cheapest, and the overwhelmingly common case.
--   2. Below StepMaxHeight               -> Step. The engine already handles it; we stay out of the way.
--   3. Tall enough to need a MANTLE      -> Mantle, if it's reachable, standable and allowed.
--   4. Otherwise it's vault/hop height   -> requires speed, shallow depth, landing room and allowance.
--
-- Mantle is evaluated BEFORE the vault bands rather than after, because the two overlap at their
-- boundary and the taller interpretation must win: a chest-high wall with a solid platform behind
-- it should be mantled onto, not vaulted over into a wall. The vault path's own HasLandingSpace
-- check would eventually refuse that case too, but it would refuse with "NoLandingSpace" and do
-- nothing, where the player can plainly see somewhere to climb -- exactly the class of "I can see
-- the obstacle but the system doesn't" complaint the debug mode exists to surface.
function ObstacleClassifier.Classify(measurement: ObstacleMeasurement, config: ClassifierConfig): Classification
	if not measurement.Found then
		return result("None", "NoObstacle")
	end
	if not measurement.Grounded then
		return result("None", "Airborne")
	end
	if measurement.Height <= 0 then
		return result("None", "NoHeight")
	end

	if measurement.Height <= config.StepMaxHeight then
		return result("Step", "BelowStepHeight")
	end

	-- Mantle band: anything from just above vault height up to MantleMaxHeight. Also catches the
	-- "vault-height but too deep to vault over" case below, which routes here rather than refusing.
	local needsMantle = measurement.Height > config.VaultMaxHeight
		or measurement.Depth > config.VaultMaxDepth
		or not measurement.HasLandingSpace

	if needsMantle then
		if measurement.Height > config.MantleMaxHeight then
			return result("None", "TooTallToMantle")
		end
		if not measurement.MantleAllowed then
			return result("None", "MantleNotAllowedHere")
		end
		if measurement.Distance > config.MantleMaxReach then
			return result("None", "MantleOutOfReach")
		end
		if not measurement.HasStandingSpace then
			return result("None", "NoStandingSpace")
		end
		return result("Mantle", "MantleClear")
	end

	-- Vault/hop band. Speed is required for both -- vaulting is a momentum move, and a standing
	-- player at a waist-high wall gets a mantle (handled above once HasLandingSpace fails) or
	-- nothing, never a vault animation from a dead stop.
	if measurement.Speed < config.VaultMinSpeed then
		return result("None", "TooSlowToVault")
	end
	if not measurement.VaultAllowed then
		return result("None", "VaultNotAllowedHere")
	end

	if measurement.Height <= config.HopMaxHeight then
		return result("Hop", "HopClear")
	end
	return result("Vault", "VaultClear")
end

-- Whether a classification is a traversal the parkour system should actually perform. "Step" is
-- deliberately excluded (it is an explicit decision to do nothing, see ObstacleAction above), which
-- keeps every call site from having to remember that -- and keeps the exclusion in one place if a
-- future step-up assist ever does want to act on it.
function ObstacleClassifier.IsTraversal(classification: Classification): boolean
	return classification.Action == "Hop" or classification.Action == "Vault" or classification.Action == "Mantle"
end

return ObstacleClassifier
