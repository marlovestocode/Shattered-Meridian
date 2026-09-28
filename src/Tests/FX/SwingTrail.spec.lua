--!strict
-- Builds a real Trail from AttackConstants.Presentation.SwingTrail, property by property, exactly as
-- Client/FX/AttackTrail.lua does. Roblox property names are unchecked until the engine touches them:
-- the tuning table once carried `Width`, which Trail does not have, and every swing in play threw
-- "Width is not a valid member of Trail" -- no lint or type pass could see it. This spec is the engine
-- touching it.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local AttackConstants = require(ReplicatedStorage.Shared.Attack.AttackConstants)
local AttackTrail = require(StarterPlayer.StarterPlayerScripts.Client.FX.AttackTrail)

local TUNING = AttackConstants.Presentation.SwingTrail

return function()
	it("sets only properties a Trail actually has", function()
		local part = Instance.new("Part")
		local a0 = Instance.new("Attachment")
		a0.Parent = part
		local a1 = Instance.new("Attachment")
		a1.Parent = part

		local trail = Instance.new("Trail")
		trail.Attachment0 = a0
		trail.Attachment1 = a1
		trail.Color = TUNING.Color
		trail.Transparency = TUNING.Transparency
		trail.WidthScale = TUNING.WidthScale
		trail.Lifetime = TUNING.LifetimeSeconds
		trail.Parent = part

		expect(trail.Lifetime).to.be.near(TUNING.LifetimeSeconds, 1e-4)
		part:Destroy()
	end)

	it("has no Width field for anything to try to set", function()
		expect((TUNING :: any).Width).to.equal(nil)
	end)

	it("strikes left hand, right hand, left foot through the bare-hands string", function()
		expect(AttackTrail.FistLimbFor("Basic", 1)).to.equal("Left Arm")
		expect(AttackTrail.FistLimbFor("Basic", 2)).to.equal("Right Arm")
		expect(AttackTrail.FistLimbFor("Basic", 3)).to.equal("Left Leg")
	end)

	it("falls back to the default limb off the end of the string, for the Finisher and for a Heavy", function()
		local default = TUNING.FistDefaultLimb
		expect(AttackTrail.FistLimbFor("Basic", 4)).to.equal(default)
		expect(AttackTrail.FistLimbFor("Basic", 0)).to.equal(default)
		expect(AttackTrail.FistLimbFor("Heavy", 1)).to.equal(default)
	end)

	it("names limbs a real R6 rig has", function()
		local r6 = { ["Left Arm"] = true, ["Right Arm"] = true, ["Left Leg"] = true, ["Right Leg"] = true }
		for _, limb in TUNING.FistLimbByStage do
			expect(r6[limb]).to.equal(true)
		end
		expect(r6[TUNING.FistDefaultLimb]).to.equal(true)
	end)

	it("draws the fist trail as a thin line, and a blade's as a real edge", function()
		-- A trail's thickness IS its Attachment pair's separation.
		local fist = math.abs(TUNING.FistOffsetStuds.Near - TUNING.FistOffsetStuds.Far)
		local blade = math.abs(TUNING.WeaponOffsetStuds.Near - TUNING.WeaponOffsetStuds.Far)
		expect(fist > 0 and fist <= 0.5).to.equal(true)
		expect(blade > fist).to.equal(true)
	end)
end
