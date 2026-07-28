--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Constants = require(ReplicatedStorage.Shared.Constants)
local RagdollController = require(ServerScriptService.Server.Combat.RagdollController)

-- Builds a minimal R15-shaped rig -- just enough for RagdollController to find a HumanoidRootPart
-- and a Humanoid; HoldAloft/ClearHold/Recover under test here never touch limbs, so no other parts
-- or Motor6Ds are needed. Deliberately NOT anchored -- HoldAloft (RagdollController.lua's own guard,
-- "if rootPart.Anchored then return") is a genuine no-op on an anchored part, which would silently
-- skip the exact pin-creation this spec is testing. Every SetNetworkOwner/velocity write RagdollController
-- makes on an unanchored, unparented-to-Workspace part is already pcall-guarded (this module's own
-- header: "every ownership/physics call is pcall-guarded"), so a failed ownership call here is
-- expected and harmless -- only the Instance bookkeeping (AirComboHoldAlign et al.) is under test.
local function makeRig(): (Model, Humanoid, BasePart)
	local model = Instance.new("Model")
	local humanoid = Instance.new("Humanoid")
	humanoid.RigType = Enum.HumanoidRigType.R15
	humanoid.Parent = model
	local rootPart = Instance.new("Part")
	rootPart.Name = "HumanoidRootPart"
	rootPart.Parent = model
	return model, humanoid, rootPart
end

local function holdInstanceNames(rootPart: BasePart): { string }
	local names = {}
	for _, name in ipairs({
		"AirComboHoldAlign",
		"AirComboHoldAttachment",
		"AirComboHoldGravityCancel",
		"AirComboHoldOrient",
	}) do
		if rootPart:FindFirstChild(name) then
			table.insert(names, name)
		end
	end
	return names
end

return function()
	describe("RagdollController.HoldAloft / ClearHold", function()
		it("creates a rigid AlignPosition pin on the held rootPart", function()
			local _model, _humanoid, rootPart = makeRig()

			RagdollController.HoldAloft(
				rootPart,
				nil,
				Vector3.new(0, 12, 0),
				Constants.Combat.AirCombo.AirborneSeconds,
				Constants.Combat.AirCombo.HoverRiseSpeed,
				Constants.Combat.AirCombo.HoverResponsiveness
			)

			local align = rootPart:FindFirstChild("AirComboHoldAlign")
			expect(align).to.be.ok()
			expect((align :: AlignPosition).MaxForce).to.equal(math.huge)
		end)

		it("removes the pin and is idempotent when called again with nothing held", function()
			local _model, _humanoid, rootPart = makeRig()

			RagdollController.HoldAloft(
				rootPart,
				nil,
				Vector3.new(0, 12, 0),
				Constants.Combat.AirCombo.AirborneSeconds,
				Constants.Combat.AirCombo.HoverRiseSpeed,
				Constants.Combat.AirCombo.HoverResponsiveness
			)
			expect(rootPart:FindFirstChild("AirComboHoldAlign")).to.be.ok()

			RagdollController.ClearHold(rootPart, nil)
			expect(rootPart:FindFirstChild("AirComboHoldAlign")).to.equal(nil)

			-- Calling again with no active hold must not error -- this is exactly the safety property
			-- CombatSystem.ResetCombatState's new unconditional third cleanup path depends on: it now
			-- calls ClearHold on every reset target's own rootPart regardless of whether that player
			-- happens to be currently held.
			RagdollController.ClearHold(rootPart, nil)
			expect(rootPart:FindFirstChild("AirComboHoldAlign")).to.equal(nil)
		end)

		it(
			"Recover (ragdoll-only reversal) does NOT clear a HoldAloft pin on the same rootPart -- "
				.. "only ClearHold does, which is the exact gap ResetCombatState's third cleanup path closes",
			function()
				local model, humanoid, rootPart = makeRig()

				-- Mirrors what happens to an air-combo TARGET: LaunchAndRagdoll ragdolls the body, then
				-- AirCombo.Apply calls HoldAloft on the SAME rootPart to pin it aloft. Both writes land
				-- on the target's rootPart, but (per the bug this fix addresses) the CombatState field
				-- that would normally gate a ClearHold call is only ever set on the ATTACKER's own
				-- CombatState, never the target's.
				RagdollController.LaunchAndRagdoll(model, humanoid, rootPart, nil, nil, 10, 5, 0, 1.8)
				RagdollController.HoldAloft(
					rootPart,
					nil,
					Vector3.new(0, 12, 0),
					Constants.Combat.AirCombo.AirborneSeconds,
					Constants.Combat.AirCombo.HoverRiseSpeed,
					Constants.Combat.AirCombo.HoverResponsiveness
				)
				expect(#holdInstanceNames(rootPart) > 0).to.equal(true)

				RagdollController.Recover(model)

				-- The bug: Recover reverses the ragdoll joints/ownership but leaves the AlignPosition
				-- pin fully intact and still applying MaxForce = math.huge to this rootPart.
				expect(#holdInstanceNames(rootPart) > 0).to.equal(true)

				-- The fix: an unconditional ClearHold alongside Recover actually releases the pin.
				RagdollController.ClearHold(rootPart, nil)
				expect(#holdInstanceNames(rootPart)).to.equal(0)
			end
		)
	end)
end
