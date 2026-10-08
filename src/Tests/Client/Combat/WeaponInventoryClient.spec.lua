--!strict
-- Covers Client/Combat/WeaponInventoryClient.lua's refusal toast -- what a refused draw, sheathe or switch says.

local StarterPlayer = game:GetService("StarterPlayer")

local WeaponInventoryClient = require(StarterPlayer.StarterPlayerScripts.Client.Combat.WeaponInventoryClient)

return function()
	describe("WeaponInventoryClient.RefusalNotice", function()
		it("names the cooldown and how long is left", function()
			local title, detail = WeaponInventoryClient.RefusalNotice("SwapCooldown", 2.44)
			expect(title).to.equal("Weapon swap on cooldown")
			expect(detail).to.equal("Ready in 2.4s")
		end)

		it("names a body gate without a countdown", function()
			local title, detail = WeaponInventoryClient.RefusalNotice("Hitstun", nil)
			expect(title).to.equal("Can't swap while stunned")
			expect(detail).to.equal(nil)
		end)

		it("falls back to a generic line for a reason it does not know", function()
			local title = WeaponInventoryClient.RefusalNotice("SomethingNew", 0)
			expect(title).to.equal("Can't swap weapons right now")
		end)
	end)
end
