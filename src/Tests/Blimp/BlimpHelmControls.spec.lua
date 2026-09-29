--!strict
-- Covers BlimpConstants.Controls as a MAP, the same way Tests/Input/GamepadBindings.spec.lua covers
-- Constants.Keybinds.GamepadDefaults -- and for the same reason. A helm control scheme is mostly
-- taste, and taste does not get a test. What is asserted here is the small set of rules that are not
-- taste, every one of which fails SILENTLY: a mis-mapped helm button does not error, does not warn
-- and does not fail to compile. It opens the settings panel when a pilot asks for more speed, or
-- leaves a controller player welded to a ship they cannot get off, and the only way to find out is to
-- be holding a controller at the time.
--
-- The load-bearing claim in BlimpConstants.Controls' header is that its gamepad column is conflict
-- free BY CONSTRUCTION -- that it needs no ContextActionService sink and no suppression switch,
-- because every button it takes has a global meaning that is inert at a helm. That claim is only true
-- while the global map agrees, and the global map is edited by people who have never opened this
-- file. Everything below is that agreement, written down where a change to either side breaks it.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BlimpConstants = require(ReplicatedStorage.Shared.Blimp.BlimpConstants)
local Constants = require(ReplicatedStorage.Shared.Constants)

local CONTROLS = BlimpConstants.Controls

-- The four edge presses, by name. The two axis rows are a different shape (a key PAIR plus a stick)
-- and are asserted separately below.
local PRESS_CONTROLS = { "ThrottleUp", "ThrottleDown", "AllStop", "Autopilot", "Release" }

-- Global gamepad bindings whose own consumer already declines to act while
-- Constants.Attributes.Mounted is set, and is therefore safe for a helm control to share. Each entry
-- names the module that does the declining, because that module is what a future reader has to go and
-- re-check if they want to move a binding off this list.
local GATED_WHILE_MOUNTED: { [string]: string } = {
	-- Client/Parkour/ParkourInput.lua -- every Began is behind its isMounted() check.
	Slide = "ParkourInput",
	Evade = "ParkourInput",
	Dash = "ParkourInput",
	Leap = "ParkourInput",
	-- Client/Emotes/EmoteWheelClient.lua -- refuses to open the wheel while mounted.
	EmoteWheel = "EmoteWheelClient",
	-- Client/Camera/ShiftLockCamera.lua -- reads the same Attribute and yields the camera slot.
	ShiftLock = "ShiftLockCamera",
}

