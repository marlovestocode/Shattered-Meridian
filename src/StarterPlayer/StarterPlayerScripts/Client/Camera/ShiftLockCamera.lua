--!strict
--[[
	ShiftLockCamera.lua

	Owns: the custom shift-lock camera mode -- combat-philosophy.md's "Established systems" list
	names the combat camera as bespoke, not default Roblox behavior. Toggled with the ShiftLock
	keybind (KeybindManager.lua, LeftShift default; the engine's own mouse-lock switch is disabled
	in default.project.json -- StarterPlayer.EnableMouseLockOption = false -- so both systems can
	never toggle on the same key press and fight over MouseBehavior). While engaged: the mouse is
	locked to screen center (re-asserted every render step, not written once -- Roblox's own camera
	scripts reset MouseBehavior on their internal state changes, so a single write silently
	unsticks), the camera frames over the right shoulder (Humanoid.CameraOffset, eased rather than
	snapped, so the default camera's zoom and collision handling keep working underneath), and the
	character's yaw tracks the camera's yaw every frame (AutoRotate off; root CFrame rotation
	written at RenderPriority.Camera + 1 so it reads the camera's final pose for the frame instead
	of lagging it by one). WASD therefore strafes relative to the camera -- which is exactly what
	makes Dash's WalkSpeed-burst-plus-held-WASD movement (CombatSystem.lua's handleDashRequest)
	steerable in a fight instead of a commitment to whichever way the character last faced.

	Purely client-side ("server owns truth, client owns feel" -- software-architecture.md): nothing
	here crosses NetworkBridge. The character orientation this module writes reaches the server
	through Roblox's standard character replication, the same channel it already came through before
	this module existed -- CombatSystem's facing validation (isWithinAttackArc) reads the replicated
	root CFrame and never trusted a client-computed facing value, so this module changes camera
	feel, not the trust model.

	The CameraOffset write goes through Client/FX/CameraOffsetComposer.lua (a named "ShiftLock"
	continuous slot, eased by that module itself via its own easeSpeed) rather than a direct
	Humanoid.CameraOffset write -- see that module's header for why: it's what replaced the old direct
	write and the manual "skip while Flying" mutual-exclusion this file used to need to hand-roll
	against FlightCamera.lua's own direct write.

	Cursor: while engaged the default mouse cursor is hidden entirely (MouseIconEnabled = false --
	the engine's stock MouseLockedCursor texture reads as exactly the "generic Roblox UI style"
	docs/ui-ux-philosophy.md rules out) and the game-styled ShiftLockCrosshair component
	(UI/Components/ShiftLockCrosshair.lua) marks the aim point instead, driven through
	CombatFeedback's ShiftLockEngaged handle field on the same engage/disengage transitions.

	Does not own: keybinds (KeybindManager.lua), lock-on targeting or its reticle (CombatClient.lua/
	LockOnReticle.lua -- lock-on is a targeting system, shift lock is a camera mode; they're
	independent and can be active in any combination), the crosshair's own appearance
	(ShiftLockCrosshair.lua renders; this module only sets the engaged flag it displays), or any
	Humanoid property the server drives (CombatSystem.lua owns WalkSpeed; this module never touches
	it -- AutoRotate is the only Humanoid field it writes directly, and CameraOffset is registered
	through CameraOffsetComposer rather than written directly -- see above).

	Death/respawn: the toggle survives respawn -- it's a mode preference, not per-life state, same
	as the engine's own shift lock. While the character is dead or missing the mode *disengages*
	(mouse released so any death-screen UI is clickable, `engaged` below) and re-engages
	automatically once the new character binds.

	Root-control lock: the per-frame yaw write below (`root.CFrame = ...`) is suspended while this
	client's own Humanoid has its server-set "RootControlLocked" Attribute true (CombatSystem.lua's
	syncRootControlLocked -- true while CombatState.ragdollExpiry or airComboChaseExpiry haven't
	elapsed, i.e. a finisher/DashPunch ragdoll is tumbling this body, or RagdollController.HoldAloft
	has a rigid AlignOrientation pin on it as the air-combo attacker). Without this, this module kept
	forcibly overwriting the local player's own rootPart rotation to camera yaw EVERY frame regardless
	of what else was driving it -- invisible to every other client (shift lock only ever drives the
	LOCAL player's own character, never a remote one), but on the owning client's own screen it fought
	the server's authoritative hold/ragdoll orientation continuously, which is why an air-combo
	attacker's own view of their flight looked different from how the same flight looked to everyone
	else (the server-replicated, uncontested state everyone else renders). Same server-Attribute-on-
	Humanoid pattern as "Flying" (DevMenu/FlightController.lua) / "BonusWalkSpeed"
	(Server/Combat/Movement.lua) -- server truth, read reactively by a client presentation module,
	never a NetworkBridge remote for this.

	Logging (Logger.scope("ShiftLockCamera"), Studio-only per Logger.lua): toggle and engage/
	disengage transitions and character (re)binds only -- nothing logs at render-step frequency.

	Input suspension (2026-08-10, radial emote wheel): SetInputSuspended(true) tells this module to
	skip its own per-frame MouseBehavior/yaw writes below without touching `enabled`/`engaged` at all
	-- CameraOffset easing keeps running regardless, so a shift-locked player's shoulder framing
	doesn't visibly snap away and back. Client/Emotes/EmoteWheelClient.lua is the one caller today: the
	wheel needs MouseBehavior at Default for its own mouse-steered selection, and this module's own
	"re-assert LockCenter every frame while engaged" loop (see this file's header on why once isn't
	enough) would otherwise silently overwrite that one frame later. This is the same "coordinate with
	the canonical writer instead of fighting it" contract FOVOffset/CameraOffsetComposer already give
	other camera-property writers, applied to MouseBehavior specifically since no shared composer
	exists for that property yet -- a second caller needing the same suspend semantics for a different
	reason is the point at which generalizing this into one would earn its keep.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants = require(ReplicatedStorage.Shared.Constants)
local FlightMath = require(ReplicatedStorage.Shared.FlightMath)
local Logger = require(ReplicatedStorage.Shared.Logger)
local Fusion = require(ReplicatedStorage.Packages.Fusion)

local KeybindManager = require(script.Parent.Parent.Input.KeybindManager)
local CameraOffsetComposer = require(script.Parent.Parent.FX.CameraOffsetComposer)

local logger = Logger.scope("ShiftLockCamera")

local RENDER_STEP_NAME = "ShiftLockCameraUpdate"

local ShiftLockCamera = {}

-- The player's toggle: what they've asked for. Survives death/respawn (see file header).
local enabled = false
-- Whether the mode is actually driving camera/character THIS frame -- enabled AND a live, bound
-- character to drive. Tracked across frames so the icon/AutoRotate/MouseBehavior writes happen
-- once per transition instead of every tick -- the same enter/exit-transition pattern
-- CombatSystem.lua's finisherReadyNotifier (Shared/ChangeNotifier) uses for Combat_ComboStateChanged.
local engaged = false

local humanoid: Humanoid? = nil
local rootPart: BasePart? = nil

-- Mirrors this character's own Humanoid "RootControlLocked" Attribute (see file header) --
-- cached in a local rather than read fresh every render step so onRenderStep's hot path is a
-- plain boolean check, not a GetAttribute call every frame. Kept current via
-- GetAttributeChangedSignal in onCharacterAdded, same pattern as FlightController.BindCharacter's
-- "Flying" watch.
local rootControlLocked = false

-- Mirrors this character's own Humanoid "Flying" Attribute (Client/DevMenu/FlightController.lua/
-- FlightCamera.lua) -- while true, FlightCamera.lua owns CameraOffset/yaw entirely (a flying admin
-- isn't also meant to be in shift-lock combat framing), so this module skips both writes below
-- rather than fighting it for the same properties every frame. Same watch/cache shape as
-- rootControlLocked above.
local flying = false

-- CombatFeedback's ShiftLockEngaged Value (see that file's handle type), bound in Start() --
-- drives the game-styled crosshair (UI/Components/ShiftLockCrosshair.lua) that replaces the
-- engine's stock mouse-locked cursor while the default cursor is hidden below.
local crosshairEngaged: Fusion.Value<boolean>? = nil

-- See this file's header, "Input suspension" section. Read once per render step in onRenderStep
-- below -- a plain boolean check, not a GetAttribute/remote lookup, so suspending costs nothing on
-- every OTHER frame this mode isn't engaged anyway.
local inputSuspended = false

local function setEngaged(nowEngaged: boolean): ()
	if nowEngaged == engaged then
		return
	end
	engaged = nowEngaged

	if crosshairEngaged then
		crosshairEngaged:set(nowEngaged)
	end

	if nowEngaged then
		-- The default cursor disappears entirely while locked -- the ShiftLockCrosshair component
		-- is the aim marker, styled to docs/ui-ux-philosophy.md instead of the engine's stock
		-- MouseLockedCursor texture ("avoid generic Roblox UI styles").
		UserInputService.MouseIconEnabled = false
		if humanoid then
			humanoid.AutoRotate = false
		end
		logger:debug("Shift lock engaged")
	else
		UserInputService.MouseIconEnabled = true
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		-- humanoid is nil here when disengaging because the character was just removed -- the
		-- destroyed humanoid doesn't need its AutoRotate back, and a fresh one spawns with the
		-- default true anyway.
		if humanoid then
			humanoid.AutoRotate = true
		end
		logger:debug("Shift lock disengaged")
	end
end

-- deltaTime is unused now that the CameraOffset ease itself moved into CameraOffsetComposer (this
-- function only computes a target and hands it over, same "_"-prefixed convention FlightCamera.lua
-- already uses for an accepted-but-unused parameter).
local function onRenderStep(_deltaTime: number): ()
	local camera = Workspace.CurrentCamera
	local currentHumanoid = humanoid
	local currentRootPart = rootPart

	local hasLiveCharacter = camera ~= nil
		and currentHumanoid ~= nil
		and currentHumanoid.Health > 0
		and currentRootPart ~= nil
		and currentRootPart.Parent ~= nil

	setEngaged(enabled and hasLiveCharacter)

	local shiftLock = Constants.Camera.ShiftLock

	-- CameraOffset eases every frame regardless of engagement so releasing the mode (or dying
	-- mid-fight) glides the camera back to center instead of snapping it. Skipped entirely while
	-- Flying -- see the `flying` local's own header. Registered through CameraOffsetComposer (a
	-- named "ShiftLock" continuous slot, eased by that module itself via OffsetLerpSpeed) rather than
	-- writing Humanoid.CameraOffset directly -- see this file's header.
	if currentHumanoid and not flying then
		local targetOffset = Vector3.zero
		if engaged and camera and currentRootPart then
			local cameraDistance = (camera.CFrame.Position - currentRootPart.Position).Magnitude
			if cameraDistance >= shiftLock.FirstPersonDistanceThreshold then
				targetOffset = shiftLock.ShoulderOffset
			end
		end

		CameraOffsetComposer.SetContinuous("ShiftLock", targetOffset, shiftLock.OffsetLerpSpeed)
	elseif flying then
		-- Hand CameraOffset over to FlightCamera's own "Flight" slot entirely while flying --
		-- clearing rather than leaving this slot at its last (possibly non-zero, shoulder-offset)
		-- value, which would otherwise keep summing into the composer's total on top of Flight's
		-- own chase pull-back once both slots exist on the same shared composer.
		CameraOffsetComposer.ClearContinuous("ShiftLock")
	end

	if not engaged then
		return
	end

	-- See this file's header, "Input suspension" section -- skips the MouseBehavior/yaw writes below
	-- for exactly the window a suspending caller (Client/Emotes/EmoteWheelClient.lua) owns, without
	-- otherwise touching `engaged` or the CameraOffset easing above.
	if inputSuspended then
		return
	end

	-- Re-asserted every frame while engaged -- see the file header for why once is not enough.
	UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter

	-- Character yaw tracks camera yaw -- UNLESS the server is currently driving this body's own
	-- rotation authoritatively (see file header's "Root-control lock" section). Skipping the write
	-- entirely here, rather than e.g. blending it in more softly, is deliberate: any write at all
	-- competes with the server's AlignOrientation/ragdoll physics for the same frame, and the server
	-- always wins on the NEXT replication tick regardless -- fighting it for even one frame is what
	-- produced the visible jitter this lock exists to prevent.
	if rootControlLocked or flying then
		return
	end

	-- Flattened with the same degenerate-vector guard CombatSystem.lua's isWithinAttackArc uses --
	-- a camera pitched straight down has no usable yaw for one frame, so the character just keeps
	-- its current facing until it does.
	local currentCamera = camera :: Camera
	local root = currentRootPart :: BasePart
	local yaw = FlightMath.YawFromFlatDirection(currentCamera.CFrame.LookVector)
	if yaw then
		root.CFrame = CFrame.new(root.Position) * CFrame.Angles(0, yaw, 0)
	end
end

local function onCharacterAdded(character: Model): ()
	local localPlayer = Players.LocalPlayer

	local humanoidInstance = character:WaitForChild("Humanoid", Constants.Network.WaitForChildTimeoutSeconds)
	if not humanoidInstance or not humanoidInstance:IsA("Humanoid") then
		logger:warn("Character has no Humanoid -- shift lock cannot drive this character")
		return
	end
	local rootPartInstance = character:WaitForChild("HumanoidRootPart", Constants.Network.WaitForChildTimeoutSeconds)
	if not rootPartInstance or not rootPartInstance:IsA("BasePart") then
		logger:warn("Character has no HumanoidRootPart -- shift lock cannot drive this character")
		return
	end

	-- The WaitForChild calls above yield -- if this character was already replaced while we
	-- waited (rapid respawn), binding it now would clobber the newer character's handler.
	if localPlayer.Character ~= character then
		logger:debug("Character replaced while binding -- skipping stale bind")
		return
	end

	humanoid = humanoidInstance
	rootPart = rootPartInstance

	-- A fresh character's Humanoid never carries over the old one's Attributes -- seed from
	-- whatever the server has already set (normally false/unset on a fresh spawn, but read it
	-- rather than assume in case this bind is racing a same-tick server write) and keep it live
	-- from here on. Same watch shape as FlightController.BindCharacter's "Flying" signal.
	rootControlLocked = humanoidInstance:GetAttribute(Constants.Attributes.RootControlLocked) == true
	humanoidInstance:GetAttributeChangedSignal(Constants.Attributes.RootControlLocked):Connect(function()
		rootControlLocked = humanoidInstance:GetAttribute(Constants.Attributes.RootControlLocked) == true
	end)

	flying = humanoidInstance:GetAttribute(Constants.Attributes.Flying) == true
	humanoidInstance:GetAttributeChangedSignal(Constants.Attributes.Flying):Connect(function()
		flying = humanoidInstance:GetAttribute(Constants.Attributes.Flying) == true
	end)

	logger:debug("Character bound", { enabled = enabled, rootControlLocked = rootControlLocked })
end

local function onCharacterRemoving(): ()
	humanoid = nil
	rootPart = nil
end

-- See this file's header, "Input suspension" section.
function ShiftLockCamera.SetInputSuspended(suspended: boolean): ()
	inputSuspended = suspended
end

-- shiftLockEngaged is CombatFeedback's handle field of the same name (Main.client.lua passes it
-- through) -- the one UI touchpoint this module has, set only on engage/disengage transitions.
function ShiftLockCamera.Start(shiftLockEngaged: Fusion.Value<boolean>): ()
	logger:info("ShiftLockCamera.Start called")

	crosshairEngaged = shiftLockEngaged

	local localPlayer = Players.LocalPlayer

	localPlayer.CharacterAdded:Connect(onCharacterAdded)
	localPlayer.CharacterRemoving:Connect(onCharacterRemoving)
	if localPlayer.Character then
		-- task.spawn because onCharacterAdded yields on WaitForChild -- the client boot sequence
		-- (Main.client.lua) shouldn't stall behind character assembly.
		task.spawn(onCharacterAdded, localPlayer.Character)
	end

	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if gameProcessed then
			return
		end
		if not KeybindManager.Matches("ShiftLock", input) then
			return
		end
		enabled = not enabled
		logger:info("Shift lock toggled", { enabled = enabled })
	end)

	-- Camera.Value + 1: after the default camera scripts have produced the frame's final camera
	-- pose, so the yaw the character copies is this frame's, not last frame's.
	RunService:BindToRenderStep(RENDER_STEP_NAME, Enum.RenderPriority.Camera.Value + 1, onRenderStep)

	logger:info("ShiftLockCamera started")
end

return ShiftLockCamera
