--!strict
-- Covers Shared/Combat/WeaponModelRegistry.lua -- the authoring contract a weapon model placed at the
-- one fixed path (Workspace.Weapons) has to satisfy to come back out of GetTemplate:
-- Tool-passthrough, Model-wrapping (including the no-Handle skip), and the duplicate-name "keep the
-- first" rule WeaponModelRegistry.lua's header documents. The live ChildAdded/ChildRemoved path is
-- exercised through the SAME registerSource/unregisterSource functions Start()'s GetChildren loop
-- already drives -- there is no separate implementation for it to diverge from -- so it is not
-- separately re-tested here with a signal wait, the same "don't re-prove the platform's own mechanism"
-- reasoning WeaponVisualSystem.spec.lua's header gives for not re-testing Humanoid:EquipTool's own
-- grip creation.

local Workspace = game:GetService("Workspace")

local WeaponModelRegistry = require(game:GetService("ReplicatedStorage").Shared.Combat.WeaponModelRegistry)

local spawned: { Instance } = {}

-- Workspace.Weapons itself -- created on first use if this headless place doesn't already have one,
-- reused (never destroyed) otherwise, so specs never race each other over who owns it. Only the
-- CHILDREN a test adds are cleaned up, in afterEach below.
local function container(): Folder
	local existing = Workspace:FindFirstChild("Weapons")
	if existing and existing:IsA("Folder") then
		return existing :: Folder
	end
	local folder = Instance.new("Folder")
	folder.Name = "Weapons"
	folder.Parent = Workspace
	return folder
end

local function placeTool(name: string): Tool
	local tool = Instance.new("Tool")
	tool.Name = name

	local handle = Instance.new("Part")
	handle.Name = "Handle"
	handle.Parent = tool

	tool.Parent = container()
	table.insert(spawned, tool)
	return tool
end

local function placeModel(name: string, includeHandle: boolean): Model
	local model = Instance.new("Model")
	model.Name = name

	if includeHandle then
		local handle = Instance.new("Part")
		handle.Name = "Handle"
		handle.Size = Vector3.new(0.2, 0.9, 0.2)
		-- ANCHORED, like every real weapon standing in the world -- that is what keeps it on its rack.
		-- The fixture models it because an unanchored fixture would let the teleport regression below
		-- pass without the fix being present.
		handle.Anchored = true
		handle.Parent = model
	end

	local blade = Instance.new("Part")
	blade.Name = "Blade"
	blade.Anchored = true
	blade.Parent = model

	model.Parent = container()
	table.insert(spawned, model)
	return model
end

