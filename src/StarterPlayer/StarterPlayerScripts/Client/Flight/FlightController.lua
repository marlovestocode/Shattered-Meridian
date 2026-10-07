--!strict
--[[
	FlightController.lua

	Owns: free 3D movement for the LOCAL player while their own Humanoid's "Flying" Attribute is
	true (AdminActionSystem.SetFlying, toggled via the dev menu -- see DevMenuClient.lua). Runs
	unconditionally for every client (wired from Main.client.lua, not gated behind the dev-menu
	whitelist) -- it's entirely reactive to server-set state, never requests the toggle itself, so
	there's nothing to authorize here: the Attribute only ever becomes true via an already-
	authorized DevMenuSystem.lua action, the same "server owns truth" reasoning WalkSpeed itself
	already relies on. This also means a non-admin TARGET (an admin flying someone else, not just
	themselves) gets correctly driven by their OWN client the moment their OWN Humanoid's Attribute
	flips, without this module needing to know who's an admin at all.

	Server-side, flight is nothing more than a boolean flag + Humanoid.PlatformStand (suspends the
	Humanoid's own ground movement/state machine) plus, now, a quieted AutoRotate/GettingUp/Physics
	controller state (see AdminActionSystem.SetFlying's own header) -- the same trick
	RagdollController.lua uses for a limp knockdown, reused here for the opposite reason: staying
	fully upright and controllable while THIS module (Noclip) or FlightPhysics.lua (Collide) drives
	position/orientation instead of the default ground character controller.

	Movement is momentum-based (Shared/FlightMath.lua), camera-relative WASD + a vertical axis
	(Space/LeftControl) + a Boost hold (reads Sprint's OWN bound key via KeybindManager.Get("Sprint")
	rather than hardcoding LeftShift -- Sprint has zero effect while PlatformStand=true, so reusing
	its key is deliberate, but the actual key is looked up live so a future Sprint rebind can't
	silently desync Boost from it), with banking/pitch eased in on top so the
	body visibly leans into turns/climbs/dives instead of holding a rigid nose. Two mutually
	exclusive position/orientation drivers, chosen per-frame off the server-set "FlyCollide" Humanoid
	Attribute:
	  - Noclip (default): a direct CFrame write, bypassing collision entirely (deliberate -- admin/
	    debug flight is meant to be able to fly through walls to observe the map).
	  - Collide: FlightPhysics.lua's LinearVelocity/AlignOrientation constraint rig, so the character
	    genuinely stops at walls/floors (useful for testing whether a build is air-navigable).

	Also owns takeoff (a launch burst if the character was grounded when Flying flipped true) and
	landing detection (an in-flight ground-graze raycast, classified soft/hard by descent speed, PLUS
	a post-flight free-fall path via the Humanoid's native Landed state for "flew up, turned flight
	off, fell, landed" -- the natural way most flight sessions end), plus a sonic-boom one-shot when
	sustained boosted speed crosses a threshold. handleTakeoffEvent/handleLandingEvent dispatch to
	FlightAnimator (Client/FX/FlightAnimator.lua), FlightAudio/FlightVFX (Client/FX/), CameraShake.lua
	(hard landings only, reusing the FinisherSlam preset), and HitStop.FreezeFlightLanding; per-frame
	motion is pushed to FlightCamera (Client/Camera/FlightCamera.lua) and FlightAudio's wind-rush loop.

	Does not own: the decision to grant flight or Collide mode (AdminActionSystem.SetFlying/
	SetFlightCollide, admin-only via DevMenuSystem.lua's whitelist) -- this module only ever
	reacts to its OWN Humanoid's Attributes. Nor the momentum/bank-angle/hover-bob MATH itself
	(Shared/FlightMath.lua) or the Collide-mode constraint rig (Client/Flight/FlightPhysics.lua).

	Root-control lock: the per-frame root-part write in stepFlight (Noclip's direct CFrame write, or
	Collide's FlightPhysics.SetCommandedVelocity/SetCommandedOrientation pair) is suspended while this
	client's own Humanoid has its server-set "RootControlLocked" Attribute true (CombatSystem.lua's
	syncRootControlLocked -- true while a finisher/DashPunch ragdoll is tumbling this body, or
	RagdollController.HoldAloft has a rigid AlignPosition/AlignOrientation pin on it, e.g. an admin who
	flew into a fight and got hit or air-combo'd while Flying stayed true). Without this, flight kept
	driving its own position/orientation writes on every Heartbeat regardless of what else was holding
	the body, fighting the server's own ragdoll joints or hold constraints for every frame both were
	active -- the same class of bug Client/Camera/ShiftLockCamera.lua's own yaw write already had, and
	the exact same server-Attribute-on-Humanoid pattern is reused here (same Attribute name, same
	watch-and-cache-a-local shape) rather than re-deriving a second mechanism for the same signal.
]]

local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AttributeConstants = require(ReplicatedStorage.Shared.AttributeConstants)
local FXConstants = require(ReplicatedStorage.Shared.FXConstants)
local CharacterUtil = require(ReplicatedStorage.Shared.CharacterUtil)
local FlightConstants = require(ReplicatedStorage.Shared.Flight.FlightConstants)
local FlightMath = require(ReplicatedStorage.Shared.FlightMath)
local Logger = require(ReplicatedStorage.Shared.Logger)
local PlayerLifecycle = require(ReplicatedStorage.Shared.PlayerLifecycle)
local Trove = require(ReplicatedStorage.Shared.Trove)

local FlightPhysics = require(script.Parent.FlightPhysics)
local FlightAnimator = require(script.Parent.Parent.FX.FlightAnimator)
local FlightAudio = require(script.Parent.Parent.FX.FlightAudio)
local FlightVFX = require(script.Parent.Parent.FX.FlightVFX)
local CameraShake = require(script.Parent.Parent.FX.CameraShake)
local HitStop = require(script.Parent.Parent.FX.HitStop)
local FlightCamera = require(script.Parent.Parent.Camera.FlightCamera)
local KeybindManager = require(script.Parent.Parent.Input.KeybindManager)

local logger = Logger.scope("FlightController")

local FlightController = {}

local heartbeatConnection: RBXScriptConnection? = nil
-- Every Attribute/state watch this module puts on the CURRENT character's Humanoid. A
-- Shared/Trove.lua scope rather than the hand-rolled list-plus-disconnect-loop it used to be -- same
-- job, but "rebind without leaking" is now a property of the structure instead of of remembering to
-- reset one specific field, which is the whole argument that module's header makes.
local attributeTrove = Trove.New()
-- The post-flight descent sampler's own scope. Unlike heartbeatConnection above -- which is read as
-- "are we flying" by both StopFlying and startFlying and therefore stays a field -- this one is a
-- pure handle, and it disconnects itself from inside its own handler, which was three separate
-- if-Disconnect-nil blocks before this.
local postFlightSampleTrove = Trove.New()

-- Per-flight-session movement state. Reset at the top of startFlying(); meaningless while not
-- flying (no Heartbeat is reading them then).
local currentVelocity = Vector3.zero
local renderedYaw = 0
local renderedPitch = 0
local renderedBank = 0
local previousTargetYaw = 0
local previousHoverBobOffset = 0
local landingArmed = true
-- A live playtest showed the position-only rearm debounce above can fire twice within a few
-- milliseconds (a brief touch-clear-touch flicker right at the moment of landing) -- this adds a
-- minimum-time floor alongside it, same throttle idiom as sonicBoomLastFireClock below.
local lastLandingFireClock = 0

-- Sampled continuously for a short window after StopFlying() (see startPostFlightSampling) so the
-- post-flight free-fall Landed handler has a real descent speed to classify against, without
-- needing an always-on per-frame connection for the common case where a character never flies.
local lastDescentSpeed = 0
local recentlyFlyingUntil = 0

-- Edge-triggered (fires once per crossing, not continuously while sustained above threshold) --
-- see the SonicBoomCooldownSeconds check in stepFlight.
local sonicBoomLastFireClock = 0

-- Mirrors this character's own Humanoid "RootControlLocked" Attribute -- see this file's header,
-- "Root-control lock". Cached in a local rather than read fresh every Heartbeat so stepFlight's hot
-- path is a plain boolean check, not a GetAttribute call every frame -- same reasoning and shape as
-- ShiftLockCamera.lua's own `rootControlLocked` local. Kept current via GetAttributeChangedSignal in
-- BindCharacter, alongside the existing Flying/FlyCollide watches.
local rootControlLocked = false

local raycastParams: RaycastParams? = nil

-- Throttled diagnostic log (~1/sec) -- cheap enough to leave in permanently (same Debug-level,
-- Constants.Debug.Logging.Scopes-gated convention every other system in this codebase already
-- uses), and directly answers "is velocity actually growing, and is the position actually
-- changing" without needing to re-instrument this file every time flight feel needs debugging.
local lastDiagnosticLogClock = 0

-- Shortest signed angle from `to` back to `from`, wrapped to [-pi, pi] -- lets yaw/turn-rate math
-- treat the wrap from pi to -pi as a tiny step instead of a near-2*pi jump.
local function angleDelta(to: number, from: number): number
	return (to - from + math.pi) % (2 * math.pi) - math.pi
end

-- Shared with FOVOffset.lua/ShiftLockCamera.lua/FlightCamera.lua's own ease call sites --
-- Shared/FlightMath.EaseAlpha computes the rate->alpha conversion; angleDelta above handles the
-- wrap-around this angular (not linear) ease needs on top of it.
local function easeAngle(current: number, target: number, ratePerSecond: number, deltaTime: number): number
	local alpha = FlightMath.EaseAlpha(ratePerSecond, deltaTime)
	return current + angleDelta(target, current) * alpha
end

-- Only dispatches the burst/anim/sound/dust if the character was actually grounded at the moment
-- Flying flipped true -- toggling flight while already airborne has nothing to "launch off of," so
-- it starts flight silently instead of playing a takeoff beat that doesn't match what happened.
local function handleTakeoffEvent(wasGrounded: boolean, position: Vector3): ()
	logger:info("Flight takeoff", { wasGrounded = wasGrounded, position = tostring(position) })
	if not wasGrounded then
		return
	end
	FlightAnimator.PlayTakeoff()
	FlightAudio.PlayTakeoff()
	FlightVFX.PlayTakeoffDust(position)
end

local function handleLandingEvent(isHard: boolean, position: Vector3): ()
	logger:info("Flight landing", { hard = isHard, position = tostring(position) })
	if isHard then
		FlightAnimator.PlayLandingHard()
		FlightAudio.PlayHardLanding()
		CameraShake.Shake(FXConstants.CameraShake.FinisherSlam)
	else
		FlightAnimator.PlayLandingSoft()
		FlightAudio.PlaySoftLanding()
	end
	FlightVFX.PlayLandingRing(position, isHard)
	HitStop.FreezeFlightLanding(isHard)
end

local function raycastDown(origin: Vector3, distance: number): RaycastResult?
	if not raycastParams then
		return nil
	end
	return Workspace:Raycast(origin, Vector3.new(0, -distance, 0), raycastParams)
end

-- Creates/destroys the Collide-mode constraint rig AND toggles rootPart.Anchored to match `Flying
-- AND FlyCollide` -- called on every transition of either Attribute, not just once, since Collide
-- can be toggled mid-flight (or before takeoff) independently of Flying itself.
--
-- Anchoring during Noclip (Flying AND NOT FlyCollide) is what actually stops a residual gravity
-- drift a live playtest exposed: a live (non-anchored) part still gets one physics step of gravity
-- between each Heartbeat's position reset, which reads as a slow downward sag while "hovering" at
-- zero commanded velocity. An Anchored part is fully kinematic -- immune to gravity/collision/
-- velocity entirely -- which is exactly what Noclip already wants (this file's own header:
-- "bypassing collision entirely"). Collide mode needs the OPPOSITE (a real, unanchored body for its
-- LinearVelocity/AlignOrientation rig to move), and Flying=false needs it unanchored too, so
-- gravity resumes normally for the post-flight free-fall landing path.
local function syncCollideMode(humanoid: Humanoid, rootPart: BasePart): ()
	local flying = humanoid:GetAttribute(AttributeConstants.Flying) == true
	local collide = humanoid:GetAttribute(AttributeConstants.FlyCollide) == true
	rootPart.Anchored = flying and not collide
	if flying and collide then
		FlightPhysics.EnterCollideMode(rootPart)
	else
		FlightPhysics.ExitCollideMode(rootPart)
	end
end

-- Runs for RecentlyFlyingGraceSeconds after StopFlying(), sampling AssemblyLinearVelocity.Y so the
-- Humanoid.StateChanged->Landed handler (bound once per character, see BindCharacter) has a real
-- descent speed to classify a post-flight free-fall landing against. Self-disconnects once the
-- grace window elapses -- bounded cost, not a permanent per-character connection.
local function startPostFlightSampling(rootPart: BasePart): ()
	postFlightSampleTrove:Clean()
	postFlightSampleTrove:Connect(RunService.Heartbeat, function()
		if os.clock() >= recentlyFlyingUntil or not rootPart.Parent then
			postFlightSampleTrove:Clean()
			return
		end
		lastDescentSpeed = rootPart.AssemblyLinearVelocity.Y
	end)
end

local function classifyLanding(descentSpeed: number): (boolean, boolean)
	-- descentSpeed is signed (negative while falling); returns (shouldFire, isHard).
	local fallSpeed = -descentSpeed
	if fallSpeed <= FlightConstants.LandingSpeedDeadzone then
		return false, false
	end
	return true, fallSpeed >= FlightConstants.HardLandingSpeedThreshold
end

local function stepFlight(humanoid: Humanoid, rootPart: BasePart, deltaTime: number): ()
	if deltaTime <= 0 then
		return
	end

	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	local cfg = FlightConstants

	local horizontalInput = Vector3.zero
	if UserInputService:IsKeyDown(Enum.KeyCode.W) then
		horizontalInput += camera.CFrame.LookVector
	end
	if UserInputService:IsKeyDown(Enum.KeyCode.S) then
		horizontalInput -= camera.CFrame.LookVector
	end
	if UserInputService:IsKeyDown(Enum.KeyCode.A) then
		horizontalInput -= camera.CFrame.RightVector
	end
	if UserInputService:IsKeyDown(Enum.KeyCode.D) then
		horizontalInput += camera.CFrame.RightVector
	end
	local verticalInput = 0
	if UserInputService:IsKeyDown(Enum.KeyCode.Space) then
		verticalInput += 1
	end
	if UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) then
		verticalInput -= 1
	end
	-- Reads Sprint's OWN bound key through KeybindManager rather than hardcoding LeftShift directly --
	-- the two happen to be the same key only by coincidence today (Constants.Keybinds.Defaults.Sprint
	-- is also LeftShift); without this, a future Sprint rebind would silently desync Boost from it.
	-- Sprint has no UserInputType binding (only KeyCode) in its Constants.Keybinds.Defaults entry, so
	-- this always has a KeyCode to check.
	local sprintKeybind = KeybindManager.Get("Sprint")
	local boosting = sprintKeybind.KeyCode ~= nil and UserInputService:IsKeyDown(sprintKeybind.KeyCode :: Enum.KeyCode)

	local desiredDirection = horizontalInput
	if desiredDirection.Magnitude > 1e-3 then
		desiredDirection = desiredDirection.Unit + Vector3.new(0, verticalInput * cfg.VerticalSpeedFraction, 0)
	elseif verticalInput ~= 0 then
		desiredDirection = Vector3.new(0, verticalInput * cfg.VerticalSpeedFraction, 0)
	end

	local targetMaxSpeed = cfg.CruiseSpeed * (if boosting then cfg.BoostSpeedMultiplier else 1)
	local acceleration = if boosting then cfg.BoostAcceleration else cfg.Acceleration
	currentVelocity = FlightMath.ComputeNextVelocity(
		currentVelocity,
		desiredDirection,
		targetMaxSpeed,
		acceleration,
		cfg.Deceleration,
		deltaTime
	)

	-- Facing target: the direction of travel when there's meaningful horizontal velocity, otherwise
	-- held at whatever it last was (hovering shouldn't fight the player by snapping to the camera).
	local targetYaw = FlightMath.YawFromFlatDirection(currentVelocity) or previousTargetYaw
	local turnRate = angleDelta(targetYaw, previousTargetYaw) / deltaTime
	previousTargetYaw = targetYaw

	local maxBankRadians = math.rad(cfg.MaxBankAngleDegrees)
	local maxPitchRadians = math.rad(cfg.MaxPitchAngleDegrees)
	local targetBank = FlightMath.ComputeBankAngle(turnRate, maxBankRadians, cfg.BankTurnRateSensitivity)
	local verticalFraction = math.clamp(currentVelocity.Y / math.max(targetMaxSpeed, 1), -1, 1)
	local targetPitch = verticalFraction * maxPitchRadians

	renderedYaw = easeAngle(renderedYaw, targetYaw, cfg.OrientationResponsiveness, deltaTime)
	renderedPitch = easeAngle(renderedPitch, targetPitch, cfg.OrientationResponsiveness, deltaTime)
	renderedBank = easeAngle(renderedBank, targetBank, cfg.OrientationResponsiveness, deltaTime)

	local orientationRotation = CFrame.Angles(0, renderedYaw, 0)
		* CFrame.Angles(renderedPitch, 0, 0)
		* CFrame.Angles(0, 0, renderedBank)

	-- Hover bob: blended fully in at zero speed, fully out at/above HoverSpeedThreshold.
	local bobBlend = 1 - math.clamp(currentVelocity.Magnitude / math.max(cfg.HoverSpeedThreshold, 1e-3), 0, 1)
	local hoverBobOffset = FlightMath.ComputeHoverBobOffset(
		os.clock(),
		cfg.HoverBobAmplitudeStuds,
		cfg.HoverBobPeriodSeconds
	) * bobBlend

	local collideMode = humanoid:GetAttribute(AttributeConstants.FlyCollide) == true
	-- Server-owned root control always wins -- see this file's header, "Root-control lock". Skips
	-- ONLY the position/orientation write itself, the same narrow scope ShiftLockCamera.lua's own
	-- gated yaw write uses: currentVelocity/previousHoverBobOffset keep updating underneath so flight
	-- resumes smoothly the instant the lock clears, instead of resuming from a frozen, one-Heartbeat-
	-- stale snapshot, and the rest of this function (landing detection, sonic boom, camera/audio feed)
	-- stays live rather than pausing wholesale for a lock that's usually brief.
	if not rootControlLocked then
		if collideMode then
			local bobVelocity = (hoverBobOffset - previousHoverBobOffset) / deltaTime
			FlightPhysics.SetCommandedVelocity(rootPart, currentVelocity + Vector3.new(0, bobVelocity, 0))
			FlightPhysics.SetCommandedOrientation(rootPart, CFrame.new(rootPart.Position) * orientationRotation)
		else
			local nextPosition = rootPart.Position
				- Vector3.new(0, previousHoverBobOffset, 0)
				+ currentVelocity * deltaTime
				+ Vector3.new(0, hoverBobOffset, 0)
			-- rootPart is Anchored whenever this (Noclip) branch runs -- see syncCollideMode's own
			-- header for why that's the fix for gravity/momentum drift, not a per-frame velocity reset:
			-- an Anchored part is fully kinematic, so this direct CFrame write is the sole authority over
			-- its position with no physics interaction to fight.
			rootPart.CFrame = CFrame.new(nextPosition) * orientationRotation
		end
	end
	previousHoverBobOffset = hoverBobOffset

	local now = os.clock()

	-- In-flight landing/graze detection -- meaningfully "stops" descent only in Collide mode, but
	-- detected identically in both so the classification/FX hook fires either way.
	local rayDistance = math.max(cfg.LandingRaycastDistance, cfg.LandingRearmHeightStuds) + 1
	local rayResult = raycastDown(rootPart.Position, rayDistance)
	local touchingGround = rayResult ~= nil and rayResult.Distance <= cfg.LandingRaycastDistance
	local clearOfGround = rayResult == nil or rayResult.Distance >= cfg.LandingRearmHeightStuds

	if touchingGround and landingArmed and now - lastLandingFireClock >= FlightConstants.LandingFireDebounceSeconds then
		local shouldFire, isHard = classifyLanding(currentVelocity.Y)
		if shouldFire then
			handleLandingEvent(isHard, rootPart.Position)
			landingArmed = false
			lastLandingFireClock = now
		end
	elseif clearOfGround then
		landingArmed = true
	end

	-- Sonic boom: edge-triggered (fires once on crossing the threshold, throttled by
	-- SonicBoomCooldownSeconds) rather than continuously while sustained above it -- a boosted
	-- straight-line flight would otherwise refire this every frame.
	if
		currentVelocity.Magnitude >= cfg.SonicBoomSpeedThreshold
		and now - sonicBoomLastFireClock >= cfg.SonicBoomCooldownSeconds
	then
		sonicBoomLastFireClock = now
		FlightAudio.PlaySonicBoom()
		FlightVFX.PlaySonicBoomBurst(rootPart.Position)
	end

	FlightCamera.SetFlightMotion(currentVelocity.Magnitude, renderedBank, renderedPitch, boosting)
	FlightAnimator.SetFlightMotion(currentVelocity.Magnitude, boosting)
	FlightAudio.SetWindIntensity(currentVelocity.Magnitude / math.max(targetMaxSpeed, 1))

	if now - lastDiagnosticLogClock >= 1 then
		lastDiagnosticLogClock = now
		-- rawInputMagnitude is the pre-normalization horizontalInput/verticalInput read straight off
		-- UserInputService:IsKeyDown THIS frame -- distinguishes "stuck because no key is actually
		-- being read as held" (rawInputMagnitude == 0, e.g. the game viewport lost input focus) from
		-- a genuine movement-math/collision bug (rawInputMagnitude > 0 but speed stays 0 anyway).
		logger:debug("Flight diagnostic", {
			position = tostring(rootPart.Position),
			velocity = tostring(currentVelocity),
			speed = currentVelocity.Magnitude,
			collideMode = collideMode,
			platformStand = humanoid.PlatformStand,
			humanoidState = tostring(humanoid:GetState()),
			boosting = boosting,
			rawInputMagnitude = desiredDirection.Magnitude,
		})
	end
end

function FlightController.StopFlying(): ()
	if heartbeatConnection then
		heartbeatConnection:Disconnect()
		heartbeatConnection = nil
		FlightAudio.StopWind()
	end
end

local function startFlying(humanoid: Humanoid, character: Model): ()
	if heartbeatConnection then
		return
	end
	local rootPart = CharacterUtil.RootOf(character)
	if not rootPart then
		return
	end

	FlightAudio.StartWind()

	raycastParams = RaycastParams.new()
	raycastParams.FilterType = Enum.RaycastFilterType.Exclude
	raycastParams.FilterDescendantsInstances = { character }
	raycastParams.IgnoreWater = true

	currentVelocity = Vector3.zero
	previousHoverBobOffset = 0
	landingArmed = true
	lastLandingFireClock = 0
	previousTargetYaw = FlightMath.YawFromFlatDirection(rootPart.CFrame.LookVector) or 0
	renderedYaw = previousTargetYaw
	renderedPitch = 0
	renderedBank = 0

	local groundCheck = raycastDown(rootPart.Position, FlightConstants.TakeoffGroundCheckStuds)
	local wasGrounded = groundCheck ~= nil
	if wasGrounded then
		local forward = rootPart.CFrame.LookVector
		local flatForward = Vector3.new(forward.X, 0, forward.Z)
		flatForward = if flatForward.Magnitude > 1e-3 then flatForward.Unit else Vector3.zero
		currentVelocity = flatForward * FlightConstants.TakeoffBurstForwardSpeed
			+ Vector3.new(0, FlightConstants.TakeoffBurstUpSpeed, 0)
	end
	handleTakeoffEvent(wasGrounded, rootPart.Position)

	heartbeatConnection = RunService.Heartbeat:Connect(function(deltaTime: number)
		if not rootPart.Parent or humanoid.Health <= 0 then
			logger:warn("Flight loop exiting early", {
				rootPartParented = rootPart.Parent ~= nil,
				humanoidHealth = humanoid.Health,
			})
			FlightController.StopFlying()
			return
		end
		local ok, errorMessage = pcall(stepFlight, humanoid, rootPart, deltaTime)
		if not ok then
			logger:error("stepFlight errored", { errorMessage = tostring(errorMessage) })
		end
	end)
end

-- Watches this character's own Humanoid for the server-set "Flying"/"FlyCollide"/"RootControlLocked"
-- Attributes and the native Landed state (post-flight free-fall landing path) -- called once per
-- character spawn (FlightController.Start's own CharacterAdded binding below).
function FlightController.BindCharacter(character: Model): ()
	FlightController.StopFlying()
	attributeTrove:Clean()
	postFlightSampleTrove:Clean()
	recentlyFlyingUntil = 0
	lastDescentSpeed = 0

	local humanoid = CharacterUtil.AwaitHumanoid(character)
	if not humanoid then
		return
	end
	local rootPart = CharacterUtil.RootOf(character)

	-- A fresh character's Humanoid never carries over the old one's Attributes -- seed from whatever
	-- the server has already set (same "read rather than assume" reasoning as the Flying/FlyCollide
	-- reads below) and keep it live from here on. See this file's header, "Root-control lock", and
	-- ShiftLockCamera.lua's onCharacterAdded for the identical watch shape on the same Attribute.
	rootControlLocked = humanoid:GetAttribute(AttributeConstants.RootControlLocked) == true
	attributeTrove:Connect(humanoid:GetAttributeChangedSignal(AttributeConstants.RootControlLocked), function()
		rootControlLocked = humanoid:GetAttribute(AttributeConstants.RootControlLocked) == true
	end)

	FlightAnimator.BindCharacter(character)

	if humanoid:GetAttribute(AttributeConstants.Flying) == true then
		startFlying(humanoid, character)
	end
	if rootPart then
		syncCollideMode(humanoid, rootPart)
	end

	attributeTrove:Connect(humanoid:GetAttributeChangedSignal(AttributeConstants.Flying), function()
		if humanoid:GetAttribute(AttributeConstants.Flying) == true then
			startFlying(humanoid, character)
		else
			FlightController.StopFlying()
			recentlyFlyingUntil = os.clock() + FlightConstants.RecentlyFlyingGraceSeconds
			if rootPart then
				startPostFlightSampling(rootPart)
			end
		end
		if rootPart then
			syncCollideMode(humanoid, rootPart)
		end
	end)

	attributeTrove:Connect(humanoid:GetAttributeChangedSignal(AttributeConstants.FlyCollide), function()
		if rootPart then
			syncCollideMode(humanoid, rootPart)
		end
	end)

	-- Post-flight free-fall landing path: covers "flew up, turned flight off, fell, landed" -- the
	-- natural way most flight sessions end. Always connected (cheap, single-property watch); the
	-- recentlyFlyingUntil gate below means it's a no-op for a character that has never flown.
	attributeTrove:Connect(humanoid.StateChanged, function(_old: Enum.HumanoidStateType, new: Enum.HumanoidStateType)
		if new ~= Enum.HumanoidStateType.Landed then
			return
		end
		if os.clock() >= recentlyFlyingUntil then
			return
		end
		local shouldFire, isHard = classifyLanding(lastDescentSpeed)
		if shouldFire and rootPart then
			handleLandingEvent(isHard, rootPart.Position)
		end
	end)
end

function FlightController.Start(): ()
	-- Through Shared/PlayerLifecycle.lua, which fixes a boot stall this had: BindCharacter yields on
	-- WaitForChild("Humanoid"), and the already-present-character call above it was made INLINE on
	-- Main.client.lua's synchronous boot thread -- so on the Studio play-solo and fast-rejoin paths
	-- every module booted after this one waited behind one character's assembly, up to the full
	-- WaitForChild timeout. The binder always spawns that call.
	PlayerLifecycle.BindLocalCharacter({
		Scope = "FlightController",
		OnCharacter = function(character: Model)
			FlightController.BindCharacter(character)
		end,
	})
end

return FlightController
