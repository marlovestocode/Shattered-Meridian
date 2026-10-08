--!strict
-- Covers Server/Combat/RootControl.lua -- RootControlLocked as a set of claims. The case that matters is the
-- overlap: before this module, any one writer's release cleared every other writer's lock.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local AttributeConstants = require(ReplicatedStorage.Shared.AttributeConstants)
local RootControl = require(ServerScriptService.Server.Combat.RootControl)

local OWNERS = RootControl.Owners

return function()
	describe("RootControl", function()
		local holder: Instance
		local humanoid: Humanoid

		beforeEach(function()
			RootControl.ResetForTesting()
			holder = Instance.new("Model")
			humanoid = Instance.new("Humanoid")
			humanoid.Parent = holder
		end)

		afterEach(function()
			holder:Destroy()
		end)

		local function locked(): boolean
			return humanoid:GetAttribute(AttributeConstants.RootControlLocked) == true
		end

		it("locks on the first claim and unlocks on its release", function()
			RootControl.Claim(humanoid, OWNERS.Swing)
			expect(locked()).to.equal(true)
			RootControl.Release(humanoid, OWNERS.Swing)
			expect(locked()).to.equal(false)
			expect(humanoid:GetAttribute(AttributeConstants.RootControlLocked)).to.equal(nil)
		end)

		it("keeps the body locked while another writer still holds it", function()
			-- An air-combo victim staggered out of a parry: the stagger ending must not hand the held body back.
			RootControl.Claim(humanoid, OWNERS.AirCombo)
			RootControl.Claim(humanoid, OWNERS.Defense)
			RootControl.Release(humanoid, OWNERS.Defense)
			expect(locked()).to.equal(true)
			expect(RootControl.IsClaimed(humanoid, OWNERS.AirCombo)).to.equal(true)
			RootControl.Release(humanoid, OWNERS.AirCombo)
			expect(locked()).to.equal(false)
		end)

		it("holds one claim per owner however often it is taken", function()
			RootControl.Claim(humanoid, OWNERS.GrabVictim)
			RootControl.Claim(humanoid, OWNERS.GrabVictim)
			RootControl.Release(humanoid, OWNERS.GrabVictim)
			expect(locked()).to.equal(false)
		end)

		it("ignores a release by a writer that holds nothing", function()
			RootControl.Claim(humanoid, OWNERS.Vessel)
			RootControl.Release(humanoid, OWNERS.Swing)
			expect(locked()).to.equal(true)
			expect(RootControl.Holders(humanoid)[1]).to.equal(OWNERS.Vessel)
		end)

		it("sets or drops a claim from a boolean", function()
			RootControl.Set(humanoid, OWNERS.Defense, true)
			expect(RootControl.IsClaimed(humanoid)).to.equal(true)
			RootControl.Set(humanoid, OWNERS.Defense, false)
			expect(RootControl.IsClaimed(humanoid)).to.equal(false)
		end)
	end)
end
