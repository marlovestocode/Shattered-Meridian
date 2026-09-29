--!strict
-- Covers the pure halves of Client/Combat/CombatTargets.lua (the angle arithmetic lock-on and swing
-- tracking share) and Client/Combat/LocalCombatState.lua's hit-confirm cut point. No rig and no camera:
-- the per-frame drivers built on these are exercised in play.
local StarterPlayer = game:GetService("StarterPlayer")

local CombatTargets = require(StarterPlayer.StarterPlayerScripts.Client.Combat.CombatTargets)
local LocalCombatState = require(StarterPlayer.StarterPlayerScripts.Client.Combat.LocalCombatState)

return function()
	describe("CombatTargets -- yaw arithmetic", function()
		it("uses Roblox's facing convention: CFrame.Angles(0, yaw, 0) looks along the direction", function()
			for _, direction in { Vector3.new(0, 0, -1), Vector3.new(1, 0, 0), Vector3.new(-3, 2, 4) } do
				local yaw = CombatTargets.YawOf(direction) :: number
				local look = CFrame.Angles(0, yaw, 0).LookVector
				local flat = Vector3.new(direction.X, 0, direction.Z).Unit
				expect((look - flat).Magnitude).to.be.near(0, 1e-6)
			end
		end)

		it("has no yaw for a straight-up direction", function()
			expect(CombatTargets.YawOf(Vector3.new(0, 1, 0))).to.equal(nil)
		end)

		it("takes the short way round", function()
			expect(CombatTargets.AngleDelta(math.rad(170), math.rad(-170))).to.be.near(math.rad(20), 1e-6)
			expect(CombatTargets.AngleDelta(math.rad(-170), math.rad(170))).to.be.near(math.rad(-20), 1e-6)
			expect(CombatTargets.AngleDelta(0, math.rad(90))).to.be.near(math.rad(90), 1e-6)
		end)

		it("measures a flat bearing and distance, ignoring height", function()
			local angle, distance =
				CombatTargets.FlatBearing(Vector3.zero, Vector3.new(0, 0, -1), Vector3.new(5, 9, -5))
			expect(angle).to.be.near(45, 1e-4)
			expect(distance).to.be.near(math.sqrt(50), 1e-6)
		end)
	end)

	describe("LocalCombatState -- the hit-confirm cut point", function()
		afterEach(function()
			LocalCombatState.ResetForNewLife()
		end)

		it("frees a cancelable action at the cut point and everything else at the swing's end", function()
			LocalCombatState.SetSwing(10)
			LocalCombatState.SetCancelAt(9)
			expect(LocalCombatState.FreeAt(5)).to.equal(10)
			expect(LocalCombatState.FreeAt(5, true)).to.equal(9)
		end)

		it("forgets the cut point when the next swing starts", function()
			LocalCombatState.SetSwing(10)
			LocalCombatState.SetCancelAt(9)
			LocalCombatState.SetSwing(20)
			expect(LocalCombatState.CancelAt()).to.equal(0)
			expect(LocalCombatState.FreeAt(5, true)).to.equal(20)
		end)
	end)
end
