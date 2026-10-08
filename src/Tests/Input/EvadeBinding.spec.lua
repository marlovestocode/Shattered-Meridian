--!strict
-- The Evade action has NO default key (Q is the combat dash now) but must stay a known, rebindable
-- action: the keyboard Defaults table is also the allowlist Settings and the saved-override validation
-- read, so deleting the entry would silently remove it from the Keybinds tab.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants = require(ReplicatedStorage.Shared.Constants)

return function()
	local defaults = Constants.Keybinds.Defaults :: { [string]: any }
	local gamepadDefaults = Constants.Keybinds.GamepadDefaults :: { [string]: any }

	it("keeps Evade in the rebindable action list", function()
		expect(defaults.Evade).to.be.ok()
	end)

	it("gives Evade no default keyboard key or mouse button", function()
		expect(defaults.Evade.KeyCode).to.equal(nil)
		expect(defaults.Evade.UserInputType).to.equal(nil)
	end)

	it("gives Evade no default gamepad button", function()
		expect(gamepadDefaults.Evade).to.equal(nil)
	end)
end
