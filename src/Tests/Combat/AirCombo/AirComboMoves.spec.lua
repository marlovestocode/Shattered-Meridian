--!strict
-- Covers Shared/AirCombo/AirComboMoves.lua -- the air moves' id scheme, which four modules read (the move
-- registry names them with it, the sequencer resolves to them, the animation table keys by it, and the damage
-- layer prices them flat). A typo in the scheme is a move that silently never resolves, so it is pinned here.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AirComboMoves = require(ReplicatedStorage.Shared.AirCombo.AirComboMoves)

return function()
	describe("AirComboMoves", function()
		it("builds and reads back every air move id", function()
			local launcher = AirComboMoves.RoleOf(AirComboMoves.LauncherId("Cutlass"))
			expect((launcher :: any).Role).to.equal("Launcher")
			local beat = AirComboMoves.RoleOf(AirComboMoves.AirId("Cutlass", 2))
			expect((beat :: any).Role).to.equal("Air")
			expect((beat :: any).Beat).to.equal(2)
			for _, kind in AirComboMoves.FinisherKinds do
				local finisher = AirComboMoves.RoleOf(AirComboMoves.FinisherId("Cutlass", kind))
				expect((finisher :: any).Role).to.equal("Finisher")
				expect((finisher :: any).Finisher).to.equal(kind)
			end
		end)

		it("gives ground and custom moves no air role", function()
			expect(AirComboMoves.RoleOf("default:Cutlass:Basic:1")).to.equal(nil)
			expect(AirComboMoves.RoleOf("default:Cutlass:Finisher")).to.equal(nil)
			expect(AirComboMoves.RoleOf("my-custom-slug")).to.equal(nil)
			expect(AirComboMoves.RoleOf("default:Cutlass:AirFinisher:Nope")).to.equal(nil)
		end)

		it("launches off a Default launcher, or any move authored StartsAirCombo", function()
			expect(AirComboMoves.IsLauncher("default:Cutlass:Launcher")).to.equal(true)
			expect(AirComboMoves.IsLauncher("my-custom-slug", true)).to.equal(true)
			expect(AirComboMoves.IsLauncher("default:Cutlass:Basic:2")).to.equal(false)
		end)

		it("prices air hits and finishers flat, but lets the launcher escalate like a heavy", function()
			expect(AirComboMoves.IsFlatPriced(AirComboMoves.AirId("Cutlass", 1))).to.equal(true)
			expect(AirComboMoves.IsFlatPriced(AirComboMoves.FinisherId("Cutlass", "Spike"))).to.equal(true)
			expect(AirComboMoves.IsFlatPriced(AirComboMoves.LauncherId("Cutlass"))).to.equal(false)
			expect(AirComboMoves.IsFlatPriced("default:Cutlass:Heavy:1")).to.equal(false)
		end)
	end)
end
