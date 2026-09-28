--!strict
--[[
	ParkourController.lua

	Owns: the parkour framework's per-frame orchestration for the LOCAL player -- building the context,
	scheduling the probes, driving the state machine, committing the motor, and fanning the result out
	to the animation, camera, network and debug layers. The one module that knows all the others exist.

	THE FRAME, in order, because the order is load-bearing:
	  1. GATE      -- if the framework is off, or the character isn't bound, or combat owns the body,
	                  release the motor and stop. Nothing below runs.
	  2. SAMPLE    -- read the character's live motion into the reused context.
	  3. PROBE     -- EnvironmentProbe fills the context's probe fields, refreshing only what the
	                  active state declared plus whatever its own schedule is due for.
	  4. DECIDE    -- StateMachine.Update runs the active state and applies at most one transition.
	  5. COMMIT    -- ParkourMotor.Apply writes the frame's command to the body. Nothing before this
	                  point has touched the character.
	  6. PRESENT   -- animation, camera, debug overlay, and (on a transition) the server report.
	Probing before deciding is what lets a state's CanEnter read fresh geometry; committing after
	deciding is what guarantees a transition's Exit hand-off is the command that actually lands (see
	StateSupport.HandOff's own header for the ordering bug that would otherwise eat every vault's exit
	velocity).

	RUNS ON HEARTBEAT, not RenderStepped. Movement is physics, and Heartbeat is the tick that runs
	after physics has stepped -- reading a velocity on RenderStepped means reading last frame's. This
	also matches Client/Flight/FlightController.lua's own loop and the server's own authoritative tick.

	SPRINT IS NOT OWNED HERE. Client/Movement/RunController.lua owns run intent -- the key,
	hold-versus-toggle, Autorun and the remote that tells the server -- and this module READS it once
	per frame through RunController.IsSprinting(). A pull rather than a push, and not by preference:
	this module already requires RunController in order to push its own live state id out to the run
	presentation, so a setter here would close a require cycle. Two systems deciding whether a player is
	running is exactly the split ownership this framework exists to avoid; one system deciding and the
	other reading is the shape that cannot drift.

	Does not own: any movement behavior (the States own that), any raycast (EnvironmentProbe), any
	write to the character (ParkourMotor), or any validation (the server re-checks everything).
]]

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Constants = require(ReplicatedStorage.Shared.Constants)
local CharacterUtil = require(ReplicatedStorage.Shared.CharacterUtil)
local ParkourConstants = require(ReplicatedStorage.Shared.Parkour.ParkourConstants)
local ParkourMath = require(ReplicatedStorage.Shared.Parkour.ParkourMath)
local ParkourOwnership = require(ReplicatedStorage.Shared.Parkour.ParkourOwnership)
local ParkourTypes = require(ReplicatedStorage.Shared.Parkour.ParkourTypes)
local Logger = require(ReplicatedStorage.Shared.Logger)
local PlayerLifecycle = require(ReplicatedStorage.Shared.PlayerLifecycle)
local Trove = require(ReplicatedStorage.Shared.Trove)

local ParkourAudio = require(script.Parent.Parent.FX.ParkourAudio)
local MovementVFX = require(script.Parent.Parent.FX.MovementVFX)
local EnvironmentProbe = require(script.Parent.EnvironmentProbe)
local InputBuffer = require(script.Parent.InputBuffer)
local ParkourAnimator = require(script.Parent.ParkourAnimator)
local ParkourCamera = require(script.Parent.ParkourCamera)
local ParkourDebug = require(script.Parent.ParkourDebug)
local ParkourInput = require(script.Parent.ParkourInput)
local ParkourMotor = require(script.Parent.ParkourMotor)
local ParkourNetwork = require(script.Parent.ParkourNetwork)
local StateMachine = require(script.Parent.StateMachine)
local States = require(script.Parent.States)
-- The run system's presentation owner (Client/Movement/RunController.lua). Required in THIS direction
-- -- the framework pushing outward -- for the same reason ParkourAnimator/ParkourCamera are: this
-- module is the one that knows every other layer exists, and a run system that pulled the state id
-- back out of here would need its own polling loop and could observe a state one frame stale. The run
-- system reads it, exactly like the animation, camera, network and debug layers already do.
local RunController = require(script.Parent.Parent.Movement.RunController)
-- The combat client's record of this player's own swing and stun (Client/Combat/LocalCombatState.lua),
-- read once a frame into ParkourContext.CombatCommitted. A leaf module with no requires of its own, so
-- pulling it here cannot form a cycle with the combat clients that write it.
local LocalCombatState = require(script.Parent.Parent.Combat.LocalCombatState)

