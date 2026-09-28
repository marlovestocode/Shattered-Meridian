--!strict
-- Covers the roll's presentation and the contact sparks: Client/FX/RollAfterimage.lua,
-- Client/FX/RemoteMovementFX.lua and Client/FX/ImpactSparks.lua.
--
-- Engine-touching on purpose, for the same reason Tests/FX/SwingTrail.spec.lua is: a ParticleEmitter
-- or Part property name that does not exist fails only when the engine is asked to set it, and no lint
-- or type pass catches it. The spark presets are applied to a real emitter here, field by field.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")
local Workspace = game:GetService("Workspace")

local DefenseConstants = require(ReplicatedStorage.Shared.Defense.DefenseConstants)
local FXConstants = require(ReplicatedStorage.Shared.FXConstants)
local ImpactSparks = require(StarterPlayer.StarterPlayerScripts.Client.FX.ImpactSparks)
local RemoteMovementFX = require(StarterPlayer.StarterPlayerScripts.Client.FX.RemoteMovementFX)
local RollAfterimage = require(StarterPlayer.StarterPlayerScripts.Client.FX.RollAfterimage)

local R6_LIMBS = { "Head", "Torso", "Left Arm", "Right Arm", "Left Leg", "Right Leg" }

local function makeRig(): Model
	local model = Instance.new("Model")
	model.Name = "RollRig"
	for index, name in R6_LIMBS do
		local part = Instance.new("Part")
		part.Name = name
		part.Anchored = true
		part.Size = Vector3.new(1, 2, 1)
		part.CFrame = CFrame.new(index * 2, 50, 0)
		part.Parent = model
	end
	model.Parent = Workspace
	return model
end

return function()
	describe("RollAfterimage", function()
		afterEach(function()
			RollAfterimage.Stop()
		end)

		it("stamps an inert, limb-for-limb ghost and releases it on Stop", function()
			RollAfterimage.Start()
			local rig = makeRig()
			RollAfterimage.FlashEvade(rig)
			expect(RollAfterimage.CountLive()).to.equal(1)

			local holder = Workspace:FindFirstChild("RollAfterimageHolder")
			expect(holder).never.to.equal(nil)
			local ghost = (holder :: Instance):FindFirstChildOfClass("Model")
			expect(ghost).never.to.equal(nil)
			for _, name in R6_LIMBS do
				local part = (ghost :: Model):FindFirstChild(name) :: Part
				expect(part).never.to.equal(nil)
				expect(part.Anchored).to.equal(true)
				expect(part.CanCollide).to.equal(false)
				expect(part.CanQuery).to.equal(false)
				expect(part.CanTouch).to.equal(false)
				expect(part.Transparency < 1).to.equal(true)
			end

			RollAfterimage.Stop()
			expect(RollAfterimage.CountLive()).to.equal(0)
			rig:Destroy()
		end)

		it("does nothing before Start", function()
			local rig = makeRig()
			RollAfterimage.FlashEvade(rig)
			RollAfterimage.PlayRoll(rig)
			expect(RollAfterimage.CountLive()).to.equal(0)
			expect(RollAfterimage.IsPending(rig)).to.equal(false)
			rig:Destroy()
		end)

		it("schedules a roll's stamps rather than drawing them all at once", function()
			RollAfterimage.Start()
			local rig = makeRig()
			RollAfterimage.PlayRoll(rig)
			expect(RollAfterimage.IsPending(rig)).to.equal(true)
			expect(RollAfterimage.CountLive()).to.equal(0)
			rig:Destroy()
		end)

		it("never draws more ghosts than its pool", function()
			RollAfterimage.Start()
			local rig = makeRig()
			for _ = 1, FXConstants.RollAfterimage.PoolMaxSize + 5 do
				RollAfterimage.FlashEvade(rig)
			end
			expect(RollAfterimage.CountLive()).to.equal(FXConstants.RollAfterimage.PoolMaxSize)
			rig:Destroy()
		end)

		it("draws its stamps inside the server's evade window, not before or after it", function()
			local config = FXConstants.RollAfterimage
			local evade = DefenseConstants.Evade
			local lastStamp = config.StartDelaySeconds + (config.StampCount - 1) * config.IntervalSeconds
			expect(config.StartDelaySeconds).to.be.near(evade.StartupSeconds, 1e-6)
			expect(lastStamp <= evade.StartupSeconds + evade.ActiveSeconds).to.equal(true)
		end)
	end)

	describe("RemoteMovementFX.Classify", function()
		it("reads an accepted roll's start and end off the ParkourState Attribute", function()
			expect(RemoteMovementFX.Classify("", "Roll")).to.equal("Start")
			expect(RemoteMovementFX.Classify(nil, "Roll")).to.equal("Start")
			expect(RemoteMovementFX.Classify("Roll", "")).to.equal("End")
			expect(RemoteMovementFX.Classify("Roll", "Slide")).to.equal("End")
		end)

		it("ignores every other movement action", function()
			expect(RemoteMovementFX.Classify("", "Slide")).to.equal(nil)
			expect(RemoteMovementFX.Classify("Roll", "Roll")).to.equal(nil)
			expect(RemoteMovementFX.Classify("Vault", "")).to.equal(nil)
		end)
	end)

	describe("ImpactSparks", function()
		it("has a preset for every steel-on-steel outcome and none for a body hit", function()
			for _, kind in { "Parried", "Blocked", "Trade", "GuardBroken" } do
				expect(ImpactSparks.HasPreset(kind)).to.equal(true)
			end
			for _, kind in { "Clean", "Backstab", "Evaded" } do
				expect(ImpactSparks.HasPreset(kind)).to.equal(false)
			end
		end)

		it("sets only properties a ParticleEmitter actually has, for every preset", function()
			for _, preset in FXConstants.ImpactSparks.Presets :: { [string]: any } do
				local emitter = Instance.new("ParticleEmitter")
				emitter.Color = preset.Color
				emitter.Speed = preset.Speed
				emitter.Lifetime = preset.LifetimeSeconds
				emitter.Size = preset.Size
				emitter.Drag = preset.Drag
				emitter.Acceleration = preset.Acceleration
				emitter.LightEmission = preset.LightEmission
				expect(emitter.Drag).to.be.near(preset.Drag, 1e-4)
				emitter:Destroy()
			end
		end)

		it("plays a burst through the real pool without erroring", function()
			ImpactSparks.Play("Parried", Vector3.new(0, 60, 0))
			ImpactSparks.Play("Clean", Vector3.new(0, 60, 0))
			local holder = Workspace:FindFirstChild("ImpactSparksHolder")
			expect(holder).never.to.equal(nil)
		end)
	end)
end
