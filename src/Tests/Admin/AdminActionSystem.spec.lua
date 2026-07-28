--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Constants = require(ReplicatedStorage.Shared.Constants)
local AdminActionSystem = require(ServerScriptService.Server.Systems.AdminActionSystem)

type AdminOverrideState = AdminActionSystem.AdminOverrideState

return function()
	describe("AdminActionSystem.CreateOverrideState", function()
		it("returns every field at its inert default", function()
			local state = AdminActionSystem.CreateOverrideState()
			expect(state.Godmode).to.equal(false)
			expect(state.Frozen).to.equal(false)
			expect(state.SavedJumpPower).to.equal(nil)
			expect(state.SpeedMultiplier).to.equal(1)
			expect(state.Invisible).to.equal(false)
			expect(state.SavedFlightAutoRotate).to.equal(nil)
		end)
	end)

	describe("AdminActionSystem.ApplyGodmode", function()
		it("sets the override flag and mirrors the Godmode Attribute true", function()
			local state = AdminActionSystem.CreateOverrideState()
			local humanoid = Instance.new("Humanoid")

			AdminActionSystem.ApplyGodmode(state, humanoid, true)

			expect(state.Godmode).to.equal(true)
			expect(humanoid:GetAttribute(Constants.Attributes.Godmode)).to.equal(true)
		end)

		it("clears the override flag and mirrors the Godmode Attribute false", function()
			local state = AdminActionSystem.CreateOverrideState()
			state.Godmode = true
			local humanoid = Instance.new("Humanoid")
			humanoid:SetAttribute(Constants.Attributes.Godmode, true)

			AdminActionSystem.ApplyGodmode(state, humanoid, false)

			expect(state.Godmode).to.equal(false)
			expect(humanoid:GetAttribute(Constants.Attributes.Godmode)).to.equal(false)
		end)
	end)

	describe("AdminActionSystem.ApplyFlying", function()
		it("enabling sets PlatformStand, mirrors the Flying Attribute, and saves AutoRotate", function()
			local state = AdminActionSystem.CreateOverrideState()
			local humanoid = Instance.new("Humanoid")
			humanoid.AutoRotate = true

			AdminActionSystem.ApplyFlying(state, humanoid, true)

			expect(humanoid.PlatformStand).to.equal(true)
			expect(humanoid:GetAttribute(Constants.Attributes.Flying)).to.equal(true)
			expect(state.SavedFlightAutoRotate).to.equal(true)
			expect(humanoid.AutoRotate).to.equal(false)
		end)

		it("disabling restores the AutoRotate value captured when flight was enabled", function()
			local state = AdminActionSystem.CreateOverrideState()
			local humanoid = Instance.new("Humanoid")
			humanoid.AutoRotate = false

			AdminActionSystem.ApplyFlying(state, humanoid, true)
			expect(state.SavedFlightAutoRotate).to.equal(false)

			AdminActionSystem.ApplyFlying(state, humanoid, false)

			expect(humanoid.PlatformStand).to.equal(false)
			expect(humanoid:GetAttribute(Constants.Attributes.Flying)).to.equal(false)
			expect(humanoid.AutoRotate).to.equal(false)
		end)

		it("disabling falls back to AutoRotate = true when flight was never actually enabled this session", function()
			local state = AdminActionSystem.CreateOverrideState()
			local humanoid = Instance.new("Humanoid")
			humanoid.AutoRotate = false

			AdminActionSystem.ApplyFlying(state, humanoid, false)

			expect(humanoid.AutoRotate).to.equal(true)
		end)
	end)

	describe("AdminActionSystem.ApplyFlightCollide", function()
		it("mirrors the FlyCollide Attribute", function()
			local humanoid = Instance.new("Humanoid")
			AdminActionSystem.ApplyFlightCollide(humanoid, true)
			expect(humanoid:GetAttribute(Constants.Attributes.FlyCollide)).to.equal(true)

			AdminActionSystem.ApplyFlightCollide(humanoid, false)
			expect(humanoid:GetAttribute(Constants.Attributes.FlyCollide)).to.equal(false)
		end)
	end)

	describe("AdminActionSystem.ReapplyRespawnOverrides", function()
		local function makeCharacter(): (Model, Humanoid)
			local character = Instance.new("Model")
			local humanoid = Instance.new("Humanoid")
			humanoid.Parent = character
			return character, humanoid
		end

		it("mirrors Godmode/Frozen/SpeedMultiplier onto a fresh Humanoid's Attributes", function()
			local character, humanoid = makeCharacter()
			local state: AdminOverrideState = {
				Godmode = true,
				Frozen = false,
				SavedJumpPower = nil,
				SpeedMultiplier = 1.5,
				Invisible = false,
				SavedFlightAutoRotate = nil,
			}

			AdminActionSystem.ReapplyRespawnOverrides(state, character, humanoid)

			expect(humanoid:GetAttribute(Constants.Attributes.Godmode)).to.equal(true)
			expect(humanoid:GetAttribute(Constants.Attributes.Frozen)).to.equal(false)
			expect(humanoid:GetAttribute(Constants.Attributes.SpeedMultiplier)).to.equal(1.5)
		end)

		it("zeroes JumpPower and captures the pre-freeze value when Frozen is persisted true", function()
			local character, humanoid = makeCharacter()
			humanoid.JumpPower = 42
			local state: AdminOverrideState = {
				Godmode = false,
				Frozen = true,
				SavedJumpPower = nil,
				SpeedMultiplier = 1,
				Invisible = false,
				SavedFlightAutoRotate = nil,
			}

			AdminActionSystem.ReapplyRespawnOverrides(state, character, humanoid)

			expect(humanoid.JumpPower).to.equal(0)
			expect(state.SavedJumpPower).to.equal(42)
		end)

		it("leaves JumpPower untouched when Frozen is persisted false", function()
			local character, humanoid = makeCharacter()
			humanoid.JumpPower = 42
			local state: AdminOverrideState = {
				Godmode = false,
				Frozen = false,
				SavedJumpPower = nil,
				SpeedMultiplier = 1,
				Invisible = false,
				SavedFlightAutoRotate = nil,
			}

			AdminActionSystem.ReapplyRespawnOverrides(state, character, humanoid)

			expect(humanoid.JumpPower).to.equal(42)
			expect(state.SavedJumpPower).to.equal(nil)
		end)

		it("re-applies Transparency = 1 to every BasePart when Invisible is persisted true", function()
			local character, humanoid = makeCharacter()
			local torso = Instance.new("Part")
			torso.Transparency = 0
			torso.Parent = character
			local state: AdminOverrideState = {
				Godmode = false,
				Frozen = false,
				SavedJumpPower = nil,
				SpeedMultiplier = 1,
				Invisible = true,
				SavedFlightAutoRotate = nil,
			}

			AdminActionSystem.ReapplyRespawnOverrides(state, character, humanoid)

			expect(humanoid:GetAttribute(Constants.Attributes.Invisible)).to.equal(true)
			expect(torso.Transparency).to.equal(1)
		end)

		it("leaves part Transparency untouched when Invisible is persisted false", function()
			local character, humanoid = makeCharacter()
			local torso = Instance.new("Part")
			torso.Transparency = 0
			torso.Parent = character
			local state: AdminOverrideState = {
				Godmode = false,
				Frozen = false,
				SavedJumpPower = nil,
				SpeedMultiplier = 1,
				Invisible = false,
				SavedFlightAutoRotate = nil,
			}

			AdminActionSystem.ReapplyRespawnOverrides(state, character, humanoid)

			expect(humanoid:GetAttribute(Constants.Attributes.Invisible)).to.equal(false)
			expect(torso.Transparency).to.equal(0)
		end)
	end)

	describe("AdminActionSystem.ApplyFrozen", function()
		it("enabling sets the Frozen Attribute, zeroes JumpPower, and saves the previous value", function()
			local state = AdminActionSystem.CreateOverrideState()
			local humanoid = Instance.new("Humanoid")
			humanoid.JumpPower = 42

			AdminActionSystem.ApplyFrozen(state, humanoid, true)

			expect(state.Frozen).to.equal(true)
			expect(humanoid:GetAttribute(Constants.Attributes.Frozen)).to.equal(true)
			expect(humanoid.JumpPower).to.equal(0)
			expect(state.SavedJumpPower).to.equal(42)
		end)

		it("disabling restores the JumpPower captured when freezing was enabled", function()
			local state = AdminActionSystem.CreateOverrideState()
			local humanoid = Instance.new("Humanoid")
			humanoid.JumpPower = 42

			AdminActionSystem.ApplyFrozen(state, humanoid, true)
			AdminActionSystem.ApplyFrozen(state, humanoid, false)

			expect(state.Frozen).to.equal(false)
			expect(humanoid:GetAttribute(Constants.Attributes.Frozen)).to.equal(false)
			expect(humanoid.JumpPower).to.equal(42)
		end)

		it("disabling falls back to DefaultJumpPower when never actually frozen this life", function()
			local state = AdminActionSystem.CreateOverrideState()
			local humanoid = Instance.new("Humanoid")
			humanoid.JumpPower = 7

			AdminActionSystem.ApplyFrozen(state, humanoid, false)

			expect(humanoid.JumpPower).to.equal(Constants.Debug.DevMenu.DefaultJumpPower)
		end)
	end)

	describe("AdminActionSystem.ApplyInvisible", function()
		local function makeCharacter(): (Model, Humanoid, BasePart)
			local character = Instance.new("Model")
			local humanoid = Instance.new("Humanoid")
			humanoid.Parent = character
			local torso = Instance.new("Part")
			torso.Transparency = 0
			torso.Parent = character
			return character, humanoid, torso
		end

		it("enabling sets the Invisible Attribute and makes every part transparent", function()
			local state = AdminActionSystem.CreateOverrideState()
			local character, humanoid, torso = makeCharacter()

			AdminActionSystem.ApplyInvisible(state, character, humanoid, true)

			expect(state.Invisible).to.equal(true)
			expect(humanoid:GetAttribute(Constants.Attributes.Invisible)).to.equal(true)
			expect(torso.Transparency).to.equal(1)
		end)

		it("disabling restores full opacity", function()
			local state = AdminActionSystem.CreateOverrideState()
			local character, humanoid, torso = makeCharacter()

			AdminActionSystem.ApplyInvisible(state, character, humanoid, true)
			AdminActionSystem.ApplyInvisible(state, character, humanoid, false)

			expect(state.Invisible).to.equal(false)
			expect(humanoid:GetAttribute(Constants.Attributes.Invisible)).to.equal(false)
			expect(torso.Transparency).to.equal(0)
		end)
	end)

	describe("AdminActionSystem.ApplySpeedMultiplier", function()
		it("accepts every preset in Constants.Debug.DevMenu.SpeedMultiplierPresets", function()
			local state = AdminActionSystem.CreateOverrideState()
			local humanoid = Instance.new("Humanoid")

			for _, preset in ipairs(Constants.Debug.DevMenu.SpeedMultiplierPresets) do
				local ok = AdminActionSystem.ApplySpeedMultiplier(state, humanoid, preset)
				expect(ok).to.equal(true)
				expect(state.SpeedMultiplier).to.equal(preset)
				expect(humanoid:GetAttribute(Constants.Attributes.SpeedMultiplier)).to.equal(preset)
			end
		end)

		it("rejects a multiplier outside the closed preset whitelist without mutating state", function()
			local state = AdminActionSystem.CreateOverrideState()
			local humanoid = Instance.new("Humanoid")
			state.SpeedMultiplier = 1

			local ok = AdminActionSystem.ApplySpeedMultiplier(state, humanoid, 999)

			expect(ok).to.equal(false)
			expect(state.SpeedMultiplier).to.equal(1)
			expect(humanoid:GetAttribute(Constants.Attributes.SpeedMultiplier)).to.equal(nil)
		end)
	end)

	-- AdminActionSystem.TeleportToPosition/SetFrozen/SetInvisible/SetSpeedMultiplier (the Player-keyed
	-- public wrappers, as opposed to the Apply*/CreateOverrideState/ReapplyRespawnOverrides pure
	-- functions tested above) all take a real Player and read/write overrideStates[targetPlayer] --
	-- a bare Player can't be constructed in this headless harness (Instance.new("Player") errors), so
	-- these have no direct spec coverage here, the same already-accepted gap SetGodmode/SetFlying/
	-- SetFlightCollide have. Requires Studio/live-server verification.
end
