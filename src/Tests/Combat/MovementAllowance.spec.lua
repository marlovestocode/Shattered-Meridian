--!strict
-- Covers Server/Combat/MovementAllowance.lua -- KnockbackUntil as a deadline that only ever extends. The case
-- that matters is the overlap: a realm's 0.6 s correction used to overwrite a launch's 2 s allowance with a
-- deadline 1.4 s nearer.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local AttributeConstants = require(ReplicatedStorage.Shared.AttributeConstants)
local DamageConstants = require(ReplicatedStorage.Shared.Damage.DamageConstants)
local DomainConstants = require(ReplicatedStorage.Shared.Domain.DomainConstants)
local MovementAllowance = require(ServerScriptService.Server.Combat.MovementAllowance)

return function()
	describe("MovementAllowance", function()
		local holder: Instance
		local humanoid: Humanoid

		beforeEach(function()
			holder = Instance.new("Model")
			humanoid = Instance.new("Humanoid")
			humanoid.Parent = holder
		end)

		afterEach(function()
			holder:Destroy()
		end)

		it("has no deadline until something stamps one", function()
			expect(MovementAllowance.Until(humanoid)).to.equal(0)
			expect(humanoid:GetAttribute(AttributeConstants.KnockbackUntil)).to.equal(nil)
		end)

		it("stamps the deadline it is given", function()
			expect(MovementAllowance.Stamp(humanoid, 120)).to.equal(120)
			expect(humanoid:GetAttribute(AttributeConstants.KnockbackUntil)).to.equal(120)
			expect(MovementAllowance.Until(humanoid)).to.equal(120)
		end)

		it("extends to a later deadline", function()
			MovementAllowance.Stamp(humanoid, 120)
			expect(MovementAllowance.Stamp(humanoid, 130)).to.equal(130)
			expect(MovementAllowance.Until(humanoid)).to.equal(130)
		end)

		it("never pulls a deadline back: a shorter claim landing inside a longer one leaves it", function()
			MovementAllowance.Stamp(humanoid, 130)
			expect(MovementAllowance.Stamp(humanoid, 125)).to.equal(130)
			expect(MovementAllowance.Until(humanoid)).to.equal(130)
		end)

		it("keeps a launch's allowance when a realm correction lands inside it", function()
			-- The two real grants, read from their constants: the launch is the longer one.
			local launch = DamageConstants.Knockback.MovementAllowanceSeconds
			local correction = DomainConstants.ContainmentAllowanceSeconds
			expect(launch > correction).to.equal(true)

			local hitAt = 100
			MovementAllowance.Stamp(humanoid, hitAt + launch)
			MovementAllowance.Stamp(humanoid, hitAt + 0.5 + correction)
			expect(MovementAllowance.Until(humanoid)).to.equal(hitAt + launch)
		end)

		it("treats a junk value already on the Attribute as no deadline", function()
			humanoid:SetAttribute(AttributeConstants.KnockbackUntil, "soon")
			expect(MovementAllowance.Until(humanoid)).to.equal(0)
			expect(MovementAllowance.Stamp(humanoid, 5)).to.equal(5)
		end)
	end)
end
