--!strict
-- Covers Server/Combat/Domain/DomainInstance.lua -- a realm's lifecycle on a synthetic clock.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local DomainInstance = require(ServerScriptService.Server.Combat.Domain.DomainInstance)
local DomainTypes = require(ReplicatedStorage.Shared.Domain.DomainTypes)

local function newRealm(overrides: { [string]: any }?): DomainInstance.DomainInstance
	local spec = DomainTypes.Defaults() :: any
	spec.ActivationSeconds = 1
	spec.ActiveSeconds = 5
	spec.EndSeconds = 1
	for key, value in overrides or {} do
		spec[key] = value
	end
	return DomainInstance.new({
		Id = "D1",
		Owner = Instance.new("Model"),
		MoveId = "spec-realm",
		Spec = spec,
		OwnerPose = CFrame.new(0, 5, 0),
	})
end

local function phases(transitions: { DomainInstance.Transition }): string
	local names = {}
	for _, transition in transitions do
		table.insert(names, transition.To)
	end
	return table.concat(names, ",")
end

return function()
	describe("DomainInstance lifecycle", function()
		it("starts Idle and begins Activating", function()
			local realm = newRealm()
			expect(realm.Phase).to.equal("Idle")
			local transition = DomainInstance.Begin(realm, 10) :: DomainInstance.Transition
			expect(transition.To).to.equal("Activating")
			expect(realm.PhaseEndsAt).to.equal(11)
			expect(DomainInstance.Begin(realm, 10)).to.equal(nil)
		end)

		it("walks Activating -> Active -> Ending -> Finished on its scheduled boundaries", function()
			local realm = newRealm()
			DomainInstance.Begin(realm, 0)
			expect(phases(DomainInstance.Advance(realm, 0.5))).to.equal("")
			expect(phases(DomainInstance.Advance(realm, 1))).to.equal("Active")
			expect(realm.PhaseStartedAt).to.equal(1)
			expect(phases(DomainInstance.Advance(realm, 6))).to.equal("Ending")
			expect(phases(DomainInstance.Advance(realm, 7))).to.equal("Finished")
		end)

		it("does not stretch across a hitch: every phase starts at the previous one's scheduled end", function()
			local realm = newRealm()
			DomainInstance.Begin(realm, 0)
			local transitions = DomainInstance.Advance(realm, 6.5)
			expect(phases(transitions)).to.equal("Active,Ending")
			expect(transitions[2].At).to.equal(6)
			expect(realm.PhaseEndsAt).to.equal(7)
		end)

		it("collapses an unfurling realm into its fold, never straight out", function()
			local realm = newRealm()
			DomainInstance.Begin(realm, 0)
			local transition = DomainInstance.Collapse(realm, 0.4, "Interrupted") :: DomainInstance.Transition
			expect(transition.To).to.equal("Ending")
			expect(realm.CollapseReason).to.equal("Interrupted")
			expect(DomainInstance.Collapse(realm, 0.5, "Again")).to.equal(nil)
		end)

		it("erodes only the active time, and never past now", function()
			local realm = newRealm()
			DomainInstance.Begin(realm, 0)
			DomainInstance.Advance(realm, 1)
			DomainInstance.Erode(realm, 2, 1.5)
			expect(realm.PhaseEndsAt).to.equal(4)
			DomainInstance.Erode(realm, 100, 2)
			expect(realm.PhaseEndsAt).to.equal(2)
			expect(realm.Eroded).to.be.near(4, 1e-6)
		end)

		it("answers when its law lifts and when it is gone", function()
			local realm = newRealm()
			DomainInstance.Begin(realm, 0)
			expect(DomainInstance.LawEndsAt(realm, 0)).to.equal(6)
			expect(DomainInstance.GoneAt(realm, 0)).to.equal(7)
		end)

		it("centres the realm CenterForward along the owner's facing", function()
			local spec = DomainTypes.Defaults()
			spec.CenterForward = 10
			local realm = DomainInstance.new({
				Id = "D2",
				Owner = Instance.new("Model"),
				MoveId = "spec-realm",
				Spec = spec,
				OwnerPose = CFrame.lookAt(Vector3.zero, Vector3.new(1, 0, 0)),
			})
			expect((realm.Center - Vector3.new(10, 0, 0)).Magnitude < 1e-4).to.equal(true)
		end)
	end)

	describe("DomainInstance membership", function()
		it("gives a newcomer its entry grace and a founding member none", function()
			local realm = newRealm({ EntryGraceSeconds = 1 })
			local founder = Instance.new("Model")
			local newcomer = Instance.new("Model")
			DomainInstance.Admit(realm, founder, 0, true)
			DomainInstance.Admit(realm, newcomer, 0, false)
			expect(realm.MemberCount).to.equal(2)
			expect(DomainInstance.IsTargetable(realm, realm.Members[founder], 0)).to.equal(true)
			expect(DomainInstance.IsTargetable(realm, realm.Members[newcomer], 0.5)).to.equal(false)
			expect(DomainInstance.IsTargetable(realm, realm.Members[newcomer], 1)).to.equal(true)
			DomainInstance.Release(realm, newcomer)
			expect(realm.MemberCount).to.equal(1)
		end)
	end)
end