type ParkourContext = ParkourTypes.ParkourContext
type MovementStateId = ParkourTypes.MovementStateId
type ActionKind = ParkourTypes.ActionKind
type AssistSettings = ParkourTypes.AssistSettings

local logger = Logger.scope("ParkourController")

local ParkourController = {}

-- How long the client tells the server each reportable action is expected to last. The server uses
-- this to expire a velocity-ownership window on its own if the End report never arrives (a
-- disconnect mid-slide, a dropped packet), rather than trusting a client to always hand velocity
-- back -- see Server/Systems/ParkourSystem.lua. Generous relative to the real durations, because
-- expiring a window a player is still legitimately inside is worse than holding one a moment too
-- long: the former makes the server's WalkSpeed resolver fight a live slide.
local ACTION_DURATIONS: { [string]: number } = {
	Slide = ParkourConstants.Slide.MaxDurationSeconds + 0.5,
	Vault = ParkourConstants.Obstacle.VaultDurationSeconds + 0.5,
	Mantle = ParkourConstants.Obstacle.MantleDurationSeconds + 0.5,
	-- No separate WallJump entry: the kick is a phase of WallRunning now, not its own reported action --
	-- see ParkourTypes.ActionKind's own header. The WallRun duration above already has to cover it,
	-- since the open window spans the whole run including any kick taken at the end of it; a run
	-- (MaxDurationSeconds, 2.2s) chaining directly into a kick's control lock (well under 0.5s even
	-- assisted) stays comfortably inside the existing +0.5s slack.
	WallRun = ParkourConstants.WallRun.MaxDurationSeconds + 0.5,
	LedgeClimb = ParkourConstants.Ledge.ClimbDurationSeconds + 0.5,
	-- Includes the ceiling hold: a roll that finishes under something too low to stand in keeps running
	-- (crawling) for up to MaxCeilingHoldSeconds before it hands off to a slide -- see States/Rolling.lua.
	-- A window sized for DurationSeconds alone would under-declare that roll by the whole hold.
	Roll = ParkourConstants.Roll.DurationSeconds + ParkourConstants.Roll.MaxCeilingHoldSeconds + 0.5,
	-- Derived from the LONGEST direction rather than from any one of the four, so retuning a single
	-- direction longer can never under-declare the window and have the server force-expire a dash
	-- mid-burst. States/Dashing.lua's own spec asserts every direction stays at or under it.
	Dash = ParkourConstants.Dash.MaxDurationSeconds + 0.5,
	-- Includes ChargeSeconds now: the report Start fires once, at Enter, which is the moment the CHARGE
	-- begins (see States/Leaping.lua's Charging phase) -- not the moment the flight does. A window sized
	-- only for the flight would under-declare the real duration by the whole charge, and a charge+flight
	-- that ran past it would have its own ownership window force-expired by the server mid-air: the
	-- exact "player frozen" failure ParkourValidation.lua's own history documents for a mis-sized window.
	Leap = ParkourConstants.Leap.ChargeSeconds + ParkourConstants.Leap.MaxFlightSeconds + 0.5,
}

local machine = StateMachine.New("Idle")
for _, definition in States do
	machine:Register(definition)
end

local started = false
local enabled = ParkourConstants.Enabled
local heartbeatConnection: RBXScriptConnection? = nil

-- The Shared/PlayerLifecycle.lua handle Start() takes out and Stop() releases -- see both.
local lifecycleBinding: Trove.TroveInstance? = nil

local character: Model? = nil
local humanoid: Humanoid? = nil
local rootPart: BasePart? = nil

local wasGrounded = false
-- What ParkourAnimator was last told the current state's variant is. OnStateChanged only fires on an
-- actual state transition, but a variant can change WITHIN a state's own lifetime now -- States/
-- LedgeHanging.lua flips ParkourContext.AnimationVariant between "Hang" and "Shimmy" every frame based
-- on live lateral input, not just once at Enter -- so step() below has to notice that edge too, the
-- same way it already notices the grounded edge just above.
local lastAnimationVariant: string? = nil

-- Whether an AnimationVariant names the kick phase of States/WallRunning.lua rather than the ordinary
-- run loop (Left/Right) -- see that file's beginKick, which is the only thing that ever sets these.
-- Used both to decide the camera tilt (wall-run only, not the kick -- see the per-frame push below) and
-- to fire the kick's one-shot camera shake, which used to be OnStateChanged's job when the kick was its
-- own state and "next == WallJumping" was a real transition to key off (see ParkourCamera.OnStateChanged's
-- own header for why it no longer can be).
local function isKickVariant(variant: string?): boolean
	return variant == "KickLeft" or variant == "KickRight" or variant == "KickNeutral"
