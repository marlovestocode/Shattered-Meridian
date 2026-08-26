--!strict
-- Covers Server/Combat/Weapon/WeaponVisualSystem.lua.
--
-- EquipVisual is tested directly and thoroughly -- it is the entire production reaction to
-- AttackRequestSystem.OnWeaponChanged, not a copy of it (see that function's own header), so a spec
-- driving it is exercising the real code path.
--
-- Attach/Init/Reset's WIRING to the real AttackRequestSystem.OnWeaponChanged signal is only checked
-- for idempotency here, NOT end-to-end (subscribe, then have a real swap/spawn actually fire it). The
-- two calls that fire that signal -- handleSwap and bindCharacter -- both resolve a real Player
-- (Players:GetPlayerFromCharacter / PlayerLifecycle's own CharacterAdded plumbing), and a bare
-- Instance.new("Player") errors in this headless harness -- the same already-accepted gap
-- AttackRequestSystem.spec.lua's own header documents for its Hotbar coverage. There is no
-- synthetic-dummy substitute for it here either; deferred to Studio/live-server verification.
--
-- Dummies are minimal (Model + HumanoidRootPart + Humanoid), matching AttackRequestSystem.spec.lua's
-- own makeDummy -- deliberately WITHOUT a RightHand/Right Arm part, so these cases also cannot assert
-- on the actual grip joint Humanoid:EquipTool creates on a real R15/R6 rig. Building that grip is
-- Roblox's own well-tested mechanism (see WeaponVisualSystem.lua's header on why it is not reinvented
-- here), not this System's to re-prove; what this file owns is that EquipVisual asks for the right
-- Tool, replaces the right one, and never throws doing it.
--
-- AND THE HARNESS BUILDS NO GRIP AT ALL, not even for a dummy carrying a "Right Arm" part -- measured,
-- not assumed. That is why MotorizeGrip is driven DIRECTLY below rather than through EquipVisual: a
-- case that equipped and then looked for the swapped joint would find nothing to swap and pass while
-- asserting nothing, which is worse than no case at all. See that function's own header.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local ServerScriptService = game:GetService("ServerScriptService")

local AttackRequestSystem = require(ServerScriptService.Server.Combat.Attack.AttackRequestSystem)
local WeaponModelRegistry = require(ReplicatedStorage.Shared.Combat.WeaponModelRegistry)
local WeaponVisualSystem = require(ServerScriptService.Server.Combat.Weapon.WeaponVisualSystem)

local TOOL_NAME = "EquippedWeaponVisual"

local spawned: { Instance } = {}

-- Workspace.Weapons itself -- created on first use if this headless place doesn't already have one,
-- reused otherwise, matching WeaponModelRegistry.spec.lua's own container().
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

local function makeDummy(name: string): Model
	local model = Instance.new("Model")
	model.Name = name

	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = Vector3.new(2, 2, 1)
	root.Anchored = true
	root.CanCollide = false
	root.Parent = model

	local humanoid = Instance.new("Humanoid")
	humanoid.RequiresNeck = false
	humanoid.Parent = model

	model.PrimaryPart = root
	model.Parent = Workspace
	table.insert(spawned, model)
	return model
end

-- EquipVisual only ever produces a Tool once a WeaponModelRegistry template is registered for that
-- weapon id (there is no procedural fallback -- WeaponModels.lua's own header), so every case here
-- that exercises a real equip places one first. The model's Name IS the weapon id. Uses
-- WeaponModelRegistry.Start() directly rather than WeaponVisualSystem.Init() so cases testing
-- Init/Attach in isolation below aren't affected by it.
local function registerLongswordTemplate(): ()
	local tool = Instance.new("Tool")
	tool.Name = "Longsword"
	local handle = Instance.new("Part")
	handle.Name = "Handle"
	handle.Parent = tool
	tool.Parent = container()
	table.insert(spawned, tool)
	WeaponModelRegistry.Start()
end

return function()
	afterEach(function()
		WeaponVisualSystem.Reset()
		-- Explicitly, because WeaponVisualSystem.Reset no longer clears the shared registry for us --
		-- see its own header. This file registers its own templates, so this file cleans them up.
		WeaponModelRegistry.Reset()
		AttackRequestSystem.Reset()
		for _, model in spawned do
			model:Destroy()
		end
		table.clear(spawned)
	end)

	describe("WeaponVisualSystem.EquipVisual", function()
		it("equips a Tool named for the current weapon", function()
			registerLongswordTemplate()
			local character = makeDummy("Swordsman")
			WeaponVisualSystem.EquipVisual(character, "Longsword")

			local tool = character:FindFirstChild(TOOL_NAME)
			expect(tool).to.be.ok()
			assert(tool and tool:IsA("Tool"), "must equip a Tool")
			expect(tool:GetAttribute("WeaponId")).to.equal("Longsword")
		end)

		it("swaps the grip Weld for a Motor6D, preserving Part0/Part1/C0/C1", function()
			registerLongswordTemplate()
			local character = makeDummy("Rigged")
			-- "Right Arm", because this game is R6-locked -- that is the part Humanoid:EquipTool hangs
			-- the grip off on the rig players actually arrive on. MotorizeGrip never reads the name
			-- (it matches on what the joint CONNECTS), so this is fidelity to the shipping rig rather
			-- than something the assertions depend on.
			local arm = Instance.new("Part")
			arm.Name = "Right Arm"
			arm.Anchored = true
			arm.Parent = character

			WeaponVisualSystem.EquipVisual(character, "Longsword")
			local tool = character:FindFirstChild(TOOL_NAME)
			assert(tool and tool:IsA("Tool"), "must equip a Tool")
			local handle = tool:FindFirstChild("Handle")
			assert(handle and handle:IsA("BasePart"), "the equipped Tool must have a Handle")

			-- Stands in for what Humanoid:EquipTool builds on a real rig -- see this file's header on why
			-- the harness cannot produce one. The C0/C1 are arbitrary but DISTINCT and non-identity, so a
			-- Motor6D that silently defaulted them instead of copying cannot pass.
			local weld = Instance.new("Weld")
			weld.Name = "RightGrip"
			weld.Part0 = arm
			weld.Part1 = handle :: BasePart
			weld.C0 = CFrame.new(0, -1.5, 0) * CFrame.Angles(math.rad(90), 0, 0)
			weld.C1 = CFrame.new(0.25, 0, -0.5)
			weld.Parent = arm

			WeaponVisualSystem.MotorizeGrip(character, tool)

			expect(weld.Parent).to.equal(nil)

			local joints: { Instance } = {}
			for _, descendant in character:GetDescendants() do
				if descendant.Name == "RightGrip" and descendant:IsA("JointInstance") then
					table.insert(joints, descendant)
				end
			end
			-- Exactly one: replaced, never a Motor6D layered over the Weld it was meant to retire.
			expect(#joints).to.equal(1)

			local motor = joints[1]
			assert(motor:IsA("Motor6D"), "the grip must be a Motor6D -- an Animator drives nothing else")
			expect(motor.Part0).to.equal(arm)
			expect(motor.Part1).to.equal(handle)
			expect(motor.Parent).to.equal(arm)
			-- The rest pose has to survive the swap intact, or every rigged weapon plays its clip
			-- correctly but visibly offset from the hand.
			expect(motor.C0.Position.Y).to.be.near(-1.5, 1e-4)
			expect(motor.C0.UpVector.Z).to.be.near(1, 1e-4)
			expect(motor.C1.Position.X).to.be.near(0.25, 1e-4)
			expect(motor.C1.Position.Z).to.be.near(-0.5, 1e-4)
		end)

		it("ignores a weapon's OWN RightGrip Weld and converts the real one", function()
			registerLongswordTemplate()
			local character = makeDummy("Decoyed")
			local arm = Instance.new("Part")
			arm.Name = "Right Arm"
			arm.Anchored = true
			arm.Parent = character

			WeaponVisualSystem.EquipVisual(character, "Longsword")
			local tool = character:FindFirstChild(TOOL_NAME)
			assert(tool and tool:IsA("Tool"), "must equip a Tool")
			local handle = tool:FindFirstChild("Handle")
			assert(handle and handle:IsA("BasePart"), "the equipped Tool must have a Handle")

			-- A weapon author's own joint, sharing the engine's name and pointing at the same Handle --
			-- the decoy. Placed FIRST so a naive search that takes whatever it finds first picks it.
			local decoy = Instance.new("Weld")
			decoy.Name = "RightGrip"
			decoy.Part0 = handle :: BasePart
			decoy.Part1 = handle :: BasePart
			decoy.Parent = handle

			local real = Instance.new("Weld")
			real.Name = "RightGrip"
			real.Part0 = arm
			real.Part1 = handle :: BasePart
			real.Parent = arm

			WeaponVisualSystem.MotorizeGrip(character, tool)

			-- The decoy is untouched, and the REAL grip is the one that became a Motor6D.
			expect(decoy.Parent).to.equal(handle)
			expect(decoy.ClassName).to.equal("Weld")
			expect(real.Parent).to.equal(nil)

			local motor = arm:FindFirstChild("RightGrip")
			assert(motor and motor:IsA("Motor6D"), "the arm's grip must have become a Motor6D")
			expect(motor.Part0).to.equal(arm)
		end)

		it("leaves a character with no grip joint alone rather than throwing", function()
			registerLongswordTemplate()
			local character = makeDummy("Armless")
			WeaponVisualSystem.EquipVisual(character, "Longsword")
			local tool = character:FindFirstChild(TOOL_NAME)
			assert(tool and tool:IsA("Tool"), "must equip a Tool")

			expect(function()
				WeaponVisualSystem.MotorizeGrip(character, tool)
			end).never.to.throw()
		end)

		it("replaces the previous visual on a re-equip rather than stacking two", function()
			registerLongswordTemplate()
			local character = makeDummy("Rearmed")
			WeaponVisualSystem.EquipVisual(character, "Longsword")
			local first = character:FindFirstChild(TOOL_NAME)
			assert(first, "first equip must produce a Tool")

			WeaponVisualSystem.EquipVisual(character, "Longsword")
			local second = character:FindFirstChild(TOOL_NAME)
			assert(second, "second equip must produce a Tool")

			expect(first).never.to.equal(second)
			expect(first.Parent).to.equal(nil)

			local toolCount = 0
			for _, child in character:GetChildren() do
				if child:IsA("Tool") then
					toolCount += 1
				end
			end
			expect(toolCount).to.equal(1)
		end)

		it("un-equips rather than equipping an empty Tool for a weapon with no template", function()
			registerLongswordTemplate()
			local character = makeDummy("Dagger-user")
			WeaponVisualSystem.EquipVisual(character, "Longsword")
			expect(character:FindFirstChild(TOOL_NAME)).to.be.ok()

			WeaponVisualSystem.EquipVisual(character, "NothingRegistered")
			expect(character:FindFirstChild(TOOL_NAME)).to.equal(nil)
		end)

		it("does nothing to a character with no Humanoid, rather than erroring", function()
			local model = Instance.new("Model")
			model.Name = "Headless"
			model.Parent = Workspace
			table.insert(spawned, model)

			expect(function()
				WeaponVisualSystem.EquipVisual(model, "Longsword")
			end).never.to.throw()
			expect(model:FindFirstChild(TOOL_NAME)).to.equal(nil)
		end)
	end)

	describe("WeaponVisualSystem.Attach / Init / Reset", function()
		it("Init requires AttackRequestSystem.OnWeaponChanged to be present", function()
			expect(AttackRequestSystem.OnWeaponChanged).to.be.ok()
			expect(function()
				WeaponVisualSystem.Init()
			end).never.to.throw()
		end)

		it("Attach is idempotent -- calling it twice does not double-subscribe or error", function()
			expect(function()
				WeaponVisualSystem.Attach()
				WeaponVisualSystem.Attach()
			end).never.to.throw()
		end)

		it("Reset is safe to call even with nothing attached", function()
			expect(function()
				WeaponVisualSystem.Reset()
				WeaponVisualSystem.Reset()
			end).never.to.throw()
		end)
	end)
end
