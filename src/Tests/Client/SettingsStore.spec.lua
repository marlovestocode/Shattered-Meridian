--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local ParkourConstants = require(ReplicatedStorage.Shared.Parkour.ParkourConstants)

local SettingsStore = require(StarterPlayer.StarterPlayerScripts.Client.Settings.SettingsStore)

return function()
	describe("SettingsStore", function()
		afterEach(function()
			SettingsStore.ResetForTesting()
		end)

		it("starts every group at the defaults the settings hub used to hold", function()
			local parkour = SettingsStore.Get("Parkour")
			expect(parkour.Enabled).to.equal(ParkourConstants.Enabled)
			expect(parkour.SprintMode).to.equal("Hold")
			expect(SettingsStore.Get("Comfort").CameraShake).to.equal(true)
			expect(SettingsStore.Get("Autorun")).to.equal(false)
		end)

		it("hands an observer the current value at once, then every change, until disconnected", function()
			local seen: { boolean } = {}
			local disconnect = SettingsStore.Observe("Autorun", function(enabled: boolean)
				table.insert(seen, enabled)
			end)
			SettingsStore.Set("Autorun", true)
			disconnect()
			SettingsStore.Set("Autorun", false)
			expect(#seen).to.equal(2)
			expect(seen[1]).to.equal(false)
			expect(seen[2]).to.equal(true)
		end)

		it("hands out copies, so a consumer cannot edit the store", function()
			local comfort = SettingsStore.Get("Comfort")
			comfort.CameraShake = false
			expect(SettingsStore.Get("Comfort").CameraShake).to.equal(true)
		end)
	end)
end