end

-- The single reused context. Every field is overwritten each frame before any state sees it; the
-- probe fields are assigned by EnvironmentProbe.Update to its own persistent result tables. Reused
-- rather than rebuilt for the same reason every other hot table in this framework is -- see
-- EnvironmentProbe.lua's RESULT TABLES note.
local context: ParkourContext = nil :: any

local emptyProbeRequest: ParkourTypes.ProbeRequest = { Ground = true }

local function buildInitialContext(boundCharacter: Model, boundHumanoid: Humanoid, boundRoot: BasePart): ParkourContext
	return {
		Character = boundCharacter,
		Humanoid = boundHumanoid,
		RootPart = boundRoot,
		DeltaTime = 0,
		Now = os.clock(),
		CurrentStateId = "Idle",
		PreviousStateId = "Idle",
		StateElapsed = 0,
		MoveIntent = Vector3.zero,
		AimDirection = boundRoot.CFrame.LookVector,
		SprintHeld = false,
		SprintStage = 0,
		Momentum = 0,
		DebugWallCatch = nil,
		DebugEnabled = false,
		WallCatchActive = false,
		MoveDirection = Vector3.zero,
		Velocity = Vector3.zero,
		VerticalVelocity = 0,
		PlanarSpeed = 0,
		Ground = nil :: any,
		Obstacle = nil :: any,
		WallLeft = nil :: any,
		WallRight = nil :: any,
		Ledge = nil :: any,
		CeilingClear = true,
		ApexHeight = boundRoot.Position.Y,
		FallHeight = 0,
		LeftGroundAt = 0,
		LastGroundedAt = os.clock(),
		WallRunChain = 0,
		WallJumpChain = 0,
		AirDashChain = 0,
		LastWallInstance = nil,
		LastWallLeftAt = 0,
		WallLaunchDashBoostUntil = 0,
		CombatOwned = false,
		InCombat = false,
		CombatCommitted = false,
		PreLandingMomentum = nil,
		LandedAt = nil,
		Assists = InputBuffer.GetAssists(),
		Motor = ParkourMotor.BeginFrame(),
		AnimationVariant = nil,
		LandingSeverity = nil,
		LedgeAnchorPosition = nil,
		LedgeAnchorNormal = nil,
		DebugShimmy = nil,
		DebugLedgeLeap = nil,
		DebugWallRunPivot = nil,
	}
end

-- Whether some other system currently owns this character's body. Every one of these is an Attribute
-- the SERVER already publishes for its own reasons -- this framework introduces no new signal for it,
-- it just reads the ones that already exist:
--   * RootControlLocked   -- CombatSystem.syncRootControlLocked: a finisher/DashPunch ragdoll is
--                            tumbling this body, or RagdollController.HoldAloft has an AlignPosition
--                            pin on it (an air-combo juggle, from either side).
--   * Flying              -- AdminActionSystem.SetFlying, driven by Client/Flight/FlightController.
--   * Frozen              -- DevMenuSystem.SetTargetFrozen, an absolute admin lockdown.
--   * EmoteMovementLocked -- EmoteSystem, a MovementLocked emote.
-- Reading rather than inventing is the point: these four are already the definitive answer to "is
-- someone else driving," they are already replicated, and a fifth signal would be one more thing to
-- keep in sync.
local function resolveCombatOwned(boundHumanoid: Humanoid): boolean
	return boundHumanoid:GetAttribute(Constants.Attributes.RootControlLocked) == true
		or boundHumanoid:GetAttribute(Constants.Attributes.Flying) == true
		or boundHumanoid:GetAttribute(Constants.Attributes.Frozen) == true
		or boundHumanoid:GetAttribute(Constants.Attributes.EmoteMovementLocked) == true
		or boundHumanoid.Health <= 0
end

-- The action kind the SERVER currently believes is open, as last claimed by a Start report from here.
-- Declared above reportTransition (its writer) rather than beside releaseStrandedOwnership (its reader)
-- purely so the assignment below is a local rather than a global.
local ownedReportKind: ActionKind? = nil

