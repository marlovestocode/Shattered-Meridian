--!strict
--[[
	HitResolution.lua

	Owns: the pure decision/math logic that was duplicated across CombatSystem.lua's four hit-
	resolution paths (player-vs-player, player-vs-dummy, player-vs-bot, bot-vs-player) --
	classifying a defense (parry/block/none) from timing-window state, computing the
	resulting damage/posture from that classification, the geometric arc+line-of-sight validity
	check every swing-hit candidate goes through, finisher-variant selection priority, and applying
	a finisher's ragdoll/knockback physics. Every function here is either pure (no side effects,
	takes primitives, safe to unit-test with constructed fixtures) or -- ApplyFinisherPhysics only
	-- a narrow server-only helper in the same spirit as HitboxResolver/RagdollController: it takes
	primitives, not CombatState/BotState/DummyState, so it works identically regardless of which
	concrete state type the caller has.

	Does not own: state mutation, feedback/vitals dispatch, or remote-firing -- CombatSystem.lua's
	four resolveHitAgainst*/resolveHitFromBotAgainstPlayer orchestration functions still own all of
	that (they're tightly coupled to CombatSystem's own private remote/logging infrastructure,
	which isn't worth threading through here as callbacks for logic this small). Those functions
	call into this module for the classify/math/validity/finisher-variant decisions instead of
	each re-deriving them, which is what eliminates the duplication -- see CombatSystem.lua's
	onSwingHitCandidate and resolveHitAgainst* functions, the only callers.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Constants = require(ReplicatedStorage.Shared.Constants)
local Types = require(ReplicatedStorage.Shared.Types)
local RagdollController = require(script.Parent.RagdollController)
local CombatTypes = require(script.Parent.CombatTypes)

local HitResolution = {}

export type DefenseKind = "Parry" | "Block" | "None"

--
-- Geometric validity
--

-- Rejects a target outside the attack's arc in front of the attacker -- a flat (Y-ignored) angle
-- check between the attacker's facing and the direction to the target, so a target directly above/
-- below never fails an arc check that was only ever meant to gate left/right/behind.
local function isWithinAttackArc(attackerCFrame: CFrame, targetPosition: Vector3, arcDegrees: number): boolean
	local toTarget = targetPosition - attackerCFrame.Position
	local flatToTarget = Vector3.new(toTarget.X, 0, toTarget.Z)
	if flatToTarget.Magnitude < Constants.Combat.ZeroVectorEpsilon then
		return true
	end

	local lookVector = attackerCFrame.LookVector
	local flatLook = Vector3.new(lookVector.X, 0, lookVector.Z)
	if flatLook.Magnitude < Constants.Combat.ZeroVectorEpsilon then
		return true
	end

	local cosAngle = flatLook.Unit:Dot(flatToTarget.Unit)
	local angleDegrees = math.deg(math.acos(math.clamp(cosAngle, -1, 1)))
	return angleDegrees <= arcDegrees / 2
end

-- Rejects a hit whose straight line between the two root parts is blocked by anything solid that
-- isn't part of either combatant's own character -- range/arc alone can't catch "target is in
-- front of me and in range, but there's a wall between us." Both characters' full models are
-- excluded from the cast so a combatant's own limbs/accessories (and the target's) never
-- self-block; any other Instance the ray hits before reaching the target counts as blocked line
-- of sight.
-- Padded past the target's root position (Constants.Combat.Hitboxes.LineOfSightPadding) so
-- standing flush against a thin wall doesn't produce a false "blocked" reading from
-- floating-point edge contact.
local function hasLineOfSight(
	attackerRoot: BasePart,
	attackerCharacter: Model,
	targetRoot: BasePart,
	targetCharacter: Model
): boolean
	local origin = attackerRoot.Position
	local toTarget = targetRoot.Position - origin
	local distance = toTarget.Magnitude
	if distance < Constants.Combat.ZeroVectorEpsilon then
		return true
	end

	local direction = toTarget.Unit * (distance + Constants.Combat.Hitboxes.LineOfSightPadding)

	local raycastParams = RaycastParams.new()
	raycastParams.FilterType = Enum.RaycastFilterType.Exclude
	raycastParams.FilterDescendantsInstances = { attackerCharacter, targetCharacter }
	raycastParams.IgnoreWater = true

	local result = Workspace:Raycast(origin, direction, raycastParams)
	return result == nil
end

-- Combines the arc + line-of-sight checks every swing-hit candidate (player, dummy, or bot target)
-- goes through -- was duplicated near-verbatim three times inside CombatSystem.lua's
-- onSwingHitCandidate plus once more in onBotSwingHitCandidate. Returns a rejection reason string
-- (not just a boolean) so callers can still log specifically why a candidate was rejected, matching
-- what each duplicate site logged before this was unified. `arcDegrees` nil (no arc restriction on
-- this attack) skips straight to the line-of-sight check.
function HitResolution.IsSwingTargetValid(
	attackerRoot: BasePart,
	attackerCharacter: Model,
	targetRoot: BasePart,
	targetCharacter: Model,
	arcDegrees: number?
): (boolean, string?)
	if arcDegrees and not isWithinAttackArc(attackerRoot.CFrame, targetRoot.Position, arcDegrees) then
		return false, "OutsideArc"
	end
	if not hasLineOfSight(attackerRoot, attackerCharacter, targetRoot, targetCharacter) then
		return false, "LineOfSightBlocked"
	end
	return true, nil
end

-- Reads the admin-only "Godmode" Humanoid Attribute (AdminActionSystem.lua's own AdminOverrideState
-- mirrors it there, never here -- see that module's header) -- the exact pattern Movement.
-- ComputeDesiredWalkSpeed already established for Frozen/SpeedMultiplier/Flying: none of
-- CombatSystem.lua/DummyCombat.lua/BotCombat.lua's hit resolution ever reaches into
-- AdminActionSystem's private state, they just read the one Attribute it keeps in sync. Duck-typed
-- on `{ humanoid: Humanoid? }` so it accepts a CombatState or BotState interchangeably -- though only
-- a real player's CombatState ever has godmode granted (BotState is never an admin's own character;
-- a hit against a training bot never checks this at all).
function HitResolution.IsGodmode(state: { humanoid: Humanoid? }): boolean
	return state.humanoid ~= nil and state.humanoid:GetAttribute(Constants.Attributes.Godmode) == true
end

--
-- Defense classification + damage/posture math
--

local function isWindowActive(now: number, windowExpiry: number?): boolean
	return windowExpiry ~= nil and windowExpiry > 0 and now <= windowExpiry
end

-- The parry/block triage cascade duplicated near-verbatim across all three "real defender"
-- hit-resolution paths (player defender vs. player or bot attacker, bot defender vs. player
-- attacker). Posture-broken suppresses every defense (a fully exposed target can't parry or
-- block). Pass `parryWindowExpiry = nil` for a defender with no parry/block concept (training
-- dummies) -- it simply can never classify into that branch, exactly matching what each duplicate
-- omitted before unification. Order matters: parry beats block, same priority the original
-- cascades used.
function HitResolution.ClassifyDefense(
	now: number,
	postureBrokenExpiry: number,
	parryWindowExpiry: number?,
	blocking: boolean
): DefenseKind
	if now < postureBrokenExpiry then
		return "None"
	end
	if isWindowActive(now, parryWindowExpiry) then
		return "Parry"
	end
	if blocking then
		return "Block"
	end
	return "None"
end

-- The damage/posture multiplier lines repeated verbatim at every hit-resolution site: a "Block"
-- classification applies Constants.Combat's Block multipliers, everything else (a clean "None"
-- hit -- Parry never reaches this far, it returns before any damage is computed) passes the
-- definition's numbers through unmodified.
function HitResolution.ComputeOutcome(
	definition: Types.HitboxAttackDefinition,
	defenseKind: DefenseKind
): { Damage: number, Posture: number }
	local damageMultiplier = if defenseKind == "Block" then Constants.Combat.BlockDamageMultiplier else 1
	local postureMultiplier = if defenseKind == "Block" then Constants.Combat.BlockPostureMultiplier else 1
	return {
		Damage = definition.Damage * damageMultiplier,
		Posture = definition.PostureDamage * postureMultiplier,
	}
