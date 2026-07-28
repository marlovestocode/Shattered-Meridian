--!strict
--[[
	CameraOffsetComposer.lua

	Owns: the single canonical writer of the local player's Humanoid.CameraOffset. Before this
	module existed, two client modules wrote CameraOffset directly and uncoordinated:
	ShiftLockCamera.lua's over-the-shoulder framing (eased toward Constants.Camera.ShiftLock.
	ShoulderOffset or back to zero) and FlightCamera.lua's backward chase pull-back while flying.
	Each avoided fighting the other only by manually checking a mutual-exclusion flag (ShiftLockCamera
	skipping its own write while a "flying" Attribute watch was true; FlightCamera only writing while
	its own "engaged" was true) -- the same fragile pattern Client/FX/FOVOffset.lua's own header
	describes for FieldOfView before THAT module existed. Adding a third CameraOffset writer (a future
	recoil/lean/sway feature) the same way would mean a third hand-rolled guard to keep in sync. This
	module is the fix -- the identical architectural role FOVOffset already plays for FieldOfView, just
	for CameraOffset: named slots summed onto one Vector3, written once per frame at a single
	RenderPriority.

	One composition kind for now (Continuous -- see FOVOffset.lua's header for why Punch exists there
	and doesn't here: neither existing caller needs a one-shot kick on CameraOffset today; add a Punch
	slot kind here the same way FOVOffset has one if/when a caller needs it, don't invent it ahead of
	that need). SetContinuous(name, targetOffset, easeSpeed) -- easeSpeed nil means the caller already
	eased its own delta upstream (FlightCamera's chase pull-back does its own easing against
	Constants.Camera.Flight.ChaseEaseSpeed, same reasoning as its FOVOffset.SetContinuous call sitting
	right next to it) and this module just sums/snaps to it; a positive easeSpeed means this module
	eases the slot's live value toward the target itself every frame (Shared/FlightMath.EaseAlpha, the
	same idiom FOVOffset's own Continuous slots use).

	All slots sum onto a Vector3.zero baseline (unlike FOVOffset, which lazily captures a non-zero base
	FOV some other system may have already set -- no other system in this codebase sets a meaningful
	baseline CameraOffset independent of ShiftLockCamera/FlightCamera, so there's nothing to preserve
	here) and are written to humanoid.CameraOffset once per frame for the LOCAL PLAYER's current
	character, tracked via its own CharacterAdded/CharacterRemoving watch (the same self-contained-watch
	idiom ShiftLockCamera.lua/FlightCamera.lua already use for their own humanoid references) --
	independent of either caller's own character tracking, the same way FOVOffset independently reads
	Workspace.CurrentCamera rather than relying on a caller to hand it one.

	Does not own: deciding WHEN to offset the camera (ShiftLockCamera/FlightCamera still own that), or
	any other camera/Humanoid property (FieldOfView stays FOVOffset's alone; camera rotation stays
	CameraShake's alone; AutoRotate/WalkSpeed/etc. stay owned exactly where they already are).
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local FlightMath = require(ReplicatedStorage.Shared.FlightMath)
local Constants = require(ReplicatedStorage.Shared.Constants)
local Logger = require(ReplicatedStorage.Shared.Logger)

local logger = Logger.scope("CameraOffsetComposer")

local RENDER_STEP_NAME = "CameraOffsetCompose"

type ContinuousSlot = {
	Current: Vector3,
	Target: Vector3,
	EaseSpeed: number?,
}

local CameraOffsetComposer = {}

local slots: { [string]: ContinuousSlot } = {}

local started = false
local humanoid: Humanoid? = nil

-- Persistent named offset. If easeSpeed is a positive number, THIS module eases the slot's live
-- value toward targetOffset every frame. If easeSpeed is nil, the slot snaps straight to
-- targetOffset -- for a caller that already eased its own delta upstream and would otherwise be
-- double-eased (see file header).
function CameraOffsetComposer.SetContinuous(name: string, targetOffset: Vector3, easeSpeed: number?): ()
	local existing = slots[name]
	if existing then
		existing.Target = targetOffset
		existing.EaseSpeed = easeSpeed
		if not easeSpeed then
			existing.Current = targetOffset
		end
		return
	end
	slots[name] = {
		Current = if easeSpeed then Vector3.zero else targetOffset,
		Target = targetOffset,
		EaseSpeed = easeSpeed,
	}
end

-- Hard removal, no fade -- for teardown (e.g. disengage) where a lingering offset would be wrong
-- regardless of how it looks. A caller wanting a smooth release should call
-- SetContinuous(name, Vector3.zero, easeSpeed) instead and just leave the settled ~0 slot in place.
function CameraOffsetComposer.ClearContinuous(name: string): ()
	slots[name] = nil
end

local function onRenderStep(deltaTime: number): ()
	local currentHumanoid = humanoid
	if not currentHumanoid then
		return
	end

	local total = Vector3.zero
	for _, slot in pairs(slots) do
		if slot.EaseSpeed then
			local alpha = FlightMath.EaseAlpha(slot.EaseSpeed :: number, deltaTime)
			slot.Current += (slot.Target - slot.Current) * alpha
		else
			slot.Current = slot.Target
		end
		total += slot.Current
	end

	currentHumanoid.CameraOffset = total
end

local function onCharacterAdded(character: Model): ()
	local localPlayer = Players.LocalPlayer
	local humanoidInstance = character:WaitForChild("Humanoid", Constants.Network.WaitForChildTimeoutSeconds)
	if not humanoidInstance or not humanoidInstance:IsA("Humanoid") then
		return
	end
	if localPlayer.Character ~= character then
		return
	end
	humanoid = humanoidInstance :: Humanoid
end

local function onCharacterRemoving(): ()
	humanoid = nil
end

-- Binds the render-step compositor and the local player's own character watch. Called once from
-- Main.client.lua's boot sequence. Idempotent. Binds at the same Enum.RenderPriority.Camera.Value + 1
-- slot ShiftLockCamera/FlightCamera already use for their own (now-removed) direct CameraOffset
-- writes -- a different property write than FOVOffset's FieldOfView, so there's no ordering hazard
-- sharing the same priority tier as that module.
function CameraOffsetComposer.Start(): ()
	if started then
		return
	end
	started = true

	local localPlayer = Players.LocalPlayer
	localPlayer.CharacterAdded:Connect(onCharacterAdded)
	localPlayer.CharacterRemoving:Connect(onCharacterRemoving)
	if localPlayer.Character then
		task.spawn(onCharacterAdded, localPlayer.Character)
	end

	RunService:BindToRenderStep(RENDER_STEP_NAME, Enum.RenderPriority.Camera.Value + 1, onRenderStep)
	logger:info("CameraOffsetComposer started")
end

return CameraOffsetComposer