-- Fires the network reports for a transition. Driven off the two states' declared Reports fields
-- rather than by the states themselves calling the network layer -- which is what keeps every state
-- module free of any network dependency, and what makes "which actions are reported" answerable by
-- reading the state definitions instead of by grepping for remote calls.
local function reportTransition(previousId: MovementStateId, nextId: MovementStateId): ()
	local previousDefinition = machine:GetDefinition(previousId)
	local nextDefinition = machine:GetDefinition(nextId)
	local currentRoot = rootPart
	if not currentRoot then
		return
	end

	local previousKind = previousDefinition and previousDefinition.Reports
	if previousKind then
		ParkourNetwork.ReportEnd(previousKind, context.Momentum, currentRoot.Position)
	end
	local nextKind = nextDefinition and nextDefinition.Reports
	if nextKind then
		ParkourNetwork.ReportStart(
			nextKind,
			context.Momentum,
			currentRoot.Position,
			ACTION_DURATIONS[nextKind] or ParkourConstants.Validation.MaxActionSeconds
		)
		-- Remembered, and deliberately NOT cleared when the End above is sent: the whole point of the
		-- watchdog is the case where that End did not take effect, and a kind forgotten the moment it was
		-- reported is a kind the watchdog can no longer name. It is cleared by the server agreeing --
		-- see releaseStrandedOwnership.
		ownedReportKind = nextKind
	end
end

-- THE STRANDED-OWNERSHIP WATCHDOG.
--
-- A Start report asks the server to stand its WalkSpeed resolver down for the duration of an action
-- (Constants.Attributes.ParkourVelocityOwned -> Server/Systems/RunSystem.lua resolves 0), and the
-- End report is the only thing that gives it back. If an End never lands -- dropped by the server's own
-- rate limiter, lost to a dropped packet, or refused by a validation rule -- the player stands frozen
-- until the server's window expiry rescues them, which is most of a second of the character simply not
-- responding. That failure has now been designed out on both sides (ParkourValidation.Validate never
-- refuses an End; ParkourNetwork never drops one), but "designed out" is a property of the paths we
-- thought of, and the cost of being wrong is the single worst thing a movement system can do to a
-- player.
--
-- So this is the backstop that does not depend on being right: whenever the framework is in a state
-- that claims nothing while the server still believes an action is open, it says so again. The server's
-- own view is the trigger -- the Attribute, not a client-side timer -- so this cannot fire on a
-- disagreement that does not exist, and it goes quiet the moment the server agrees.
local lastReleaseAttemptAt = 0
local OWNERSHIP_RELEASE_RETRY_SECONDS = 0.3

local function releaseStrandedOwnership(currentHumanoid: Humanoid, definition: ParkourTypes.StateDefinition?): ()
	local kind = ownedReportKind
	if kind == nil then
		return
	end
	-- An action is genuinely live: the server is supposed to own velocity right now.
	if definition and definition.Reports then
		return
	end
	if currentHumanoid:GetAttribute(Constants.Attributes.ParkourVelocityOwned) ~= true then
		ownedReportKind = nil
		return
	end
	if (context.Now - lastReleaseAttemptAt) < OWNERSHIP_RELEASE_RETRY_SECONDS then
		return
	end
	lastReleaseAttemptAt = context.Now
	logger:debug("Re-sending a parkour End -- the server still believes an action is open", { kind = kind })
	ParkourNetwork.ReportEnd(kind, context.Momentum, context.RootPart.Position)
end

-- Publishes Constants.Attributes.ParkourActionOwned for the combat layers' own client-side gate. An
-- Attribute rather than a call into Client/Combat, for the identical require-graph reason
-- ParkourFacingOwned is one: the combat modules are not in this framework's load chain and must not
-- become part of it just to be told a state changed. See that Attribute's own header in Constants for
-- what it covers and why it is not the authority.
--
-- Cleared rather than set false on the way out, so a character carries no leftover key at all -- the
-- readers treat unset and false identically, and an unset Attribute is the honest representation of
-- "this framework is not driving".
local function setActionOwned(owned: boolean): ()
	local currentHumanoid = humanoid
	if not currentHumanoid then
		return
	end
	currentHumanoid:SetAttribute(Constants.Attributes.ParkourActionOwned, if owned then true else nil)
end

local function onTransition(previousId: MovementStateId, nextId: MovementStateId): ()
	reportTransition(previousId, nextId)
	setActionOwned(ParkourOwnership.IsActionState(nextId))
	ParkourAnimator.OnStateChanged(previousId, nextId, context.AnimationVariant)
	ParkourCamera.OnStateChanged(previousId, nextId)
	ParkourAudio.OnStateChanged(previousId, nextId)
	-- Dust, the roll's camera kick and its afterimage -- the visual half of what ParkourAudio just did.
	MovementVFX.OnStateChanged(previousId, nextId)
	-- The run system, told the same thing on the same frame as the animator and the camera. This is
	-- what stops the run loop and the footstep audio from continuing straight through a slide, a
	-- wall-run, a vault or a fall -- before this, the run presentation asked only "is sprint held and
	-- is the character moving," which is true throughout all four.
	RunController.SetParkourState(nextId)
	if nextId == "Landing" and context.LandingSeverity then
		ParkourCamera.PlayLanding(context.LandingSeverity)
		ParkourAudio.PlayLanding(context.LandingSeverity)
	end
	logger:trace("Parkour state changed", { from = previousId, to = nextId })
