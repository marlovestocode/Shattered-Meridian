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
	also matches Client/DevMenu/FlightController.lua's own loop and the server's own authoritative tick.

	SPRINT IS NOT OWNED HERE. Client/Combat/CombatClient.lua keeps ownership of sprint (its remotes,
	the server-side WalkSpeed tier, hold-vs-toggle, Autorun) and pushes the resulting boolean in via
	SetSprinting -- the same shape it already uses to push sprint state into Client/FX/MovementVFX.lua.
	Two systems deciding whether a player is sprinting is exactly the split ownership this framework
	exists to avoid.

	Does not own: any movement behavior (the States own that), any raycast (EnvironmentProbe), any
	write to the character (ParkourMotor), or any validation (the server re-checks everything).
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants = require(ReplicatedStorage.Shared.Constants)
local ParkourConstants = require(ReplicatedStorage.Shared.Parkour.ParkourConstants)
local ParkourMath = require(ReplicatedStorage.Shared.Parkour.ParkourMath)
local ParkourTypes = require(ReplicatedStorage.Shared.Parkour.ParkourTypes)
local Logger = require(ReplicatedStorage.Shared.Logger)

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
	WallRun = ParkourConstants.WallRun.MaxDurationSeconds + 0.5,
	WallJump = ParkourConstants.WallJump.ControlLockSeconds + 0.5,
	LedgeClimb = ParkourConstants.Ledge.ClimbDurationSeconds + 0.5,
	Roll = ParkourConstants.Roll.DurationSeconds + 0.5,
}

local machine = StateMachine.New("Idle")
for _, definition in States do
	machine:Register(definition)
end

local started = false
local enabled = ParkourConstants.Enabled
local heartbeatConnection: RBXScriptConnection? = nil

local character: Model? = nil
local humanoid: Humanoid? = nil
local rootPart: BasePart? = nil

local sprintHeld = false
local wasGrounded = false

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
		SprintHeld = false,
		Momentum = 0,
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
		LastWallInstance = nil,
		LastWallLeftAt = 0,
		CombatOwned = false,
		Assists = InputBuffer.GetAssists(),
		Motor = ParkourMotor.BeginFrame(),
		AnimationVariant = nil,
		LandingSeverity = nil,
		LedgeAnchorPosition = nil,
		LedgeAnchorNormal = nil,
	}
end

-- Whether some other system currently owns this character's body. Every one of these is an Attribute
-- the SERVER already publishes for its own reasons -- this framework introduces no new signal for it,
-- it just reads the ones that already exist:
--   * RootControlLocked   -- CombatSystem.syncRootControlLocked: a finisher/DashPunch ragdoll is
--                            tumbling this body, or RagdollController.HoldAloft has an AlignPosition
--                            pin on it (an air-combo juggle, from either side).
--   * Flying              -- AdminActionSystem.SetFlying, driven by Client/DevMenu/FlightController.
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
	end
end

local function onTransition(previousId: MovementStateId, nextId: MovementStateId): ()
	reportTransition(previousId, nextId)
	ParkourAnimator.OnStateChanged(previousId, nextId, context.AnimationVariant)
	ParkourCamera.OnStateChanged(previousId, nextId)
	if nextId == "Landing" and context.LandingSeverity then
		ParkourCamera.PlayLanding(context.LandingSeverity)
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
	context.SprintHeld = sprintHeld
	context.Assists = InputBuffer.GetAssists()
	context.CombatOwned = resolveCombatOwned(currentHumanoid)

	local velocity = currentRoot.AssemblyLinearVelocity
	context.Velocity = velocity
	context.VerticalVelocity = velocity.Y
	context.PlanarSpeed = ParkourMath.PlanarSpeed(velocity)
	context.MoveDirection = ParkourMath.SafeUnit(ParkourMath.Flatten(velocity), Vector3.zero)
	-- Humanoid.MoveDirection is the engine's own already-camera-relative, already-normalized movement
	-- intent -- the same value Server/Combat/Movement.lua's ResolveDashDirection/IsMoving read
	-- server-side. Using it rather than polling WASD directly means this framework transparently
	-- supports gamepad sticks, touch thumbsticks and any future control scheme, with no per-device
	-- branching, for free.
	context.MoveIntent = ParkourMath.Flatten(currentHumanoid.MoveDirection)

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
			-- Touching the ground is what resets the wall-run and wall-jump chain limits. That single
			-- rule is what makes those limits a constraint on AIRTIME rather than a global budget: a
			-- player who returns to the ground gets a full fresh set, which is what keeps a long
			-- traversal readable instead of gradually running out of moves for no visible reason.
			context.WallRunChain = 0
			context.WallJumpChain = 0
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
	end

	ParkourAnimator.SetMotion(context.Momentum)
	ParkourCamera.SetSpeed(context.Momentum)
	if nextId == "WallRunning" then
		ParkourCamera.SetWallSide(if context.AnimationVariant == "Left" then -1 else 1)
	else
		ParkourCamera.SetWallSide(0)
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
	local humanoidInstance = nextCharacter:WaitForChild("Humanoid", Constants.Network.WaitForChildTimeoutSeconds)
	if not humanoidInstance or not humanoidInstance:IsA("Humanoid") then
		logger:warn("BindCharacter: no Humanoid")
		return
	end
	local rootInstance = nextCharacter:WaitForChild("HumanoidRootPart", Constants.Network.WaitForChildTimeoutSeconds)
	if not rootInstance or not rootInstance:IsA("BasePart") then
		logger:warn("BindCharacter: no HumanoidRootPart")
		return
	end

	character = nextCharacter
	humanoid = humanoidInstance :: Humanoid
	rootPart = rootInstance :: BasePart

	context = buildInitialContext(nextCharacter, humanoid :: Humanoid, rootPart :: BasePart)
	wasGrounded = false

	EnvironmentProbe.BindCharacter(nextCharacter, humanoid :: Humanoid, rootPart :: BasePart)
	ParkourMotor.BindCharacter(nextCharacter, humanoid :: Humanoid, rootPart :: BasePart)
	ParkourAnimator.BindCharacter(nextCharacter)
	ParkourCamera.Reset()
	ParkourNetwork.Reset()
	InputBuffer.Clear()

	machine:ForceTransition("Idle", context)
	logger:debug("Parkour bound to character")
end

local function unbind(): ()
	ParkourMotor.Unbind()
	EnvironmentProbe.Unbind()
	ParkourAnimator.Unbind()
	ParkourCamera.Reset()
	InputBuffer.Clear()
	character = nil
	humanoid = nil
	rootPart = nil
end

-- Sprint state, pushed in by CombatClient. See the file header for why this is a push rather than
-- this module reading the sprint key itself.
function ParkourController.SetSprinting(sprinting: boolean): ()
	sprintHeld = sprinting
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
		ParkourMotor.Release()
		ParkourAnimator.Reset()
		ParkourCamera.Reset()
		InputBuffer.Clear()
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

	local localPlayer = Players.LocalPlayer
	if localPlayer.Character then
		task.spawn(ParkourController.BindCharacter, localPlayer.Character)
	end
	localPlayer.CharacterAdded:Connect(function(nextCharacter: Model)
		ParkourController.BindCharacter(nextCharacter)
	end)
	localPlayer.CharacterRemoving:Connect(unbind)

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
	started = false
	unbind()
end

return ParkourController
