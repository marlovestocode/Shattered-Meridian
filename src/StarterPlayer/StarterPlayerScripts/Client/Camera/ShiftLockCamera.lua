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
	continuous slot, eased here and handed over finished -- see the camera-space note below) rather than a direct
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
	Humanoid pattern as "Flying" (Client/Flight/FlightController.lua) / "BonusWalkSpeed"
	(Server/Systems/RunSystem.lua) -- server truth, read reactively by a client presentation module,
	never a NetworkBridge remote for this.

	Shoulder framing is held in CAMERA space (2026-09-29). Humanoid.CameraOffset is applied in the root's
	own object space, so a shoulder offset written there swings round with the body. That never showed
	while this module pinned the body to the camera's yaw -- but swing tracking (Client/Combat/
	SwingTracking.lua) and parkour both turn the body away from the camera for a while, and every time
	they did the camera slid sideways with the shoulder, then slid back when the body was handed back.
	On every swing of a string. The offset is now built in the camera's yaw frame and converted into the
	root's frame just before the composer writes it (updateShoulderOffset, RenderPriority.Camera - 2), so
	turning the body moves the body and not the view. The engage/release ease moved with it: this module
	now eases a 0..1 blend itself and hands the composer the finished vector.

	Locked, but loose (2026-09-29). The body still ends up facing exactly where the camera looks -- that
	is the lock, and it is what aims a swing -- but it TURNS into that facing on a critically damped
	spring (CameraConstants.ShiftLock.BodyTurnFrequency) instead of being snapped onto it every frame.
	A mouse flick swings the character round a beat behind the view rather than the whole body pivoting
	on the same frame, the same "the character moves inside the camera, the camera does not move with the
	character" feel Client/Camera/CameraFollow.lua gives position. It also covers the hand-back: when
	swing tracking or parkour lets go of a body turned away from the camera, the spring (restarted from
	rest while they owned it) brings it round smoothly instead of the one-frame snap it used to take on
	every swing of a string.

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

	Yaw suspension (2026-08-13, parkour): the "ParkourFacingOwned" Humanoid Attribute skips ONLY the
	per-frame root.CFrame write below, leaving MouseBehavior, CameraOffset and `enabled`/`engaged`
	alone. Client/Parkour/ParkourMotor.lua raises it for exactly the window in which it owns the
	character's rotation -- an AlignOrientation drive during Velocity-mode traversals (wall-run,
	wall-jump, vault, mantle) and a directly-written anchored CFrame during Kinematic ones (the ledge
	hang). Without it, both of those fought this module's yaw write every render step for the whole
	duration of the move: the traversal's own facing was overwritten toward camera yaw every frame,
	which is what made a shift-locked mantle twitch and a shift-locked ledge hang refuse to hold its
	pose against the wall.

	Deliberately NOT routed through SetInputSuspended -- that one releases the mouse too, which is
	right for the emote wheel and wrong here, since a player mid-mantle is still shift-locked and still
	expects a locked cursor. The two suspensions are independent; either, both, or neither may be
	active. And deliberately an Attribute rather than a setter like SetInputSuspended's: the parkour
	folder would otherwise have to require this module, which drags Fusion and the whole camera stack
	into the parkour state registry's load chain (Client/Camera is not mounted in test.project.json, so
	Tests/Parkour/StateRegistry.spec would fail outright). Reading it costs the same cached-boolean
	watch this module already runs for Flying and RootControlLocked, and adds no dependency in either
	direction -- see Constants.Attributes.ParkourFacingOwned's own note.
]]

local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants = require(ReplicatedStorage.Shared.Constants)
local CharacterUtil = require(ReplicatedStorage.Shared.CharacterUtil)
local FlightMath = require(ReplicatedStorage.Shared.FlightMath)
local Logger = require(ReplicatedStorage.Shared.Logger)
local PlayerLifecycle = require(ReplicatedStorage.Shared.PlayerLifecycle)
local Trove = require(ReplicatedStorage.Shared.Trove)
local Fusion = require(ReplicatedStorage.Packages.Fusion)

local KeybindManager = require(script.Parent.Parent.Input.KeybindManager)
local CameraOffsetComposer = require(script.Parent.Parent.FX.CameraOffsetComposer)

