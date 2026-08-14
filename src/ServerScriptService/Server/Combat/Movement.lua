--!strict
--[[
	Movement.lua

	Owns: the neutral-game movement resolution CombatSystem.lua's request handlers delegate into --
	Dash's state mutation, Slide's state mutation, Sprint's state mutation, and the single unified
	WalkSpeed priority resolver (dash > slide > hit-slow > sprint > base) onHeartbeat calls every
	tick -- plus, since the Parkour System, the two functions that turn that resolver's instantaneous
	answer into one with real acceleration: SmoothWalkSpeed (ramps toward the resolved target instead
	of snapping) and ComputeParkourSpeedFloor (the decaying momentum carry a finished parkour action
	leaves behind). Both are additive to the tier logic rather than changes to it -- see each one's own
	header. A pure/state-mutation
	helper under Server/Combat/, the same role HitboxResolver/RagdollController play for their own
	concerns -- CombatSystem.lua still owns combatStates, request validation (rate limit/alive/
	stunned/posture-broken/commitment lock), logging, and remote-firing; this module only ever
	receives the CombatState it should read/mutate as a parameter, never reaches into CombatSystem's
	state tables itself.

	Does not own: whether a request is legal (CombatSystem.lua's shared pre-checks -- rate limit,
	alive, stunned, posture-broken, ragdolled, commitment lock -- are identical across every request
	handler, not movement-specific, and stay there), or any remote/network concern. Bots/dummies
	never touch this module -- neither has dash/sprint fields (CombatTypes.lua's
	BotState/DummyState), so it's exclusively a real-player CombatState concern.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Constants = require(ReplicatedStorage.Shared.Constants)
-- The Parkour System's tuning table (Shared/Parkour/ParkourConstants.lua). Required here rather than
-- duplicating its acceleration/momentum-carry numbers into Constants.Combat: the client-side movement
-- framework and this resolver have to agree on the same acceleration curve, and two copies of that
-- pair would silently diverge on the first retune. Pure data with no Instance dependency, so it costs
-- this module nothing and keeps it headlessly testable.
local ParkourConstants = require(ReplicatedStorage.Shared.Parkour.ParkourConstants)
local CombatTypes = require(script.Parent.CombatTypes)

type CombatState = CombatTypes.CombatState

local Movement = {}

-- Commits a Dash: a pure WalkSpeed burst, no i-frame window. Cancels an active block -- a player
-- can't be mid-block and mid-dash at once. The caller (handleDashRequest) is responsible for
-- checking state.dashCooldownExpiry first -- this function only applies the effect, it does not
-- itself validate legality (per this file's header, that's CombatSystem.lua's job). isFrontDash
-- (from ResolveDashDirection below) picks the longer front-lunge duration/commitment pair over the
-- plain one -- see Constants.Combat.DashFrontDurationSeconds' own comment for why a front dash
-- needs both a longer burst and a longer lock (it's carrying a punch, not just a step). isBackDash
-- picks the weaker speed multiplier + longer cooldown -- see DashBackSpeedMultiplier/
-- DashBackCooldownSeconds' own header for why backward specifically is tuned down. Mutually
-- exclusive with isFrontDash by construction (ResolveDashDirection returns exactly one direction).
function Movement.ApplyDash(state: CombatState, now: number, isFrontDash: boolean, isBackDash: boolean): ()
	local durationSeconds = if isFrontDash
		then Constants.Combat.DashFrontDurationSeconds
		else Constants.Combat.DashDurationSeconds
	local commitmentSeconds = if isFrontDash
		then Constants.Combat.DashFrontCommitmentSeconds
		else Constants.Combat.DashCommitmentSeconds
	local cooldownSeconds = if isBackDash
		then Constants.Combat.DashBackCooldownSeconds
		else Constants.Combat.DashCooldownSeconds
	state.Movement.dashWindowExpiry = now + durationSeconds
	state.Movement.dashCooldownExpiry = now + cooldownSeconds
	state.Movement.dashIsBackward = isBackDash
	-- Shared with Slide -- see MovementState.movementCooldownExpiry's own header for why this exists
	-- (closes the "alternate Dash/Slide to renew faster than either move's own cooldown" loophole).
	-- Uses the SAME cooldownSeconds just picked above, so a back-dash correctly imposes its own
	-- longer shared-cooldown floor too, not the cheaper plain-Dash one.
	state.Movement.movementCooldownExpiry = now + cooldownSeconds
	state.attackEndsAt = now + commitmentSeconds
	state.blocking = false
end

-- Which of the four directions a Dash should play/hit as, resolved from the dashing player's own
-- held movement input against their current facing -- the server never receives (or trusts) a
-- direction from the client, so this has to be computed authoritatively here, off the same
-- Humanoid.MoveDirection/HumanoidRootPart.CFrame data the character controller already replicates
-- server-side for actually moving the character. Similar dot-product-against-facing math to
-- CombatAnimator.lua's own resolveDashDirection (client-side, animation-selection only), but
-- DELIBERATELY not the same fallback: that client version defaults ambiguous/no-input presses to
-- "Front" because it only ever has to pick SOME animation to show, cosmetic either way. This
-- version gates a real gameplay decision (whether DashPunch's hitbox -- and its full-range Offset,
-- CombatSystem.lua's throwDashPunch -- gets thrown at all), so a stationary Dash press (no held
-- movement key) returns nil here instead of silently defaulting to "Front": without that
-- distinction, standing still and pressing Dash got a free punch at the dash's full offset range,
-- with no actual dash happening to have closed that distance.
function Movement.ResolveDashDirection(state: CombatState): ("Front" | "Back" | "Left" | "Right")?
	local humanoid = state.humanoid
	local rootPart = state.rootPart
	if not humanoid or not rootPart then
		return nil
	end

	local moveDirection = humanoid.MoveDirection
	if moveDirection.Magnitude < Constants.Combat.MovementInputMagnitudeThreshold then
		return nil
	end

	local rootCFrame = rootPart.CFrame
	local forwardComponent = moveDirection:Dot(rootCFrame.LookVector)
	local rightComponent = moveDirection:Dot(rootCFrame.RightVector)

	if math.abs(forwardComponent) >= math.abs(rightComponent) then
		return if forwardComponent >= 0 then "Front" else "Back"
	end
	return if rightComponent >= 0 then "Right" else "Left"
end

-- Sprint is a held intent flag, not a one-shot action -- see ComputeDesiredWalkSpeed for how/when
-- it actually raises WalkSpeed. Trivial, but routed through here so every movement-field write
-- (dash/sprint alike) goes through one module instead of some living here and some in
-- CombatSystem.lua.
--
-- Releasing sprint does NOT zero sprintChargeSeconds -- the charge decays on its own tick (see
-- ComputeSprintCharge), which is what lets a player who let go for half a second to round a corner
-- keep the stage they earned. ResolveSprintStage still drops the STAGE to 0 immediately, so nothing
-- downstream reads a stage the player isn't currently holding.
function Movement.SetSprinting(state: CombatState, sprinting: boolean): ()
	state.Movement.sprinting = sprinting
end

--
-- THE TWO-STAGE RUN.
--
-- Sprint used to be one flat WalkSpeed tier. It is now two: an ordinary sprint, and a sustained
-- "full stride" stage that engages after Constants.Combat.SprintStage2ThresholdSeconds of unbroken
-- running and multiplies base speed by SprintStage2SpeedMultiplier instead. The three functions
-- below are the whole of that mechanic -- two pure ones (unit-testable with no Humanoid) and one
-- thin state-mutating call site that CombatSystem.onHeartbeat drives once per tick, the same split
-- ComputeGenuineJumpAirborne/ComputeDesiredWalkSpeed already use in this file.
--
-- Server-authoritative in the strongest sense: the client is never asked, and never tells. It reads
-- the resolved stage off Constants.Attributes.SprintStage purely to decide which animation, which
-- footstep sound and which FOV offset to present.
--

-- The exact conditions under which the sprint SPEED TIER is granted -- extracted from
-- ComputeDesiredWalkSpeed's own sprint branch (its only other caller) so the tier and the charge
-- clock can never drift apart. That drift would be invisible and nasty in both directions: a charge
-- that accrues under conditions the tier doesn't honor would hand out stage 2 for standing in a
-- stunlock, and one that stalls under conditions the tier DOES honor would make the second stage
-- unreachable for reasons no player could see.
function Movement.IsSprintTierActive(state: CombatState, now: number): boolean
	return state.Movement.sprinting
		and not state.blocking
		and now >= state.attackEndsAt
		and now >= state.Vitals.stunExpiry
		and now >= state.Vitals.postureBrokenExpiry
end

-- One tick of the charge clock. Pure arithmetic; the caller resolves the two booleans.
--
--   * `held` (a parkour action owns this character's velocity) FREEZES the charge -- neither
--     accruing nor decaying. Vaulting a wall or wall-running mid-sprint is the movement system
--     working as designed, and dropping the player out of full stride for using it would punish
--     exactly the behavior the game wants. It doesn't accrue either, because a nine-second wall-run
--     is not seven seconds of running.
--   * `accruing` (the tier is granted AND the character is genuinely moving) builds toward the
--     threshold and stops there. Capped rather than unbounded so the charge can't be banked: a
--     player who has run for two minutes loses the stage on the same timer as one who has run for
--     eight seconds.
--   * Neither: decay, at Constants.Combat.SprintChargeDecayMultiplier times the build rate. See that
--     constant's header for why this is a decay and not a reset.
function Movement.ComputeSprintCharge(
	previousCharge: number,
	deltaTime: number,
	accruing: boolean,
	held: boolean
): number
	if deltaTime <= 0 or held then
		return previousCharge
	end
	if accruing then
		return math.min(previousCharge + deltaTime, Constants.Combat.SprintStage2ThresholdSeconds)
	end
	return math.max(previousCharge - deltaTime * Constants.Combat.SprintChargeDecayMultiplier, 0)
end

-- Which stage a given charge amounts to. Takes the PREVIOUS stage because the second stage is
-- hysteretic: crossing INTO it takes a full charge, staying in it only takes
-- Constants.Combat.SprintStage2SustainFraction of one -- see that constant's own header for the
-- flicker this closes (an onset whoosh replaying every time a runner clips a doorframe).
--
-- Stage 0 is "not sprinting at all", which is deliberately keyed off the held intent rather than off
-- the tier gate: a stage that dropped to 0 for the fifth of a second of a swing's commitment lock
-- would make the client tear down and rebuild the entire run presentation mid-fight.
function Movement.ResolveSprintStage(previousStage: number, chargeSeconds: number, sprinting: boolean): number
	if not sprinting then
		return 0
	end
	local threshold = Constants.Combat.SprintStage2ThresholdSeconds
	local sustainFloor = threshold * Constants.Combat.SprintStage2SustainFraction
	local required = if previousStage >= 2 then sustainFloor else threshold
	return if chargeSeconds >= required then 2 else 1
end

-- Advances the charge and resolves the stage for one tick, returning the new stage so the caller can
-- publish it. The only Instance-touching part of the mechanic, and it only READS: the three
-- top-priority lockouts (an admin freeze, flight, a movement-locked emote) and the parkour
-- velocity-ownership flag are all Attributes some other system already publishes, read here exactly
-- the way ComputeDesiredWalkSpeed already reads them rather than mirrored into CombatState.
--
-- The lockouts stop the clock rather than freezing it: flying across the map with the sprint key
-- held is not running, and neither is standing in an emote. Only a parkour action gets the freeze.
function Movement.UpdateSprintStage(state: CombatState, now: number, deltaTime: number): number
	local movement = state.Movement
	local humanoid = state.humanoid

	local locked = false
	local parkourOwned = false
	if humanoid then
		locked = humanoid:GetAttribute(Constants.Attributes.Frozen) == true
			or humanoid:GetAttribute(Constants.Attributes.Flying) == true
			or humanoid:GetAttribute(Constants.Attributes.EmoteMovementLocked) == true
		parkourOwned = humanoid:GetAttribute(Constants.Attributes.ParkourVelocityOwned) == true
	end

	local accruing = not locked and Movement.IsSprintTierActive(state, now) and Movement.IsMoving(state)
	movement.sprintChargeSeconds =
		Movement.ComputeSprintCharge(movement.sprintChargeSeconds, deltaTime, accruing, parkourOwned and not locked)
	movement.sprintStage =
		Movement.ResolveSprintStage(movement.sprintStage, movement.sprintChargeSeconds, movement.sprinting)
	return movement.sprintStage
end

-- Commits a Slide: a bigger, committed WalkSpeed burst than Dash, chained off Sprint. Mirrors
-- Movement.ApplyDash exactly (pure effect application -- the caller, handleSlideRequest, is
-- responsible for validating slideCooldownExpiry/state.sprinting/Movement.IsMoving first). No
-- direction to resolve, unlike Dash's 4-way ResolveDashDirection -- Slide always plays its single
-- supplied clip in whatever direction the player is already moving (no steering, see this
-- feature's own scope). Cancels an active block, same rule ApplyDash already enforces.
function Movement.ApplySlide(state: CombatState, now: number): ()
	state.Movement.slideWindowExpiry = now + Constants.Combat.SlideDurationSeconds
	state.Movement.slideCooldownExpiry = now + Constants.Combat.SlideCooldownSeconds
	-- Shared with Dash -- see MovementState.movementCooldownExpiry's own header for why this exists
	-- (closes the "alternate Dash/Slide to renew faster than either move's own cooldown" loophole).
	state.Movement.movementCooldownExpiry = now + Constants.Combat.SlideCooldownSeconds
	state.attackEndsAt = now + Constants.Combat.SlideCommitmentSeconds
	state.blocking = false
end

-- Move Creation System lunge grant (MoveDefinition.Movement, CombatSystem.ThrowCustomMove) --
-- reuses the Dash-burst SHAPE (a fixed-speed WalkSpeed window, its own priority tier in
-- ComputeDesiredWalkSpeed below) via customMoveLungeWindowExpiry/customMoveLungeSpeed, not Dash's
-- own state fields -- see MovementState.customMoveLungeWindowExpiry's own header. A no-op for a
-- non-positive distance/duration (an authored move with no real lunge to grant) rather than
-- setting a zero-length or infinite-speed window. The caller is responsible for legality (this
-- function only applies the effect, per this file's header); distanceStuds/durationSeconds have
-- already been clamped by MoveRegistryManager.Validate before reaching here.
function Movement.ApplyCustomMoveLunge(
	state: CombatState,
	now: number,
	distanceStuds: number,
	durationSeconds: number
): ()
	if distanceStuds <= 0 or durationSeconds <= 0 then
		return
	end
	state.Movement.customMoveLungeWindowExpiry = now + durationSeconds
	state.Movement.customMoveLungeSpeed = distanceStuds / durationSeconds
end

-- Whether `state`'s humanoid currently has meaningful held movement input -- the same
-- Constants.Combat.MovementInputMagnitudeThreshold ResolveDashDirection above already reads,
-- extracted as its own testable query since handleSlideRequest needs it as a real reject gate
-- (Slide requires genuinely moving, not just holding Sprint while stationary).
function Movement.IsMoving(state: CombatState): boolean
	local humanoid = state.humanoid
	if not humanoid then
		return false
	end
	return humanoid.MoveDirection.Magnitude >= Constants.Combat.MovementInputMagnitudeThreshold
end

-- Force-ends any in-flight Dash/Slide burst the moment its owner stops being in a state where
-- committed movement is legal -- stunned, posture-broken, ragdolled, pinned as the air-combo
-- attacker, or held as someone else's air-combo target (AirCombo.airComboHeldExpiry -- a live-held
-- DashPunch victim can Block/Parry, per ACTION_GATES.HeldAloft, but still can't move). Returns true
-- if it actually ended something (callers log/act on the transition).
--
-- This is a real defensive exploit fix, not tidiness. ComputeDesiredWalkSpeed evaluates the Dash and
-- Slide tiers ABOVE the hit-slow tier, and consults stunExpiry/postureBrokenExpiry only inside the
-- Sprint branch, so a burst that was legal when it started kept its full multiplier through a hit
-- that landed a frame later: press Slide, get hit, and the resolver still returned base * 2.0 for the
-- rest of the window. Constants.Combat.HitSlowMultiplier is documented as "the 'can't just run away'
-- factor" and was defeatable on reaction for the price of one movement cooldown. Nothing else in the
-- codebase cleared these two fields either -- only resetTransientCombatState (respawn) and
-- setActiveAction (starting a different action) ever zeroed them.
--
-- Ends the windows rather than merely reordering the resolver tiers: reordering would restore the
-- burst the instant the slow/stun lapsed, so a hit would pause the escape instead of cancelling it.
-- Deliberately does NOT touch the cooldown fields -- the burst is being taken away, but it was still
-- spent, so it must not become free to re-press.
function Movement.EndMovementBursts(state: CombatState, now: number): boolean
	local vitals = state.Vitals
	local interrupted = now < vitals.stunExpiry
		or now < vitals.postureBrokenExpiry
		or now < vitals.ragdollExpiry
		or now < state.AirCombo.airComboChaseExpiry
		or now < state.AirCombo.airComboHeldExpiry
	if not interrupted then
		return false
	end

	local movement = state.Movement
	if
		movement.dashWindowExpiry == 0
		and movement.slideWindowExpiry == 0
		and movement.customMoveLungeWindowExpiry == 0
	then
		return false
	end

	movement.dashWindowExpiry = 0
	movement.slideWindowExpiry = 0
	-- Move Creation System lunge -- same "burst is taken away, but was still spent" rule as Dash/
	-- Slide above (this function never touches the move's own cooldown, CombatState.
	-- customMoveReadyAt).
	movement.customMoveLungeWindowExpiry = 0
	return true
end

-- The pure decision half of CombatState.genuineJumpAirborne (see that field's own header in
-- CombatTypes.lua for the full exploit list this closes -- AirSlam/"Downslam" used to be throwable
-- after becoming airborne for ANY reason: DashPunch dash residue over a ledge, ordinary hit
-- knockback, parry recoil, or an ordinary fall with no jump ever pressed, not just a genuine jump).
-- CombatSystem.lua's onCharacterAdded wires this to the live Humanoid's own StateChanged signal
-- (the instance-touching half, which stays there rather than here -- this module's whole reason for
-- existing is to keep the actual DECISION unit-testable without a live Humanoid, the same "pure
-- function, thin call site" split HitResolution.ApplyParryPunish/ApplyDisarm already use elsewhere).
--
-- Entering Jumping is the ONE HumanoidStateType transition Roblox's own character controller fires
-- exclusively from a genuine jump request -- never from an external velocity write, never from
-- WalkSpeed-driven ground movement carrying a player off an edge (that goes straight to Freefall,
-- skipping Jumping entirely), and never from a ragdoll launch (PlatformStand blocks the Humanoid
-- state machine from ever reaching Jumping while ragdolled) -- so it's credited unconditionally.
-- Freefall is deliberately left alone (returns `previous` unchanged): it's both the natural
-- Jumping -> Freefall apex transition of an already-credited jump AND the exact state every
-- incidental-airborne case above also produces, which is harmless here specifically because
-- `previous` was never set true for those cases to begin with. Every OTHER state (Landed, Running,
-- RunningNoPhysics, GettingUp, Physics/ragdoll, Swimming, Climbing, Seated, whatever) clears the
-- flag -- the single unbroken "still falling from that one jump" stretch is over the moment the
-- Humanoid does anything else, so a stale credit from an earlier jump can never outlive it.
function Movement.ComputeGenuineJumpAirborne(previous: boolean, newState: Enum.HumanoidStateType): boolean
	if newState == Enum.HumanoidStateType.Jumping then
		return true
	end
	if newState == Enum.HumanoidStateType.Freefall then
		return previous
	end
	return false
end

-- The single, unified WalkSpeed resolver: given a player's current combat/movement state, returns
-- the one speed that should be in effect this tick. Every effect that wants to drive WalkSpeed
-- (air-combo chase lock, dash burst, hit-slow clip, sprint) is composed HERE in a fixed priority
-- order rather than each scheduling its own task.delay restore -- see CombatSystem.lua's
-- onHeartbeat (the only caller) for why a scheduled one-shot restore would race and lose data
-- between effects.
-- Priority, highest first:
--   1. Frozen (admin-only lock, DevMenuSystem.lua's SetTargetFrozen) -- overrides EVERYTHING,
--      including Flying, since an admin freeze is meant to be an absolute lockdown.
--   2. Flying (Client/DevMenu/FlightController.lua) -- above even air-combo-chase, see below.
--   3. EmoteMovementLocked (Server/Systems/EmoteSystem.lua) -- same tier as Frozen/Flying: a
--      MovementLocked emote is a deliberate full stop, not something any tier below should peek
--      through.
--   3b. ParkourVelocityOwned (Server/Systems/ParkourSystem.lua) -- same tier and same reasoning as
--      Flying immediately above: the client-side parkour framework is driving this character's
--      velocity directly (a slide, wall-run, vault, mantle, ledge climb, roll or wall-jump the server
--      has accepted), and a raised WalkSpeed underneath that fights the drive rather than riding
--      along with it. Placed BELOW Frozen/Flying/Emote (an admin lockdown, an admin flight and a
--      deliberate emote stop all outrank a movement action) and ABOVE air-combo-chase only because it
--      can never actually coexist with it -- ParkourSystem refuses to grant ownership while
--      RootControlLocked is set, and the client's own controller parks in its AerialCombat state for
--      the same signal, so the two are mutually exclusive by construction on both sides.
--   4. Air-combo chase/held -- RagdollController.HoldAloft currently owns this player's positioning
--      via a server-side AlignPosition, whether as the DashPunch ATTACKER (airComboChaseExpiry) or
--      as a live-held VICTIM (airComboHeldExpiry -- AirCombo.Apply); a player-commanded WalkSpeed
--      burst on top of either fights the pull instead of riding along with it, so this is pinned to
--      0 for the window regardless of what's held.
--   5. Dash window    -- a committed neutral burst.
--   6. Slide window   -- a bigger committed burst, chained off Sprint (ApplySlide). Grouped
--                        immediately below Dash since both lock the shared attackEndsAt commitment
--                        and can therefore never be simultaneously active -- their relative order
--                        doesn't affect correctness, this just keeps "committed burst movement"
--                        tiers together above the sustained ones below.
--   7. Hit-slow clip  -- you took an unmitigated hit; the stagger overrides your own locomotion...
--   8. Sprint         -- ...but a raised sprint speed only applies when you're otherwise free to
--                        move (not blocking, not mid-commitment, not stunned/posture-broken). ONE
--                        tier, two multipliers: which one applies is decided by the run stage
--                        UpdateSprintStage resolved this same tick (see that function). It stays a
--                        single tier rather than becoming two because stage 2 is not a different
--                        EFFECT that could compete with stage 1 for the property -- it is the same
--                        effect at a different magnitude.
--   9. Base -- itself scaled by the admin-only SpeedMultiplier Attribute (default 1) before any of
--      the tiers above multiply on top of it, the same "per-player Humanoid Attribute" shape
--      BonusWalkSpeed already uses.
function Movement.ComputeDesiredWalkSpeed(state: CombatState, now: number): number
	-- Admin-only freeze takes ABSOLUTE top priority -- an admin lockdown overrides even Flying.
	if state.humanoid and state.humanoid:GetAttribute(Constants.Attributes.Frozen) == true then
		return 0
	end

	-- Flying (Client/DevMenu/FlightController.lua) takes top priority, above even air-combo-chase:
	-- WalkSpeed is meaningless once PlatformStand suspends the Humanoid's own ground movement, but
	-- leaving it raised (e.g. Sprint, which has no Flying check of its own -- it's an unrelated
	-- ground-combat mechanic) still lets the Humanoid's OWN built-in Running state/sound fire off
	-- WalkSpeed+MoveDirection alone, regardless of PlatformStand -- confirmed in a live playtest as
	-- a phantom running sound while flying with Sprint held. Pinning to 0 here closes that off at
	-- the source instead of trying to silence the built-in sound/animation script directly.
	if state.humanoid and state.humanoid:GetAttribute(Constants.Attributes.Flying) == true then
		return 0
	end

	-- Emote System (Server/Systems/EmoteSystem.lua) -- same top priority tier as Frozen/Flying above:
	-- a MovementLocked emote (Sit, Dance, ...) should read as a genuine stop, not something Sprint or
	-- a lingering hit-slow window can still peek through. EmoteSystem sets/clears this Attribute
	-- directly on the emoting character's Humanoid; this module owns no emote state of its own.
	if state.humanoid and state.humanoid:GetAttribute(Constants.Attributes.EmoteMovementLocked) == true then
		return 0
	end

	-- Parkour System (Server/Systems/ParkourSystem.lua) -- see this function's own priority list for
	-- why this sits here. The client's movement framework is driving velocity directly for the
	-- duration of an accepted action; WalkSpeed must stand down entirely or the two fight for the same
	-- body, which is the exact failure this whole integration exists to prevent. ParkourSystem clears
	-- the Attribute on the action's End report AND expires it on its own timer, so a client that
	-- disconnects mid-slide cannot leave a character pinned at zero.
	if state.humanoid and state.humanoid:GetAttribute(Constants.Attributes.ParkourVelocityOwned) == true then
		return 0
	end

	-- "BonusWalkSpeed" is a per-player Humanoid Attribute (onCharacterAdded seeds it from
	-- Constants.Combat.DefaultBonusWalkSpeed), not a Constants read -- see that constant's own
	-- header for why: a future race/bloodline stat system can change it per-player without this
	-- module (or CombatSystem) needing to know anything about bloodlines.
	local bonus = 0
	if state.humanoid then
		local attributeValue = state.humanoid:GetAttribute(Constants.Attributes.BonusWalkSpeed)
		if typeof(attributeValue) == "number" then
			bonus = attributeValue
		end
	end
	-- Admin-only WalkSpeed scale (DevMenuSystem.lua's SetTargetSpeedMultiplier), same "per-player
	-- Humanoid Attribute" read as BonusWalkSpeed above -- defaults to 1 (no change) when unset/not a
	-- number, so an admin who's never touched this player's speed sees no behavior change at all.
	local speedMultiplier = 1
	if state.humanoid then
		local attributeValue = state.humanoid:GetAttribute(Constants.Attributes.SpeedMultiplier)
		if typeof(attributeValue) == "number" then
			speedMultiplier = attributeValue
		end
	end
	local base = (Constants.Combat.BaseWalkSpeed + bonus) * speedMultiplier
	-- Air-combo chase (the ATTACKER's own hold) and air-combo held (the VICTIM's own hold, see
	-- AirComboState.airComboHeldExpiry's own header) share this same top WalkSpeed tier -- both are a
	-- RagdollController.HoldAloft AlignPosition pin, and a player-commanded WalkSpeed burst on top of
	-- either one fights the pull instead of riding along with it.
	if now < state.AirCombo.airComboChaseExpiry or now < state.AirCombo.airComboHeldExpiry then
		return 0
	end
	-- Move Creation System lunge -- same commitment tier as Dash/Slide (both share attackEndsAt via
	-- setActiveAction, so a lunge and a Dash/Slide window can never be simultaneously active; this
	-- tier's position relative to Dash/Slide below is therefore never actually contested, grouped
	-- here purely to keep "committed burst movement" tiers together, same reasoning as Slide's own
	-- comment). Absolute WalkSpeed, not a multiplier on base -- see customMoveLungeSpeed's own header.
	if now < state.Movement.customMoveLungeWindowExpiry then
		return state.Movement.customMoveLungeSpeed
	end
	if now < state.Movement.dashWindowExpiry then
		-- Backward gets its own weaker multiplier -- see DashBackSpeedMultiplier's own header.
		local dashMultiplier = if state.Movement.dashIsBackward
			then Constants.Combat.DashBackSpeedMultiplier
			else Constants.Combat.DashSpeedMultiplier
		return base * dashMultiplier
	end
	if now < state.Movement.slideWindowExpiry then
		return base * Constants.Combat.SlideSpeedMultiplier
	end
	if now < state.Vitals.hitSlowExpiry then
		return base * Constants.Combat.HitSlowMultiplier
	end
	local groundSpeed = base
	-- The gate is Movement.IsSprintTierActive rather than the five conditions written out here, so the
	-- charge clock that decides the stage below cannot drift from the tier it feeds -- see that
	-- function's own header.
	if Movement.IsSprintTierActive(state, now) then
		-- Which of the two sprint multipliers applies is a pure read of the stage UpdateSprintStage
		-- already resolved this tick. Deliberately no charge/threshold arithmetic here: this function
		-- is called from one place, once per tick, and having it re-derive the stage would mean two
		-- answers to the same question with a tick of skew between them.
		local sprintMultiplier = if state.Movement.sprintStage >= 2
			then Constants.Combat.SprintStage2SpeedMultiplier
			else Constants.Combat.SprintSpeedMultiplier
		groundSpeed = base * sprintMultiplier
	end

	-- Parkour momentum carry, applied ONLY to the two free-movement tiers above (sprint and base) and
	-- never to any tier that returned early. That placement is the whole safety argument for this
	-- feature's one client-influenced number: a slide's earned speed survives into ordinary running,
	-- but it cannot peek through hit-slow, a stun, a posture break, a commitment lock, an air-combo
	-- hold, a freeze or a flight -- so no amount of parkour lets a player outrun the consequences of
	-- being hit, which is precisely what Constants.Combat.HitSlowMultiplier's own "can't just run away"
	-- comment exists to guarantee.
	return math.max(groundSpeed, Movement.ComputeParkourSpeedFloor(state, now))
end

-- The decaying WalkSpeed floor a just-finished parkour action leaves behind (see
-- Constants.Attributes.ParkourSpeedFloor). Read from the two Attributes Server/Systems/
-- ParkourSystem.lua stamps rather than from CombatState, the same "external system, read as an
-- Attribute" shape Frozen/Flying/EmoteMovementLocked already use -- which is what lets ParkourSystem
-- integrate with this resolver without ever touching CombatSystem's private state tables.
--
-- Decays linearly to zero across ParkourConstants.Locomotion.MomentumCarrySeconds. Linear rather than
-- exponential on purpose: the player should be able to feel exactly how long they have to spend their
-- momentum, and an exponential tail leaves a long, imperceptible remainder that reads as the carry
-- lasting longer than it usefully does.
--
-- Hard-capped at SprintSpeed * MomentumCarryMaxMultiplier regardless of what was reported. The
-- reported speed has already passed Shared/Parkour/ParkourValidation's plausibility checks by the time
-- it reaches the Attribute; this cap is the second, independent limit on the one number a client can
-- influence, so even a report that survives validation cannot translate into unbounded ground speed.
function Movement.ComputeParkourSpeedFloor(state: CombatState, now: number): number
	local humanoid = state.humanoid
	if not humanoid then
		return 0
	end
	local floorValue = humanoid:GetAttribute(Constants.Attributes.ParkourSpeedFloor)
	local expiryValue = humanoid:GetAttribute(Constants.Attributes.ParkourSpeedFloorExpiry)
	if typeof(floorValue) ~= "number" or typeof(expiryValue) ~= "number" then
		return 0
	end
	local floorSpeed = floorValue :: number
	local expiry = expiryValue :: number
	-- NaN guard: an Attribute is a number the server itself wrote, but a NaN here would compare false
	-- against every bound below and silently return NaN as a WalkSpeed, which pins the character in
	-- place with no error anywhere.
	if floorSpeed ~= floorSpeed or expiry ~= expiry then
		return 0
	end
	if now >= expiry or floorSpeed <= 0 then
		return 0
	end

	local carrySeconds = ParkourConstants.Locomotion.MomentumCarrySeconds
	local remaining = math.clamp((expiry - now) / math.max(carrySeconds, 1e-3), 0, 1)
	local capped = math.min(
		floorSpeed,
		ParkourConstants.Locomotion.SprintSpeed * ParkourConstants.Locomotion.MomentumCarryMaxMultiplier
	)
	return capped * remaining
end

-- Ramps `current` WalkSpeed toward `desired` instead of snapping to it -- the acceleration and
-- deceleration the design asked for ("sprinting, jumping, sliding ... should all influence the
-- player's velocity instead of completely resetting movement every time a new action begins"),
-- introduced without changing a single one of ComputeDesiredWalkSpeed's tiers. That separation is
-- deliberate: the tiers keep deciding WHAT speed is correct, and this decides HOW FAST the property
-- gets there, so every existing priority argument in this file survives untouched.
--
-- Two exceptions snap instantly rather than ramping, and both are correctness rather than feel:
--   * A desired speed of ZERO. Every zero in ComputeDesiredWalkSpeed is a hard stop with a real
--     reason behind it -- an admin freeze, a flight, an emote lock, an air-combo hold, parkour owning
--     velocity. Easing into any of those would leave the character drifting for a fraction of a
--     second after a lockdown was applied, which is exactly what those tiers exist to prevent.
--   * A current speed of zero. Coming OUT of one of those stops should be immediate for the same
--     reason -- a player released from a freeze or an air-combo should be able to move at once, not
--     accelerate out of it.
-- Pure arithmetic with no Instance access, so it is unit-testable alongside ComputeDesiredWalkSpeed.
function Movement.SmoothWalkSpeed(current: number, desired: number, deltaTime: number): number
	if desired <= 0 or current <= 0 then
		return desired
	end
	if deltaTime <= 0 then
		return current
	end
	local rate = if desired > current
		then ParkourConstants.Locomotion.WalkSpeedAcceleration
		else ParkourConstants.Locomotion.WalkSpeedDeceleration
	local maxStep = rate * deltaTime
	local gap = desired - current
	if math.abs(gap) <= maxStep then
		return desired
	end
	return current + maxStep * (if gap > 0 then 1 else -1)
end

return Movement
