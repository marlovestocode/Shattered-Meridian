--!strict
--[[
	ParkourInput.lua

	Owns: turning raw input into buffered parkour intents. The only module in this framework that
	touches UserInputService.

	Reads every rebindable action through Client/Input/KeybindManager.Matches rather than comparing
	against a hardcoded KeyCode, which is what makes parkour work identically on keyboard and gamepad
	with no per-device branching here, and what makes the Settings panel's rebind rows apply to it for
	free. Jump is the documented exception: it is not a Types.KeybindAction at all (Roblox owns
	Space/ButtonA natively), so it goes through KeybindManager.IsJumpKeyDown -- the same raw-pair
	carve-out CombatClient.lua's own finisher jump-suppression already uses, rather than a second
	hardcoded copy of that KeyCode pair.

	PRESSES ARE BUFFERED, NOT ACTED ON. Every handler here does exactly one thing: record that an
	intent happened, at what time. Whether it becomes an action -- and when -- is decided entirely by
	the state modules reading InputBuffer. That separation is what makes the forgiveness windows
	possible at all: an input that is acted on immediately can only ever succeed or be dropped, where
	a recorded one can still succeed a moment later.

	Slide deliberately overlaps with Client/Combat/CombatClient.lua's own Slide handling. Both listen;
	CombatClient asks ParkourController.HandlesSlide() before predicting/firing its legacy slide, so
	exactly one of the two responds to any given press. Recording the press here unconditionally is
	correct even when the legacy path wins -- an unconsumed buffer entry simply expires.

	Does not own: what any intent means (the States), the forgiveness windows themselves (InputBuffer),
	or sprint (CombatClient owns sprint and pushes it to ParkourController -- see that module's header).
]]

local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Logger = require(ReplicatedStorage.Shared.Logger)

local InputBuffer = require(script.Parent.InputBuffer)
local KeybindManager = require(script.Parent.Parent.Input.KeybindManager)

local logger = Logger.scope("ParkourInput")

local ParkourInput = {}

local started = false
-- Tracks whether the jump key was down last frame, so a HELD jump produces exactly one buffered
-- press. Without this a held Space would refresh the buffer timestamp every frame, and the buffer
-- would never expire -- turning "jump the moment you land" into "jump forever while held," which
-- is bunny-hopping by accident rather than by design.
local jumpWasDown = false

local function onInputBegan(input: InputObject, gameProcessed: boolean): ()
	if gameProcessed then
		return
	end
	local now = os.clock()

	if KeybindManager.Matches("Slide", input) then
		InputBuffer.PressSlide(now)
		return
	end
	if KeybindManager.Matches("Roll", input) then
		InputBuffer.PressRoll(now)
		return
	end
	if KeybindManager.Matches("Leap", input) then
		InputBuffer.PressLeap(now)
		return
	end
	-- Dash (Q / gamepad B). The binding has existed in Constants.Keybinds since the deleted combat
	-- system owned a dash of its own -- this line is what finally reads it, and the Settings panel's
	-- long-dormant "Dash" rebind row now rebinds something real.
	if KeybindManager.Matches("Dash", input) then
		InputBuffer.PressDash(now)
		return
	end
end

local function onInputEnded(input: InputObject): ()
	if KeybindManager.Matches("Slide", input) then
		InputBuffer.ReleaseSlide()
	end
end

-- Jump is polled rather than event-driven because it has no KeybindAction to match against (see the
-- file header) and because the edge-detection above needs the live down-state, not just the
-- transition -- a jump pressed while a UI element had focus, then released after it lost focus,
-- should not leave a stale buffered press behind.
local function pollJump(): ()
	local isDown = KeybindManager.IsJumpKeyDown()
	if isDown and not jumpWasDown then
		InputBuffer.PressJump(os.clock())
	end
	jumpWasDown = isDown
end

-- Binds the input handlers. Called from ParkourController.Start. Idempotent.
function ParkourInput.Start(): ()
	if started then
		return
	end
	started = true

	UserInputService.InputBegan:Connect(onInputBegan)
	UserInputService.InputEnded:Connect(onInputEnded)
	-- One cheap poll per frame, on the same tick the movement frame runs -- rather than a
	-- UserInputService.JumpRequest connection, which fires repeatedly while held and would need this
	-- same edge-detection anyway on top of a second event source.
	RunService.Heartbeat:Connect(pollJump)

	logger:info("ParkourInput started")
end

return ParkourInput
