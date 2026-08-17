--!strict
--[[
	RunSystem.lua

	Owns: the run, authoritatively. Sprint intent as received from each client, the charge clock that
	turns sustained running into a gear, the resolved stage published as Constants.Attributes.
	SprintStage, and -- the part that makes all of that mean something -- Humanoid.WalkSpeed itself.

	THIS SYSTEM IS THE WALKSPEED OWNER. Exactly one thing in this codebase may write that property,
	because two writers on a per-Heartbeat resolver do not merge, they alternate: whichever ran last
	wins, sixty times a second, and the symptom is a character whose speed flickers between two
	correct-looking answers. That owner used to be CombatSystem.onHeartbeat driving
	Server/Combat/Movement.ComputeDesiredWalkSpeed. CombatSystem is gone in the current combat rewrite,
	and with it went every driver of the run: nothing published a stage, nothing wrote WalkSpeed, and
	nothing told the client-side parkour framework that sprint was held -- which silently took
	States/Sprinting.lua, and therefore wall-running and the sprint-chained slide with it, out of the
	game entirely. This System is that ownership rehomed somewhere running actually belongs.

	Server/Combat/Movement.lua's own resolver still exists and is still tested, but nothing drives it
	any more; it is the combat rewrite's to keep, absorb or delete. Deliberately untouched here -- this
	System reaches into no combat state and requires no combat module, so the two can land in either
	order without either one blocking the other.

	THE RESOLVER, highest priority first. Every tier is either a Humanoid Attribute some other System
	already publishes for its own reasons, or the ladder itself. Reading Attributes rather than
	inventing a registration API is what lets a System influence movement without this file ever
	learning that System exists:
	  1. Frozen              -- AdminActionSystem/DevMenuSystem. An absolute lockdown; outranks flight.
	  2. Flying              -- AdminActionSystem.SetFlying. WalkSpeed is meaningless once PlatformStand
	                            suspends ground movement, but leaving it RAISED still lets the
	                            Humanoid's own built-in Running state fire off WalkSpeed + MoveDirection
	                            regardless -- a phantom running sound while flying, confirmed in a live
	                            playtest against the old resolver. Pinned to 0 closes it at the source.
	  3. EmoteMovementLocked -- EmoteSystem. A MovementLocked emote is a deliberate full stop, not
	                            something a gear can peek through.
	  4. ParkourVelocityOwned-- ParkourSystem. The client's movement framework is driving velocity
	                            directly for an accepted action; WalkSpeed must stand down entirely or
	                            the two fight for the same body.
	  5. The run ladder      -- base times the stage's multiplier, or plain base while not running.
	  6. ParkourSpeedFloor   -- the decaying momentum carry a finished traversal leaves behind, applied
	                            as a FLOOR on tier 5 rather than as a tier of its own.

	THE SEAM FOR COMBAT. There is no hit-slow, dash or commitment tier in that list, and their absence
	is a statement of fact rather than a decision: the combat layer that produced them was deleted, so
	there is nothing to read. When it comes back it should publish its own speed effect as an Attribute
	and this file grows one tier -- which is exactly how Frozen, Flying and EmoteMovementLocked already
	work, and why none of those three required a line of code in the System that owns them. Until then,
	note honestly that "you cannot just run away from a fight" is currently unenforced, because the
	thing that enforced it does not exist.

	Does not own: sprint INPUT (Client/Movement/RunController.lua owns the key, the hold-vs-toggle
	preference and Autorun, and pushes the resulting boolean here), any presentation (Constants.Run and
	that same client module), the ladder's arithmetic (Shared/Run/RunLadder.lua) or its numbers
	(Shared/Run/RunConstants.lua).
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants = require(ReplicatedStorage.Shared.Constants)
local NetworkBridge = require(ReplicatedStorage.Shared.NetworkBridge)
local ParkourConstants = require(ReplicatedStorage.Shared.Parkour.ParkourConstants)
local RateLimiter = require(ReplicatedStorage.Shared.RateLimiter)
local RunConstants = require(ReplicatedStorage.Shared.Run.RunConstants)
local RunLadder = require(ReplicatedStorage.Shared.Run.RunLadder)
local Types = require(ReplicatedStorage.Shared.Types)
local Logger = require(ReplicatedStorage.Shared.Logger)

local logger = Logger.scope("RunSystem")

local RunSystem = {}

local ATTRIBUTES = Constants.Attributes
local REMOTE_NAMES = RunConstants.Network.RemoteNames

-- Per-player run state. Deliberately small, and deliberately NOT a mirror of anything the client
-- believes: the client sends one boolean and this System derives everything else from the live
-- character. Everything here survives a respawn except what onCharacterAdded explicitly clears -- see
-- that function for which, and why.
type PlayerRunState = {
	-- The player's held intent, as last reported. The only client-supplied value in this System.
	Sprinting: boolean,
	-- Seconds of accrued charge (Shared/Run/RunLadder.StepCharge).
	ChargeSeconds: number,
	-- The stage last resolved and published. Held so the hysteresis in ResolveStage has a previous
	-- value to test against, and so the Attribute is written only on a real change.
	Stage: number,
	-- The last WalkSpeed this System wrote, so the ramp has something to ramp FROM that is not the
	-- property itself -- reading the property back would let any other writer's value silently become
	-- this System's starting point.
	WalkSpeed: number,
	-- How long the charge has been failing to accrue, in seconds, reset to 0 on any tick that does
	-- accrue. This is what lets RunLadder.StepCharge tell a one-frame flicker from a genuine stop --
	-- see RunConstants.StopGraceSeconds. Kept here rather than inside the ladder so that function stays
	-- pure.
	NotAccruingSeconds: number,
}

local playerStates: { [Player]: PlayerRunState } = {}

local rateLimiter = RateLimiter.New(RunConstants.Network.MaxIntentPerSecondPerPlayer)

-- Last tick's clock, for a real deltaTime. Heartbeat hands one in, but it is the RENDER-independent
-- server step and using it directly is correct -- this is kept only to guard the first tick after a
-- hitch, where an enormous delta would accrue most of a gear in a single frame.
local MAX_TICK_SECONDS = 0.25

local function getState(player: Player): PlayerRunState
	local existing = playerStates[player]
	if existing then
		return existing
	end
	local created: PlayerRunState = {
		Sprinting = false,
		ChargeSeconds = 0,
		Stage = 0,
		WalkSpeed = 0,
		NotAccruingSeconds = 0,
	}
	playerStates[player] = created
	return created
end

-- Reads a number Attribute with a documented default. Every Attribute this System reads is written by
-- some other System, so "not set yet" is an ordinary state (a life that has never been touched by an
-- admin, a character mid-spawn) rather than an error -- and a non-number reads as the default for the
-- same reason, defensively, since an Attribute's type is not enforced by anything.
local function numberAttribute(humanoid: Humanoid, name: string, default: number): number
	local value = humanoid:GetAttribute(name)
	if typeof(value) ~= "number" then
		return default
	end
	local numeric = value :: number
	-- NaN guard: a NaN here compares false against every bound below and would silently propagate into
	-- WalkSpeed, which pins the character in place with no error anywhere to explain it.
	if numeric ~= numeric then
		return default
	end
	return numeric
end

-- Whether some other System has taken this character outright. Tiers 1-4 of the resolver, asked as one
-- question because the answer is the same in every case: WalkSpeed is zero and the charge clock stops.
local function isMovementLocked(humanoid: Humanoid): boolean
	return humanoid:GetAttribute(ATTRIBUTES.Frozen) == true
		or humanoid:GetAttribute(ATTRIBUTES.Flying) == true
		or humanoid:GetAttribute(ATTRIBUTES.EmoteMovementLocked) == true
end

-- The decaying WalkSpeed floor a just-finished parkour action leaves behind (Constants.Attributes.
-- ParkourSpeedFloor, stamped by Server/Systems/ParkourSystem.lua off the client's action reports).
--
-- Decays linearly to zero across ParkourConstants.Locomotion.MomentumCarrySeconds. Linear rather than
-- exponential on purpose: the player should be able to feel exactly how long they have to spend their
-- momentum, and an exponential tail leaves a long, imperceptible remainder that reads as the carry
-- lasting longer than it usefully does.
--
-- Hard-capped independently of whatever was reported. ParkourSystem has already run its own
-- plausibility checks on that number by the time it reaches the Attribute; this is the second, separate
-- limit on the one value a client can influence, so even a report that survives validation cannot
-- translate into unbounded ground speed.
local function parkourSpeedFloor(humanoid: Humanoid, now: number): number
	local floorSpeed = numberAttribute(humanoid, ATTRIBUTES.ParkourSpeedFloor, 0)
	local expiry = numberAttribute(humanoid, ATTRIBUTES.ParkourSpeedFloorExpiry, 0)
	if floorSpeed <= 0 or now >= expiry then
		return 0
	end
	local LOCOMOTION = ParkourConstants.Locomotion
	local remaining = math.clamp((expiry - now) / math.max(LOCOMOTION.MomentumCarrySeconds, 1e-3), 0, 1)
	local capped = math.min(floorSpeed, LOCOMOTION.SprintSpeed * LOCOMOTION.MomentumCarryMaxMultiplier)
	return capped * remaining
end

-- The effective base this character's gears multiply against: the game's base walk speed plus the
-- per-player BonusWalkSpeed Attribute, the whole thing scaled by the admin-only SpeedMultiplier
-- Attribute. Both are read rather than assumed for the same reason the old resolver read them -- a
-- future bloodline/stat system changes BonusWalkSpeed per player and this file never needs to know
-- bloodlines exist.
--
-- BonusWalkSpeed defaults to Constants.Combat.DefaultBonusWalkSpeed rather than to 0, and that default
-- is load-bearing rather than cosmetic. The two constants are authored as a PAIR -- BaseWalkSpeed 10
-- plus a default bonus of 8 -- and every speed comment in this codebase is written against their sum
-- of 18 ("today's 18 base -> Sprint 27"). Defaulting the bonus to 0 would quietly run the whole game
-- at a base of 10, which is not a tuning difference, it is the wrong number: every gear, and the
-- parkour framework's own mirrored tiers, would be a third short with nothing to point at.
-- onCharacterAdded seeds the Attribute explicitly, so this default is the belt to that braces -- it
-- covers the window before the seed lands and any character this System never saw spawn.
local function effectiveBaseSpeed(humanoid: Humanoid): number
	local bonus = numberAttribute(humanoid, ATTRIBUTES.BonusWalkSpeed, Constants.Combat.DefaultBonusWalkSpeed)
	local multiplier = numberAttribute(humanoid, ATTRIBUTES.SpeedMultiplier, 1)
	return (Constants.Combat.BaseWalkSpeed + bonus) * multiplier
end

-- Ramps `current` toward `desired` instead of snapping to it, so a gear change reads as an
-- acceleration rather than a teleport.
--
-- Two cases snap instantly rather than ramping, and both are correctness rather than feel:
--   * A desired speed of ZERO. Every zero in the resolver is a hard stop with a real reason behind it
--     -- an admin freeze, a flight, an emote lock, parkour owning velocity. Easing into any of those
--     would leave the character drifting for a fraction of a second after a lockdown was applied,
--     which is exactly what those tiers exist to prevent.
--   * A current speed of zero. Coming OUT of one of those should be immediate for the same reason: a
--     player released from a freeze should be able to move at once, not accelerate out of it.
local function rampWalkSpeed(current: number, desired: number, deltaTime: number): number
	if desired <= 0 or current <= 0 then
		return desired
	end
	if deltaTime <= 0 then
		return current
	end
	local rate = if desired > current then RunConstants.WalkSpeedAcceleration else RunConstants.WalkSpeedDeceleration
	local maxStep = rate * deltaTime
	local gap = desired - current
	if math.abs(gap) <= maxStep then
		return desired
	end
	return current + maxStep * (if gap > 0 then 1 else -1)
end

-- One tick for one player: advance the charge, resolve and publish the stage, resolve and write the
-- speed. The whole System, really -- everything above is a helper for this.
local function stepPlayer(player: Player, state: PlayerRunState, deltaTime: number, now: number): ()
	local character = player.Character
	local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
	if not humanoid then
		return
	end
	-- A dead character is not running, and writing WalkSpeed to a corpse fights the respawn path.
	if humanoid.Health <= 0 then
		return
	end

	local locked = isMovementLocked(humanoid)
	local parkourOwned = humanoid:GetAttribute(ATTRIBUTES.ParkourVelocityOwned) == true

	-- THE CHARGE. Accrues only while the player is both holding the intent AND genuinely moving, and
	-- only while nothing has taken the character. Freezes -- neither accruing nor decaying -- while a
	-- parkour action owns velocity, which is the one interruption that must not cost a gear.
	--
	-- `locked` beats `parkourOwned` in the freeze argument below: flying across the map with the run
	-- key held is not running, and it must not preserve a gear the way a vault does.
	local moving = humanoid.MoveDirection.Magnitude >= RunConstants.MoveInputThreshold
	local accruing = state.Sprinting and moving and not locked
	local frozen = parkourOwned and not locked

	-- HOW LONG HAS THIS BEEN GOING ON. Reset the moment accrual resumes, so the aggressive stop decay
	-- only ever applies to a genuine, sustained stop and a player who clips a doorframe for two frames
	-- never leaves the grace window. A frozen tick (a parkour action owning velocity) advances neither
	-- the charge nor this counter -- a vault is not a stop, and must not start counting as one.
	if accruing or frozen then
		state.NotAccruingSeconds = 0
	else
		state.NotAccruingSeconds += deltaTime
	end

	state.ChargeSeconds =
		RunLadder.StepCharge(state.ChargeSeconds, deltaTime, accruing, frozen, state.NotAccruingSeconds)

	-- THE STAGE. Resolved from the charge and the held intent, and published only on a real change --
	-- SetAttribute is a replicated write with a changed-signal behind it, and restating the same stage
	-- sixty times a second would be sixty round trips to tell every client nothing.
	local nextStage = RunLadder.ResolveStage(state.Stage, state.ChargeSeconds, state.Sprinting and not locked)
	if nextStage ~= state.Stage then
		state.Stage = nextStage
		humanoid:SetAttribute(ATTRIBUTES.SprintStage, nextStage)
	end

	-- THE SPEED. Tiers 1-4 first, as one zero; then the ladder; then the parkour carry as a floor.
	local desired: number
	if locked or parkourOwned then
		desired = 0
	else
		desired = effectiveBaseSpeed(humanoid) * RunLadder.SpeedMultiplier(nextStage)
		-- A floor rather than a tier, and applied ONLY here -- never to the zeros above. That placement
		-- is the whole safety argument for this feature's one client-influenced number: a slide's earned
		-- speed survives into ordinary running, but it cannot peek through an admin freeze, a flight, an
		-- emote lock, or a parkour action that currently owns the body.
		desired = math.max(desired, parkourSpeedFloor(humanoid, now))
	end

	local nextSpeed = rampWalkSpeed(state.WalkSpeed, desired, deltaTime)
	state.WalkSpeed = nextSpeed
	-- Written only when it actually changed. WalkSpeed is a replicated property, and a player standing
	-- still is the overwhelmingly common case -- restating the same number every tick for every player
	-- is the single most expensive thing a System with a Heartbeat can do for no effect.
	if humanoid.WalkSpeed ~= nextSpeed then
		humanoid.WalkSpeed = nextSpeed
	end
end

local function onHeartbeat(deltaTime: number): ()
	-- Clamped so a server hitch cannot hand the charge clock a full second and skip a gear. The tick
	-- is simply short by the overrun, which costs a fraction of a second of charge and nothing else.
	local step = math.min(deltaTime, MAX_TICK_SECONDS)
	local now = os.clock()
	for player, state in playerStates do
		stepPlayer(player, state, step, now)
	end
end

-- Sprint intent from the client. The ONE thing a client tells this System, and it is a boolean, which
-- bounds what a lying client can achieve: claiming to be sprinting forever still only earns a gear if
-- the SERVER also sees the character genuinely moving, tick after tick, on the server's own clock.
local function handleSetSprinting(player: Player, sprinting: unknown): ()
	if typeof(sprinting) ~= "boolean" then
		logger:debug("Run intent rejected -- non-boolean payload", { player = player.Name })
		return
	end
	if rateLimiter:IsLimited(player) then
		return
	end
	local state = getState(player)
	if state.Sprinting == sprinting then
		return
	end
	state.Sprinting = sprinting :: boolean
end

local function onCharacterAdded(player: Player, character: Model): ()
	local state = getState(player)
	-- A new body starts from a standstill in every sense. The charge and the stage do NOT survive a
	-- respawn: they describe a run that ended when the previous character did, and carrying them over
	-- would spawn a player mid-stride at a gear they are not holding. The INTENT deliberately does
	-- survive -- a player who respawns with the key still held should keep running, and the client
	-- re-pushes it on its own character bind anyway.
	state.ChargeSeconds = 0
	state.Stage = 0
	state.WalkSpeed = 0
	state.NotAccruingSeconds = 0

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		-- WaitForChild rather than giving up: a character model replicates in pieces and the Humanoid is
		-- routinely a frame or two behind the model itself. Bounded by the same timeout every other
		-- character-binding path in this codebase uses.
		humanoid = character:WaitForChild("Humanoid", Constants.Network.WaitForChildTimeoutSeconds) :: Humanoid?
	end
	if not humanoid then
		logger:warn("Character spawned with no Humanoid", { player = player.Name })
		return
	end
	-- Seeded explicitly rather than left unset. A client that binds before this System's first tick
	-- would otherwise read nil off the Attribute and fall back to its own default -- which is the same
	-- answer, but arrived at by accident rather than by being told.
	humanoid:SetAttribute(ATTRIBUTES.SprintStage, 0)

	-- THE PER-PLAYER SPEED BONUS, seeded here because the System that used to seed it is gone.
	-- CombatSystem.onCharacterAdded stamped this from Constants.Combat.DefaultBonusWalkSpeed on every
	-- new character; with that module deleted, nothing did, and an unset Attribute would run every
	-- character at a base of 10 instead of the 18 the entire speed table is authored against.
	--
	-- Seeded rather than overwritten: a bloodline, an Art or an admin may legitimately have already set
	-- a different value on this Humanoid, and this System's job is to guarantee the Attribute EXISTS,
	-- not to have an opinion about what it should be. Only the nil/non-number case is filled in.
	if typeof(humanoid:GetAttribute(ATTRIBUTES.BonusWalkSpeed)) ~= "number" then
		humanoid:SetAttribute(ATTRIBUTES.BonusWalkSpeed, Constants.Combat.DefaultBonusWalkSpeed)
	end
end

local function onPlayerAdded(player: Player): ()
	getState(player)
	player.CharacterAdded:Connect(function(character: Model)
		onCharacterAdded(player, character)
	end)
	if player.Character then
		onCharacterAdded(player, player.Character)
	end
end

local function onPlayerRemoving(player: Player): ()
	playerStates[player] = nil
	rateLimiter:Clear(player)
end

function RunSystem.Init(): ()
	local setSprinting = NetworkBridge.CreateRemoteEvent(REMOTE_NAMES.SetSprinting)
	setSprinting.OnServerEvent:Connect(handleSetSprinting)

	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	-- Players who joined before this System booted (a fast rejoin during server start) still need their
	-- per-player state and character hook -- the same Init()-time sweep every other PlayerAdded-driven
	-- System in this codebase uses as its backstop.
	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end

	RunService.Heartbeat:Connect(onHeartbeat)

	logger:info("RunSystem.Init() complete", { stages = #RunConstants.Stages })
end

-- The live stage for a player, for dev tooling and any System that wants to know whether someone is at
-- full stride without watching the Attribute itself. Read-only projection, never a way to set one.
function RunSystem.GetStage(player: Player): number
	local state = playerStates[player]
	return if state then state.Stage else 0
end

-- How far through the current gear's charge this player is, 0..1 -- for a HUD stride meter. Same
-- read-only contract as GetStage above.
function RunSystem.GetChargeProgress(player: Player): number
	local state = playerStates[player]
	if not state then
		return 0
	end
	return RunLadder.ChargeProgress(state.Stage, state.ChargeSeconds)
end

return RunSystem :: Types.SystemModule
