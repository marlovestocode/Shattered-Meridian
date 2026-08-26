--!strict
local ServerScriptService = game:GetService("ServerScriptService")

local KitAbilitySystem = require(ServerScriptService.Server.Systems.KitAbilitySystem)
local RaceManager = require(ServerScriptService.Server.Managers.RaceManager)
local BloodlineManager = require(ServerScriptService.Server.Managers.BloodlineManager)

-- KitAbilitySystem.Init() is never called here -- it creates live remotes, neither of which this
-- file needs. SanitizeRequest is fully pure. Dispatch is exercised against RaceManager/
-- BloodlineManager's own real registries (no mocking) but only on the no-profile path its two
-- dependents (RaceSystem, BloodlineSystem) already document as Studio/live-server-only beyond that --
-- same gap RaceSystem.spec.lua/BloodlineSystem.spec.lua's own headers describe.

return function()
	describe("KitAbilitySystem.SanitizeRequest", function()
		it("rejects a non-table candidate", function()
			expect(KitAbilitySystem.SanitizeRequest("not-a-table")).to.equal(nil)
		end)

		it("rejects a SourceKind outside RaceTrait/BloodlineStage", function()
			expect(KitAbilitySystem.SanitizeRequest({
				SourceKind = "SomethingElse",
				SourceId = "x",
				AbilityId = "y",
			})).to.equal(nil)
		end)

		it("rejects a missing or empty SourceId", function()
			expect(KitAbilitySystem.SanitizeRequest({ SourceKind = "RaceTrait", AbilityId = "y" })).to.equal(nil)
			expect(KitAbilitySystem.SanitizeRequest({ SourceKind = "RaceTrait", SourceId = "", AbilityId = "y" })).to.equal(
				nil
			)
		end)

		it("rejects a missing or empty AbilityId", function()
			expect(KitAbilitySystem.SanitizeRequest({ SourceKind = "RaceTrait", SourceId = "x" })).to.equal(nil)
			expect(KitAbilitySystem.SanitizeRequest({ SourceKind = "RaceTrait", SourceId = "x", AbilityId = "" })).to.equal(
				nil
			)
		end)

		it("accepts a well-formed RaceTrait request", function()
			local request = KitAbilitySystem.SanitizeRequest({
				SourceKind = "RaceTrait",
				SourceId = "human-resolve",
				AbilityId = "human-resolve-ability",
			})
			expect(request).to.be.ok()
			expect((request :: any).SourceKind).to.equal("RaceTrait")
			expect((request :: any).SourceId).to.equal("human-resolve")
			expect((request :: any).AbilityId).to.equal("human-resolve-ability")
		end)

		it("accepts a well-formed BloodlineStage request", function()
			local request = KitAbilitySystem.SanitizeRequest({
				SourceKind = "BloodlineStage",
				SourceId = "ashen-current",
				AbilityId = "ashen-current-strike",
			})
			expect(request).to.be.ok()
			expect((request :: any).SourceKind).to.equal("BloodlineStage")
		end)
	end)

	describe("KitAbilitySystem.Dispatch", function()
		it("routes a RaceTrait request to RaceSystem, surfacing its own refusal reason", function()
			RaceManager.Init()
			local refusal = KitAbilitySystem.Dispatch({} :: any, {
				SourceKind = "RaceTrait",
				SourceId = "nothing-here",
				AbilityId = "any-ability",
			})
			expect(refusal).to.equal("UnknownTrait")
		end)

		it("routes a BloodlineStage request to BloodlineSystem, surfacing its own refusal reason", function()
			BloodlineManager.Init()
			local refusal = KitAbilitySystem.Dispatch({} :: any, {
				SourceKind = "BloodlineStage",
				SourceId = "nothing-here",
				AbilityId = "any-ability",
			})
			expect(refusal).to.equal("UnknownBloodline")
		end)
	end)
end