end

-- Zeroes posture and opens the posture-broken exposure window -- the two lines identical across
-- CombatSystem.lua's triggerPostureBreak, DummyCombat.lua's triggerDummyPostureBreak, and
-- BotCombat.lua's triggerBotPostureBreak. Takes any state table that has these two fields
-- (CombatState/BotState/DummyState all do) rather than a named type, since that's genuinely
-- everything this shared step touches -- the blocking-reset (player/bot only, a dummy has no
-- blocking field) and feedback dispatch (audience differs per state type) stay caller-owned
-- per-variant, in whichever of the three modules above is calling in.
--
-- `humanoid` is the same guard all three call sites used to hand-duplicate before this function
-- absorbed it: the killing blow that dropped posture to 0 already ran the death path synchronously
-- (Humanoid.Died fires inside TakeDamage), so a stale, contradictory PostureBreak for a target
-- whoever's watching was just told is dead must never go out. Pass nil (a target type with no
-- Humanoid to check, though none exists today) to skip the guard unconditionally. Returns whether
-- the break was actually applied, so a caller whose target turned out to already be dead knows to
-- skip its own clearBlocking/log/feedback steps too.
function HitResolution.ApplyPostureBreak(
	state: { posture: number, postureBrokenExpiry: number },
	humanoid: Humanoid?
): boolean
	if humanoid and humanoid.Health <= 0 then
		return false
	end
	state.posture = 0
	state.postureBrokenExpiry = os.clock() + Constants.Combat.PostureBreakDuration
	return true
