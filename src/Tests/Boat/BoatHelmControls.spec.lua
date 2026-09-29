--!strict
-- Covers BoatConstants.Controls as a MAP, exactly as src/Tests/Blimp/BlimpHelmControls.spec.lua covers
-- the blimp's -- read that file's header for the full argument. In short: a helm control scheme is
-- mostly taste, and taste does not get a test; what is asserted here is the small set of rules that are
-- not taste, every one of which fails SILENTLY. A mis-mapped helm button does not error, does not warn
-- and does not fail to compile. It opens the settings panel when a skipper asks for more canvas, or
-- leaves a controller player welded to a boat they cannot get off.
--
-- The load-bearing claim in BoatConstants.Controls' header is that its gamepad column is conflict free
-- BY CONSTRUCTION -- that it needs no ContextActionService sink, because every button it takes has a
-- global meaning that is inert at a helm. That claim is only true while the global map agrees, and the
-- global map is edited by people who have never opened this file.
--
-- ONE ASSERTION HERE EXISTS ONLY BECAUSE THERE ARE NOW TWO VEHICLES: the last block, which pins the two
-- schemes to each other. A player who has sailed one vehicle in this game has sailed them all, and that
-- is a property nothing else in the codebase would notice losing.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BlimpConstants = require(ReplicatedStorage.Shared.Blimp.BlimpConstants)
local BoatConstants = require(ReplicatedStorage.Shared.Boat.BoatConstants)
local Constants = require(ReplicatedStorage.Shared.Constants)

local CONTROLS = BoatConstants.Controls

-- The five edge presses, by name. The one axis row is a different shape (a key PAIR plus a stick) and is
-- asserted separately below.
local PRESS_CONTROLS = { "SailUp", "SailDown", "Furl", "Adrift", "Release" }

