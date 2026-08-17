--!strict
--[[
	OutcomeResolver.lua

	Owns: what a contact turned out to be. Given one contact's geometry and the defender's posture at
	the instant it landed, returns one DefenseTypes.OutcomeKind and the guard arithmetic that goes
	with it.

	PURE. No Instances, no clock, no services, no state. Every interesting rule in this system -- is
	this a parry, did it come from behind, does the guard hold -- is a decision about a handful of
	numbers, and keeping it that way means all of it is table-driven testable without a rig. The same
	discipline that made HitboxGeometry worth separating from HitboxEngine.

	TRADE IS NOT PRODUCIBLE HERE, on purpose. Resolve sees one contact and cannot know a second one
	exists. Trades are arbitrated across a whole frame's batch by ArbitrateTrades below -- which is
	also pure, just over a list rather than a single input. A Resolve that could return Trade would be
	one that had to know about the batch, which is exactly the coupling that keeps this module honest.

	THE ORDER OF THE RULES IS THE DESIGN, so it is written out once here rather than inferred from the
	branches:
	  1. BACKSTAB outranks everything. If the defender was covering and the hit came from the rear
	     hemisphere, nothing they were doing applies -- not the block, and not the parry. Being hit
	     from behind is supposed to be the punish that makes facing matter.
	  2. PARRY next, and only within the arc. A parry from behind is not a parry.
	  3. BLOCK next, and only within the arc, and only from a posture that actually mitigates.
	  4. CLEAN otherwise -- including the flanks, which are outside the arc but not behind.

	Does not own: the defender's posture (DefenseStateMachine), the guard pool itself (GuardMeter), or
	any damage consequence (nothing in this system applies damage).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DefenseConstants = require(ReplicatedStorage.Shared.Defense.DefenseConstants)
local DefenseTypes = require(ReplicatedStorage.Shared.Defense.DefenseTypes)

local GuardMeter = require(script.Parent.GuardMeter)

type DefenseState = DefenseTypes.DefenseState
type ResolveInput = DefenseTypes.ResolveInput
type ResolveResult = DefenseTypes.ResolveResult
type PendingContact = DefenseTypes.PendingContact

local OutcomeResolver = {}

-- Geometry ---------------------------------------------------------------------------------------

-- Horizontal angle between where the defender is LOOKING and where the attacker is, in degrees.
-- 0 is dead ahead, 180 directly behind.
--
-- FACING, NOT MOVEMENT DIRECTION. Shift lock decouples the two, and the question a block asks is
-- genuinely "which way is this player looking" -- a motion-derived answer would let a backpedalling
-- player block things behind them. The same distinction the parkour states had to make, and got
-- wrong once before.
--
-- Flattened to the horizontal plane: a hit from directly above is not a hit from behind, and letting
-- the Y component into this would make a defender's block depend on the height difference to their
-- attacker. Degenerate inputs (a target directly overhead, a zero look vector) return 0 -- dead
-- ahead -- because the alternative is NaN propagating into every comparison below and silently
-- resolving everything as Clean.
function OutcomeResolver.BearingDegrees(
	lookVector: Vector3,
	defenderPosition: Vector3,
	attackerPosition: Vector3
): number
	local facing = Vector3.new(lookVector.X, 0, lookVector.Z)
	local toAttacker = attackerPosition - defenderPosition
	toAttacker = Vector3.new(toAttacker.X, 0, toAttacker.Z)

	local facingMagnitude = facing.Magnitude
	local towardMagnitude = toAttacker.Magnitude
	if facingMagnitude <= 0 or towardMagnitude <= 0 then
		return 0
	end

	local cosine = math.clamp(facing:Dot(toAttacker) / (facingMagnitude * towardMagnitude), -1, 1)
	return math.deg(math.acos(cosine))
end

function OutcomeResolver.IsWithinBlockArc(bearingDegrees: number): boolean
	return bearingDegrees <= (DefenseConstants.BlockArcDegrees * 0.5)
end

function OutcomeResolver.IsRear(bearingDegrees: number): boolean
	return bearingDegrees >= DefenseConstants.RearHemisphereDegrees
end

-- Posture ----------------------------------------------------------------------------------------

-- Whether this posture actually stops anything. Written as one function rather than spread across
-- the branches below, because "was the guard genuinely up" is asked three times and must mean the
-- same thing each time.
--
-- Raising and ParryWindow deliberately DO NOT mitigate. The guard is not live until the window
-- closes -- that is the raise time, and it is what stops a player blocking instantly out of a
-- whiffed attack. It also means a contact inside the window that is NOT parried (because something
-- earlier in the batch already spent it) lands clean, which is precisely what makes being surrounded
-- dangerous rather than merely inconvenient.
function OutcomeResolver.Mitigates(state: DefenseState, blockHeld: boolean): boolean
	if state == "Blocking" then
		return true
	end
	if state == "Staggered" or state == "ParryRecovery" then
		-- A staggered defender may block -- the brief is explicit -- and it costs them (GuardMeter
		-- applies the stagger drain multiplier). ParryRecovery only reaches here defensively; a press
		-- during it transitions straight to Blocking.
		return blockHeld
	end
	-- GuardBroken is the one posture where a held input buys nothing at all. That is the opening.
	return false
end

-- Resolution -------------------------------------------------------------------------------------

-- Classifies ONE contact. Applies nothing -- the caller owns the guard pool and decides when to
-- commit, which is what lets pass 1 classify every contact in a frame before pass 2 applies any of
-- them.
function OutcomeResolver.Resolve(input: ResolveInput): ResolveResult
	local guard = input.Guard
	local mitigates = OutcomeResolver.Mitigates(input.DefenderState, input.BlockHeld)
	local parryAvailable = input.ParryLive and not input.ParryConsumed
	local covering = mitigates or parryAvailable

	-- 1. Behind a defender who thought they were covered. Neither the block nor the parry applies.
	--    A rear hit on someone who was NOT covering is an ordinary clean hit, not a backstab --
	--    a backstab is the punish for a false sense of security, and there is none to punish if they
	--    never raised anything.
	if covering and OutcomeResolver.IsRear(input.BearingDegrees) then
		return {
			Kind = "Backstab" :: DefenseTypes.OutcomeKind,
			Guard = guard,
			GuardDelta = 0,
			ConsumesParry = false,
		}
	end

	local inArc = OutcomeResolver.IsWithinBlockArc(input.BearingDegrees)

	-- 2. The parry.
	if parryAvailable and inArc then
		local raised, delta = GuardMeter.ApplyRestore(guard, DefenseConstants.Guard.ParryRestore, input.GuardMax)
		return {
			Kind = "Parried" :: DefenseTypes.OutcomeKind,
			Guard = raised,
			GuardDelta = delta,
			ConsumesParry = true,
		}
	end

	-- 3. The block.
	if mitigates and inArc then
		local drain = GuardMeter.DrainFor(input.PowerLevel, input.DefenderState == "Staggered")
		local remaining, delta, broke = GuardMeter.ApplyDrain(guard, drain)
		return {
			Kind = (if broke then "GuardBroken" else "Blocked") :: DefenseTypes.OutcomeKind,
			Guard = remaining,
			GuardDelta = delta,
			ConsumesParry = false,
		}
	end

	-- 4. Everything else -- the flanks, an unguarded defender, a spent window.
	return {
		Kind = "Clean" :: DefenseTypes.OutcomeKind,
		Guard = guard,
		GuardDelta = 0,
		ConsumesParry = false,
	}
end

-- Batch arbitration ------------------------------------------------------------------------------

-- Collapses mutual parries within one frame's batch into Trades, in place.
--
-- Two combatants who parried each other inside the same batch produce a single mutual outcome:
-- neither is staggered, and -- unlike an ordinary parry -- NEITHER GAINS GUARD. That last part is
-- not tidiness. An earlier draft reset both guards "to a neutral value", which two players with
-- depleted guards could farm by parrying each other on purpose to refill. A trade must cost a swing
-- each and change no resource, and the only non-exploitable neutral is to grant nothing.
--
-- SIMULTANEITY IS DEFINED BY THE BATCH, which costs no new tuning value: the quantum is one engine
-- substep, already the finest distinction the engine can make. A trade window invented on top of
-- that would be a second, arbitrary number free to disagree with the first.
--
-- Pure over the list it is handed. Mutates the contacts in place because they are the caller's own
-- freshly-built records and copying a frame's batch to change two fields would be allocation for
-- nothing.
function OutcomeResolver.ArbitrateTrades(contacts: { PendingContact }): number
	local traded = 0
	for i = 1, #contacts do
		local first = contacts[i]
		if first.Result.Kind ~= "Parried" then
			continue
		end
		for j = i + 1, #contacts do
			local second = contacts[j]
			if second.Result.Kind ~= "Parried" then
				continue
			end
			-- The mirror test: each one's attacker is the other's defender. Model identity, not
			-- combatant id, so this works for anything the engine accepts -- a player, a bot, a
			-- training dummy.
			if first.Attacker == second.Defender and first.Defender == second.Attacker then
				-- Rolled back BEFORE the delta is overwritten: Resolve already folded a parry's
				-- restore into Guard, and (Guard - GuardDelta) is the only record of what it was
				-- before. Clearing the delta first would lose the amount to subtract.
				first.Result.Guard -= first.Result.GuardDelta
				second.Result.Guard -= second.Result.GuardDelta
				first.Result.GuardDelta = DefenseConstants.Guard.TradeRestore
				second.Result.GuardDelta = DefenseConstants.Guard.TradeRestore
				first.Result.Kind = "Trade"
				second.Result.Kind = "Trade"
				traded += 2
				break
			end
		end
	end
	return traded
end

return OutcomeResolver