end

--
-- Disarm
--

-- Deterministic (no RNG, matching every other decision in this module): a Heavy attack that gets
-- Parried disarms its attacker. Scoped to Heavy specifically -- combat-philosophy.md's "no true
-- unblockable/unparryable without a telegraphed cost" is read here in reverse (a defensive punish
-- bypassing the normal parry-posture-punish-only consequence needs its own telegraphed cost to be
-- fair), and Heavy's bigger commitment/payoff is that cost. Basic pressure keeps its own value
-- untouched by this -- only Heavy throws risk a disarm on top of the existing posture punish.
--
-- TEMPORARILY DISABLED (the leading "false and" short-circuits every call to false) --
-- combat-philosophy.md lists Block/Parry/Disarm as an "Established system," so this stays the
-- single, documented gate rather than being deleted or patched out at each of the 3 call sites,
-- but "Disarm" doesn't make sense yet: nothing in this codebase currently distinguishes an armed
-- weapon-swing from a bare-fisted one (Basic AND Heavy both fall back to the same punch-style
-- animations today -- CombatAnimator.lua's header). Getting disarmed while visibly just punching
-- read as a bug, correctly. Re-enable by deleting "false and" once Heavy attacks (or some other
-- explicit state) actually represent wielding a weapon.
function HitResolution.ShouldDisarm(defenseKind: DefenseKind, isHeavy: boolean): boolean
	return false and (defenseKind == "Parry" and isHeavy)
end

-- Extends (never shortens, via math.max -- mirrors StunDuration's existing extend-don't-shorten
-- pattern) disarmedUntil by Constants.Combat.Disarm.DurationSeconds. Takes any state table with
-- this one field (CombatState/BotState both do) for the same "everything this step touches" reason
-- ApplyPostureBreak above does.
function HitResolution.ApplyDisarm(state: { disarmedUntil: number }, now: number): ()
	state.disarmedUntil = math.max(state.disarmedUntil, now + Constants.Combat.Disarm.DurationSeconds)
end

-- Single source of truth for "which committed actions drop an already-armed parry window" --
-- CombatSystem.lua's setActiveAction (the ONE place activeActionKind is ever written for a player)
-- calls this rather than hand-rolling "every kind except BlockStart" inline. ClassifyDefense checks
-- parryWindowExpiry BEFORE blocking, so if a committing action forgot to clear it, holding Block
-- and then attacking would keep the window armed through the whole swing -- a free, stock-client
-- parry with no counterplay. Only BlockStart is exempt: that's the one press that's supposed to arm
-- the window in the first place (see handleBlockStart's own header). RequestBotAttack (the bot
-- equivalent, which has no activeActionKind/CombatActionKind concept to route through this) applies
-- the identical unconditional clear inline, since a bot's attack is always a guard-dropping kind.
function HitResolution.ActionDropsParryWindow(kind: CombatTypes.CombatActionKind): boolean
	return kind ~= "BlockStart"
end

-- The standard attacker-side parry punish: posture damage + a stun. Shared by a genuine Parry
-- (CombatSystem.lua's resolveHitAgainstTarget/resolveHitAgainstBot) and the air-combo tech escape
-- (handleAirTechRequest), which punishes the attacker "exactly like the existing Parry punish" by
-- design -- extracted here rather than left duplicated inline so both call sites can never drift
-- apart. Takes any state table with these two fields (CombatState/BotState both do), same "everything
-- this step touches" reason ApplyDisarm above does. Caller still owns checking posture <= 0 and
-- triggering the posture break + feedback dispatch (those need attackerPlayer/sendVitals/sendFeedback,
-- which differ per call site and aren't worth threading through here as callbacks).
function HitResolution.ApplyParryPunish(state: { posture: number, stunExpiry: number }, now: number): ()
	state.posture = math.max(0, state.posture - Constants.Combat.ParryPunishPostureDamage)
	state.stunExpiry = now + Constants.Combat.StunDuration
end

--
-- Recent-opponent tracking (proximity InCombat extension)
--

-- The write side of CombatState.recentOpponents (see that field's own header) -- shared by every
-- site that already refreshes inCombatUntil for a player-vs-player exchange (CombatSystem.lua's
-- resolveHitAgainstTarget), so the eviction rule can't drift between call sites. Refreshing
-- an ALREADY-tracked opponent's timestamp never evicts anything (that slot isn't new); only adding a
-- genuinely new opponent past Constants.Combat.MaxTrackedOpponents evicts the single OLDEST entry
-- (lowest timestamp) first -- a small, fixed-size "recently fought" set, not an unbounded history.
-- Takes any state table with just this one field (CombatState is the only type that has it today),
-- same duck-typed "everything this step touches" shape as ApplyDisarm/ApplyParryPunish above.
function HitResolution.StampRecentOpponent(
	state: { recentOpponents: { [Player]: number } },
	opponent: Player,
	now: number
): ()
	local recentOpponents = state.recentOpponents
	if recentOpponents[opponent] == nil then
		local trackedCount = 0
		local oldestOpponent: Player? = nil
		local oldestTimestamp = math.huge
		for trackedOpponent, timestamp in pairs(recentOpponents) do
			trackedCount += 1
			if timestamp < oldestTimestamp then
				oldestTimestamp = timestamp
				oldestOpponent = trackedOpponent
			end
		end
		if trackedCount >= Constants.Combat.MaxTrackedOpponents and oldestOpponent then
			recentOpponents[oldestOpponent] = nil
		end
	end
	recentOpponents[opponent] = now
end

--
-- Finisher
--

-- The 4th-hit M1 finisher variant, chosen server-side. Only ever called for a GROUNDED finisher
-- throw -- CombatSystem.lua's handleAttackRequest intercepts every Basic-attack press made while
-- airborne into the standalone AirSlam attack before the M1 combo/finisher logic ever runs (see
-- Constants.Combat.AirSlam's own header), so this function can never be reached mid-air anymore.
-- That's why it no longer takes an isAirborne parameter or has a Downslam branch -- Downslam is now
-- produced exclusively by AirSlam (CombatSystem.lua's throwAirSlam always passes "Downslam"
-- directly). Holding jump while still grounded (the narrow window between the key press and
-- Humanoid.FloorMaterial actually flipping to Air) throws Uppercut; otherwise Normal, so the input
-- is never dead.
function HitResolution.SelectFinisherVariant(holdingJump: boolean): Types.FinisherVariant
	if holdingJump then
		return "Uppercut"
	end
	return "Normal"
end

-- Applies a finisher's knockback to a target the finisher landed on cleanly (never after a
-- block/parry -- guarding is the counter to the launch). Works on any physics character (a
-- real player, a training dummy) so it takes primitives rather than CombatState/DummyState.
-- `ownerPlayer` is the target's own Player (nil for a dummy) so RagdollController hands network
-- ownership back to the right place on recovery. Returns the seconds the target is ragdolled (0
-- for Normal, which never ragdolls) so the caller can match its own action-lockout (ragdollExpiry)
-- to the physical recovery, and (second return) whether a Downslam's ground contact was immediate --
-- see RagdollController.SlamToGround's own header -- always false for Uppercut/Normal, which don't
-- involve a ground-impact VFX concept at all. Skips the launch on a lethal blow -- a corpse should go
-- through Roblox's own death handling, not fight a ragdoll we'd immediately have to recover.
function HitResolution.ApplyFinisherPhysics(
	targetCharacter: Model,
	targetHumanoid: Humanoid,
	targetRoot: BasePart,
	ownerPlayer: Player?,
	variant: Types.FinisherVariant,
	attackerRoot: BasePart?
): (number, boolean)
	if targetHumanoid.Health <= 0 then
		return 0, false
	end

	if variant == "Uppercut" then
		local cfg = Constants.Combat.Finisher.Uppercut
		-- Adapts Constants' own field names onto RagdollController.LaunchProfile's canonical shape --
		-- see that type's own header for why the two aren't required to match by name: a new finisher
		-- just needs its own small table like this one, never a RagdollController signature change.
		RagdollController.LaunchAndRagdoll(targetCharacter, targetHumanoid, targetRoot, ownerPlayer, attackerRoot, {
			UpVelocity = cfg.LaunchUpVelocity,
			HorizontalVelocity = cfg.LaunchHorizontalVelocity,
			BackwardSpin = cfg.LaunchBackwardSpin,
			RagdollSeconds = cfg.RagdollSeconds,
		})
		return cfg.RagdollSeconds, false
	elseif variant == "Downslam" then
		local cfg = Constants.Combat.Finisher.Downslam
		local immediateGroundImpact =
			RagdollController.SlamToGround(targetCharacter, targetHumanoid, targetRoot, ownerPlayer, attackerRoot, {
				DownVelocity = cfg.SlamDownVelocity,
				FaceDownSpin = cfg.FaceDownSpin,
				KnockdownSeconds = cfg.KnockdownSeconds,
			})
		return cfg.KnockdownSeconds, immediateGroundImpact
	end

	-- Normal: no launch/ragdoll. Its only extra effect is hitstun, which the caller applies (it
	-- needs the target's CombatState -- a dummy has none and simply takes the heavier hit).
	return 0, false
end

return HitResolution
