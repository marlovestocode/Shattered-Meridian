--!strict
-- Covers Shared/HitboxEngine/HitboxAnchor.lua -- the one anchor chain HitboxEngine and the Move Editor's
-- in-world preview both resolve through.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local HitboxAnchor = require(ReplicatedStorage.Shared.HitboxEngine.HitboxAnchor)

local function part(name: string, parent: Instance): Part
	local created = Instance.new("Part")
	created.Name = name
	created.Parent = parent
	return created
end

-- A hand-built R6 body: root, torso and both arms, no hands.
local function r6(): (Model, BasePart)
	local model = Instance.new("Model")
	local root = part("HumanoidRootPart", model)
	part("Torso", model)
	part("Right Arm", model)
	part("Left Arm", model)
	return model, root
end

return function()
	describe("HitboxAnchor.Resolve", function()
		it("anchors Root to the root part", function()
			local model, root = r6()
			expect(HitboxAnchor.Resolve(model, root, "Root")).to.equal(root)
		end)

		it("falls back from R15 hands to R6 arms", function()
			local model, root = r6()
			expect(HitboxAnchor.Resolve(model, root, "RightHand")).to.equal(model:FindFirstChild("Right Arm"))
			expect(HitboxAnchor.Resolve(model, root, "LeftHand")).to.equal(model:FindFirstChild("Left Arm"))
		end)

		it("prefers a real hand when the rig has one", function()
			local model, root = r6()
			local hand = part("RightHand", model)
			expect(HitboxAnchor.Resolve(model, root, "RightHand")).to.equal(hand)
		end)

		it("falls back to the root when a rig has no arms at all", function()
			local model = Instance.new("Model")
			local root = part("HumanoidRootPart", model)
			expect(HitboxAnchor.Resolve(model, root, "LeftHand")).to.equal(root)
			expect(HitboxAnchor.Resolve(model, root, "Weapon")).to.equal(root)
		end)

		it("anchors Weapon to the tool's Blade, at any depth, before its Handle", function()
			local model, root = r6()
			local tool = Instance.new("Tool")
			tool.Parent = model
			local handle = part("Handle", tool)
			expect(HitboxAnchor.Resolve(model, root, "Weapon")).to.equal(handle)

			local nested = Instance.new("Model")
			nested.Parent = tool
			local blade = part("Blade", nested)
			expect(HitboxAnchor.Resolve(model, root, "Weapon")).to.equal(blade)
		end)

		it("falls back from an unarmed Weapon anchor to the right arm", function()
			local model, root = r6()
			expect(HitboxAnchor.Resolve(model, root, "Weapon")).to.equal(model:FindFirstChild("Right Arm"))
		end)
	end)
end
