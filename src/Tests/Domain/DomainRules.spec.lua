--!strict
-- Covers Shared/Domain/DomainRules.lua -- composing a realm's rules, publishing them on a Humanoid, and
-- the lease every reader goes through. Real Humanoids; an explicit `now` on every read.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AttributeConstants = require(ReplicatedStorage.Shared.AttributeConstants)
local DomainRules = require(ReplicatedStorage.Shared.Domain.DomainRules)

local humanoids: { Humanoid } = {}

local function humanoid(): Humanoid
	local created = Instance.new("Humanoid")
	table.insert(humanoids, created)
	return created
end

return function()
	afterEach(function()
		for _, created in humanoids do
			created:Destroy()
		end
		table.clear(humanoids)
	end)

	describe("DomainRules.Apply", function()
		it("multiplies scale rules together", function()
			local set = DomainRules.Empty()
			DomainRules.Apply(set, "DamageTaken", 2, nil)
			DomainRules.Apply(set, "DamageTaken", 1.5, nil)
			expect(set.DamageTaken).to.be.near(3, 1e-6)
		end)

		it("pulls a contested realm's scale toward 1", function()
			local set = DomainRules.Empty()
			DomainRules.Apply(set, "DamageDealt", 2, nil, 0.5)
			expect(set.DamageDealt).to.be.near(1.5, 1e-6)
		end)

		it("ORs flags and unions sealed moves", function()
			local set = DomainRules.Empty()
			DomainRules.Apply(set, "NoBlock", 1, nil)
			DomainRules.Apply(set, "Rooted", 1, nil)
			DomainRules.Apply(set, "SealMove", 1, "move-a")
			expect(bit32.band(set.Flags, DomainRules.FlagBits.NoBlock) ~= 0).to.equal(true)
			expect(bit32.band(set.Flags, DomainRules.FlagBits.Rooted) ~= 0).to.equal(true)
			expect(set.SealedMoves["move-a"]).to.equal(true)
			expect(DomainRules.IsEmpty(set)).to.equal(false)
			expect(DomainRules.IsEmpty(DomainRules.Empty())).to.equal(true)
		end)
	end)

	describe("DomainRules.Publish / Read", function()
		it("round-trips a set through the Humanoid", function()
			local body = humanoid()
			local set = DomainRules.Empty()
			DomainRules.Apply(set, "MoveSpeed", 0.5, nil)
			DomainRules.Apply(set, "NoParry", 1, nil)
			DomainRules.Apply(set, "SealMove", 1, "move-b")
			DomainRules.Publish(body, set, 100, "D1")

			local read = DomainRules.Read(body, 50) :: DomainRules.RuleSet
			expect(read).to.be.ok()
			expect(read.MoveSpeed).to.be.near(0.5, 1e-6)
			expect(read.SealedMoves["move-b"]).to.equal(true)
			expect(DomainRules.Has(body, "NoParry", 50)).to.equal(true)
			expect(DomainRules.Has(body, "NoBlock", 50)).to.equal(false)
			expect(DomainRules.GovernorOf(body, 50)).to.equal("D1")
		end)

		it("publishes a scale of 1 as no attribute at all", function()
			local body = humanoid()
			DomainRules.Publish(body, DomainRules.Empty(), 100, "D1")
			expect(body:GetAttribute(AttributeConstants.DomainDamageTaken)).to.equal(nil)
			expect(body:GetAttribute(AttributeConstants.DomainUntil)).to.equal(100)
		end)

		it("reads as nothing once the lease has passed, whatever the attributes still say", function()
			local body = humanoid()
			local set = DomainRules.Empty()
			DomainRules.Apply(set, "DamageTaken", 3, nil)
			DomainRules.Apply(set, "NoEvade", 1, nil)
			DomainRules.Publish(body, set, 100, "D1")

			expect(DomainRules.Scale(body, "DamageTaken", 99)).to.be.near(3, 1e-6)
			expect(DomainRules.Scale(body, "DamageTaken", 101)).to.equal(1)
			expect(DomainRules.Has(body, "NoEvade", 101)).to.equal(false)
			expect(DomainRules.Read(body, 101)).to.equal(nil)
		end)

		it("clears every attribute it wrote", function()
			local body = humanoid()
			local set = DomainRules.Empty()
			DomainRules.Apply(set, "Cooldown", 2, nil)
			DomainRules.Apply(set, "SealArts", 1, nil)
			DomainRules.Publish(body, set, 100, "D1")
			DomainRules.Clear(body)
			for _, name in DomainRules.Attributes do
				expect(body:GetAttribute(name)).to.equal(nil)
			end
		end)
	end)

	describe("DomainRules.IsSealed", function()
		it("seals by id and by the three category traits", function()
			local body = humanoid()
			local set = DomainRules.Empty()
			DomainRules.Apply(set, "SealMove", 1, "move-c")
			DomainRules.Apply(set, "SealProjectiles", 1, nil)
			DomainRules.Publish(body, set, 100, "D1")

			expect(DomainRules.IsSealed(body, "move-c", {}, 10)).to.equal(true)
			-- A prefix of a sealed id is a different move.
			expect(DomainRules.IsSealed(body, "move", {}, 10)).to.equal(false)
			expect(DomainRules.IsSealed(body, "other", { IsProjectile = true }, 10)).to.equal(true)
			expect(DomainRules.IsSealed(body, "other", { IsArt = true }, 10)).to.equal(false)
		end)

		it("seals nothing on a body no realm governs", function()
			expect(DomainRules.IsSealed(humanoid(), "anything", { IsDomain = true }, 10)).to.equal(false)
		end)
	end)

	describe("DomainRules.OwnsLiveDomain", function()
		it("follows the owner lease", function()
			local owner = humanoid()
			DomainRules.SetOwned(owner, 20)
			expect(DomainRules.OwnsLiveDomain(owner, 19)).to.equal(true)
			expect(DomainRules.OwnsLiveDomain(owner, 21)).to.equal(false)
			DomainRules.SetOwned(owner, nil)
			expect(DomainRules.OwnsLiveDomain(owner, 0)).to.equal(false)
		end)
	end)
end