end

local function step(deltaTime: number): ()
	local currentCharacter = character
	local currentHumanoid = humanoid
	local currentRoot = rootPart
	if not currentCharacter or not currentHumanoid or not currentRoot or not currentRoot.Parent then
		return
	end

	local now = os.clock()
	context.DeltaTime = deltaTime
	context.Now = now
	-- Resolved ONCE here rather than by each producer, so the whole frame agrees about whether anybody
	-- is looking -- see ParkourContext.DebugEnabled. Two readers, and a state should not have to know
	-- about either: ParkourDebug.Update draws the overlay, and ParkourConstants.Debug.LogWallCatch
	-- routes the same verdicts to the log without the overlay being open.
	context.DebugEnabled = ParkourDebug.IsEnabled() or ParkourConstants.Debug.LogWallCatch
	-- PULLED, not pushed. Client/Movement/RunController.lua owns run intent (the key, hold-vs-toggle,
	-- Autorun) and this module already requires it in order to push its own state id out -- so a push
	-- back would be a require cycle. Reading it here rides the dependency that already exists, and
	-- removes the window in which a pushed mirror could be a frame stale against the module that
	-- actually knows the answer.
	context.SprintHeld = RunController.IsSprinting()
	-- The server's own resolved run stage, read straight off the Humanoid the same way
	-- resolveCombatOwned reads its four ownership Attributes -- one more read per frame on a value the
	-- server publishes anyway, rather than a second subscription and a cached mirror to keep in sync.
	-- Non-number (never set yet, on the first frames of a life) reads as stage 0, which is exactly
	-- what a character that has not started running yet is.
	local stageValue = currentHumanoid:GetAttribute(Constants.Attributes.SprintStage)
	context.SprintStage = if typeof(stageValue) == "number" then stageValue else 0
	context.Assists = InputBuffer.GetAssists()
	context.CombatOwned = resolveCombatOwned(currentHumanoid)
	-- One more Attribute read on this same Humanoid, for the same reason SprintStage above is read
	-- rather than subscribed to: the server already publishes it (CombatSystem's inCombatNotifier), and
	-- a cached mirror fed by the Combat_InCombatChanged remote would be a second source of truth to
	-- keep correct across respawns. Unset (a life that has never fought) reads as false, which is
	-- exactly right.
	context.InCombat = currentHumanoid:GetAttribute(Constants.Attributes.InCombat) == true
	-- Pulled from the combat client's own mirror, the same way SprintHeld is pulled from RunController:
	-- LocalCombatState is the one place this client already records its own swing and its own stun, and
	-- a second copy kept here would be a third answer to a question the server has already answered.
	-- See ParkourContext.CombatCommitted for who reads it.
	context.CombatCommitted = LocalCombatState.FreeAt(now) > now

	local velocity = currentRoot.AssemblyLinearVelocity
	context.Velocity = velocity
	context.VerticalVelocity = velocity.Y
	context.PlanarSpeed = ParkourMath.PlanarSpeed(velocity)
	context.MoveDirection = ParkourMath.SafeUnit(ParkourMath.Flatten(velocity), Vector3.zero)
	-- Humanoid.MoveDirection is the engine's own already-camera-relative, already-normalized movement
	-- intent -- the same value Server/Systems/RunSystem.lua reads server-side to decide whether a
	-- player is genuinely moving. Using it rather than polling WASD directly means this framework
	-- transparently
	-- supports gamepad sticks, touch thumbsticks and any future control scheme, with no per-device
	-- branching, for free.
	context.MoveIntent = ParkourMath.Flatten(currentHumanoid.MoveDirection)
	-- Where the player is LOOKING, pitch included -- published here so no state has to reach for the
	-- camera itself (see ParkourContext.AimDirection). Falls back to the body's own facing if there is
	-- somehow no camera, which keeps the field always meaningful rather than sometimes zero.
	local camera = Workspace.CurrentCamera
	context.AimDirection = if camera then camera.CFrame.LookVector else currentRoot.CFrame.LookVector

	-- Refresh the motor command BEFORE the machine runs, so the active state (and any Exit/Enter the
	-- transition fires) writes into a clean frame rather than inheriting the last one.
	context.Motor = ParkourMotor.BeginFrame()

	local definition = machine:GetCurrentDefinition()
	local probeRequest = if definition then definition.Probes else emptyProbeRequest
	EnvironmentProbe.Update(context, probeRequest)

	-- Ground-contact bookkeeping, maintained here rather than in any state because several states need
	-- it and none of them owns the transition it keys off (a character can leave the ground from any
	-- of half a dozen states).
	local grounded = context.Ground.Grounded
	if grounded ~= wasGrounded then
		if grounded then
			context.LastGroundedAt = now
			-- Holding the slide key through a fall queues a slide for the moment of contact. Called
			-- here rather than from a state because this edge is the only place the touchdown is
			-- detected at all -- see InputBuffer.ArmHeldSlideOnLanding for why the press is re-stamped
			-- on the edge rather than the buffer window being widened to cover a whole fall.
			InputBuffer.ArmHeldSlideOnLanding(now)
			-- Touching the ground is what resets the wall-run, wall-jump and air-dash chain limits.
			-- That single rule is what makes those limits a constraint on AIRTIME rather than a global
			-- budget: a player who returns to the ground gets a full fresh set, which is what keeps a
			-- long traversal readable instead of gradually running out of moves for no visible reason.
			context.WallRunChain = 0
			context.WallJumpChain = 0
			context.AirDashChain = 0
			context.LastWallInstance = nil
		else
			context.LeftGroundAt = now
		end
		wasGrounded = grounded
	end

	local previousId = machine:GetCurrentId()
	local nextId = machine:Update(context)

	ParkourMotor.Apply()

	if nextId ~= previousId then
		onTransition(previousId, nextId)
		lastAnimationVariant = context.AnimationVariant
	elseif context.AnimationVariant ~= lastAnimationVariant then
		-- SAME state, but its own Update just asked for a different variant -- LedgeHanging switching
		-- between "Hang" and "Shimmy" as the player starts/stops shimmying, or WallRunning switching
		-- into its own kick phase (Left/Right -> Kick*), are the two cases this exists for. OnStateChanged
		-- is reused rather than duplicated because it already does exactly the resolve-and-SetClaim this
		-- needs; passing nextId for both previous and next is safe because the function never reads its
		-- `_previous` argument (see its own signature). RunController is deliberately NOT told about
		-- this -- SetParkourState only cares about which STATE is active for locomotion-presentation
		-- purposes, and a variant swap within one state never changes that answer.
		ParkourAnimator.OnStateChanged(nextId, nextId, context.AnimationVariant)
		-- The kick's one-shot camera punch, fired on the same edge (entering a Kick* variant this frame,
		-- having not been in one last frame) that used to be "next == WallJumping" back when the kick was
		-- its own state -- see ParkourCamera.PlayWallKick's own header.
		if
			nextId == "WallRunning"
			and isKickVariant(context.AnimationVariant)
			and not isKickVariant(lastAnimationVariant)
		then
			ParkourCamera.PlayWallKick()
		end
		lastAnimationVariant = context.AnimationVariant
	end

	-- After the transition, so it sees the state the frame actually ended in rather than the one it
	-- started in -- the frame a wall-jump becomes a Falling is exactly the frame its End was sent, and
	-- therefore the first frame worth checking whether that End took.
	releaseStrandedOwnership(currentHumanoid, machine:GetCurrentDefinition())

	ParkourAnimator.SetMotion(context.Momentum)
	ParkourCamera.SetSpeed(context.Momentum)
	-- Tilt belongs to the RUN, not the kick -- Left/Right only, never a Kick* variant. Without this
	-- guard a departing kick would read "not Left" and tilt as if still leaning into the wall on the
	-- ordinary (arbitrary) side, right as the character is pushing away from it.
	if nextId == "WallRunning" and (context.AnimationVariant == "Left" or context.AnimationVariant == "Right") then
		ParkourCamera.SetWallSide(if context.AnimationVariant == "Left" then -1 else 1)
	else
		ParkourCamera.SetWallSide(0)
	end
	-- The mantle's own continuous camera feed -- see ParkourCamera.SetMantleProgress's own header for
	-- why this is pushed every frame rather than fired once on the transition. StateElapsed over the
	-- state's authored duration is the SAME alpha States/Mantling.lua's own Update computes for the
	-- traversal curve -- read from the context rather than re-derived, so the camera and the character's
	-- actual position can never read two different fractions of the same climb.
	if nextId == "Mantling" then
		ParkourCamera.SetMantleProgress(
			context.StateElapsed / math.max(ParkourConstants.Obstacle.MantleDurationSeconds, 1e-3)
		)
	end

	ParkourDebug.Update(context, machine)
