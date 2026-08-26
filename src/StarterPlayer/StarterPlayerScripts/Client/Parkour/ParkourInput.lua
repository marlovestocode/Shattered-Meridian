--!strict
--[[
	ParkourInput.lua

	Owns: turning raw input into buffered parkour intents. The only module in this framework that
	dispatches input at all -- routed through Client/Input/InputRouter.lua rather than a
	UserInputService connection of its own, so gameProcessed and the modal-panel gate live in exactly
	one place across every migrated feature, not one hand-rolled copy per file.

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
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Constants = require(ReplicatedStorage.Shared.Constants)
local CharacterUtil = require(ReplicatedStorage.Shared.CharacterUtil)
local Logger = require(ReplicatedStorage.Shared.Logger)

local InputBuffer = require(script.Parent.InputBuffer)
local InputRouter = require(script.Parent.Parent.Input.InputRouter)
local KeybindManager = require(script.Parent.Parent.Input.KeybindManager)

local logger = Logger.scope("ParkourInput")

local ParkourInput = {}

local started = false
-- Tracks whether the jump key was down last frame, so a HELD jump produces exactly one buffered
-- press. Without this a held Space would refresh the buffer timestamp every frame, and the buffer
-- would never expire -- turning "jump the moment you land" into "jump forever while held," which
-- is bunny-hopping by accident rather than by design.
local jumpWasDown = false

-- Whether the local character is welded to a blimp station right now (Server/Systems/BlimpSystem.lua
-- writes the Attribute; see Constants.Attributes.Mounted). Read straight off the Humanoid rather than
-- cached, the same way ParkourController's own resolveCombatOwned reads its four ownership Attributes --
-- this runs once per keypress on one branch, not per frame.
local function isMounted(): boolean
	local character = Players.LocalPlayer.Character
	if not character then
		return false
	end
	local humanoid = CharacterUtil.HumanoidOf(character)
	return humanoid ~= nil and humanoid:GetAttribute(Constants.Attributes.Mounted) == true
end

-- Bound through InputRouter's "Gameplay" layer -- see ParkourInput.Start below for the one
-- behavioural note this migration introduces (none of these four actions used to check the modal
-- Attribute at all, and "Gameplay" now does).
local function bindParkourActions(): ()
	InputRouter.Bind("Slide", {
		Layer = "Gameplay",
		Began = function()
			InputBuffer.PressSlide(os.clock())
		end,
		Ended = function()
			InputBuffer.ReleaseSlide()
		end,
	})

	InputRouter.Bind("Roll", {
		Layer = "Gameplay",
		Began = function()
			InputBuffer.PressRoll(os.clock())
		end,
	})

	-- Leap and Interact share E (see Constants.Keybinds.Defaults.Interact's own comment for the whole
	-- argument). A press that is REALLY the "let go of the blimp" press must not also leave a leap in
	-- the buffer: the mount's RootControlLocked parks parkour while it lasts, but the buffered press
	-- would outlive the release by its own window and fire the instant the body came back, launching a
	-- player off a deck they were only trying to step down from. isMounted() stays inline, the same
	-- reason ParkourInput/DefenseClient keep their own ownership checks inline -- InputRouter has no
	-- opinion about blimp mounting.
	InputRouter.Bind("Leap", {
		Layer = "Gameplay",
		Began = function()
			if not isMounted() then
				InputBuffer.PressLeap(os.clock())
			end
		end,
	})

	-- Dash (Q / gamepad B). The binding has existed in Constants.Keybinds since the deleted combat
	-- system owned a dash of its own -- this is what finally reads it, and the Settings panel's
	-- long-dormant "Dash" rebind row now rebinds something real.
	InputRouter.Bind("Dash", {
		Layer = "Gameplay",
		Began = function()
			InputBuffer.PressDash(os.clock())
		end,
	})
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
--
-- BEHAVIOUR NOTE FROM THE InputRouter MIGRATION: Slide/Roll/Leap/Dash previously checked only
-- gameProcessed, never Constants.Attributes.UiModalOpen -- unlike Client/Combat/AttackInputClient.lua
-- and Client/Combat/GrabInputClient.lua, which both already gate on it. InputRouter's "Gameplay"
-- layer applies that gate uniformly (see InputRouter.lua's own header), so these four actions now
-- also go quiet while a modal panel is open, which they did not before. This brings ParkourInput in
-- line with its two combat-input siblings rather than leaving it the one exception, but it is a real
-- behavioural change in the narrow case of a keypress that does not land on the open panel itself
-- (gameProcessed alone would have let it through) -- flagged here rather than silently folded in,
-- per this migration's own instructions.
function ParkourInput.Start(): ()
	if started then
		return
	end
	started = true

	bindParkourActions()
	-- One cheap poll per frame, on the same tick the movement frame runs -- rather than a
	-- UserInputService.JumpRequest connection, which fires repeatedly while held and would need this
	-- same edge-detection anyway on top of a second event source.
	RunService.Heartbeat:Connect(pollJump)

	logger:info("ParkourInput started")
end

return ParkourInput