local logger = Logger.scope("ShiftLockCamera")

local RENDER_STEP_NAME = "ShiftLockCameraUpdate"
local OFFSET_STEP_NAME = "ShiftLockCameraOffset"

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

-- How far the root's facing may differ from the camera's before onRenderStep bothers rewriting it.
-- ~0.05 degrees: two orders of magnitude below the smallest rotation a player could perceive, and
-- comfortably above the float noise two LookVector-derived yaws carry against each other.
local YAW_WRITE_EPSILON_RADIANS = 0.001

-- Mirrors this character's own Humanoid "Flying" Attribute (Client/Flight/FlightController.lua/
-- FlightCamera.lua) -- while true, FlightCamera.lua owns CameraOffset/yaw entirely (a flying admin
-- isn't also meant to be in shift-lock combat framing), so this module skips both writes below
-- rather than fighting it for the same properties every frame. Same watch/cache shape as
-- rootControlLocked above.
local flying = false

-- Mirrors this character's own Humanoid "Mounted" Attribute (Server/Systems/BlimpSystem.lua sets it
-- for the length of a blimp mount). Exactly the same carve-out as `flying` immediately above, for
-- exactly the same reason, just with a different owner: while it is true Client/Camera/BlimpCamera.lua
-- owns the camera offset and the body's facing is a weld the server controls, so contesting either
-- would be this module fighting a system that always wins on the next replication tick.
--
-- A THIRD ATTRIBUTE RATHER THAN LEANING ON RootControlLocked, which BlimpSystem also sets. That one
-- already stops the YAW write (see the guard in onRenderStep), but it does NOT stop the CameraOffset
-- write, and it must not start: RootControlLocked is set by ragdolls and air-combo chases too, and a
-- player being ragdolled out of shift lock should keep their shoulder framing rather than have it
-- snap to centre and back. Mounting is the narrower fact, so it gets the narrower read.
local mounted = false

-- Mirrors whether this character's Humanoid "DefenseState" Attribute is one of the two punish states
-- (Staggered, GuardBroken), or a guard state a stagger can be running underneath (see readPunishLocked
-- in onCharacterAdded). DefenseSystem takes RootControlLocked for these, but only to park the
-- parkour framework (no roll or dash out of a punish) -- nothing physically drives the body's rotation
-- then, unlike a ragdoll, a grab or a mount. Suspending the yaw write for it froze a shift-locked
-- player at whatever angle the stagger caught them (1.8s on a perfect parry), while a player without
-- shift lock could still turn freely through the same stagger. See the yaw guard in onRenderStep.
local punishLocked = false

-- Mirrors this character's own Humanoid "Grabbed" Attribute. A grab victim's root is welded into the
-- attacker's assembly (GrabSystem's hold), which this client does not own, so it must keep the yaw
-- write suspended even if it is also staggered.
local grabbed = false

-- CombatFeedback's ShiftLockEngaged Value (see that file's handle type), bound in Start() --
-- drives the game-styled crosshair (UI/Components/ShiftLockCrosshair.lua) that replaces the
-- engine's stock mouse-locked cursor while the default cursor is hidden below.
local crosshairEngaged: Fusion.Value<boolean>? = nil

-- See this file's header, "Input suspension" section. Read once per render step in onRenderStep
-- below -- a plain boolean check, not a GetAttribute/remote lookup, so suspending costs nothing on
-- every OTHER frame this mode isn't engaged anyway.
local inputSuspended = false

-- Mirrors this character's own Humanoid "ParkourFacingOwned" Attribute -- see this file's header,
-- "Yaw suspension" section, and Constants.Attributes.ParkourFacingOwned's own note. Same cached-local
-- + GetAttributeChangedSignal shape as rootControlLocked/flying above, and cached for the same reason:
-- onRenderStep reads it every frame and a GetAttribute call there would not be free. Deliberately
-- separate from `inputSuspended` above, which also releases the mouse -- right for the emote wheel,
-- wrong for a traversal, since a player mid-mantle is still shift-locked and still expects a locked
-- cursor.
local parkourFacingOwned = false

