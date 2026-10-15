--!strict
-- Covers Client/Combat/OwnRealm.lua -- the local player's own-realm mirror the cancel timer reads: held while the
-- realm can still be cancelled, dropped when it folds or finishes, never held for a realm no press can end.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local DomainTypes = require(ReplicatedStorage.Shared.Domain.DomainTypes)
local OwnRealm = require(StarterPlayer.StarterPlayerScripts.Client.Combat.OwnRealm)

local function view(overrides: { [string]: any }?): DomainTypes.DomainView
	local result = {
		Id = "D1",
		Owner = nil,
		MoveId = "spec-move",
		Shape = "Sphere",
		Radius = 10,
		Height = 20,
		Center = Vector3.zero,
		Offset = Vector3.zero,
		Yaw = 0,
		Anchor = "Fixed",
		EntryRule = "Free",
		ExitRule = "Free",
		Phase = "Activating",
		PhaseStartedAt = 100,
		PhaseEndsAt = 101,
		ActivationSeconds = 1,
		EndSeconds = 1,
		ClashState = "None",
		CancelableAt = 110,
	} :: any
	for key, value in overrides or {} do
		result[key] = value
	end
	return result
end

return function()
	afterEach(function()
		OwnRealm.Reset()
	end)

	describe("OwnRealm", function()
		it("holds a cancellable realm and says when cancelling opens", function()
			OwnRealm.Open(view())
			local state = OwnRealm.Get()
			expect(state).to.be.ok()
			expect((state :: any).MoveId).to.equal("spec-move")
			expect((state :: any).OpenedAt).to.equal(100)
			expect((state :: any).CancelableAt).to.equal(110)
		end)

		it("never holds a realm no press can end", function()
			OwnRealm.Open(view({ CancelableAt = 0 }))
			expect(OwnRealm.Get()).to.equal(nil)
		end)

		it("never holds a realm already folding when it was first seen", function()
			OwnRealm.Open(view({ Phase = "Ending" }))
			expect(OwnRealm.Get()).to.equal(nil)
		end)

		it("records when the law ends once the realm is Active, and lets go when it folds", function()
			OwnRealm.Open(view())
			OwnRealm.Phase("D1", "Active", 120)
			expect((OwnRealm.Get() :: any).LawEndsAt).to.equal(120)
			OwnRealm.Phase("D1", "Ending", 121)
			expect(OwnRealm.Get()).to.equal(nil)
		end)

		it("ignores a phase for a realm it is not holding", function()
			OwnRealm.Open(view())
			OwnRealm.Phase("D2", "Ending", 121)
			expect(OwnRealm.Get()).to.be.ok()
		end)

		it("tells subscribers about each change, and stops after a disconnect", function()
			local seen: { string } = {}
			local disconnect = OwnRealm.OnChanged(function(state)
				table.insert(seen, if state then "held" else "gone")
			end)
			OwnRealm.Open(view())
			OwnRealm.Close("D1")
			disconnect()
			OwnRealm.Open(view())
			expect(table.concat(seen, ",")).to.equal("held,gone")
		end)
	end)
end
