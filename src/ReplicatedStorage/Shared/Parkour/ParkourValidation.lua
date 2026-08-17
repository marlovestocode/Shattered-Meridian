--!strict
--[[
	ParkourValidation.lua

	Owns: the pure decision half of Server/Systems/ParkourSystem.lua's trust boundary -- whether a
	client's parkour action report is well-formed, and whether its claims are physically plausible
	against what the server can independently observe about that character.

	WHAT THIS IS AND ISN'T, stated plainly because overstating it would be worse than not having it:
	Roblox gives a client network ownership of its own character's unanchored parts. That is true
	with or without this system -- a cheating client could already write its own CFrame before any of
	this existed. So this module does NOT and cannot prevent movement exploits in general. What it
	does do, and what it is worth having for:
	  * Keeps an HONEST client's state machine and the server's view of it in agreement, so the
	    server-side WalkSpeed resolver (Server/Combat/Movement.lua) never fights a legitimate parkour
	    action or grants ownership for one that already ended.
	  * Rejects the crude and obviously-impossible: a vault that claims 200 studs of lift, a report
	    stream faster than any human input, an ownership window claimed and never closed.
	  * Feeds a rejection counter into the EXISTING suspected-cheater path (ModerationSystem's own
	    flag), so a client producing a sustained stream of impossible claims becomes visible to a
	    human moderator rather than silently tolerated.
	Caps are therefore deliberately LOOSE (see ParkourConstants.Validation's own header): a false
	positive on an honest player mid-fight is a far worse outcome than a false negative on a cheater
	who could bypass this anyway.

	Pure and Instance-free, the same contract as Shared/Parkour/ParkourMath.lua and
	ObstacleClassifier.lua -- the caller reads the character's real position/time and passes plain
	values in. That is what lets the whole trust boundary be spec'd headlessly, which matters more
	here than anywhere else in this feature: a validator that silently stops validating is
	indistinguishable from one that works.

	Does not own: any remote, rate limiter, Player, character lookup, logging, or the decision to
	flag (Server/Systems/ParkourSystem.lua owns all of those and calls into here).
]]

local ParkourTypes = require(script.Parent.ParkourTypes)

type ActionKind = ParkourTypes.ActionKind
type ActionPhase = ParkourTypes.ActionPhase
type ActionReport = ParkourTypes.ActionReport
type RejectionReason = ParkourTypes.RejectionReason

local ParkourValidation = {}

-- Every ActionKind the remote will accept, as a set. A closed set checked server-side rather than a
-- string passed through -- an unrecognized kind is a malformed payload, not something to store and
-- later act on.
-- No separate WallJump entry: kicking off a wall is a phase of States/WallRunning.lua now, not its own
-- state, and reports as a continuation of the same "WallRun" window rather than a second kind -- see
-- ParkourTypes.ActionKind's own header.
local VALID_KINDS: { [string]: boolean } = {
	Slide = true,
	Vault = true,
	Mantle = true,
	WallRun = true,
	LedgeClimb = true,
	Leap = true,
	Roll = true,
}

local VALID_PHASES: { [string]: boolean } = {
	Start = true,
	End = true,
}

-- The subset of ParkourConstants.Validation this module reads -- its own type rather than the whole
-- constants table, same reasoning as ObstacleClassifier.ClassifierConfig.
export type ValidationConfig = {
	MaxReportedSpeed: number,
	MaxVerticalGainStuds: number,
	MaxTravelSpeed: number,
	MaxActionSeconds: number,
	-- Read only by ResolveMomentumCarry -- see its own header for what they defend against.
	MomentumCarryObservedTolerance: number,
	MomentumCarryObservedSlackStuds: number,
}

-- What the SERVER independently knows, gathered by ParkourSystem before calling in here. Nothing in
-- this table comes from the client -- that is the entire point of separating it from the report.
export type ObservedState = {
	-- Where the server currently sees this character.
	Position: Vector3,
	Now: number,
	-- The still-open action for this player, if any: what it was, when it started, and where the
	-- character was at the time. nil when no action is open.
	OpenKind: ActionKind?,
	OpenStartedAt: number?,
	OpenStartPosition: Vector3?,
	-- os.clock() of the last accepted report of this same kind, or 0 if never -- the per-kind
	-- minimum-interval guard.
	LastSameKindAt: number,
	MinSameKindIntervalSeconds: number,
}

-- Is this value a real, finite number? Rejects NaN (which compares false against itself and would
-- otherwise slip past every range check below) and the infinities, both of which a hand-crafted
-- payload can carry. The same defensive shape CombatSystem's own numeric request validation uses.
local function isFiniteNumber(value: unknown): boolean
	if typeof(value) ~= "number" then
		return false
	end
	local number = value :: number
	return number == number and number ~= math.huge and number ~= -math.huge
end

local function isFiniteVector(value: unknown): boolean
	if typeof(value) ~= "Vector3" then
		return false
	end
	local vector = value :: Vector3
	return isFiniteNumber(vector.X) and isFiniteNumber(vector.Y) and isFiniteNumber(vector.Z)
end

-- Structural validation of a raw RemoteEvent argument. Returns the typed report on success, or nil
-- plus the reason -- never a partially-trusted table. A client can send literally anything here
-- (a string, a function-carrying table, a Vector3 of NaNs), so every field is checked for both type
-- and finiteness before any of it is read as gameplay data.
function ParkourValidation.Parse(raw: unknown): (ActionReport?, RejectionReason?)
	if typeof(raw) ~= "table" then
		return nil, "MalformedPayload"
	end
	local rawTable = raw :: { [string]: unknown }

	local kind = rawTable.Kind
	if typeof(kind) ~= "string" or not VALID_KINDS[kind :: string] then
		return nil, "MalformedPayload"
	end
	local phase = rawTable.Phase
	if typeof(phase) ~= "string" or not VALID_PHASES[phase :: string] then
		return nil, "MalformedPayload"
	end
	if not isFiniteNumber(rawTable.Speed) then
		return nil, "MalformedPayload"
	end
	if not isFiniteVector(rawTable.Position) then
		return nil, "MalformedPayload"
	end

	local duration = rawTable.DurationSeconds
	if duration ~= nil and not isFiniteNumber(duration) then
		return nil, "MalformedPayload"
	end

	return {
		Kind = kind :: ActionKind,
		Phase = phase :: ActionPhase,
		Speed = rawTable.Speed :: number,
		Position = rawTable.Position :: Vector3,
		DurationSeconds = duration :: number?,
	},
		nil
end

-- Plausibility validation of an already-parsed report against what the server observes. Returns
-- true on accept, or false plus the reason.
--
-- The checks, and why each one earns its place:
--   * Position agreement -- the client's claimed position versus where the server actually sees the
--     character. This is the load-bearing one: every other claim in the report is anchored to a
--     position, so a report whose position doesn't match the body it belongs to is worthless
--     regardless of how reasonable its other numbers look.
--   * Reported speed -- catches the crude "I am moving at 5000" claim.
--   * Per-kind interval -- catches a stuck or scripted client re-firing one action every frame,
--     more cheaply and more specifically than the shared rate limiter can. START REPORTS ONLY, and
--     that restriction is load-bearing rather than a nicety -- see the End-phase note below.
--   * Duration -- a Start report may not claim an ownership window longer than MaxActionSeconds,
--     and an End report may not close a window that has been open longer than that (the server
--     expires those itself; a late End is a symptom, not something to honor).
--   * Travel between Start and End -- distance covered divided by elapsed time, against
--     MaxTravelSpeed. The one check that looks at the action as a whole rather than an instant, and
--     the only one that can catch a teleport disguised as a legitimate slide.
--   * Duplicate Start -- a second Start for a kind already open, which would otherwise leave the
--     first window's expiry orphaned.
function ParkourValidation.Validate(
	report: ActionReport,
	observed: ObservedState,
	config: ValidationConfig
): (boolean, RejectionReason?)
	if report.Speed < 0 or report.Speed > config.MaxReportedSpeed then
		return false, "ImplausibleSpeed"
	end

	-- The client's own claimed position must match where the server sees the body. Tolerance is the
	-- distance a legitimately-moving character can cover in the round trip -- generous, since this
	-- is a sanity check on the report's anchor, not a latency-sensitive hit test.
	local claimDrift = (report.Position - observed.Position).Magnitude
	if claimDrift > config.MaxTravelSpeed then
		return false, "ImplausibleTravel"
	end

	if report.Phase == "Start" then
		-- THE PER-KIND INTERVAL, and why it lives inside the Start branch rather than above the split.
		--
		-- It used to run before the phase test, applying to Starts and Ends alike, and that was a real
		-- and very visible bug rather than an over-strict rule: a Start grants velocity ownership
		-- (ParkourSystem.beginAction sets ParkourVelocityOwned, which pins the player's WalkSpeed at zero
		-- in Movement.ComputeDesiredWalkSpeed) and the End is the only thing that gives it back. Any
		-- action that legitimately ends within MinSameKindIntervalSeconds of starting therefore had its
		-- RELEASE rejected as a duplicate and left the player frozen where they stood until the server's
		-- own window expiry rescued them -- most reliably a wall-kick that reaches the ground almost
		-- immediately, which the kick phase in States/WallRunning.lua (updateDeparting) ends after 0.05s
		-- against a 0.06s interval. That is the "sometimes I get stuck when I land" report, and it is
		-- not a rate problem at all.
		--
		-- A Start is a CLAIM and a claim can be spammed, which is what this check is for. An End is a
		-- RELEASE: refusing one can never protect anything -- the worst a flood of Ends can do is close
		-- windows that are already closed -- while granting one always returns the player their own
		-- movement. There is no version of this check on the End phase that is not strictly harmful.
		if
			observed.LastSameKindAt > 0
			and (observed.Now - observed.LastSameKindAt) < observed.MinSameKindIntervalSeconds
		then
			return false, "DuplicateAction"
		end

		local duration = report.DurationSeconds
		if duration ~= nil and (duration <= 0 or duration > config.MaxActionSeconds) then
			return false, "ActionTooLong"
		end
		if observed.OpenKind == report.Kind then
			return false, "DuplicateAction"
		end
		return true, nil
	end

	-- End phase. An End with no matching open window is not an error worth rejecting -- the server
	-- expires windows on its own, so a slightly-late End for an already-expired action is the
	-- expected, benign case and honoring it is a no-op. What IS rejected is an End whose implied
	-- travel is impossible.
	local startedAt = observed.OpenStartedAt
	local startPosition = observed.OpenStartPosition
	if observed.OpenKind ~= report.Kind or startedAt == nil or startPosition == nil then
		return true, nil
	end

	local elapsed = observed.Now - startedAt
	if elapsed > config.MaxActionSeconds then
		return false, "ActionTooLong"
	end

	local travelled = (report.Position - startPosition).Magnitude
	-- A floor on elapsed time so a near-instant action (a hop, a wall-jump) doesn't divide by
	-- something close to zero and report an infinite speed for a perfectly ordinary two-stud move.
	local effectiveElapsed = math.max(elapsed, 1 / 30)
	if travelled / effectiveElapsed > config.MaxTravelSpeed then
		return false, "ImplausibleTravel"
	end

	local verticalGain = report.Position.Y - startPosition.Y
	if verticalGain > config.MaxVerticalGainStuds then
		return false, "ImplausibleVerticalGain"
	end

	return true, nil
end

-- Drops rejection timestamps older than the window, in place, and returns how many remain. The
-- rejection counter has to decay or a player who trips the validator twice a month across a long
-- session would eventually be flagged for nothing -- see ParkourConstants.Validation.
-- RejectionWindowSeconds.
--
-- Mutates and returns the same table rather than allocating a filtered copy: this is called on
-- every rejection, and the lists are tiny (bounded by RejectionsBeforeFlag) but the allocation
-- would be pure waste.
function ParkourValidation.PruneRejections(timestamps: { number }, now: number, windowSeconds: number): number
	local writeIndex = 1
	for readIndex = 1, #timestamps do
		local timestamp = timestamps[readIndex]
		if (now - timestamp) <= windowSeconds then
			timestamps[writeIndex] = timestamp
			writeIndex += 1
		end
	end
	for index = #timestamps, writeIndex, -1 do
		timestamps[index] = nil
	end
	return #timestamps
end

-- Whether a player's live rejection count has crossed the flag threshold. Trivial on its own;
-- exists as a named function so the threshold comparison lives next to PruneRejections rather than
-- being re-expressed at the call site, and so a spec can pin the exact boundary behavior (at the
-- threshold flags, one below does not).
function ParkourValidation.ShouldFlag(rejectionCount: number, threshold: number): boolean
	return rejectionCount >= threshold
end

-- THE MOMENTUM CARRY AN END REPORT HAS EARNED, or nil for "grant nothing." The one client-supplied
-- number in this feature that reaches gameplay, so it is resolved here -- pure, and specced -- rather
-- than inline in ParkourSystem where an orchestrator's environment makes it untestable.
--
-- Two independent ceilings, because this closes a real exploit rather than guarding a typo.
--
-- 1. `hadOpenWindow`. Validate deliberately ACCEPTS an End that matches no open window: the server
--    expires windows on its own, a slightly-late End is the ordinary benign case, and refusing one
--    can only strand an honest player's movement. But "not worth rejecting" was being read as
--    "earned a reward," so an End needed no Start at all to stamp a speed floor. Firing
--    End{Kind="Slide", Speed=110} on a loop while standing still -- having never performed a parkour
--    action -- held a permanent WalkSpeed near 59 against a base of 18. Every one of those reports
--    was accepted, so the suspected-cheater counter never moved either.
--
-- 2. `observedPlanarSpeed`, the speed the SERVER can see the body actually travelling. Requiring a
--    real window alone does not finish the job: an attacker can still cycle Start/End at the rate
--    limit and claim 110 each time, since a stationary player trivially passes the travel checks.
--    Comparing the claim against replicated truth is what makes the claim worth something.
--
-- The observed check is a CLAMP, never a rejection, and its tolerance is deliberately generous: the
-- server's view of a client-owned assembly is slightly stale, and an honest slide ending at real
-- speed must never lose its carry to a network hiccup. A claim inflated enough to matter is off by
-- far more than this margin. Pass observedPlanarSpeed = nil when the body can't be read at all (no
-- root part), which falls back to the reported-speed ceiling alone.
function ParkourValidation.ResolveMomentumCarry(
	reportedSpeed: number,
	observedPlanarSpeed: number?,
	hadOpenWindow: boolean,
	config: ValidationConfig
): number?
	if not hadOpenWindow then
		return nil
	end

	local carry = math.clamp(reportedSpeed, 0, config.MaxReportedSpeed)

	if observedPlanarSpeed ~= nil and observedPlanarSpeed == observedPlanarSpeed then
		-- The self-inequality above is the NaN guard, and it is load-bearing rather than defensive: a
		-- NaN ceiling would make the comparison below false and pass the raw claim straight through --
		-- the exact outcome this function exists to prevent.
		local ceiling = observedPlanarSpeed * config.MomentumCarryObservedTolerance
			+ config.MomentumCarryObservedSlackStuds
		if carry > ceiling then
			return ceiling
		end
	end

	return carry
end

return ParkourValidation
