--!strict
--[[
	RunSystem.lua

	Owns: the run, authoritatively. Sprint intent as received from each client, the charge clock that
	turns sustained running into a gear, the resolved stage published as AttributeConstants.
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

	Server/Combat/Movement.lua's own resolver outlived its last caller for a while and has since been
	deleted, along with the CombatTypes.lua it typed itself against. This System is now the only thing
	in the tree that writes WalkSpeed at all, not merely the only thing driven -- which matters mostly
	because roughly fifty comments across the codebase still described that file as the live resolver,
	and those were corrected in the same change that removed it.

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
	  4. Grabbed             -- Server/Combat/Grab/GrabSystem.lua. True for a victim's whole
	                            hold-then-flight lifetime -- pinned by the same fist (or, mid-air, by
	                            nothing but the thrown velocity itself) that already owns their
	                            RootControlLocked Attribute, so WalkSpeed has nothing legitimate to
	                            drive either way. GrabThrowing, the holder's side of the same grab, shares
                            the tier: rooted for the length of their throw clip.
	  5. ParkourVelocityOwned-- ParkourSystem. The client's movement framework is driving velocity
	                            directly for an accepted action; WalkSpeed must stand down entirely or
	                            the two fight for the same body.
	  6. The run ladder      -- base times the stage's multiplier, or plain base while not running.
	  7. ParkourSpeedFloor   -- the decaying momentum carry a finished traversal leaves behind, applied
	                            as a FLOOR on tier 6 rather than as a tier of its own.

	THE SEAM FOR COMBAT, now taken. The rebuilt combat layer publishes two things this System reads,
	and neither layer required a line of code in the other:
	  * AttributeConstants.CombatBusyUntil -- an os.clock() deadline written by
	    Server/Combat/Attack/AttackRequestSystem.lua covering the swing it just accepted, AND by
	    Server/Combat/Damage/DamageSystem.lua covering the hitstun of a hit the player just took -- so
	    getting hit while running drops the run exactly as throwing a swing does.
	  * DefenseConstants.DefenseStateAttribute -- the live defence state, already published for the HUD
	    ("purely informational: nothing in this system gates on it"). It is gated on HERE, which is the
	    first consumer to make a decision out of it, so that constant's own header now understates it.
	Both mean the same thing to this file: a combat action is committing this body. WHILE COMMITTED THE
	BODY MOVES AT WALKING PACE -- the published stage and the WalkSpeed drop to 0 / base for exactly as
	long as the swing, the guard or the hitstun lasts -- but THE GEAR IS HELD, not lost: the charge is
	frozen the same way a vault freezes it, and the moment the commitment ends the player is back in the
	gear they were in, ramping up at the ordinary acceleration.

	CHANGED 2026-09-28 FROM A CHARGE RESET. It used to zero the charge on every swing and every hit, so
	a player re-earned the gear from scratch after each exchange -- and an M1 string, one swing every
	half second, never let the ladder climb past first gear at all. Playtest read that as combat being
	stop-start. (2026-10-06: the player's OWN swing now keeps part of that held gear rather than dropping to
	walking -- RunConstants.Combat.SwingGearCarry, see swingOnly. A guard, a stagger or a stun still walks.)
	The old argument for the reset ("pinning a number would hand the gear straight back the
	instant the pin lifted") is exactly what is wanted now: you cannot SPRINT while swinging, guarding or
	stunned, and you do not pay for a whole run every time you throw a punch.

	There is still no hit-slow or dash tier in the list above, and their absence remains a statement of
	fact rather than a decision -- nothing publishes one yet.

	Does not own: sprint INPUT (Client/Movement/RunController.lua owns the key, the hold-vs-toggle
	preference and Autorun, and pushes the resulting boolean here), any presentation (RunConstants and
	that same client module), the ladder's arithmetic (Shared/Run/RunLadder.lua) or its numbers
	(Shared/Run/RunConstants.lua).
]]

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local AttributeConstants = require(ReplicatedStorage.Shared.AttributeConstants)
local CharacterUtil = require(ReplicatedStorage.Shared.CharacterUtil)
local CombatConstants = require(ReplicatedStorage.Shared.Combat.CombatConstants)
local NetworkBridge = require(ReplicatedStorage.Shared.NetworkBridge)
local ParkourConstants = require(ReplicatedStorage.Shared.Parkour.ParkourConstants)
local RateLimiter = require(ReplicatedStorage.Shared.RateLimiter)
local DefenseConstants = require(ReplicatedStorage.Shared.Defense.DefenseConstants)
local DomainRules = require(ReplicatedStorage.Shared.Domain.DomainRules)
local RunConstants = require(ReplicatedStorage.Shared.Run.RunConstants)
local RunLadder = require(ReplicatedStorage.Shared.Run.RunLadder)
local Types = require(ReplicatedStorage.Shared.Types)
local Logger = require(ReplicatedStorage.Shared.Logger)
local PlayerLifecycle = require(ReplicatedStorage.Shared.PlayerLifecycle)
local Trove = require(ReplicatedStorage.Shared.Trove)

local logger = Logger.scope("RunSystem")

local RunSystem = {}

local ATTRIBUTES = AttributeConstants
local REMOTE_NAMES = RunConstants.Network.RemoteNames

-- Per-player run state. Deliberately small, and deliberately NOT a mirror of anything the client
-- believes: the client sends one boolean and this System derives everything else from the live
-- character. Everything here survives a respawn except what onCharacterAdded explicitly clears -- see
-- that function for which, and why.
-- EVERY ATTRIBUTE stepPlayer used to read off the Humanoid, mirrored into plain Lua fields.
--
-- The resolver reads twelve Attributes per player per tick, and every one of them is written by some
-- OTHER System at event rate -- an admin freeze, a grab, a mount, a swing, a parkour report. At 40
-- players that was ~480 GetAttribute calls a frame to re-answer questions whose answers had not
-- changed since the last time somebody actually did something. Mirroring turns each into a plain
-- table read and pays the engine cost once per change instead of sixty times a second per player.
--
-- Kept CURRENT by one Humanoid.AttributeChanged connection per character (see bindCharacter), not by
-- twelve GetAttributeChangedSignal connections -- AttributeChanged already carries the name, and the
-- names this System cares about are a fixed set, so one connection plus one table lookup in the
-- handler covers all twelve and extends to a thirteenth for free.
--
-- Seeded at bind time rather than left to the first change. An Attribute another System set BEFORE
-- this character was bound (a player who spawns already Mounted, say) has no edge left to catch, and
-- an unseeded mirror would read that player as unlocked -- which is a stuck-sprinting bug that only
-- reproduces under a spawn race.
type LiveAttributes = {
	-- Tiers 1-4 of the resolver: some other System has taken this character outright.
	Frozen: boolean,
	Flying: boolean,
	EmoteMovementLocked: boolean,
	Grabbed: boolean,
	GrabThrowing: boolean,
	Mounted: boolean,
	SwingRooted: boolean,
	-- A parkour action currently owns velocity, so this System writes nothing.
	ParkourVelocityOwned: boolean,
	-- Deadlines and states compared against `now` each tick -- the COMPARISON stays per-frame, only
	-- the read of the number behind it moves to event rate.
	CombatBusyUntil: number,
	-- The stun alone (DamageSystem), so a commitment that is only the player's own swing can be told from one
	-- that is a hit they took -- see swingOnly.
	HitstunUntil: number,
	DefenseState: string,
	ParkourSpeedFloor: number,
	ParkourSpeedFloorExpiry: number,
	-- Pre-multiplied (BaseWalkSpeed + BonusWalkSpeed) * SpeedMultiplier, recomputed whenever either
	-- input Attribute changes. effectiveBaseSpeed used to do this arithmetic, and both reads behind
	-- it, on every tick for every player.
	BaseSpeed: number,
	-- A realm's movement rules (Shared/Domain/DomainRules.lua): its MoveSpeed scale and its Rooted flag, and
	-- the lease both are read through (server time). The lease is compared every tick -- a realm's rules
	-- lapse at DomainUntil even if nothing rewrites the Attributes.
	DomainMoveSpeed: number,
	DomainRooted: boolean,
	DomainUntil: number,
}

-- The Attribute names bindCharacter's one connection actually reacts to. Anything else on the
-- Humanoid -- including SprintStage, which this System writes itself -- is filtered by a single table
-- lookup, so this System's own writes cannot feed back into its own mirror.
local MIRRORED_ATTRIBUTES: { [string]: true } = {
	[ATTRIBUTES.Frozen] = true,
	[ATTRIBUTES.Flying] = true,
	[ATTRIBUTES.EmoteMovementLocked] = true,
	[ATTRIBUTES.Grabbed] = true,
	[ATTRIBUTES.GrabThrowing] = true,
	[ATTRIBUTES.Mounted] = true,
	[ATTRIBUTES.SwingRooted] = true,
	[ATTRIBUTES.ParkourVelocityOwned] = true,
	[ATTRIBUTES.CombatBusyUntil] = true,
	[ATTRIBUTES.HitstunUntil] = true,
	[DefenseConstants.DefenseStateAttribute] = true,
	[ATTRIBUTES.ParkourSpeedFloor] = true,
	[ATTRIBUTES.ParkourSpeedFloorExpiry] = true,
	[ATTRIBUTES.BonusWalkSpeed] = true,
	[ATTRIBUTES.SpeedMultiplier] = true,
	[ATTRIBUTES.DomainUntil] = true,
	[ATTRIBUTES.DomainFlags] = true,
	[ATTRIBUTES.DomainMoveSpeed] = true,
}

type PlayerRunState = {
	-- The player's held intent, as last reported. The only client-supplied value in this System.
	Sprinting: boolean,
	-- Seconds of accrued charge (Shared/Run/RunLadder.StepCharge).
	ChargeSeconds: number,
	-- The gear the player is HOLDING -- resolved every tick, and kept through a combat commitment (see
	-- this file's header). Held so the hysteresis in ResolveStage has a previous value to test against.
	Stage: number,
	-- The stage last written to the SprintStage Attribute: Stage, or 0 while a combat action commits
	-- the body. Its own field so the Attribute is still written only on a real change.
	PublishedStage: number,
	-- The last WalkSpeed this System wrote, so the ramp has something to ramp FROM that is not the
	-- property itself -- reading the property back would let any other writer's value silently become
	-- this System's starting point.
	WalkSpeed: number,
	-- How long the charge has been failing to accrue, in seconds, reset to 0 on any tick that does
	-- accrue. This is what lets RunLadder.StepCharge tell a one-frame flicker from a genuine stop --
	-- see RunConstants.StopGraceSeconds. Kept here rather than inside the ladder so that function stays
	-- pure.
	NotAccruingSeconds: number,
	-- The character this state's mirror and Humanoid are bound to, and the Humanoid itself. Held so
	-- the tick does not have to re-resolve them: stepPlayer used to call FindFirstChildOfClass on
	-- every player on every frame, which is a linear scan of an R6 character's children to find
	-- something onCharacterAdded had already resolved and thrown away.
	--
	-- Compared against player.Character each tick rather than trusted, so a respawn cannot leave this
	-- System writing WalkSpeed to a corpse -- see resolveHumanoid, which rebinds on a mismatch rather
	-- than giving up, so a character this System never saw spawn still gets picked up on the next tick.
	Character: Model?,
	Humanoid: Humanoid?,
	-- Holds the one AttributeChanged connection behind Live below. Cleaned on every rebind and on
	-- PlayerRemoving; a bare connection field here would be a connection somebody has to remember to
	-- disconnect on both paths.
	CharacterTrove: Trove.TroveInstance,
	Live: LiveAttributes,
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
		PublishedStage = 0,
		WalkSpeed = 0,
		NotAccruingSeconds = 0,
		Character = nil,
		Humanoid = nil,
		CharacterTrove = Trove.New(),
		-- Seeded to the same answers an unset Attribute would have produced, so a state that exists
		-- before its first bind reads exactly as it used to: nothing locked, no floor, base speed at
		-- the authored default pair. resolveHumanoid refuses to step an unbound state anyway, but the
		-- table is never allowed to be half-built.
		Live = {
			Frozen = false,
			Flying = false,
			EmoteMovementLocked = false,
			Grabbed = false,
			GrabThrowing = false,
			Mounted = false,
			SwingRooted = false,
			ParkourVelocityOwned = false,
			CombatBusyUntil = 0,
			HitstunUntil = 0,
			DefenseState = "",
			ParkourSpeedFloor = 0,
			ParkourSpeedFloorExpiry = 0,
			BaseSpeed = (CombatConstants.BaseWalkSpeed + CombatConstants.DefaultBonusWalkSpeed),
			DomainMoveSpeed = 1,
			DomainRooted = false,
			DomainUntil = 0,
		},
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

-- Reads the mirror rather than the Humanoid -- see LiveAttributes. The five questions and their
-- ordering are unchanged; only where the answers come from moved.
local function readLiveAttributes(live: LiveAttributes, humanoid: Humanoid): ()
	live.Frozen = humanoid:GetAttribute(ATTRIBUTES.Frozen) == true
	live.Flying = humanoid:GetAttribute(ATTRIBUTES.Flying) == true
	live.EmoteMovementLocked = humanoid:GetAttribute(ATTRIBUTES.EmoteMovementLocked) == true
	live.Grabbed = humanoid:GetAttribute(ATTRIBUTES.Grabbed) == true
	live.GrabThrowing = humanoid:GetAttribute(ATTRIBUTES.GrabThrowing) == true
	live.Mounted = humanoid:GetAttribute(ATTRIBUTES.Mounted) == true
	live.SwingRooted = humanoid:GetAttribute(ATTRIBUTES.SwingRooted) == true
	live.ParkourVelocityOwned = humanoid:GetAttribute(ATTRIBUTES.ParkourVelocityOwned) == true
	live.CombatBusyUntil = numberAttribute(humanoid, ATTRIBUTES.CombatBusyUntil, 0)
	live.HitstunUntil = numberAttribute(humanoid, ATTRIBUTES.HitstunUntil, 0)
	local defenceState = humanoid:GetAttribute(DefenseConstants.DefenseStateAttribute)
	live.DefenseState = if typeof(defenceState) == "string" then defenceState :: string else ""
	live.ParkourSpeedFloor = numberAttribute(humanoid, ATTRIBUTES.ParkourSpeedFloor, 0)
	live.ParkourSpeedFloorExpiry = numberAttribute(humanoid, ATTRIBUTES.ParkourSpeedFloorExpiry, 0)

	-- The effective base this character's gears multiply against: the game's base walk speed plus the
	-- per-player BonusWalkSpeed Attribute, the whole thing scaled by the admin-only SpeedMultiplier
	-- Attribute. Both are read rather than assumed for the same reason the old resolver read them -- a
	-- future bloodline/stat system changes BonusWalkSpeed per player and this file never needs to know
	-- bloodlines exist.
	--
	-- BonusWalkSpeed defaults to CombatConstants.DefaultBonusWalkSpeed rather than to 0, and that
	-- default is load-bearing rather than cosmetic. The two constants are authored as a PAIR --
	-- BaseWalkSpeed 10 plus a default bonus of 8 -- and every speed comment in this codebase is written
	-- against their sum of 18 ("today's 18 base -> Sprint 27"). Defaulting the bonus to 0 would quietly
	-- run the whole game at a base of 10, which is not a tuning difference, it is the wrong number:
	-- every gear, and the parkour framework's own mirrored tiers, would be a third short with nothing
	-- to point at. onCharacterAdded seeds the Attribute explicitly, so this default is the belt to that
	-- braces -- it covers the window before the seed lands and any character this System never saw spawn.
	local bonus = numberAttribute(humanoid, ATTRIBUTES.BonusWalkSpeed, CombatConstants.DefaultBonusWalkSpeed)
	local multiplier = numberAttribute(humanoid, ATTRIBUTES.SpeedMultiplier, 1)
	live.BaseSpeed = (CombatConstants.BaseWalkSpeed + bonus) * multiplier

	-- A realm's two movement rules -- read raw here (the mirror is event-rate) and gated on the lease per
	-- tick in stepPlayer (realmSpeedScale / realmRooted), which is the DomainRules contract.
	live.DomainUntil = numberAttribute(humanoid, ATTRIBUTES.DomainUntil, 0)
	live.DomainMoveSpeed = math.max(numberAttribute(humanoid, ATTRIBUTES.DomainMoveSpeed, 1), 0)
	local flags = math.floor(numberAttribute(humanoid, ATTRIBUTES.DomainFlags, 0))
	live.DomainRooted = bit32.band(flags, DomainRules.FlagBits.Rooted) ~= 0
end

-- Whether a realm's rules still govern this body -- the lease, on the shared server clock.
local function realmGoverns(live: LiveAttributes): boolean
	return live.DomainUntil > 0 and live.DomainUntil > Workspace:GetServerTimeNow()
end

-- Whether some other System has taken this character outright. Tiers 1-4 of the resolver, asked as one
-- question because the answer is the same in every case: WalkSpeed is zero and the charge clock stops.
local function isMovementLocked(live: LiveAttributes): boolean
	return live.Frozen
		or live.Flying
		or live.EmoteMovementLocked
		-- Grab layer (Server/Combat/Grab/GrabSystem.lua) -- true for the whole hold-then-flight
		-- lifetime. Same "external system freezes movement without touching this System's own
		-- resolver" shape as the three above; see AttributeConstants.Grabbed's own header for why
		-- this is a separate Attribute from RootControlLocked rather than a widened meaning for it.
		or live.Grabbed
		-- The other end of a grab: a holder rooted for their throw clip. See AttributeConstants.GrabThrowing.
		or live.GrabThrowing
		-- Blimp layer (Server/Systems/BlimpSystem.lua) -- true for as long as this player is welded to a
		-- station. Same shape as Grabbed immediately above; see AttributeConstants.Mounted's own header.
		or live.Mounted
		-- A move that Locks movement holds its attacker from the start of its Active window through its
		-- recovery (HitboxEngine.setMovementLock). See AttributeConstants.SwingRooted.
		or live.SwingRooted
		-- A realm's Rooted rule (Shared/Domain/DomainRules.lua) -- the same "an external system holds this
		-- body where it is" tier, gated on the realm's lease.
		or (live.DomainRooted and realmGoverns(live))
end

-- The decaying WalkSpeed floor a just-finished parkour action leaves behind (AttributeConstants.
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
-- Whether a combat action is committing this body right now -- a swing still inside its own
-- windup/active/recovery, or a guard that is up. See this file's header on the two Attributes and on
-- why both collapse to one answer here.
--
-- The defence side reads "anything that is not Neutral", which deliberately sweeps in Staggered and
-- GuardBroken alongside Raising/ParryWindow/Blocking/ParryRecovery. Those two are not actions the
-- player chose, but a player being punished for a broken guard is even less entitled to a sprint gear
-- than one who chose to guard, so listing the states to include would only create a way to get one
-- back by being parried.
local function combatCommitted(live: LiveAttributes, now: number): boolean
	if now < live.CombatBusyUntil then
		return true
	end
	local defenceState = live.DefenseState
	return defenceState ~= "" and defenceState ~= "Neutral"
end

-- Whether the commitment is ONLY the player's own swing -- not a stun they are reeling from, and no guard,
-- stagger or guard break. Only that one keeps part of its gear (RunConstants.Combat.SwingGearCarry).
local function swingOnly(live: LiveAttributes, now: number): boolean
	if now >= live.CombatBusyUntil or now < live.HitstunUntil then
		return false
	end
	local defenceState = live.DefenseState
	return defenceState == "" or defenceState == "Neutral"
end

local function parkourSpeedFloor(live: LiveAttributes, now: number): number
	local floorSpeed = live.ParkourSpeedFloor
	local expiry = live.ParkourSpeedFloorExpiry
	if floorSpeed <= 0 or now >= expiry then
		return 0
	end
	local LOCOMOTION = ParkourConstants.Locomotion
	local remaining = math.clamp((expiry - now) / math.max(LOCOMOTION.MomentumCarrySeconds, 1e-3), 0, 1)
	local capped = math.min(floorSpeed, LOCOMOTION.SprintSpeed * LOCOMOTION.MomentumCarryMaxMultiplier)
	return capped * remaining
end

-- Points this state's mirror at `character`/`humanoid` and keeps it current for that character's
-- whole life. Called from onCharacterAdded on the ordinary spawn path, and from resolveHumanoid on
-- the fallback one.
--
-- ONE connection, not twelve. Humanoid.AttributeChanged already carries the name of whatever changed,
-- and MIRRORED_ATTRIBUTES filters it in a single table lookup -- including this System's own
-- SprintStage writes, which must not feed back into its own mirror. Re-reading all twelve on any one
-- of them changing is deliberate: it happens at event rate (an admin freeze, a grab, a swing), so the
-- twelve reads are free where a per-name updater table would be twelve more things to keep in sync.
local function bindCharacter(state: PlayerRunState, character: Model, humanoid: Humanoid): ()
	state.CharacterTrove:Clean()
	state.Character = character
	state.Humanoid = humanoid
	readLiveAttributes(state.Live, humanoid)
	state.CharacterTrove:Connect(humanoid.AttributeChanged, function(name: string)
		if MIRRORED_ATTRIBUTES[name] then
			readLiveAttributes(state.Live, humanoid)
		end
	end)
end

-- The live Humanoid for this player, or nil if there is nothing to step this tick.
--
-- Cached, and re-validated against player.Character rather than trusted -- a respawn must not leave
-- this System writing WalkSpeed to a corpse. On a mismatch it REBINDS rather than returning nil, so a
-- character this System never saw spawn (a join race, a CharacterAdded this System's bind missed) is
-- picked up on the next tick instead of never. The FindFirstChildOfClass that used to run for every
-- player on every frame now runs once per character.
local function resolveHumanoid(player: Player, state: PlayerRunState): Humanoid?
	local character = player.Character
	if not character then
		if state.Character then
			state.CharacterTrove:Clean()
			state.Character = nil
			state.Humanoid = nil
		end
		return nil
	end
	if state.Character == character then
		return state.Humanoid
	end
	-- No WaitForChild here, unlike onCharacterAdded: this path runs on Heartbeat and simply tries
	-- again next frame, where blocking would stall every other player's tick behind one spawning one.
	local humanoid = CharacterUtil.HumanoidOf(character)
	if not humanoid then
		return nil
	end
	bindCharacter(state, character, humanoid)
	return humanoid
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
	local humanoid = resolveHumanoid(player, state)
	if not humanoid then
		return
	end
	local live = state.Live
	-- A dead character is not running, and writing WalkSpeed to a corpse fights the respawn path.
	if humanoid.Health <= 0 then
		return
	end

	local locked = isMovementLocked(live)
	local parkourOwned = live.ParkourVelocityOwned
	-- Read the same way Client/Movement/RunController.lua already reads the identical question
	-- (FloorMaterial ~= Air, "the same single check MovementVFX's dust trickle uses") -- the server
	-- and the client must agree on what "on the ground" means, since the client's own presentation
	-- already hides footsteps and the FOV pull for every airborne/traversal state.
	local grounded = humanoid.FloorMaterial ~= Enum.Material.Air

	-- THE CHARGE. Accrues only while the player is holding the intent, genuinely moving, standing on
	-- something, and not taken by anything else. Freezes -- neither accruing nor decaying -- while
	-- EITHER a parkour action owns velocity OR the character is simply airborne. Those are not the
	-- same condition: Reports-bearing states (vault, wall-run, wall-jump, ledge-climb, roll, leap)
	-- claim ParkourVelocityOwned and were already covered, but States/LedgeHanging.lua, LedgeLeaping,
	-- Jumping, Falling and CombatHeld never do -- so a ledge hang or a jump arc taken with Sprint
	-- and a direction held used to charge (or drain) the ladder exactly as if the character were
	-- still flat-out sprinting on the ground. Grounded closes that: any state that leaves the ground,
	-- reported or not, is "not a stop" in the same sense a vault already was, and must not cost or
	-- earn a gear either way.
	--
	-- `locked` beats both in the freeze argument below: flying across the map with the run key held
	-- is not running, and it must not preserve a gear the way a vault or a jump does.
	local moving = humanoid.MoveDirection.Magnitude >= RunConstants.MoveInputThreshold
	-- COMBAT PAUSES THE RUN -- it FREEZES the charge exactly as a traversal does (neither accruing nor
	-- decaying), and the stage/speed below are pinned to walking for as long as it lasts. See this
	-- file's header for why this is a pause and no longer a reset.
	local committed = combatCommitted(live, now)

	local accruing = state.Sprinting and moving and not locked and grounded and not committed
	local frozen = (parkourOwned or not grounded or committed) and not locked

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

	-- THE STAGE. The HELD gear is resolved from the charge and the held intent every tick, committed or
	-- not -- ResolveStage owns the hysteresis, and the frozen charge is what keeps the gear through a
	-- swing. What is PUBLISHED is that gear, or walking while a combat action commits the body; it is
	-- written only on a real change, since SetAttribute is a replicated write and restating the same
	-- stage sixty times a second would be sixty round trips to tell every client nothing.
	state.Stage = RunLadder.ResolveStage(state.Stage, state.ChargeSeconds, state.Sprinting and not locked)
	local nextStage = if committed then 0 else state.Stage
	if nextStage ~= state.PublishedStage then
		state.PublishedStage = nextStage
		humanoid:SetAttribute(ATTRIBUTES.SprintStage, nextStage)
	end

	-- THE SPEED. Tiers 1-4 first, as one zero; then the ladder; then the parkour carry as a floor.
	local desired: number
	if locked or parkourOwned then
		desired = 0
	else
		desired = live.BaseSpeed * RunLadder.SpeedMultiplier(nextStage)
		-- A swing keeps part of the gear it was thrown from (RunConstants.Combat.SwingGearCarry): pressure on the
		-- run stays on the run. Walking pace is the floor, so a walking swing is unchanged.
		if committed and swingOnly(live, now) then
			local carry = RunLadder.SpeedMultiplier(state.Stage) * math.max(RunConstants.Combat.SwingGearCarry, 0)
			desired = live.BaseSpeed * math.max(1, carry)
		end
		-- A realm's MoveSpeed rule scales the gear, and -- like every tier above the floor -- sits under the
		-- parkour carry below, which can preserve a speed a player earned but never grant one.
		if live.DomainMoveSpeed ~= 1 and realmGoverns(live) then
			desired *= live.DomainMoveSpeed
		end
		-- A floor rather than a tier, and applied ONLY here -- never to the zeros above. That placement
		-- is the whole safety argument for this feature's one client-influenced number: a slide's earned
		-- speed survives into ordinary running, but it cannot peek through an admin freeze, a flight, an
		-- emote lock, or a parkour action that currently owns the body.
		desired = math.max(desired, parkourSpeedFloor(live, now))
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
	state.PublishedStage = 0
	state.WalkSpeed = 0
	state.NotAccruingSeconds = 0

	local humanoid = CharacterUtil.HumanoidOf(character)
	if not humanoid then
		-- WaitForChild rather than giving up: a character model replicates in pieces and the Humanoid is
		-- routinely a frame or two behind the model itself. Bounded by the same timeout every other
		-- character-binding path in this codebase uses.
		humanoid = CharacterUtil.AwaitHumanoid(character)
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
	-- CombatSystem.onCharacterAdded stamped this from CombatConstants.DefaultBonusWalkSpeed on every
	-- new character; with that module deleted, nothing did, and an unset Attribute would run every
	-- character at a base of 10 instead of the 18 the entire speed table is authored against.
	--
	-- Seeded rather than overwritten: a bloodline, an Art or an admin may legitimately have already set
	-- a different value on this Humanoid, and this System's job is to guarantee the Attribute EXISTS,
	-- not to have an opinion about what it should be. Only the nil/non-number case is filled in.
	if typeof(humanoid:GetAttribute(ATTRIBUTES.BonusWalkSpeed)) ~= "number" then
		humanoid:SetAttribute(ATTRIBUTES.BonusWalkSpeed, CombatConstants.DefaultBonusWalkSpeed)
	end

	-- LAST, after both seeds above, so the mirror's first read already sees them rather than catching
	-- them as changes a frame later. Everything the tick reads off this character comes from here now.
	bindCharacter(state, character, humanoid :: Humanoid)
end

function RunSystem.Init(): ()
	local setSprinting = NetworkBridge.CreateRemoteEvent(REMOTE_NAMES.SetSprinting)
	setSprinting.OnServerEvent:Connect(handleSetSprinting)

	-- Shared/PlayerLifecycle.lua owns the PlayerAdded / PlayerRemoving / Init-time-GetPlayers-sweep
	-- triple that used to be written out here, and the per-player CharacterAdded hookup inside it. The
	-- sweep in particular is not optional and was easy to forget: a player who joined before this
	-- System booted is otherwise never given a run state, which only reproduces under a real join race.
	PlayerLifecycle.BindAllPlayers({
		Scope = "RunSystem",
		OnPlayer = function(player: Player)
			getState(player)
		end,
		OnPlayerRemoving = function(player: Player)
			local state = playerStates[player]
			if state then
				state.CharacterTrove:Clean()
			end
			playerStates[player] = nil
			rateLimiter:Clear(player)
		end,
		OnCharacter = function(player: Player, character: Model)
			onCharacterAdded(player, character)
		end,
	})
	-- Players who joined before this System booted (a fast rejoin during server start) still need their
	-- per-player state and character hook -- the same Init()-time sweep every other PlayerAdded-driven
	-- System in this codebase uses as its backstop.
	RunService.Heartbeat:Connect(onHeartbeat)

	logger:info("RunSystem.Init() complete", { stages = #RunConstants.Stages })
end

-- The live stage for a player -- the one their body is actually moving at, the same value the
-- SprintStage Attribute carries (0 while a combat action holds their gear) -- for dev tooling and any
-- System that wants to know whether someone is at full stride without watching the Attribute itself.
-- Read-only projection, never a way to set one.
function RunSystem.GetStage(player: Player): number
	local state = playerStates[player]
	return if state then state.PublishedStage else 0
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
