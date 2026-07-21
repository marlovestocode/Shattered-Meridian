--!strict
--[[
	Movement.lua

	Owns: the neutral-game movement resolution CombatSystem.lua's request handlers delegate into --
	Dash's state mutation, Slide's state mutation, Sprint's state mutation, and the single unified
	WalkSpeed priority resolver (dash > slide > hit-slow > sprint > base) onHeartbeat calls every
	tick. A pure/state-mutation
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
	state.dashWindowExpiry = now + durationSeconds
	state.dashCooldownExpiry = now + cooldownSeconds
	state.dashIsBackward = isBackDash
	-- Shared with Slide -- see CombatState.movementCooldownExpiry's own header for why this exists
	-- (closes the "alternate Dash/Slide to renew faster than either move's own cooldown" loophole).
	-- Uses the SAME cooldownSeconds just picked above, so a back-dash correctly imposes its own
	-- longer shared-cooldown floor too, not the cheaper plain-Dash one.
	state.movementCooldownExpiry = now + cooldownSeconds
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
function Movement.SetSprinting(state: CombatState, sprinting: boolean): ()
	state.sprinting = sprinting
end

-- Commits a Slide: a bigger, committed WalkSpeed burst than Dash, chained off Sprint. Mirrors
-- Movement.ApplyDash exactly (pure effect application -- the caller, handleSlideRequest, is
-- responsible for validating slideCooldownExpiry/state.sprinting/Movement.IsMoving first). No
-- direction to resolve, unlike Dash's 4-way ResolveDashDirection -- Slide always plays its single
-- supplied clip in whatever direction the player is already moving (no steering, see this
-- feature's own scope). Cancels an active block, same rule ApplyDash already enforces.
function Movement.ApplySlide(state: CombatState, now: number): ()
	state.slideWindowExpiry = now + Constants.Combat.SlideDurationSeconds
	state.slideCooldownExpiry = now + Constants.Combat.SlideCooldownSeconds
	-- Shared with Dash -- see CombatState.movementCooldownExpiry's own header for why this exists
	-- (closes the "alternate Dash/Slide to renew faster than either move's own cooldown" loophole).
	state.movementCooldownExpiry = now + Constants.Combat.SlideCooldownSeconds
	state.attackEndsAt = now + Constants.Combat.SlideCommitmentSeconds
	state.blocking = false
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
--   3. Air-combo chase -- RagdollController.HoldAloft currently owns this player's positioning via
--      a server-side AlignPosition (CombatSystem.lua's applyAirCombo); a player-commanded WalkSpeed
--      burst on top of that fights the pull instead of riding along with it, so this is pinned to 0
--      for the window regardless of what's held.
--   4. Dash window    -- a committed neutral burst.
--   5. Slide window   -- a bigger committed burst, chained off Sprint (ApplySlide). Grouped
--                        immediately below Dash since both lock the shared attackEndsAt commitment
--                        and can therefore never be simultaneously active -- their relative order
--                        doesn't affect correctness, this just keeps "committed burst movement"
--                        tiers together above the sustained ones below.
--   6. Hit-slow clip  -- you took an unmitigated hit; the stagger overrides your own locomotion...
--   7. Sprint         -- ...but a raised sprint speed only applies when you're otherwise free to
--                        move (not blocking, not mid-commitment, not stunned/posture-broken).
--   8. Base -- itself scaled by the admin-only SpeedMultiplier Attribute (default 1) before any of
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
	if now < state.airComboChaseExpiry then
		return 0
	end
	if now < state.dashWindowExpiry then
		-- Backward gets its own weaker multiplier -- see DashBackSpeedMultiplier's own header.
		local dashMultiplier = if state.dashIsBackward
			then Constants.Combat.DashBackSpeedMultiplier
			else Constants.Combat.DashSpeedMultiplier
		return base * dashMultiplier
	end
	if now < state.slideWindowExpiry then
		return base * Constants.Combat.SlideSpeedMultiplier
	end
	if now < state.hitSlowExpiry then
		return base * Constants.Combat.HitSlowMultiplier
	end
	if
		state.sprinting
		and not state.blocking
		and now >= state.attackEndsAt
		and now >= state.stunExpiry
		and now >= state.postureBrokenExpiry
	then
		return base * Constants.Combat.SprintSpeedMultiplier
	end
	return base
end

return Movement
