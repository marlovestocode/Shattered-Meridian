--!strict
-- Covers Shared/Combat/WeaponModels.lua -- the two questions this builder answers: does a registered
-- WeaponModelRegistry template come back as a fresh, equippable clone with the right ToolTip; and does
-- a weapon with no template registered for its ModelId come back nil rather than an empty Tool. There
-- is no procedural fallback to cover here -- WeaponModels.lua's own header explains why one existed
-- briefly and was cut.

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local WeaponModelRegistry = require(ReplicatedStorage.Shared.Combat.WeaponModelRegistry)
local WeaponModels = require(ReplicatedStorage.Shared.Combat.WeaponModels)

-- Workspace.Weapons itself -- created on first use if this headless place doesn't already have one,
-- reused otherwise. WeaponModelRegistry.spec.lua's own container() does the same; never destroyed
-- here, only the child this file adds to it.
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

-- A WeaponId IS the model's Name now, so the name used here is the id Build is called with -- there is
-- no separate map in between (WeaponModels.lua's own header).
local function placeLongswordTemplate(): Tool
	local tool = Instance.new("Tool")
	tool.Name = "Longsword"
	local handle = Instance.new("Part")
	handle.Name = "Handle"
	handle.Parent = tool
	tool.Parent = container()
	return tool
end

return function()
	afterEach(function()
		WeaponModelRegistry.Reset()
	end)

	describe("WeaponModels.Build -- no template registered", function()
		it("returns nil for both weapons rather than an empty Tool", function()
			expect(WeaponModels.Build("Longsword")).to.equal(nil)
			expect(WeaponModels.Build("NothingRegistered")).to.equal(nil)
		end)
	end)

	describe("WeaponModels.Build -- a registered WeaponModelRegistry template", function()
		it("clones the template and stamps the weapon's own ToolTip", function()
			local source = placeLongswordTemplate()
			WeaponModelRegistry.Start()

			local built = WeaponModels.Build("Longsword")
			assert(built, "Longsword must build a Tool")
			expect(built:IsA("Tool")).to.equal(true)
			expect(built:FindFirstChild("Handle")).to.be.ok()
			expect(built.ToolTip).to.equal("Longsword")

			built:Destroy()
			source:Destroy()
		end)

		it("builds a fresh Tool on every call rather than sharing one Instance", function()
			local source = placeLongswordTemplate()
			WeaponModelRegistry.Start()

			local first = WeaponModels.Build("Longsword")
			local second = WeaponModels.Build("Longsword")
			assert(first and second, "Longsword must build a Tool both times")
			expect(first).never.to.equal(second)

			first:Destroy()
			second:Destroy()
			source:Destroy()
		end)

		it("never hands out the cached master itself as an equipped Tool", function()
			local source = placeLongswordTemplate()
			WeaponModelRegistry.Start()

			local master = WeaponModelRegistry.GetTemplate("Longsword")
			local built = WeaponModels.Build("Longsword")
			assert(built, "Longsword must build a Tool")

			expect(built).never.to.equal(master)

			built:Destroy()
			source:Destroy()
		end)
	end)
end