-- Mirrors the client-written "CombatFacingOwned" Attribute: Client/Combat/SwingTracking.lua is turning (or
-- holding) the body toward a target for a swing's windup and hit window. Exactly the ParkourFacingOwned
-- carve-out above, for a second owner -- see Constants.Attributes.CombatFacingOwned.
local combatFacingOwned = false

-- The shoulder framing's 0..1 engage blend, eased here (see the header's camera-space note). And the last
-- usable camera yaw, for the frame a camera pitched straight down has none.
local shoulderBlend = 0
local lastCameraYaw = 0

-- The body's turn rate (radians/second) on its spring toward the camera's yaw -- see the header's "locked,
-- but loose" note. Zeroed whenever this module is not the one turning the body (disengaged, suspended, or
-- another owner holding the facing), so every hand-back starts the turn from rest.
local bodyYawVelocity = 0

-- Below both of these the body is facing the camera and not turning: nothing to write.
local BODY_YAW_REST_VELOCITY = 0.01

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

-- The shoulder framing, every frame, just before CameraOffsetComposer writes (Camera - 1) -- so it is
-- converted into the root's frame with THIS frame's root rotation, not last frame's. See the header's
-- camera-space note.
--
-- Eases every frame regardless of engagement so releasing the mode (or dying mid-fight) glides the camera
-- back to centre instead of snapping it. Skipped entirely while Flying or Mounted -- see those locals'
-- own headers.
local function updateShoulderOffset(deltaTime: number): ()
	local currentHumanoid = humanoid
	if currentHumanoid == nil then
		return
	end
	if flying or mounted then
		-- Hand CameraOffset over to whichever module owns it -- FlightCamera's own "Flight" slot while
		-- flying, BlimpCamera's "Blimp" slot while mounted. Cleared rather than left at its last
		-- (possibly non-zero, shoulder-offset) value, which would otherwise keep summing into the
		-- composer's total on top of that module's own offset for as long as the state lasted. The blend
		-- restarts from zero, so the shoulder eases back in afterwards exactly as it did before.
		shoulderBlend = 0
		CameraOffsetComposer.ClearContinuous("ShiftLock")
		return
	end

	local shiftLock = Constants.Camera.ShiftLock
	local camera = Workspace.CurrentCamera
	local root = rootPart
	local blendTarget = 0
	if engaged and camera and root then
		local cameraDistance = (camera.CFrame.Position - root.Position).Magnitude
		if cameraDistance >= shiftLock.FirstPersonDistanceThreshold then
			blendTarget = 1
		end
	end
	shoulderBlend += (blendTarget - shoulderBlend) * FlightMath.EaseAlpha(shiftLock.OffsetLerpSpeed, deltaTime)

	local offset = Vector3.zero
	if shoulderBlend > 1e-4 and camera and root then
		local cameraYaw = FlightMath.YawFromFlatDirection(camera.CFrame.LookVector)
		if cameraYaw then
			lastCameraYaw = cameraYaw
		end
		local worldOffset = CFrame.Angles(0, lastCameraYaw, 0)
			:VectorToWorldSpace(shiftLock.ShoulderOffset * shoulderBlend)
		offset = root.CFrame:VectorToObjectSpace(worldOffset)
	end
	-- Already eased above, so the composer is told not to ease it again (its nil-easeSpeed contract).
	CameraOffsetComposer.SetContinuous("ShiftLock", offset, nil)
end

