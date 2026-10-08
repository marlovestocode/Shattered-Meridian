--!strict
--[[
	SwingTracking.lua

	Owns: turning the LOCAL player's body toward their target while one of their swings winds up. The
	target is the lock-on target (LockOnController) when there is one, otherwise the nearest combatant in
	a narrow cone in front of the body (the soft assist, LockOnConstants.Tracking). With neither, nothing
	turns and the swing goes where the player aimed it.

	WHY. The server resolves every swing's hitbox from the body's real facing. Shift lock pins that facing
	to the camera, and without shift lock it follows movement, so a swing thrown slightly off-line whiffed
	past a target standing right there. Turning the body during the windup fixes the aim before the hit
	window opens, on the one machine that owns the body.

	CAPPED, NOT SNAPPED. The turn is limited to Locked/AssistTurnDegreesPerSecond, so a defender who moves
	late enough still slips the swing: spacing stays a defence. It stops when the hit window opens, and the
	facing is then HELD (not turned) until the window closes. Turning through the active window would sweep
	the server's hitbox sideways, which is a bigger hitbox, not better aim. Holding stops shift lock from
	snapping the body back to the camera mid-swing and doing the same thing.

	HOW IT HOLDS THE BODY. For the window it raises the client-only CombatFacingOwned Attribute, which
	ShiftLockCamera honours by skipping its yaw write (the ParkourFacingOwned pattern), and it turns
	Humanoid.AutoRotate off so movement does not rotate the body either. Both are put back when the window
	ends, is cancelled, or the character goes away.

	Never turns a body something else already owns: a server root lock, a parkour traversal, a vessel
	mount, a grab, or the air combo (its follow drives the attacker). Air moves are skipped for that reason.

	Does not own: choosing the lock-on target (LockOnController), the candidate list (CombatTargets), the
	forward step (SwingLunge), or whether the swing hits (the server).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local AirComboAttributes = require(ReplicatedStorage.Shared.AirCombo.AirComboAttributes)
local AirComboMoves = require(ReplicatedStorage.Shared.AirCombo.AirComboMoves)
local AttackTypes = require(ReplicatedStorage.Shared.Attack.AttackTypes)
local CharacterUtil = require(ReplicatedStorage.Shared.CharacterUtil)
local AttributeConstants = require(ReplicatedStorage.Shared.AttributeConstants)
local LockOnConstants = require(ReplicatedStorage.Shared.Combat.LockOnConstants)
local Logger = require(ReplicatedStorage.Shared.Logger)
local PlayerLifecycle = require(ReplicatedStorage.Shared.PlayerLifecycle)
local Trove = require(ReplicatedStorage.Shared.Trove)

local AttackInputClient = require(script.Parent.AttackInputClient)
local CombatTargets = require(script.Parent.CombatTargets)
local LockOnController = require(script.Parent.LockOnController)

type AttackStartedPayload = AttackTypes.AttackStartedPayload

local logger = Logger.scope("SwingTracking")

local SwingTracking = {}

type Window = {
	Target: Model,
	-- Degrees per second.
	TurnRate: number,
	-- os.clock() the turning stops (the hit window opens), and the facing hold ends (it closes).
	TurnEndsAt: number,
	HoldEndsAt: number,
	-- The AutoRotate the body had before this window turned it off.
	RestoreAutoRotate: boolean,
}

local window: Window? = nil

local character: Model? = nil
local humanoid: Humanoid? = nil
local rootPart: BasePart? = nil
local started = false

-- Whether something else owns this body's rotation right now.
local function rotationOwnedElsewhere(currentHumanoid: Humanoid): boolean
	local attributes = AttributeConstants
	return currentHumanoid:GetAttribute(attributes.RootControlLocked) == true
		or currentHumanoid:GetAttribute(attributes.ParkourFacingOwned) == true
		or currentHumanoid:GetAttribute(attributes.Mounted) == true
		or currentHumanoid:GetAttribute(attributes.Grabbed) == true
		or AirComboAttributes.IsParticipant(currentHumanoid)
end

local function finish(): ()
	local current = window
	window = nil
	local currentHumanoid = humanoid
	if current == nil or currentHumanoid == nil or currentHumanoid.Parent == nil then
		return
	end
	currentHumanoid:SetAttribute(AttributeConstants.CombatFacingOwned, nil)
	-- Only put AutoRotate back if nothing changed it while this window held it (a shift-lock toggle).
	if current.RestoreAutoRotate and currentHumanoid.AutoRotate == false then
		currentHumanoid.AutoRotate = true
	end
end

-- The target a swing thrown from `root` right now would track, and whether it is a lock-on target. The
-- lock-on target wins whenever it is alive; otherwise the soft assist's pick, or nil.
function SwingTracking.PickTarget(root: BasePart): (Model?, boolean)
	local locked = LockOnController.GetTarget()
	if locked and CombatTargets.LiveRoot(locked, character) then
		return locked, true
	end
	local tuning = LockOnConstants.Tracking
	local assist = CombatTargets.NearestInCone(
		root.Position,
		root.CFrame.LookVector,
		tuning.AssistRangeStuds,
		tuning.AssistConeDegrees,
		character
	)
	return assist, false
end

local function onAttackStarted(payload: AttackStartedPayload): ()
	finish()
	local tuning = LockOnConstants.Tracking
	if not tuning.Enabled then
		return
	end
	if typeof(payload.MoveId) ~= "string" or AirComboMoves.RoleOf(payload.MoveId) ~= nil then
		return
	end
	local currentHumanoid, root = humanoid, rootPart
	if currentHumanoid == nil or root == nil or rotationOwnedElsewhere(currentHumanoid) then
		return
	end
	local targetModel, locked = SwingTracking.PickTarget(root)
	if targetModel == nil then
		return
	end

	local windup = if typeof(payload.WindupSeconds) == "number" then payload.WindupSeconds else 0
	local active = if typeof(payload.ActiveSeconds) == "number" then payload.ActiveSeconds else 0
	local now = os.clock()
	window = {
		Target = targetModel,
		TurnRate = if locked then tuning.LockedTurnDegreesPerSecond else tuning.AssistTurnDegreesPerSecond,
		TurnEndsAt = now + windup + tuning.StopAfterWindupSeconds,
		HoldEndsAt = now + windup + active,
		RestoreAutoRotate = currentHumanoid.AutoRotate,
	}
	currentHumanoid:SetAttribute(AttributeConstants.CombatFacingOwned, true)
	currentHumanoid.AutoRotate = false
end

-- Runs on PreSimulation, BEFORE this frame's physics step, not on Heartbeat after it. A Heartbeat write
-- overwrote the pose physics had just produced and only reached the simulation a frame later, so the turn
-- trailed the input by a frame and fought the Humanoid's own rotation for one step every frame of the
-- windup. Written here, the turn is simulated (and replicated) in the same frame it was decided.
local function onPreSimulation(deltaTime: number): ()
	local current = window
	if current == nil then
		return
	end
	local now = os.clock()
	if now >= current.HoldEndsAt then
		finish()
		return
	end
	if now >= current.TurnEndsAt then
		-- Holding, not turning. See this file's header.
		return
	end
	local currentHumanoid, root = humanoid, rootPart
	if currentHumanoid == nil or root == nil or root.Parent == nil then
		finish()
		return
	end
	if rotationOwnedElsewhere(currentHumanoid) then
		return
	end
	local targetRoot = CombatTargets.LiveRoot(current.Target, character)
	if targetRoot == nil then
		return
	end
	local desired = CombatTargets.YawOf(targetRoot.Position - root.Position)
	local facing = CombatTargets.YawOf(root.CFrame.LookVector)
	if desired == nil or facing == nil then
		return
	end
	local maxStep = math.rad(current.TurnRate) * deltaTime
	local step = math.clamp(CombatTargets.AngleDelta(facing, desired), -maxStep, maxStep)
	if math.abs(step) < 1e-4 then
		return
	end
	root.CFrame = CFrame.new(root.Position) * CFrame.Angles(0, facing + step, 0)
end

local function onCharacter(newCharacter: Model, newHumanoid: Humanoid, _life: Trove.TroveInstance): ()
	finish()
	character = newCharacter
	humanoid = newHumanoid
	rootPart = CharacterUtil.AwaitRoot(newCharacter)
end

local function onCharacterRemoving(): ()
	finish()
	character = nil
	humanoid = nil
	rootPart = nil
end

-- Whether a swing's facing is being held right now. For a spec and the debug overlay.
function SwingTracking.IsActive(): boolean
	return window ~= nil
end

function SwingTracking.Start(): ()
	if started then
		return
	end
	started = true

	AttackInputClient.OnAttackStarted(onAttackStarted)
	AttackInputClient.OnSwingCancelled(function()
		finish()
	end)
	RunService.PreSimulation:Connect(onPreSimulation)

	PlayerLifecycle.BindLocalCharacter({
		Scope = "SwingTracking",
		OnCharacter = onCharacter,
		OnCharacterRemoving = onCharacterRemoving,
	})

	logger:debug("SwingTracking started", { enabled = LockOnConstants.Tracking.Enabled })
end

return SwingTracking
