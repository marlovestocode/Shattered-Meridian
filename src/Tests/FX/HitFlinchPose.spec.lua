--!strict
-- HitFlinchPose's pure pieces: the flinch's envelope and where a second hit picks it up. The pose writes
-- themselves need a rig and a render step, which a playtest covers.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local FXConstants = require(ReplicatedStorage.Shared.FXConstants)
local HitFlinchPose = require(StarterPlayer.StarterPlayerScripts.Client.FX.HitFlinchPose)

local CONFIG = FXConstants.HitFlinch

return function()
	describe("HitFlinchPose.Envelope", function()
		it("rises to full strength on the hit and settles back to nothing", function()
			expect(HitFlinchPose.Envelope(0)).to.equal(0)
			expect(HitFlinchPose.Envelope(CONFIG.RiseSeconds)).to.be.near(1, 1e-6)
			expect(HitFlinchPose.Envelope(CONFIG.RiseSeconds + CONFIG.SettleSeconds)).to.equal(0)
		end)

		it("only ever eases down once it has peaked", function()
			local previous = 1
			local steps = 20
			for index = 1, steps do
				local elapsed = CONFIG.RiseSeconds + CONFIG.SettleSeconds * index / steps
				local weight = HitFlinchPose.Envelope(elapsed)
				expect(weight <= previous + 1e-9).to.equal(true)
				previous = weight
			end
		end)

		it("is over well inside the shortest stun, so the body is upright when it can act", function()
			expect(CONFIG.RiseSeconds + CONFIG.SettleSeconds < 0.4).to.equal(true)
		end)
	end)

	describe("HitFlinchPose.RetriggerElapsed", function()
		it("picks a second hit up at the strength the body is already at, not from upright", function()
			local midSettle = CONFIG.RiseSeconds + CONFIG.SettleSeconds / 2
			local current = HitFlinchPose.Envelope(midSettle)
			local resumed = HitFlinchPose.RetriggerElapsed(midSettle)
			expect(HitFlinchPose.Envelope(resumed)).to.be.near(current, 1e-6)
			expect(resumed <= CONFIG.RiseSeconds).to.equal(true)
		end)
	end)

	describe("HitFlinchPose.JointOffset", function()
		it("does nothing at zero strength", function()
			expect(HitFlinchPose.JointOffset("RootJoint", 0, 1)).to.equal(CFrame.identity)
		end)

		it("rocks the torso back, not forward", function()
			local x = HitFlinchPose.JointOffset("RootJoint", 1, 1):ToEulerAnglesXYZ()
			expect(x < 0).to.equal(true)
		end)
	end)
end