return function()
	afterEach(function()
		WeaponModelRegistry.Reset()
		for _, instance in spawned do
			instance:Destroy()
		end
		table.clear(spawned)
	end)

	describe("WeaponModelRegistry.Start / GetTemplate -- Tool children", function()
		it("returns nil for a name nothing has registered", function()
			WeaponModelRegistry.Start()
			expect(WeaponModelRegistry.GetTemplate("Nonexistent")).to.equal(nil)
		end)

		it("clones a placed Tool as-is and returns the cached master on repeated calls", function()
			placeTool("Longsword")
			WeaponModelRegistry.Start()

			local master = WeaponModelRegistry.GetTemplate("Longsword")
			expect(master).to.be.ok()
			assert(master, "must register a template")
			expect(master:IsA("Tool")).to.equal(true)
			expect(master.RequiresHandle).to.equal(true)
			expect(master.CanBeDropped).to.equal(false)
			expect(master:FindFirstChild("Handle")).to.be.ok()

			expect(WeaponModelRegistry.GetTemplate("Longsword")).to.equal(master)
		end)

		it("ignores a placed Tool with no Handle child", function()
			local tool = Instance.new("Tool")
			tool.Name = "Handleless"
			tool.Parent = container()
			table.insert(spawned, tool)

			WeaponModelRegistry.Start()
			expect(WeaponModelRegistry.GetTemplate("Handleless")).to.equal(nil)
		end)
	end)

	describe("WeaponModelRegistry.Start / GetTemplate -- Model children", function()
		it("wraps a Model with a Handle part into an equippable Tool, welding siblings to it", function()
			placeModel("DualDaggers", true)
			WeaponModelRegistry.Start()

			local master = WeaponModelRegistry.GetTemplate("DualDaggers")
			assert(master, "must register a template")
			expect(master:IsA("Tool")).to.equal(true)

			local handle = master:FindFirstChild("Handle")
			expect(handle).to.be.ok()
			assert(handle and handle:IsA("BasePart"), "Handle must be a BasePart")

			local blade = master:FindFirstChild("Blade")
			expect(blade).to.be.ok()
			assert(blade and blade:IsA("BasePart"), "Blade must be a BasePart")

			local weldConstraint = blade:FindFirstChildOfClass("WeldConstraint")
			expect(weldConstraint).to.be.ok()
			assert(weldConstraint, "Blade must be welded to Handle")
			expect(weldConstraint.Part0).to.equal(handle)
			expect(weldConstraint.Part1).to.equal(blade)
		end)

		it("leaves a Motor6D-articulated part unwelded, so an Animator can still drive it", function()
			local model = placeModel("RiggedBlade", true)
			local handleSource = model:FindFirstChild("Handle") :: BasePart
			local bladeSource = model:FindFirstChild("Blade") :: BasePart
			local joint = Instance.new("Motor6D")
			joint.Name = "BladeJoint"
			joint.Part0 = handleSource
			joint.Part1 = bladeSource
			joint.Parent = handleSource

			WeaponModelRegistry.Start()

			local master = WeaponModelRegistry.GetTemplate("RiggedBlade")
			assert(master, "must register a template")

			local handle = master:FindFirstChild("Handle")
			local blade = master:FindFirstChild("Blade")
			assert(handle and handle:IsA("BasePart"), "Handle must be a BasePart")
			assert(blade and blade:IsA("BasePart"), "Blade must be a BasePart")

			-- THE REGRESSION. A WeldConstraint across the same pair the Motor6D already joins pins the
			-- joint shut: the clip loads, plays, reports the right Length and weight, and the blade
			-- never moves. Asserting the ABSENCE of the weld is the only way to catch it -- every other
			-- observable stays correct.
			expect(blade:FindFirstChildOfClass("WeldConstraint")).to.equal(nil)

			local builtJoint = master:FindFirstChild("BladeJoint", true)
			expect(builtJoint).to.be.ok()
			assert(builtJoint and builtJoint:IsA("Motor6D"), "the Motor6D must survive into the template")
			expect(builtJoint.Part0).to.equal(handle)
			expect(builtJoint.Part1).to.equal(blade)
		end)

		it("still welds a part whose Motor6D chain never reaches the Handle", function()
			local model = placeModel("Orphaned", true)
			local bladeSource = model:FindFirstChild("Blade") :: BasePart
			local floater = Instance.new("Part")
			floater.Name = "Pommel"
			floater.Anchored = true
			floater.Parent = model
			-- Joined to the BLADE, which is itself only welded -- so this chain never reaches Handle.
			-- Sparing it would leave both parts held to the weapon by nothing at all.
			local joint = Instance.new("Motor6D")
			joint.Part0 = bladeSource
			joint.Part1 = floater
			joint.Parent = floater

			WeaponModelRegistry.Start()

			local master = WeaponModelRegistry.GetTemplate("Orphaned")
			assert(master, "must register a template")
			local pommel = master:FindFirstChild("Pommel", true)
			assert(pommel and pommel:IsA("BasePart"), "Pommel must survive into the template")
			expect(pommel:FindFirstChildOfClass("WeldConstraint")).to.be.ok()
		end)

		it("skips a Model with no part named Handle, rather than guessing one", function()
			placeModel("Unhandled", false)
			WeaponModelRegistry.Start()
			expect(WeaponModelRegistry.GetTemplate("Unhandled")).to.equal(nil)
		end)

		it("finds a Handle nested inside the art and lifts it to be a direct child of the Tool", function()
			-- THE SHAPE AN IMPORTED WEAPON ACTUALLY ARRIVES IN: Model > MeshPart > Handle, rather than
			-- with the Handle already flattened to the top. Roblox's own grip only ever looks one level
			-- down, so a Handle left nested is a Tool that silently refuses to grip -- which reads in
			-- play as an invisible weapon with no error anywhere. This is the case that catches it.
			local model = Instance.new("Model")
			model.Name = "Nested"

			local art = Instance.new("Part")
			art.Name = "Nested"
			art.Parent = model

			local handle = Instance.new("Part")
			handle.Name = "Handle"
			handle.Parent = art

			model.Parent = container()
			table.insert(spawned, model)

			WeaponModelRegistry.Start()

			local master = WeaponModelRegistry.GetTemplate("Nested")
			expect(master).to.be.ok()
			assert(master, "a nested Handle must still register")

			-- Direct child of the Tool, not still buried in the art.
			local built = master:FindFirstChild("Handle")
			expect(built).to.be.ok()
			assert(built and built:IsA("BasePart"), "Handle must be lifted to the Tool's top level")

			-- And the art it came out of is still there, welded to it, so nothing was lost in the lift.
			local builtArt = master:FindFirstChild("Nested")
			expect(builtArt).to.be.ok()
			assert(builtArt and builtArt:IsA("BasePart"), "the art must survive the lift")
			local weldConstraint = builtArt:FindFirstChildOfClass("WeldConstraint")
			expect(weldConstraint).to.be.ok()
			assert(weldConstraint, "the art must be welded to the lifted Handle")
			expect(weldConstraint.Part0).to.equal(built)
		end)

		it("finds a Blade nested inside the art and lifts it to be a direct child of the Tool too", function()
			-- THE SHAPE A REAL AUTHORED WEAPON ACTUALLY ARRIVES IN: an outer container holding both an
			-- Animations folder and a separate inner grip model, itself holding Handle and Blade --
			-- exactly the structure that shipped for the game's own Cutlass and exposed this gap.
			-- HitboxEngine.resolveAttachmentPart's "Weapon" case looks for a DIRECT child of the equipped
			-- Tool named "Blade" first (see that function's own header); a Blade left nested a level down
			-- would silently and permanently fall back to Handle-anchored geometry, with nothing anywhere
			-- reporting it -- the same class of silent failure the Handle-lift test above exists to catch.
			local model = Instance.new("Model")
			model.Name = "NestedBlade"

			local grip = Instance.new("Model")
			grip.Name = "NestedBlade"
			grip.Parent = model

			local handle = Instance.new("Part")
			handle.Name = "Handle"
			handle.Parent = grip

			local blade = Instance.new("Part")
			blade.Name = "Blade"
			blade.Parent = grip

			model.Parent = container()
			table.insert(spawned, model)

			WeaponModelRegistry.Start()

			local master = WeaponModelRegistry.GetTemplate("NestedBlade")
			expect(master).to.be.ok()
			assert(master, "a nested Blade must still register")

			-- Direct child of the Tool, not still buried in the grip model -- FindFirstChild without the
			-- recursive flag is exactly what HitboxEngine.resolveAttachmentPart calls.
			local builtBlade = master:FindFirstChild("Blade")
			expect(builtBlade).to.be.ok()
			assert(builtBlade and builtBlade:IsA("BasePart"), "Blade must be lifted to the Tool's top level")

			local weldConstraint = builtBlade:FindFirstChildOfClass("WeldConstraint")
			expect(weldConstraint).to.be.ok()
			assert(weldConstraint, "the lifted Blade must still be welded to Handle")
			expect(weldConstraint.Part1).to.equal(builtBlade)
		end)

		it("forces every welded part non-colliding and massless so a held weapon can't shove its wielder", function()
			placeModel("Physical", true)
			WeaponModelRegistry.Start()

			local master = WeaponModelRegistry.GetTemplate("Physical")
			assert(master, "must register a template")
			for _, descendant in master:GetDescendants() do
				if descendant:IsA("BasePart") then
					expect(descendant.CanCollide).to.equal(false)
					expect(descendant.Massless).to.equal(true)
				end
			end
		end)

		it("composes the Grip from the authored WeaponGripRotation/WeaponGripPosition Attributes", function()
			-- Vector3, NOT CFrame -- Studio's Attributes panel cannot set a CFrame at all, so the
			-- CFrame version of this knob was unusable for the exact job it existed to do. See
			-- WeaponModelRegistry's own GRIP_ROTATION_ATTRIBUTE comment.
			local model = placeModel("Offset", true)
			model:SetAttribute("WeaponGripRotation", Vector3.new(0, 90, 0))
			model:SetAttribute("WeaponGripPosition", Vector3.new(0, -1, 0))

			WeaponModelRegistry.Start()
			local master = WeaponModelRegistry.GetTemplate("Offset")
			assert(master, "must register a template")

			local expected = CFrame.new(0, -1, 0) * CFrame.Angles(0, math.rad(90), 0)
			expect(master.Grip.Position.Y).to.be.near(expected.Position.Y, 1e-4)
			-- Rotation applied, and applied about the axis asked for: a quarter turn about Y sends the
			-- Handle's own +X onto world -Z.
			expect(master.Grip.RightVector.Z).to.be.near(expected.RightVector.Z, 1e-4)
		end)

		it("defaults to a half turn about Y -- turned around, NOT rolled upside down", function()
			placeModel("Defaulted", true)
			WeaponModelRegistry.Start()

			local master = WeaponModelRegistry.GetTemplate("Defaulted")
			assert(master, "must register a template")
			-- UP STAYS UP. This is the whole point of the axis choice: a Z or X half turn also reverses
			-- the blade, but inverts the Handle's own up axis doing it, and presents in play as the sword
			-- being held upside down. Asserting UpVector rather than just "something rotated" is what
			-- makes this case able to fail on the wrong axis.
			expect(master.Grip.UpVector.Y).to.be.near(1, 1e-4)
			-- And it IS reversed: a half turn about Y sends the Handle's own -Z onto +Z.
			expect(master.Grip.LookVector.Z).to.be.near(1, 1e-4)
		end)
	end)

	describe("WeaponModelRegistry -- duplicate child Name", function()
		it("keeps the first registration and ignores the second, without throwing", function()
			placeTool("Shared")
			placeTool("Shared")

			expect(function()
				WeaponModelRegistry.Start()
			end).never.to.throw()

			expect(WeaponModelRegistry.GetTemplate("Shared")).to.be.ok()
		end)
	end)

	describe("WeaponModelRegistry.Reset", function()
		it("clears every registered template", function()
			placeTool("Cleared")
			WeaponModelRegistry.Start()
			expect(WeaponModelRegistry.GetTemplate("Cleared")).to.be.ok()

			WeaponModelRegistry.Reset()
			expect(WeaponModelRegistry.GetTemplate("Cleared")).to.equal(nil)
		end)

		it("is safe to call even with nothing started", function()
			expect(function()
				WeaponModelRegistry.Reset()
				WeaponModelRegistry.Reset()
			end).never.to.throw()
		end)
	end)
end
