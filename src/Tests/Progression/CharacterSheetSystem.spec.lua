--!strict
-- Covers Server/Systems/CharacterSheetSystem.lua's pure comparison -- what decides whether a Refresh has
-- anything new to push. The push itself is Player-keyed (Studio verification only, like the rest of the
-- Player-keyed Systems); the comparison is the part that has to be right.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local CharacterSheetSystem = require(ServerScriptService.Server.Systems.CharacterSheetSystem)
local Types = require(ReplicatedStorage.Shared.Types)

local function sheet(overrides: { [string]: any }?): Types.CharacterSheetPayload
	local result: any = {
		DisplayName = "Spec",
		RaceId = "Human",
		Faction = nil,
		Attributes = { Vitality = 5, MeridianFlow = 7 },
		BloodlineIds = { "amberlane" },
		BloodlineStageProgress = { amberlane = 2 },
		BloodlineRerolls = 1,
		Corruption = 0,
		QiDeviationRisk = 0.25,
		FactionStanding = 0,
		HasAscended = false,
	}
	for key, value in overrides or {} do
		result[key] = value
	end
	return result
end

return function()
	describe("CharacterSheetSystem.SheetsEqual", function()
		it("treats two separately built but identical sheets as equal", function()
			expect(CharacterSheetSystem.SheetsEqual(sheet(), sheet())).to.equal(true)
		end)

		it("sees a changed scalar", function()
			expect(CharacterSheetSystem.SheetsEqual(sheet(), sheet({ QiDeviationRisk = 0.5 }))).to.equal(false)
			expect(CharacterSheetSystem.SheetsEqual(sheet(), sheet({ HasAscended = true }))).to.equal(false)
		end)

		it("sees a change inside a nested table", function()
			expect(CharacterSheetSystem.SheetsEqual(sheet(), sheet({ BloodlineIds = { "amberlane", "stillwater" } }))).to.equal(
				false
			)
			expect(
				CharacterSheetSystem.SheetsEqual(sheet(), sheet({ Attributes = { Vitality = 6, MeridianFlow = 7 } }))
			).to.equal(false)
		end)

		it("sees a key present on one side only, in either direction", function()
			expect(CharacterSheetSystem.SheetsEqual(sheet(), sheet({ Faction = "Verdant" }))).to.equal(false)
			expect(CharacterSheetSystem.SheetsEqual(sheet({ Faction = "Verdant" }), sheet())).to.equal(false)
		end)
	end)
end
