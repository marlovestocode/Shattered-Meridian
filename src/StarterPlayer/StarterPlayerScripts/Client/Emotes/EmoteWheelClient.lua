--!strict
--[[
	EmoteWheelClient.lua

	Owns: the input/orchestration side of the radial emote wheel -- mirrors DevMenuClient.lua's role
	(an input-owning client module driving a Screen's handle from outside), not
	Client/UI/Screens/EmoteWheel/init.lua, which is pure presentation with no input handling of its
	own (see that file's header). KeybindManager, pointer tracking and every EmoteController call live
	here. The only thing this module is allowed to call to actually play, stop, or re-slot an emote is
	Client/Emotes/EmoteController.lua's RequestPlay/RequestStop/RequestSetLoadoutSlot -- see that
	file's own header for why (server-validated request/response plumbing, no client prediction).

	TWO POINTERS AIM THIS WHEEL, not one. The mouse steers it by screen position and the gamepad's
	LEFT thumbstick steers it by direction, and both resolve through the same WheelSelection call --
	see openWheel's own InputChanged handler and WheelSelection.CursorFromStick for the conversion.
	The gamepad could open this wheel long before it could use it: the bind existed
	(Constants.Keybinds.GamepadDefaults.EmoteWheel), the selection did not.

	IT ALSO OWNS GETTING OUT OF A POSE, which is not wheel input at all and lives here anyway,
	because this module's own rule above is that every EmoteController call is made from this file.
	A movement or jump press ends a MovementLocked emote through EmoteController.RequestStop -- see
	beginCancelWatch, and Server/Systems/EmoteSystem.lua's WHAT ENDS A LOOPING EMOTE header for why
	that had to be built at all (Sit and Dance zeroed the player's WalkSpeed and nothing in the whole
	system ever cleared it again).

	Lifecycle: ONE UserInputService.InputBegan connection is opened at Start() and stays live for the
	whole client session (cheap -- matches DevMenuClient.lua/CombatClient.lua's own always-on
	InputBegan pattern). It does two things: opens the wheel on the EmoteWheel keybind (keyboard B /
	gamepad DPadDown, Constants.Keybinds.Defaults/GamepadDefaults), and, only while the wheel is
	already open, closes it without confirming on right-click (MouseButton2). ESCAPE IS NO LONGER ONE
	OF THEM -- it is the shell's single Escape stack now (Client/UI/Shell/Chrome.lua), bound in Start
	below off the same handle.IsOpen this module already keeps in lockstep with isOpenValue. The
	cancel behaviour is identical; what changed is that Escape with the wheel open over a panel now
	closes the wheel only, instead of the wheel and whatever it was over. The mouse-
	tracking InputChanged connection and the release-detecting InputEnded connection are NOT part of
	that always-on handler -- both are connected only once the wheel actually opens and disconnected
	the instant it closes (confirm, cancel, or the escape/right-click path), per this feature's own
	"no continuous polling while the wheel is closed" performance requirement. SelectedIndex is only
	ever written when WheelSelection.GetSelectedIndex's result actually changes, never once per
	InputChanged event unconditionally.

	Mouse/camera interaction -- the trickiest part, read this before touching it. Steering wheel
	selection with the mouse must NOT also spin the third-person camera. Roblox's stock camera only
	rotates from raw mouse movement in two cases: while a mouse button is held (click-drag), or while
	UserInputService.MouseBehavior is LockCenter (shift lock / mouse-locked mode) -- with
	MouseBehavior at its Default and no button held, moving the mouse just moves a free OS-style
	cursor across the screen with no camera effect at all, which is exactly the "steer the wheel, not
	the camera" behavior this feature needs. So opening the wheel forces MouseBehavior to Default and
	MouseIconEnabled to true for the open window, restoring whatever was captured at open time on
	close.

	The one real coordination hazard: Client/Camera/ShiftLockCamera.lua is already a canonical writer
	of MouseBehavior -- while its own `engaged` is true, it re-asserts MouseBehavior = LockCenter on
	EVERY render step (see that file's header on why once isn't enough), which would silently fight
	this module's own Default write one frame later if left alone. Rather than duplicating that
	re-assertion or guessing at a priority order, this module now coordinates with it directly:
	ShiftLockCamera.SetInputSuspended(true/false) tells that module to skip its own per-frame
	MouseBehavior/yaw writes for exactly this module's open/close window, the same "named continuous
	slot" spirit CameraOffsetComposer/FOVOffset already use for camera properties with more than one
	writer -- MouseBehavior just doesn't have that generalized composer today, so this is a direct,
	minimal, purpose-built suspend flag instead. FlightCamera.lua never touches MouseBehavior at all
	(confirmed by reading it), so it needs no equivalent coordination.

	NEEDS A LIVE STUDIO PLAYTEST -- selene/stylua/TestEZ can't tell us whether the wheel actually
	feels like a GTA-style wheel in play (cursor responsiveness, whether the free cursor reads as
	comfortable at various sensitivities, whether ShiftLockCamera's suspend/resume is ever visibly
	glitchy on rapid open/close). The two thumbstick numbers below (STICK_SELECT_THRESHOLD,
	STICK_CANCEL_THRESHOLD) are in the same position and cannot be sized from a spec either -- they
	are starting points chosen to be obviously separated, not measured ones. Say so explicitly
	wherever this module is discussed.

	Does not own: whether a play/loadout request is actually legal (Server/Systems/EmoteSystem.lua
	re-validates regardless), the wheel's own rendering/layout (Screens/EmoteWheel/init.lua), or any
	angle/geometry math (Screens/EmoteWheel/WheelSelection.lua, pure and Instance-free).
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Logger = require(ReplicatedStorage.Shared.Logger)

local CharacterUtil = require(ReplicatedStorage.Shared.CharacterUtil)
local Trove = require(ReplicatedStorage.Shared.Trove)
local Constants = require(ReplicatedStorage.Shared.Constants)
local EmoteRegistry = require(ReplicatedStorage.Shared.Emotes.EmoteRegistry)

local KeybindManager = require(script.Parent.Parent.Input.KeybindManager)
local EmoteController = require(script.Parent.EmoteController)
local EmoteWheelModule = require(script.Parent.Parent.UI.Screens.EmoteWheel)
local WheelSelection = require(script.Parent.Parent.UI.Screens.EmoteWheel.WheelSelection)
local ClientStateModule = require(script.Parent.Parent.UI.State.ClientState)
local ShiftLockCamera = require(script.Parent.Parent.Camera.ShiftLockCamera)
local Chrome = require(script.Parent.Parent.UI.Shell.Chrome)
local Surface = require(script.Parent.Parent.UI.Shell.Surface)

local peek = Fusion.peek

local logger = Logger.scope("EmoteWheelClient")

type EmoteWheelHandle = EmoteWheelModule.EmoteWheelHandle
type ClientState = ClientStateModule.ClientState

local EmoteWheelClient = {}

-- The smallest change in the cursor's angle worth republishing to the dial's needle spring. NOT a
-- selection threshold -- WheelSelection.GetSelectedIndex's dead zone owns that, and this number must
-- never be allowed to grow into a second, competing one.
--
-- It exists because InputChanged fires on mouse events that move the pointer by a fraction of a
-- pixel, and re-targeting a spring with a value it is already at is not free: every write wakes the
-- spring for another settle it does not need. At SEGMENT_RADIUS (172px, EmoteWheel/init.lua) this is
-- roughly a fifth of a pixel of arc -- comfortably below anything a player can aim at, and orders of
-- magnitude below the ~0.006 rad a single pixel of real cursor movement produces there, so a genuine
-- slow drag is never swallowed.
local ANGLE_EPSILON_RADIANS = 0.001

-- Thumbstick throw, 0..1, past which the stick counts as pointing somewhere. Gamepad sticks rest
-- noisily rather than at exact zero, so a wheel that read the raw magnitude would sit with a segment
-- selected the whole time the player was not touching it -- the same "nothing chosen has to be a
-- real state" argument WheelSelection.lua's own dead-zone header makes for the mouse, applied to the
-- one axis a mouse does not have.
local STICK_SELECT_THRESHOLD = 0.35

-- A movement or jump press ENDS A MOVEMENT-LOCKED EMOTE, and this list is what counts as one. Raw
-- KeyCodes rather than KeybindManager lookups because none of these are Types.KeybindAction entries
-- -- character movement belongs to the stock control module, not to this codebase's own bind table,
-- exactly as Client/Blimp/BlimpController.lua already reads W/A/S/D directly for the helm axes and as
-- KeybindManager.IsJumpKeyDown already hardcodes the Space/ButtonA jump pair for the same reason.
--
-- ONLY A LOCKED EMOTE IS CANCELLED THIS WAY -- see onActiveEmoteChanged. A Wave or a Taunt declares
-- MovementLocked = false precisely so it can play while its owner keeps running, and cancelling
-- those on the first movement key would make them unusable on the move.
local CANCEL_KEYCODES: { [Enum.KeyCode]: boolean } = {
	[Enum.KeyCode.W] = true,
	[Enum.KeyCode.A] = true,
	[Enum.KeyCode.S] = true,
	[Enum.KeyCode.D] = true,
	[Enum.KeyCode.Space] = true,
	[Enum.KeyCode.ButtonA] = true,
}

-- The gamepad half of the same cancel. Higher than STICK_SELECT_THRESHOLD above on purpose: standing
-- up out of a pose should take a deliberate shove of the stick, not the drift that would merely be
-- enough to aim a wheel the player is already looking at.
local STICK_CANCEL_THRESHOLD = 0.5

-- Module-scope, not a Fusion Value -- see this module's own header on why CombatClient.lua needs to
-- call EmoteWheelClient.IsOpen() safely even before Start() runs (always false until Start() wires
-- input). Kept as the single source of truth the always-on InputBegan handler below also reads,
-- rather than re-deriving "is the wheel open" from handle.IsOpen (a Fusion Value) at every input
-- event.
local isOpenValue = false

-- Everything the OPEN wheel holds -- the pointer/stick watch and the release watch. Cleaned in
-- closeWheel and refilled by the next openWheel, which is exactly Shared/Trove.lua's reusable-scope
-- contract: closing a wheel that was never opened is a no-op, so closeWheel needs no guard of its own
-- beyond the isOpenValue early-out it already has.
local openTrove = Trove.New()

-- Captured the instant the wheel opens, restored exactly on close -- see this file's header. Default/
-- true are reasonable startup fallbacks (Roblox's own engine defaults) in case this module is ever
-- queried before an open/close cycle has run once, though that's not a real code path today.
local savedMouseBehavior: Enum.MouseBehavior = Enum.MouseBehavior.Default
local savedMouseIconEnabled = true

-- Safe to call at any time, including before Start() -- see isOpenValue's own header.
function EmoteWheelClient.IsOpen(): boolean
	return isOpenValue
end

-- Cancelling a pose -------------------------------------------------------------------------------

-- OPEN ONLY WHILE A MOVEMENT-LOCKED EMOTE IS ACTUALLY RUNNING, which is the whole reason these are
-- not folded into the always-on InputBegan handler in Start() below. That handler already exists and
-- could carry the keyboard half for free -- but not the gamepad half, which needs InputChanged, and
-- InputChanged fires on every pixel of mouse movement for the entire session. This module's own
-- header promises no continuous polling outside an open wheel; a pose is a second, equally bounded
-- window, so these connections live and die with it.
local cancelTrove = Trove.New()

local function endCancelWatch(): ()
	cancelTrove:Clean()
end

-- The one thing a player could not do before this existed: get up. See Shared/EmoteConstants.lua's
-- RemoteNames.RequestStop and Server/Systems/EmoteSystem.lua's WHAT ENDS A LOOPING EMOTE header --
-- Sit and Dance are both Loop and MovementLocked, so nothing in the system ever cleared the zeroed
-- WalkSpeed on its own and sitting down was a trap.
--
-- A key already HELD when the pose starts does not cancel it, because InputBegan does not re-fire
-- for it -- which is the behaviour that reads correctly: a player who sat down mid-run has to ask to
-- stand up, rather than being stood straight back up by the key they were already leaning on.
local function beginCancelWatch(): ()
	endCancelWatch()

	cancelTrove:Connect(UserInputService.InputBegan, function(input: InputObject, gameProcessed: boolean)
		-- Typing a W into the chat bar is not a request to stand up.
		if gameProcessed then
			return
		end
		if CANCEL_KEYCODES[input.KeyCode] then
			logger:debug("Emote cancelled by movement input", { keyCode = input.KeyCode.Name })
			EmoteController.RequestStop()
		end
	end)

	cancelTrove:Connect(UserInputService.InputChanged, function(input: InputObject)
		if input.KeyCode ~= Enum.KeyCode.Thumbstick1 then
			return
		end
		if Vector2.new(input.Position.X, input.Position.Y).Magnitude < STICK_CANCEL_THRESHOLD then
			return
		end
		logger:debug("Emote cancelled by movement stick")
		EmoteController.RequestStop()
	end)
end

-- Whichever emote the server says is running now, or nil -- EmoteController's own report, wired in
-- Start() below. Only a MovementLocked one arms the watch; see CANCEL_KEYCODES.
local function onActiveEmoteChanged(emoteId: string?): ()
	if emoteId == nil then
		endCancelWatch()
		return
	end
	local definition = EmoteRegistry.Get(emoteId)
	if definition and definition.MovementLocked then
		beginCancelWatch()
	else
		endCancelWatch()
	end
end

local function closeWheel(handle: EmoteWheelHandle): ()
	if not isOpenValue then
		return
	end
	isOpenValue = false

	openTrove:Clean()

	handle.IsOpen:set(false)
	handle.SelectedIndex:set(nil)

	ShiftLockCamera.SetInputSuspended(false)
	UserInputService.MouseBehavior = savedMouseBehavior
	UserInputService.MouseIconEnabled = savedMouseIconEnabled

	logger:debug("Emote wheel closed")
end

-- Release-with-a-selection path -- reads the confirmed slot straight off clientState.EmoteLoadout
-- (never a copy this module made itself) and fires it through EmoteController.RequestPlay, THEN
-- closes. Firing before closeWheel (rather than after) doesn't matter functionally -- RequestPlay is
-- fire-and-forget -- but keeps the "what did the player just do" log line paired with a still-valid
-- SelectedIndex read.
local function confirmSelection(handle: EmoteWheelHandle, clientState: ClientState): ()
	local index = peek(handle.SelectedIndex)
	if not index then
		return
	end
	local loadout = peek(clientState.EmoteLoadout)
	local emoteId = loadout[index]
	if not emoteId then
		return
	end
	logger:debug("Emote wheel confirmed", { index = index, emoteId = emoteId })
	EmoteController.RequestPlay(emoteId)
end

-- A mounted body is welded to a blimp station with its arms driven by that mount's own pose solver,
-- and Server/Systems/EmoteSystem.handleRequestPlay refuses every emote from one for exactly that
-- reason. Without this guard the wheel still OPENED there: a player at the helm could bring it up,
-- aim it, release, and get nothing at all -- the same silence at the other end of the client that
-- the furnace prompt used to answer a press with.
--
-- READ AS AN ATTRIBUTE, matching the gate it is mirroring rather than requiring BlimpController --
-- Constants.Attributes.Mounted is the seam, and this module has no business knowing which System
-- writes it (see Client/Blimp/BlimpController.lua's own posture and EmoteSystem's header).
--
-- REFUSING TO OPEN rather than opening and reporting a refusal, because the player is standing at a
-- lit console with a control legend on screen: "not while you are flying this" is already the more
-- legible message, and a toast over the helm HUD would be answering a question nobody asked.
local function isMounted(): boolean
	local _, humanoid = CharacterUtil.LiveRig(Players.LocalPlayer)
	return humanoid ~= nil and humanoid:GetAttribute(Constants.Attributes.Mounted) == true
end

local function openWheel(handle: EmoteWheelHandle, clientState: ClientState): ()
	if isOpenValue then
		return
	end
	if isMounted() then
		logger:debug("Emote wheel refused: mounted")
		return
	end
	isOpenValue = true

	handle.SelectedIndex:set(nil)
	handle.IsOpen:set(true)

	savedMouseBehavior = UserInputService.MouseBehavior
	savedMouseIconEnabled = UserInputService.MouseIconEnabled
	ShiftLockCamera.SetInputSuspended(true)
	UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	UserInputService.MouseIconEnabled = true

	-- The wheel's own Screen anchors its whole tree to the screen center (EmoteWheel/init.lua's own
	-- "Wheel" Frame, Position fromScale(0.5, 0.5)), computed once per open (a mid-session viewport
	-- resize while the wheel is open is not a case worth reacting to live).
	--
	-- MINUS THE TOP BAR INSET, and that correction is not cosmetic. The wheel's ScreenGui sets
	-- IgnoreGuiInset = true (Shell/Surface.lua's single decision for every surface), so its own
	-- (0, 0) is the true top-left of the viewport and its centre is ViewportSize / 2 in THAT space.
	-- UserInputService:GetMouseLocation reports in the other space -- origin below Roblox's top bar --
	-- so comparing the two directly puts the wheel's centre half an inset (~18px) above where the
	-- player sees it, biasing every selection upward. Harmless enough to go unnoticed while the wheel
	-- was eight text tiles; not once a needle is drawn pointing at the cursor, because the needle then
	-- visibly does not point at the cursor. Surface.TopBarInset() is the shared accessor
	-- (Shell/Regions.lua and Parkour/ParkourDebug.lua already read the same one).
	local camera = Workspace.CurrentCamera
	local viewportSize = if camera then camera.ViewportSize else Vector2.new(0, 0)
	local center = viewportSize / 2 - Vector2.new(0, Surface.TopBarInset())

	-- Already multiplied by the viewport scale by the screen that owns it -- see EmoteWheel/init.lua's
	-- header on why the radius is published on the handle instead of duplicated here. Peeked once per
	-- open, for the same reason `center` is.
	local deadZoneRadius = peek(handle.DeadZoneRadius)

	local lastSelectedIndex: number? = nil
	local lastAngle = peek(handle.CursorAngle)
	local function refreshSelection(cursor: Vector2): ()
		local loadout = peek(clientState.EmoteLoadout)

		-- Presentation only (the dial's needle). Unwrapped against the previous value before it is
		-- published so a cursor crossing 12 o'clock never asks the needle's spring to sweep the long
		-- way round -- see WheelSelection.UnwrapAngle's own header. Written only when it actually
		-- moved, the same "never once per InputChanged unconditionally" rule SelectedIndex follows
		-- below: sub-pixel cursor jitter reports an angle change of ~0 and must not re-target a spring.
		local angle = WheelSelection.GetCursorAngle(center, cursor)
		if angle then
			local unwrapped = WheelSelection.UnwrapAngle(lastAngle, angle)
			if math.abs(unwrapped - lastAngle) > ANGLE_EPSILON_RADIANS then
				lastAngle = unwrapped
				handle.CursorAngle:set(unwrapped)
			end
		end

		local index = WheelSelection.GetSelectedIndex(center, cursor, #loadout, deadZoneRadius)
		if index == lastSelectedIndex then
			return
		end
		lastSelectedIndex = index
		handle.SelectedIndex:set(index)
	end
	refreshSelection(UserInputService:GetMouseLocation())

	-- ONE CONNECTION, TWO POINTERS. The gamepad opens this wheel already (Constants.Keybinds.
	-- GamepadDefaults.EmoteWheel is DPadDown) and, before the Thumbstick1 branch below existed, could
	-- then do nothing with it: selection came from the mouse alone, so a controller player opened a
	-- wheel, released the button, and performed whatever the untouched cursor happened to be nearest.
	--
	-- The LEFT stick rather than the right, despite the right being where a shooter's weapon wheel
	-- usually lives: the right stick is the camera on this project and would spin the view while the
	-- player aimed the wheel. The cost is that the left stick still walks the character at the same
	-- time, which is the same cost the keyboard path already pays (W still walks while the wheel is
	-- up), and the wheel is a standing-still surface either way.
	openTrove:Connect(UserInputService.InputChanged, function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.MouseMovement then
			refreshSelection(UserInputService:GetMouseLocation())
		elseif input.KeyCode == Enum.KeyCode.Thumbstick1 then
			local stick = Vector2.new(input.Position.X, input.Position.Y)
			refreshSelection(WheelSelection.CursorFromStick(center, stick, deadZoneRadius, STICK_SELECT_THRESHOLD))
		end
	end)

	openTrove:Connect(UserInputService.InputEnded, function(input: InputObject)
		if not KeybindManager.Matches("EmoteWheel", input) then
			return
		end
		confirmSelection(handle, clientState)
		closeWheel(handle)
	end)

	logger:debug("Emote wheel opened")
end

function EmoteWheelClient.Start(handle: EmoteWheelHandle, clientState: ClientState, chrome: Chrome.ChromeHandle): ()
	-- ESCAPE IS THE SHELL'S NOW; RIGHT-CLICK IS STILL THIS MODULE'S. The two used to be one branch,
	-- and separating them is the whole of this migration: MouseButton2 is a wheel-specific cancel
	-- gesture that means nothing anywhere else in the client, while Escape is the one key nine panels
	-- were each answering on their own terms (see Shell/Chrome.lua's Escape-stack header). Bound off
	-- handle.IsOpen rather than isOpenValue below because BindEscape wants a Fusion value and the two
	-- are written in lockstep by openWheel/closeWheel -- which is what isOpenValue's own note above
	-- promises.
	chrome:BindEscape("EmoteWheel", handle.IsOpen, function()
		logger:debug("Emote wheel cancelled")
		closeWheel(handle)
	end)

	-- The pose-cancel watch is armed and disarmed off the server's own Started/Stopped echoes rather
	-- than off anything this module predicts -- the same "the server's echo is the truth" posture
	-- EmoteController.lua holds for playback itself. Registered the way EmoteController already
	-- registers EmoteAnimator's finished hook: one callback slot, one owner.
	EmoteController.SetActiveChangedCallback(onActiveEmoteChanged)

	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if gameProcessed then
			return
		end

		if not isOpenValue then
			if KeybindManager.Matches("EmoteWheel", input) then
				openWheel(handle, clientState)
			end
			return
		end

		-- Cancel path -- closes WITHOUT confirming, distinct from the normal release-with-a-selection
		-- path above (InputEnded matching the EmoteWheel keybind itself). See this file's header on
		-- why MouseButton2 needing a guard against CombatClient.lua's own Feint bind is handled on
		-- that module's side (EmoteWheelClient.IsOpen()), not here.
		if input.UserInputType == Enum.UserInputType.MouseButton2 then
			logger:debug("Emote wheel cancelled")
			closeWheel(handle)
		end
	end)

	logger:info("EmoteWheelClient.Start() complete")
end

return EmoteWheelClient
