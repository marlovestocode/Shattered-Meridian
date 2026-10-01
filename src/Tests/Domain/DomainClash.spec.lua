--!strict
-- Covers Shared/Domain/DomainClash.lua -- who wins when two realms meet, and what the winner does.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DomainClash = require(ReplicatedStorage.Shared.Domain.DomainClash)

type Participant = DomainClash.Participant

local function realm(id: string, overrides: { [string]: any }?): Participant
	local result: any = {
		Id = id,
		MoveId = `move-{id}`,
		Priority = 10,
		Behavior = "Suppress",
		Overrides = {},
		TieBreak = "Contest",
		Interacts = true,
		OpenedAt = 0,
	}
	for key, value in overrides or {} do
		result[key] = value
	end
	return result
end

return function()
	describe("DomainClash.Resolve", function()
		it("lets the higher priority win, with its own behaviour", function()
			local outcome = DomainClash.Resolve(realm("A", { Priority = 20, Behavior = "Erode" }), realm("B"))
			expect(outcome.Behavior).to.equal("Erode")
			expect(outcome.Winner).to.equal("A")
			expect(outcome.Loser).to.equal("B")
		end)

		it("answers in the same way whichever order the realms are handed in", function()
			local a = realm("A", { Priority = 5 })
			local b = realm("B", { Priority = 30, Behavior = "Dominate" })
			local forward = DomainClash.Resolve(a, b)
			local backward = DomainClash.Resolve(b, a)
			expect(forward.Winner).to.equal("B")
			expect(backward.Winner).to.equal("B")
			expect(forward.Behavior).to.equal(backward.Behavior)
		end)

		it("uses the winner's per-opponent override for that opponent", function()
			local a = realm("A", { Priority = 20, Behavior = "Suppress", Overrides = { ["move-B"] = "Dominate" } })
			expect(DomainClash.Resolve(a, realm("B")).Behavior).to.equal("Dominate")
			expect(DomainClash.Resolve(a, realm("C")).Behavior).to.equal("Suppress")
		end)

		it("contests a tie when the challenger's tie-break says so", function()
			local outcome = DomainClash.Resolve(realm("A", { OpenedAt = 1 }), realm("B", { OpenedAt = 2 }))
			expect(outcome.Behavior).to.equal("Contest")
			expect(outcome.Winner).to.equal(nil)
		end)

		it("lets the incumbent hold a tie against an Older challenger, and a Newer one claim it", function()
			local incumbent = realm("A", { OpenedAt = 1 })
			local yielding = DomainClash.Resolve(incumbent, realm("B", { OpenedAt = 2, TieBreak = "Older" }))
			expect(yielding.Winner).to.equal("A")
			local claiming = DomainClash.Resolve(incumbent, realm("B", { OpenedAt = 2, TieBreak = "Newer" }))
			expect(claiming.Winner).to.equal("B")
		end)

		it("coexists when either realm does not interact", function()
			local outcome = DomainClash.Resolve(
				realm("A", { Priority = 99, Behavior = "Shatter" }),
				realm("B", { Interacts = false })
			)
			expect(outcome.Behavior).to.equal("Coexist")
			expect(outcome.Winner).to.equal(nil)
		end)

		it("classifies what each outcome does", function()
			expect(DomainClash.SuppressesLoser("Suppress")).to.equal(true)
			expect(DomainClash.SuppressesLoser("Erode")).to.equal(true)
			expect(DomainClash.SuppressesLoser("Contest")).to.equal(false)
			expect(DomainClash.Collapses("Dominate")).to.equal(true)
			expect(DomainClash.Collapses("Shatter")).to.equal(true)
			expect(DomainClash.Collapses("Coexist")).to.equal(false)
		end)
	end)
end