return function()
	local gamepadDefaults = Constants.Keybinds.GamepadDefaults :: { [string]: any }

	describe("the shape of the table", function()
		it("gives every edge press a gamepad button", function()
			for _, name in PRESS_CONTROLS do
				local binding = (CONTROLS :: { [string]: any })[name]
				expect(binding).to.be.ok()
				expect(binding.Gamepad).to.be.ok()
			end
		end)

		-- Exactly one of the two, never both and never neither -- BlimpTypes.HelmPressBinding says so
		-- with two optional fields, which the typechecker cannot turn into an exclusive choice.
		it("names each edge press by a keyboard key or an action, not both", function()
			for _, name in PRESS_CONTROLS do
				local binding = (CONTROLS :: { [string]: any })[name]
				local named = (if binding.Keyboard ~= nil then 1 else 0) + (if binding.Action ~= nil then 1 else 0)
				expect(named).to.equal(1)
			end
		end)

		-- BlimpTypes.HelmPressBinding types this as a Types.KeybindAction, so a typo is already a type
		-- error -- but a KeybindAction is only a NAME, and this asserts the stronger thing that name is
		-- relied on for: that the action has a real keyboard binding to resolve to. Without one the
		-- release row would draw "Unbound" and the release press would never match, with nothing at any
		-- layer objecting.
		it("only names actions that are really bound", function()
			for _, name in PRESS_CONTROLS do
				local binding = (CONTROLS :: { [string]: any })[name]
				if binding.Action ~= nil then
					expect(Constants.Keybinds.Defaults[binding.Action]).to.be.ok()
				end
			end
		end)

		it("gives both held axes an opposed key pair and a stick", function()
			for _, name in { "Steer", "Lift" } do
				local axis = (CONTROLS :: { [string]: any })[name]
				expect(axis).to.be.ok()
				expect(axis.Positive).to.be.ok()
				expect(axis.Negative).to.be.ok()
				expect(axis.Positive).never.to.equal(axis.Negative)
				-- Thumbstick1 specifically, not merely "some gamepad input": BlimpController reads the
				-- axes through Analog.Move(), which is the LEFT stick and nothing else. A legend drawing
				-- one stick while the code polled the other would be a lie no type could catch.
				expect(axis.Gamepad).to.equal(Enum.KeyCode.Thumbstick1)
			end
		end)
	end)

	describe("the gamepad column against the global map", function()
		it("never gives two helm controls the same button", function()
			local seen: { [Enum.KeyCode]: string } = {}
			for _, name in PRESS_CONTROLS do
				local keyCode = (CONTROLS :: { [string]: any })[name].Gamepad
				local existing = seen[keyCode]
				expect(existing == nil or existing == name).to.equal(true)
				seen[keyCode] = name
			end
		end)

		-- THE CENTRAL ASSERTION OF THIS FILE. A helm button may collide with a global binding only when
		-- that binding's own consumer already stands down while mounted. Anything else is a press that
		-- does two things at once -- the concrete case this rules out is DPadUp, which is
		-- SettingsToggle and is deliberately NOT mount-gated, because a pilot has every right to open
		-- their settings mid-flight.
		it("only shares a button with an action that already stands down while mounted", function()
			local ownerOf: { [Enum.KeyCode]: string } = {}
			for action, keybind in pairs(gamepadDefaults) do
				if keybind.KeyCode ~= nil then
					ownerOf[keybind.KeyCode] = action
				end
			end

			for _, name in PRESS_CONTROLS do
				local keyCode = (CONTROLS :: { [string]: any })[name].Gamepad
				local clashingAction = ownerOf[keyCode]
				if clashingAction ~= nil then
					expect(GATED_WHILE_MOUNTED[clashingAction]).to.be.ok()
				end
			end
		end)

		-- The chord modifier is the one button a helm control must never take, and it is the one case
		-- the check above cannot catch: the modifier is not an ACTION in the plain map, so it owns no
		-- entry there. Holding it as a throttle lever would put the pad on the alternate layer for the
		-- whole time a pilot leaned on it.
		it("never takes the chord modifier", function()
			local modifier = Constants.Keybinds.GamepadModifier.KeyCode
			for _, name in PRESS_CONTROLS do
				expect((CONTROLS :: { [string]: any })[name].Gamepad).never.to.equal(modifier)
			end
		end)

		-- The counterpart of Tests/Input/GamepadBindings.spec.lua's "leaves ButtonA alone" rule, and
		-- the reason the two specs do not contradict each other: that rule is about the GLOBAL map,
		-- whose premise is a player who can jump. This map's premise is a player welded to a station
		-- with PlatformStand set, who cannot. The exemption is scoped to this table, so it is asserted
		-- here as a fact about this table rather than left to look like an oversight in that one.
		it("spends the engine's own jump button, which only a contextual map may do", function()
			expect(CONTROLS.ThrottleDown.Gamepad).to.equal(Enum.KeyCode.ButtonA)
			for _, keybind in pairs(gamepadDefaults) do
				expect(keybind.KeyCode).never.to.equal(Enum.KeyCode.ButtonA)
			end
		end)

		-- Mounting is a ProximityPrompt press and dismounting is this binding, and a player who learns
		-- one has learned the other only while they are the same button. BlimpSystem leaves the station
		-- prompts' GamepadKeyCode at the engine default, which is ButtonX.
		it("releases on the same button the prompt boards with", function()
			expect(CONTROLS.Release.Gamepad).to.equal(Enum.KeyCode.ButtonX)
		end)
	end)

	describe("the keyboard column", function()
		-- The old arrangement's real failure mode, in the one direction a spec can still see it: these
		-- keys were matched raw in BlimpController and spelled again as literals in Screens/BlimpHelm,
		-- and nothing tied the two together. They are one table now, and this asserts the keys did not
		-- quietly change identity in the move.
		it("keeps the keys pilots already have in their hands", function()
			expect(CONTROLS.Steer.Negative).to.equal(Enum.KeyCode.A)
			expect(CONTROLS.Steer.Positive).to.equal(Enum.KeyCode.D)
			expect(CONTROLS.Lift.Positive).to.equal(Enum.KeyCode.Space)
			expect(CONTROLS.Lift.Negative).to.equal(Enum.KeyCode.LeftShift)
			expect(CONTROLS.ThrottleUp.Keyboard).to.equal(Enum.KeyCode.W)
			expect(CONTROLS.ThrottleDown.Keyboard).to.equal(Enum.KeyCode.S)
			expect(CONTROLS.AllStop.Keyboard).to.equal(Enum.KeyCode.X)
			expect(CONTROLS.Autopilot.Keyboard).to.equal(Enum.KeyCode.G)
		end)

		-- The furnace's unload prompt sits on the same hull, within arm's reach of the wheel, and
		-- BlimpConstants.Prompt.UnloadKeyCode's own header records checking the helm's raw keys before
		-- picking V -- explicitly ruling out X because that is All Stop, even though prompts are
		-- suppressed while mounted and the two could never have fired together. This holds that line.
		--
		-- ONLY THE KEYBOARD HALF, and the asymmetry is deliberate rather than an omission. That header's
		-- stated reason for the stricter rule is that a shared key is "one rebind away from being a real
		-- collision" -- a risk that exists because Interact IS rebindable and sits on the neighbouring
		-- prompt. The gamepad column has no such neighbour: the helm's ButtonY and
		-- UnloadGamepadKeyCode's ButtonY genuinely overlap, neither is rebindable, and nothing can ever
		-- bring them closer together than they already are. What keeps them apart is
		-- BlimpController.setPromptsSuppressed, which turns ProximityPromptService off outright for a
		-- mounted client -- the same switch that makes the release press reachable at all. Asserting
		-- non-equality there would be asserting a spare margin this scheme cannot afford (four helm
		-- commands, four face buttons) in exchange for a risk that does not exist.
		it("keeps the keyboard column clear of the furnace's unload prompt", function()
			for _, name in PRESS_CONTROLS do
				local binding = (CONTROLS :: { [string]: any })[name]
				expect(binding.Keyboard).never.to.equal(BlimpConstants.Prompt.UnloadKeyCode)
			end
		end)
	end)
end