-- Global gamepad bindings whose own consumer already declines to act while Constants.Attributes.Mounted
-- is set, and is therefore safe for a helm control to share. Each entry names the module that does the
-- declining, because that module is what a future reader has to go and re-check if they want to move a
-- binding off this list. Identical to the blimp spec's list, and deliberately duplicated rather than
-- shared: the two schemes are allowed to diverge, and a shared list would quietly stop being checked
-- against one of them.
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

		-- Exactly one of the two, never both and never neither -- VesselTypes.HelmPressBinding says so
		-- with two optional fields, which the typechecker cannot turn into an exclusive choice.
		it("names each edge press by a keyboard key or an action, not both", function()
			for _, name in PRESS_CONTROLS do
				local binding = (CONTROLS :: { [string]: any })[name]
				local named = (if binding.Keyboard ~= nil then 1 else 0) + (if binding.Action ~= nil then 1 else 0)
				expect(named).to.equal(1)
			end
		end)

		-- A KeybindAction is only a NAME. This asserts the stronger thing that name is relied on for:
		-- that the action has a real keyboard binding to resolve to. Without one the release row would
		-- draw "Unbound" and the release press would never match, with nothing at any layer objecting.
		it("only names actions that are really bound", function()
			for _, name in PRESS_CONTROLS do
				local binding = (CONTROLS :: { [string]: any })[name]
				if binding.Action ~= nil then
					expect(Constants.Keybinds.Defaults[binding.Action]).to.be.ok()
				end
			end
		end)

		it("gives the rudder an opposed key pair and the LEFT stick", function()
			local axis = CONTROLS.Steer
			expect(axis.Positive).to.be.ok()
			expect(axis.Negative).to.be.ok()
			expect(axis.Positive).never.to.equal(axis.Negative)
			-- Thumbstick1 specifically, not merely "some gamepad input": BoatController reads the axis
			-- through Analog.Move(), which is the LEFT stick and nothing else. A legend drawing one stick
			-- while the code polled the other would be a lie no type could catch.
			expect(axis.Gamepad).to.equal(Enum.KeyCode.Thumbstick1)
		end)

		it("has NO second axis -- a boat has no lift, and a dead row would invite one", function()
			expect((CONTROLS :: { [string]: any }).Lift).to.never.be.ok()
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
		-- does two things at once -- the concrete case this rules out is DPadUp, which is SettingsToggle
		-- and is deliberately NOT mount-gated, because a skipper has every right to open their settings
		-- under way.
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

		-- The chord modifier is the one button a helm control must never take, and the one case the
		-- check above cannot catch: the modifier is not an ACTION in the plain map, so it owns no entry
		-- there. Holding it as a sail lever would put the pad on the alternate layer for the whole time
		-- a skipper leaned on it.
		it("never takes the chord modifier", function()
			local modifier = Constants.Keybinds.GamepadModifier.KeyCode
			for _, name in PRESS_CONTROLS do
				expect((CONTROLS :: { [string]: any })[name].Gamepad).never.to.equal(modifier)
			end
		end)

		-- The counterpart of Tests/Input/GamepadBindings.spec.lua's "leaves ButtonA alone" rule. That
		-- rule is about the GLOBAL map, whose premise is a player who can jump; this map's premise is a
		-- player welded to a station with PlatformStand set, who cannot. The exemption is scoped to
		-- contextual maps, so it is asserted here as a fact about this one rather than left to look like
		-- an oversight in that one.
		it("spends the engine's own jump button, which only a contextual map may do", function()
			expect(CONTROLS.SailDown.Gamepad).to.equal(Enum.KeyCode.ButtonA)
			for _, keybind in pairs(gamepadDefaults) do
				expect(keybind.KeyCode).never.to.equal(Enum.KeyCode.ButtonA)
			end
		end)

		-- Mounting is a ProximityPrompt press and dismounting is this binding, and a player who learns
		-- one has learned the other only while they are the same button. BoatSystem leaves the station
		-- prompts' GamepadKeyCode at the engine default, which is ButtonX.
		it("releases on the same button the prompt boards with", function()
			expect(CONTROLS.Release.Gamepad).to.equal(Enum.KeyCode.ButtonX)
		end)
	end)

	describe("the two vehicles agree", function()
		-- The property that exists only because there are now two of these tables. A player who has
		-- sailed a blimp has sailed a boat: the rudder is the same pair and the same stick, more power
		-- is the same button, less is the same button, the panic press is the same button, the latch is
		-- the same button, and getting off is the same button. Nothing else in the codebase would notice
		-- that quietly ceasing to be true.
		--
		-- What the two are NOT pinned to is what the controls MEAN. W/S move canvas here and speed
		-- there; X furls here and rings All Stop there. Those are different verbs on purpose, and a spec
		-- that pinned the labels together would be pinning the wrong thing.
		it("uses the same rudder keys and the same stick", function()
			expect(CONTROLS.Steer.Positive).to.equal(BlimpConstants.Controls.Steer.Positive)
			expect(CONTROLS.Steer.Negative).to.equal(BlimpConstants.Controls.Steer.Negative)
			expect(CONTROLS.Steer.Gamepad).to.equal(BlimpConstants.Controls.Steer.Gamepad)
		end)

		it("puts more power, less power, the panic press and the latch on the same five inputs", function()
			local pairs_: { { any } } = {
				{ CONTROLS.SailUp, BlimpConstants.Controls.ThrottleUp },
				{ CONTROLS.SailDown, BlimpConstants.Controls.ThrottleDown },
				{ CONTROLS.Furl, BlimpConstants.Controls.AllStop },
				{ CONTROLS.Adrift, BlimpConstants.Controls.Autopilot },
				{ CONTROLS.Release, BlimpConstants.Controls.Release },
			}
			for _, row in pairs_ do
				expect(row[1].Keyboard).to.equal(row[2].Keyboard)
				expect(row[1].Action).to.equal(row[2].Action)
				expect(row[1].Gamepad).to.equal(row[2].Gamepad)
			end
		end)

		it("leaves the keys the blimp spends on lift free, rather than reusing them for something else", function()
			-- Headroom, deliberately kept -- see BoatConstants.Controls' own note. A boat may yet want an
			-- anchor or a sounding lead, and a scheme with no spare inputs is one where the next control
			-- has to displace an existing one.
			local spent: { [Enum.KeyCode]: boolean } = {}
			for _, name in PRESS_CONTROLS do
				local keyboard = (CONTROLS :: { [string]: any })[name].Keyboard
				if keyboard ~= nil then
					spent[keyboard] = true
				end
			end
			spent[CONTROLS.Steer.Positive] = true
			spent[CONTROLS.Steer.Negative] = true

			expect(spent[BlimpConstants.Controls.Lift.Positive]).to.never.be.ok()
			expect(spent[BlimpConstants.Controls.Lift.Negative]).to.never.be.ok()
		end)
	end)
end
