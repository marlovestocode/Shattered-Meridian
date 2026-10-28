--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local DebugKeys = require(ReplicatedStorage.Shared.Input.DebugKeys)
local DebugConstants = require(ReplicatedStorage.Shared.DebugConstants)
local ParkourConstants = require(ReplicatedStorage.Shared.Parkour.ParkourConstants)

return function()
	describe("DebugKeys", function()
		it("has no raw dev key that collides with another, a keyboard default, or an engine key", function()
			local clashes = DebugKeys.Clashes()
			expect(table.concat(clashes, "; ")).to.equal("")
		end)

		it("is what each dev tool's own config reads", function()
			expect(DebugConstants.FpsCounter.ToggleKeyCode).to.equal(DebugKeys.FpsCounter)
			expect(DebugConstants.Storybook.ToggleKeyCode).to.equal(DebugKeys.Storybook)
			expect(ParkourConstants.Debug.ToggleKeyCode).to.equal(DebugKeys.ParkourDebug)
		end)
	end)
end