end

local function onHeartbeat(deltaTime: number): ()
	if not enabled then
		return
	end
	local currentHumanoid = humanoid
	if not currentHumanoid then
		return
	end
	-- Combat ownership is checked BEFORE the frame runs as well as inside it: the AerialCombat state
	-- exists to park the machine correctly while combat holds the body, but the body must be released
	-- on the very frame ownership changes, not on the frame after the machine notices.
	if resolveCombatOwned(currentHumanoid) and machine:GetCurrentId() ~= "AerialCombat" then
		context.Now = os.clock()
		context.DeltaTime = deltaTime
		context.CombatOwned = true
		context.Motor = ParkourMotor.BeginFrame()
		local previousId = machine:GetCurrentId()
		machine:ForceTransition("AerialCombat", context)
		ParkourMotor.Release()
		InputBuffer.Clear()
		onTransition(previousId, "AerialCombat")
		return
	end

	local ok, errorMessage = pcall(step, deltaTime)
	if not ok then
		-- A movement frame that errors must never leave the body anchored or constraint-driven -- that
		-- state is unrecoverable without a respawn. Releasing on error costs one frame of parkour and
		-- guarantees the character is always left in a controllable state.
		ParkourMotor.Release()
		logger:error("Parkour step errored", { errorMessage = tostring(errorMessage) })
	end
