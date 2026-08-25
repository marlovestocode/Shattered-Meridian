--!strict
--[[
	EmoteWheelClient.lua

	Owns: the input/orchestration side of the radial emote wheel -- mirrors DevMenuClient.lua's role
	(an input-owning client module driving a Screen's handle from outside), not
	Client/UI/Screens/EmoteWheel/init.lua, which is pure presentation with no input handling of its
	own (see that file's header). KeybindManager, mouse tracking, and every EmoteController call live
	here. The only thing this module is allowed to call to actually play an emote or change a loadout
	slot is Client/Emotes/EmoteController.lua's RequestPlay/RequestSetLoadoutSlot -- see that file's
	own header for why (server-validated request/response plumbing, no client prediction).

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
	glitchy on rapid open/close). Say so explicitly wherever this module is discussed.

	Does not own: whether a play/loadout request is actually legal (Server/Systems/EmoteSystem.lua
	re-validates regardless), the wheel's own rendering/layout (Screens/EmoteWheel/init.lua), or any
	angle/geometry math (Screens/EmoteWheel/WheelSelection.lua, pure and Instance-free).
]]

local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Logger = require(ReplicatedStorage.Shared.Logger)

local KeybindManager = require(script.Parent.Parent.Input.KeybindManager)
local EmoteController = require(script.Parent.EmoteController)
local EmoteWheelModule = require(script.Parent.Parent.UI.Screens.EmoteWheel)
local WheelSelection = require(script.Parent.Parent.UI.Screens.EmoteWheel.WheelSelection)
local ClientStateModule = require(script.Parent.Parent.UI.State.ClientState)
local ShiftLockCamera = require(script.Parent.Parent.Camera.ShiftLockCamera)
local Chrome = require(script.Parent.Parent.UI.Shell.Chrome)

local peek = Fusion.peek

local logger = Logger.scope("EmoteWheelClient")

type EmoteWheelHandle = EmoteWheelModule.EmoteWheelHandle
type ClientState = ClientStateModule.ClientState

local EmoteWheelClient = {}

-- Module-scope, not a Fusion Value -- see this module's own header on why CombatClient.lua needs to
-- call EmoteWheelClient.IsOpen() safely even before Start() runs (always false until Start() wires
-- input). Kept as the single source of truth the always-on InputBegan handler below also reads,
-- rather than re-deriving "is the wheel open" from handle.IsOpen (a Fusion Value) at every input
-- event.
local isOpenValue = false

local mouseMovedConnection: RBXScriptConnection? = nil
local inputEndedConnection: RBXScriptConnection? = nil

-- Captured the instant the wheel opens, restored exactly on close -- see this file's header. Default/
-- true are reasonable startup fallbacks (Roblox's own engine defaults) in case this module is ever
-- queried before an open/close cycle has run once, though that's not a real code path today.
local savedMouseBehavior: Enum.MouseBehavior = Enum.MouseBehavior.Default
local savedMouseIconEnabled = true

-- Safe to call at any time, including before Start() -- see isOpenValue's own header.
function EmoteWheelClient.IsOpen(): boolean
	return isOpenValue
end

local function closeWheel(handle: EmoteWheelHandle): ()
	if not isOpenValue then
		return
	end
	isOpenValue = false

	if mouseMovedConnection then
		mouseMovedConnection:Disconnect()
		mouseMovedConnection = nil
	end
	if inputEndedConnection then
		inputEndedConnection:Disconnect()
		inputEndedConnection = nil
	end

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

local function openWheel(handle: EmoteWheelHandle, clientState: ClientState): ()
	if isOpenValue then
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
	-- "Wheel" Frame, Position fromScale(0.5, 0.5)) -- ViewportSize / 2 is that same point in the
	-- mouse's own screen-space coordinates, computed once per open (a mid-session viewport resize
	-- while the wheel is open is not a case worth reacting to live).
	local camera = Workspace.CurrentCamera
	local center = if camera then camera.ViewportSize / 2 else Vector2.new(0, 0)

	local lastSelectedIndex: number? = nil
	local function refreshSelection(): ()
		local cursor = UserInputService:GetMouseLocation()
		local loadout = peek(clientState.EmoteLoadout)
		local index = WheelSelection.GetSelectedIndex(center, cursor, #loadout)
		if index == lastSelectedIndex then
			return
		end
		lastSelectedIndex = index
		handle.SelectedIndex:set(index)
	end
	refreshSelection()

	mouseMovedConnection = UserInputService.InputChanged:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.MouseMovement then
			refreshSelection()
		end
	end)

	inputEndedConnection = UserInputService.InputEnded:Connect(function(input: InputObject)
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