local function onRenderStep(deltaTime: number): ()
	local camera = Workspace.CurrentCamera
	local currentHumanoid = humanoid
	local currentRootPart = rootPart

	local hasLiveCharacter = camera ~= nil
		and currentHumanoid ~= nil
		and currentHumanoid.Health > 0
		and currentRootPart ~= nil
		and currentRootPart.Parent ~= nil

	setEngaged(enabled and hasLiveCharacter)

	if not engaged then
		bodyYawVelocity = 0
		return
	end

	-- See this file's header, "Input suspension" section -- skips the MouseBehavior/yaw writes below
	-- for exactly the window a suspending caller (Client/Emotes/EmoteWheelClient.lua) owns, without
	-- otherwise touching `engaged` or the shoulder easing (updateShoulderOffset, its own render step).
	if inputSuspended then
		bodyYawVelocity = 0
		return
	end

	-- Re-asserted every frame while engaged -- see the file header for why once is not enough. READ
	-- FIRST, though: something else clobbering MouseBehavior is the rare case this re-assert exists
	-- for, and a write that restates the value already there still crosses into the engine and still
	-- runs the property's own setter. The compare is free; the write is not.
	if UserInputService.MouseBehavior ~= Enum.MouseBehavior.LockCenter then
		UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
	end

	-- Character yaw tracks camera yaw -- UNLESS the server is currently driving this body's own
	-- rotation authoritatively (see file header's "Root-control lock" section). Skipping the write
	-- entirely here, rather than e.g. blending it in more softly, is deliberate: any write at all
	-- competes with the server's AlignOrientation/ragdoll physics for the same frame, and the server
	-- always wins on the NEXT replication tick regardless -- fighting it for even one frame is what
	-- produced the visible jitter this lock exists to prevent.
	--
	-- A punish-only lock (see `punishLocked`) is the exception: RootControlLocked is set, but nothing is
	-- rotating the body, so the camera keeps steering it exactly as it would without shift lock.
	local lockOwnsFacing = rootControlLocked and not (punishLocked and not grabbed and not mounted)
	if lockOwnsFacing or flying then
		bodyYawVelocity = 0
		return
	end

	-- See this file's header, "Yaw suspension" section -- Client/Parkour/ParkourMotor.lua owns the
	-- character's rotation for the duration of an owned traversal, and this write would otherwise
	-- contest it every render step. Grouped with the rootControlLocked/flying guard above rather than
	-- folded into it because it is a different owner with a different lifetime, and kept AFTER the
	-- MouseBehavior re-assert because a suspended YAW is not a suspended MODE: the player is still
	-- shift-locked and still expects a locked cursor while a mantle plays out.
	if parkourFacingOwned or combatFacingOwned then
		bodyYawVelocity = 0
		return
	end

	-- Flattened with the same degenerate-vector guard CombatSystem.lua's isWithinAttackArc uses --
	-- a camera pitched straight down has no usable yaw for one frame, so the character just keeps
	-- its current facing until it does.
	local currentCamera = camera :: Camera
	local root = currentRootPart :: BasePart
	local yaw = FlightMath.YawFromFlatDirection(currentCamera.CFrame.LookVector)
	if not yaw then
		return
	end

	-- GATED ON A REAL YAW CHANGE, not written blind. This is a write to HumanoidRootPart.CFrame on
	-- every render frame for as long as shift lock is engaged, and a CFrame write is not an ordinary
	-- property assignment: it builds two CFrames, multiplies them, touches the physics assembly and
	-- marks the part for replication. A player standing still with the mouse untouched was paying all
	-- of that sixty times a second to re-state the rotation the root already had.
	--
	-- COMPARED AGAINST THE ROOT'S OWN CURRENT YAW, not against the last yaw this function wrote --
	-- which is the difference between a dedupe and a behaviour change. The unconditional write was
	-- also, incidentally, a continuous re-assertion: anything else that rotated the body got undone on
	-- the next frame. Remembering what we last wrote would lose that; asking the body what it is
	-- actually facing keeps it, because an external rotation shows up as a mismatch and is corrected
	-- exactly as before.
	--
	-- An epsilon rather than an exact compare because both yaws come out of LookVectors and will
	-- differ in the last float bits even with a perfectly still mouse. The threshold is far below what
	-- a player can see or a server can act on -- roughly a twentieth of a degree -- so any movement
	-- anybody could notice still writes.
	--
	-- What the gate does NOT re-assert is pitch/roll: the write flattens them, and a body whose yaw
	-- already matches now keeps whatever tilt it has. That is not a live case here -- a ragdoll or an
	-- air-combo chase sets RootControlLocked, which returns several guards above this one, and an
	-- upright Humanoid does not accumulate tilt on its own.
	--
	-- Its two siblings (FX/CameraOffsetComposer.lua, FX/FOVOffset.lua) already dedupe their own
	-- per-frame writes and both cite Server/Systems/RunSystem.lua's "single most expensive thing"
	-- comment for why; this one never got the same treatment.
	--
	-- With the turn now on a spring, "a real yaw change" means the body is off the camera's yaw OR still
	-- turning: a spring settling onto its target keeps writing until it is at rest there.
	local currentYaw = FlightMath.YawFromFlatDirection(root.CFrame.LookVector)
	if currentYaw then
		-- The short way round, so a body facing the other way never spins through 350 degrees.
		local delta = (yaw - currentYaw) % (2 * math.pi)
		if delta > math.pi then
			delta -= 2 * math.pi
		end
		if math.abs(delta) < YAW_WRITE_EPSILON_RADIANS and math.abs(bodyYawVelocity) < BODY_YAW_REST_VELOCITY then
			bodyYawVelocity = 0
			return
		end
		-- Locked, but loose -- see the header. Read back off the root every frame rather than remembered,
		-- so the spring always resumes from where the body really is. A frequency of 0 or less turns the
		-- looseness off: the old rigid snap.
		local shiftLock = Constants.Camera.ShiftLock
		if shiftLock.BodyTurnFrequency > 0 then
			yaw, bodyYawVelocity = FlightMath.SpringStep(
				currentYaw,
				bodyYawVelocity,
				currentYaw + delta,
				shiftLock.BodyTurnFrequency,
				shiftLock.BodyTurnDamping,
				deltaTime
			)
		end
	end
	root.CFrame = CFrame.new(root.Position) * CFrame.Angles(0, yaw, 0)
end

-- `life` is the per-life Shared/Trove.lua scope Shared/PlayerLifecycle.lua hands every bind. Every
-- Attribute watch below goes into it, which is a real fix and not just tidying: those three
-- GetAttributeChangedSignal connections used to be made fresh on every respawn and disconnected never,
-- so a session's worth of deaths left a stack of live listeners all writing the same three
-- module-locals from bodies that no longer existed.
local function onCharacterAdded(character: Model, humanoidInstance: Humanoid, life: Trove.TroveInstance): ()
	-- The Humanoid is already resolved and already re-checked against the current character by the
	-- binder. The HumanoidRootPart is this module's own additional requirement and still waits here --
	-- see Shared/PlayerLifecycle.lua's header on why it knows about exactly one part of a character.
	local rootPartInstance = CharacterUtil.AwaitRoot(character)
	if not rootPartInstance then
		logger:warn("Character has no HumanoidRootPart -- shift lock cannot drive this character")
		return
	end

	humanoid = humanoidInstance
	rootPart = rootPartInstance

	-- A fresh character's Humanoid never carries over the old one's Attributes -- seed from
	-- whatever the server has already set (normally false/unset on a fresh spawn, but read it
	-- rather than assume in case this bind is racing a same-tick server write) and keep it live
	-- from here on. Same watch shape as FlightController.BindCharacter's "Flying" signal.
	rootControlLocked = humanoidInstance:GetAttribute(Constants.Attributes.RootControlLocked) == true
	life:Connect(humanoidInstance:GetAttributeChangedSignal(Constants.Attributes.RootControlLocked), function()
		rootControlLocked = humanoidInstance:GetAttribute(Constants.Attributes.RootControlLocked) == true
	end)

	flying = humanoidInstance:GetAttribute(Constants.Attributes.Flying) == true
	life:Connect(humanoidInstance:GetAttributeChangedSignal(Constants.Attributes.Flying), function()
		flying = humanoidInstance:GetAttribute(Constants.Attributes.Flying) == true
	end)

	-- Same shape again -- see the `mounted` local's own comment. Seeded rather than assumed false for
	-- the same reason as its neighbours: a player who dies at a blimp helm and respawns can land this
	-- bind after the server has already written the new character's Attributes.
	mounted = humanoidInstance:GetAttribute(Constants.Attributes.Mounted) == true
	life:Connect(humanoidInstance:GetAttributeChangedSignal(Constants.Attributes.Mounted), function()
		mounted = humanoidInstance:GetAttribute(Constants.Attributes.Mounted) == true
	end)

	-- Same shape again for the two reads behind `punishLocked`'s carve-out -- see those locals.
	-- The guard states are included for a parry armed OUT OF a stagger (DefenseConstants.Rally): the
	-- stagger's lock stays on through it, and a guarding body cannot be holding any other lock -- a guard
	-- press mid-swing is deferred until the swing ends, and a grab or a mount is excluded by name below.
	local function readPunishLocked(): boolean
		local state = humanoidInstance:GetAttribute(Constants.Attributes.DefenseState)
		return state == "Staggered"
			or state == "GuardBroken"
			or state == "Raising"
			or state == "ParryWindow"
			or state == "ParryRecovery"
	end
	punishLocked = readPunishLocked()
	life:Connect(humanoidInstance:GetAttributeChangedSignal(Constants.Attributes.DefenseState), function()
		punishLocked = readPunishLocked()
	end)

	grabbed = humanoidInstance:GetAttribute(Constants.Attributes.Grabbed) == true
	life:Connect(humanoidInstance:GetAttributeChangedSignal(Constants.Attributes.Grabbed), function()
		grabbed = humanoidInstance:GetAttribute(Constants.Attributes.Grabbed) == true
	end)

	-- Same shape again, one owner further out: this one is written by another CLIENT module
	-- (Client/Parkour/ParkourMotor.lua) rather than by the server, which changes nothing about how it
	-- is read. Seeded rather than assumed false for the same reason as the two above -- a rapid respawn
	-- can land this bind after the motor has already taken the new character.
	parkourFacingOwned = humanoidInstance:GetAttribute(Constants.Attributes.ParkourFacingOwned) == true
	life:Connect(humanoidInstance:GetAttributeChangedSignal(Constants.Attributes.ParkourFacingOwned), function()
		local nowOwned = humanoidInstance:GetAttribute(Constants.Attributes.ParkourFacingOwned) == true
		parkourFacingOwned = nowOwned
		-- Parkour just handed rotation back. ParkourMotor.restoreRestorables writes Humanoid.AutoRotate
		-- back to whatever it captured at the MOMENT parkour first took ownership -- but if this player
		-- toggled shift lock at any point DURING that traversal, setEngaged (below) already wrote a
		-- newer AutoRotate underneath it that the capture never saw, and the restore just clobbered that
		-- with the stale one. The failure mode is exactly "stops turning to face movement": disengaging
		-- shift lock mid-traversal restores AutoRotate to the shift-locked `false` it captured, and with
		-- `engaged` now false this module's own per-frame yaw write (below) is ALSO not running to
		-- compensate -- so nothing rotates the character at all until the next parkour move happens to
		-- fix it by accident. Reasserting here, from the CURRENT `engaged` rather than a snapshot, is
		-- what keeps the two independent capture/restore systems from being able to disagree. Skipped
		-- while something else legitimately owns the body (root-control lock, flight), same guard as the
		-- per-frame yaw write below -- this module has no business asserting AutoRotate over either.
		if not nowOwned and not rootControlLocked and not flying then
			humanoidInstance.AutoRotate = not engaged
		end
	end)

	combatFacingOwned = humanoidInstance:GetAttribute(Constants.Attributes.CombatFacingOwned) == true
	life:Connect(humanoidInstance:GetAttributeChangedSignal(Constants.Attributes.CombatFacingOwned), function()
		combatFacingOwned = humanoidInstance:GetAttribute(Constants.Attributes.CombatFacingOwned) == true
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

	-- See Shared/PlayerLifecycle.lua. This module and FlightCamera were the two that already kept the
	-- post-yield stale-character re-check by hand; that check is now every caller's, not just theirs.
	PlayerLifecycle.BindLocalCharacter({
		Scope = "ShiftLockCamera",
		OnCharacter = onCharacterAdded,
		OnCharacterRemoving = onCharacterRemoving,
	})

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
	-- Before CameraOffsetComposer (Camera - 1), so the shoulder is converted with this frame's root.
	RunService:BindToRenderStep(OFFSET_STEP_NAME, Enum.RenderPriority.Camera.Value - 2, updateShoulderOffset)

	logger:info("ShiftLockCamera started")
end

return ShiftLockCamera