end

-- Binds a freshly-spawned character. Every sub-module with per-life state is rebound here, in one
-- place, so a new life cannot start with any of them holding the previous one's data -- the class of
-- bug this codebase has already paid for once (see CombatSystem.onCharacterAdded's own reset block).
function ParkourController.BindCharacter(nextCharacter: Model): ()
	local humanoidInstance = CharacterUtil.AwaitHumanoid(nextCharacter)
	if not humanoidInstance then
		logger:warn("BindCharacter: no Humanoid")
		return
	end
	local rootInstance = CharacterUtil.AwaitRoot(nextCharacter)
	if not rootInstance then
		logger:warn("BindCharacter: no HumanoidRootPart")
		return
	end

	character = nextCharacter
	humanoid = humanoidInstance
	rootPart = rootInstance

	context = buildInitialContext(nextCharacter, humanoid :: Humanoid, rootPart :: BasePart)
	wasGrounded = false
	lastAnimationVariant = nil

	EnvironmentProbe.BindCharacter(nextCharacter, humanoid :: Humanoid, rootPart :: BasePart)
	ParkourMotor.BindCharacter(nextCharacter, humanoid :: Humanoid, rootPart :: BasePart)
	ParkourAnimator.BindCharacter(nextCharacter)
	ParkourCamera.Reset()
	ParkourAudio.Reset()
	ParkourNetwork.Reset()
	InputBuffer.Clear()

	machine:ForceTransition("Idle", context)
	-- The framework is driving again, from Idle. Told explicitly rather than left to the first
	-- transition, so a life that starts and ends without the machine ever leaving Idle still leaves
	-- the run system with an accurate view rather than the previous life's last state.
	RunController.SetParkourState(machine:GetCurrentId())
	logger:debug("Parkour bound to character")
end

local function unbind(): ()
	-- Before the handles are dropped below -- setActionOwned needs the Humanoid it is clearing.
	setActionOwned(false)
	ParkourMotor.Unbind()
	EnvironmentProbe.Unbind()
	ParkourAnimator.Unbind()
	ParkourCamera.Reset()
	ParkourAudio.Reset()
	InputBuffer.Clear()
	-- nil, not "Idle": the framework is no longer driving at all, and the run system's fallback path
	-- (its own grounded/moving checks, with no parkour veto) is the correct behavior in that case --
	-- see RunController.SetParkourState.
	RunController.SetParkourState(nil)
	character = nil
	humanoid = nil
	rootPart = nil
end

-- Player-facing master switch (Settings -> Gameplay -> "Parkour movement"). Disabling releases the
-- body immediately and stops the loop, falling the game back to Roblox's stock character controller
-- plus CombatClient's own legacy Slide path -- a real, exercised fallback rather than a dead branch,
-- which is why ParkourInput.lua reports whether it consumed a Slide press instead of assuming it did.
function ParkourController.SetEnabled(nextEnabled: boolean): ()
	if enabled == nextEnabled then
		return
	end
	enabled = nextEnabled
	if not enabled then
		-- The framework is switched off, so whatever state it was parked in is no longer an action
		-- anyone is doing. Left set, it would refuse every combat press for the rest of the life.
		setActionOwned(false)
		ParkourMotor.Release()
		ParkourAnimator.Reset()
		ParkourCamera.Reset()
		InputBuffer.Clear()
		-- Same nil-not-Idle reasoning as unbind's: with the framework switched off there is no parkour
		-- opinion for the run system to honor, and leaving a stale state id behind would let the last
		-- traversal before the toggle suppress the run presentation forever.
		RunController.SetParkourState(nil)
	else
		RunController.SetParkourState(machine:GetCurrentId())
	end
	logger:info("Parkour framework toggled", { enabled = enabled })
end

function ParkourController.IsEnabled(): boolean
	return enabled
end

-- Player-facing assist preferences (Settings -> Gameplay). Pushed straight through to InputBuffer,
-- which is the single consumer -- see ParkourMath.CoyoteAvailable/BufferLive for why each assist is a
-- parameter to the predicate rather than a check at the call site.
function ParkourController.SetAssists(assists: AssistSettings): ()
	InputBuffer.SetAssists(assists)
end

function ParkourController.SetCameraEffectsEnabled(cameraEnabled: boolean): ()
	ParkourCamera.SetEffectsEnabled(cameraEnabled)
end

-- Whether the framework is currently in a state where it -- rather than CombatClient's legacy path --
-- should handle a Slide press. Read by CombatClient before it predicts/fires its own Slide, so
-- exactly one of the two systems responds to the key. Returns false while disabled or unbound, which
-- is what makes the fallback above genuinely reachable.
function ParkourController.HandlesSlide(): boolean
	return enabled and character ~= nil and humanoid ~= nil
end

-- The live state id, for CombatClient/HUD/debug consumers that want to know what movement is doing
-- without depending on the machine itself.
function ParkourController.GetStateId(): MovementStateId
	return machine:GetCurrentId()
end

local function onActionRejected(payload: ParkourTypes.ActionRejectedPayload): ()
	logger:warn(
		"Parkour action rejected by server",
		{ kind = payload.Kind, phase = payload.Phase, reason = payload.Reason }
	)
	-- A rejected START means the server never granted velocity ownership -- so continuing to drive the
	-- body would put the client and server in exactly the disagreement this framework's whole network
	-- design exists to prevent. Fall back to ordinary locomotion immediately.
	if payload.Phase ~= "Start" then
		return
	end
	local currentRoot = rootPart
	if not currentRoot then
		return
	end
	local previousId = machine:GetCurrentId()
	local target: MovementStateId = if context.Ground.Grounded then "Idle" else "Falling"
	if machine:ForceTransition(target, context) then
		ParkourMotor.Release()
		onTransition(previousId, target)
	end
end

-- Boots the framework. Called from Main.client.lua after CombatClient (which owns sprint and must
-- already be live to push it) and after the camera composers (FOVOffset/CameraOffsetComposer/
-- CameraShake), whose named slots ParkourCamera composes through.
function ParkourController.Start(): ()
	if started then
		return
	end
	started = true

	ParkourNetwork.Start()
	ParkourNetwork.OnRejected(onActionRejected)
	ParkourInput.Start()
	ParkourCamera.Start()
	ParkourDebug.Start()

	-- See Shared/PlayerLifecycle.lua. BindCharacter keeps its own Humanoid/HumanoidRootPart waits and
	-- its public signature -- the binder's Humanoid wait makes the first of those two a table lookup
	-- rather than removing it, and this stays callable directly by a future harness.
	--
	-- The returned handle is what Stop() below needs: this module's own Stop used to disconnect the
	-- Heartbeat and release the body while LEAVING these two connections live, so a "stopped"
	-- controller quietly rebound itself and started driving again on the player's next respawn.
	lifecycleBinding = PlayerLifecycle.BindLocalCharacter({
		Scope = "ParkourController",
		OnCharacter = function(nextCharacter: Model)
			ParkourController.BindCharacter(nextCharacter)
		end,
		OnCharacterRemoving = unbind,
	})

	heartbeatConnection = RunService.Heartbeat:Connect(onHeartbeat)
	logger:info("ParkourController started")
end

-- Stops the loop entirely and releases the body. Not called anywhere in the shipped boot path -- it
-- exists so a test harness or a future "spectator mode" can stand the framework down cleanly rather
-- than leaving a Heartbeat connection driving a character nobody is controlling.
function ParkourController.Stop(): ()
	if heartbeatConnection then
		heartbeatConnection:Disconnect()
		heartbeatConnection = nil
	end
	-- Cleaned BEFORE unbind below, so a CharacterAdded landing in the same frame as a Stop cannot
	-- rebind the body this call is in the middle of releasing.
	if lifecycleBinding then
		lifecycleBinding:Clean()
		lifecycleBinding = nil
	end
	started = false
	unbind()
end

return ParkourController
