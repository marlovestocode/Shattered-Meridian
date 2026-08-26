--!strict
-- Covers Shared/Vehicle/VehicleCatalog.lua -- reading a registry folder into definitions, and the
-- rejection reason for each of the ways a builder can get the folder shape wrong.
--
-- These DO need Instances (the whole function is a walk over real children, and GetBoundingBox is a
-- real measurement), but nothing here goes into Workspace: an unparented Folder is a complete
-- registry root as far as ReadRegistry is concerned, which is exactly the property that makes it
-- testable without a place.
--
-- The case that matters most is the two-Models entry. The shipped content shape is
-- Vehicles/Blimp/Model, so "one Model inside a folder" is the common path -- but a builder keeping a
-- Model_Old beside the live one is normal, and resolving that to the wrong hull silently would show
-- the right name in the Dev Menu and spawn the wrong thing.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local VehicleCatalog = require(ReplicatedStorage.Shared.Vehicle.VehicleCatalog)
local VehicleConstants = require(ReplicatedStorage.Shared.Vehicle.VehicleConstants)

-- A Model with one part in it, so it passes the has-any-BasePart check.
local function newTemplate(name: string, size: Vector3, parent: Instance): Model
	local model = Instance.new("Model")
	model.Name = name

	local part = Instance.new("Part")
	part.Name = "Hull"
	part.Anchored = true
	part.CanCollide = false
	part.Size = size
	part.CFrame = CFrame.new(0, 0, 0)
	part.Parent = model

	model.Parent = parent
	return model
end

local function newEntryFolder(name: string, parent: Instance): Folder
	local folder = Instance.new("Folder")
	folder.Name = name
	folder.Parent = parent
	return folder
end

local function findDefinition(definitions, id: string)
	for _, definition in definitions do
		if definition.Id == id then
			return definition
		end
	end
	return nil
end

local function findRejection(rejections, path: string)
	for _, rejection in rejections do
		if rejection.Path == path then
			return rejection
		end
	end
	return nil
end

return function()
	local roots: { Instance } = {}

	local function newRoot(): Folder
		local root = Instance.new("Folder")
		root.Name = VehicleConstants.Registry.FolderName
		table.insert(roots, root)
		return root
	end

	afterEach(function()
		for _, root in roots do
			root:Destroy()
		end
		roots = {}
	end)

	describe("template resolution", function()
		it("reads the shipped Vehicles/<Id>/Model shape", function()
			local root = newRoot()
			local entry = newEntryFolder("Blimp", root)
			newTemplate("Model", Vector3.new(10, 4, 30), entry)

			local definitions, rejections = VehicleCatalog.ReadRegistry(root)

			expect(#definitions).to.equal(1)
			expect(#rejections).to.equal(0)
			expect(definitions[1].Id).to.equal("Blimp")
			expect(definitions[1].Template.Name).to.equal("Model")
		end)

		it("keys on the ENTRY name, not the template name", function()
			-- Every vehicle's template is called "Model", so keying on it would collapse the whole
			-- registry to one entry.
			local root = newRoot()
			newTemplate("Model", Vector3.new(4, 4, 4), newEntryFolder("Blimp", root))
			newTemplate("Model", Vector3.new(4, 4, 4), newEntryFolder("Skiff", root))

			local definitions = VehicleCatalog.ReadRegistry(root)

			expect(#definitions).to.equal(2)
			expect(findDefinition(definitions, "Blimp")).to.be.ok()
			expect(findDefinition(definitions, "Skiff")).to.be.ok()
		end)

		it("accepts an entry that IS a Model", function()
			local root = newRoot()
			newTemplate("Skiff", Vector3.new(6, 3, 12), root)

			local definitions, rejections = VehicleCatalog.ReadRegistry(root)

			expect(#definitions).to.equal(1)
			expect(#rejections).to.equal(0)
			expect(definitions[1].Id).to.equal("Skiff")
		end)

		it("accepts a single differently-named Model inside a folder", function()
			local root = newRoot()
			newTemplate("Hull_v3", Vector3.new(6, 3, 12), newEntryFolder("Skiff", root))

			local definitions = VehicleCatalog.ReadRegistry(root)

			expect(#definitions).to.equal(1)
			expect(definitions[1].Template.Name).to.equal("Hull_v3")
		end)

		it("prefers the Model named Model when an entry holds several", function()
			local root = newRoot()
			local entry = newEntryFolder("Blimp", root)
			newTemplate("Model_Old", Vector3.new(4, 4, 4), entry)
			newTemplate("Model", Vector3.new(9, 9, 9), entry)

			local definitions, rejections = VehicleCatalog.ReadRegistry(root)

			expect(#rejections).to.equal(0)
			expect(definitions[1].Template.Name).to.equal("Model")
		end)

		it("does not descend into a template's own nested Models", function()
			-- A Blimp's gondola is a Model inside the hull Model; a recursive search would find it and
			-- offer to spawn a detached gondola.
			local root = newRoot()
			local template = newTemplate("Model", Vector3.new(40, 20, 90), newEntryFolder("Blimp", root))
			newTemplate("Gondola", Vector3.new(6, 4, 10), template)

			local definitions = VehicleCatalog.ReadRegistry(root)

			expect(#definitions).to.equal(1)
			expect(definitions[1].Template.Name).to.equal("Model")
		end)
	end)

	describe("rejections", function()
		it("names an entry with no Model in it", function()
			local root = newRoot()
			newEntryFolder("Empty", root)

			local definitions, rejections = VehicleCatalog.ReadRegistry(root)

			expect(#definitions).to.equal(0)
			expect(findRejection(rejections, "Empty")).to.be.ok()
		end)

		it("names an entry whose Model has no parts", function()
			local root = newRoot()
			local entry = newEntryFolder("Hollow", root)
			local model = Instance.new("Model")
			model.Name = "Model"
			model.Parent = entry

			local definitions, rejections = VehicleCatalog.ReadRegistry(root)

			expect(#definitions).to.equal(0)
			expect(findRejection(rejections, "Hollow")).to.be.ok()
		end)

		it("names an ambiguous entry rather than guessing", function()
			local root = newRoot()
			local entry = newEntryFolder("Ambiguous", root)
			newTemplate("HullA", Vector3.new(4, 4, 4), entry)
			newTemplate("HullB", Vector3.new(4, 4, 4), entry)

			local definitions, rejections = VehicleCatalog.ReadRegistry(root)

			expect(#definitions).to.equal(0)
			expect(findRejection(rejections, "Ambiguous")).to.be.ok()
		end)

		it("ignores non-Model, non-Folder children silently", function()
			-- A builder keeping notes beside their vehicles is normal; reporting it would train them
			-- to stop reading the rejection list.
			local root = newRoot()
			newTemplate("Model", Vector3.new(4, 4, 4), newEntryFolder("Blimp", root))
			local note = Instance.new("StringValue")
			note.Name = "Notes"
			note.Parent = root

			local definitions, rejections = VehicleCatalog.ReadRegistry(root)

			expect(#definitions).to.equal(1)
			expect(#rejections).to.equal(0)
		end)

		it("still returns every good entry alongside the bad ones", function()
			local root = newRoot()
			newTemplate("Model", Vector3.new(4, 4, 4), newEntryFolder("Good", root))
			newEntryFolder("Bad", root)

			local definitions, rejections = VehicleCatalog.ReadRegistry(root)

			expect(#definitions).to.equal(1)
			expect(#rejections).to.equal(1)
		end)
	end)

	describe("attributes", function()
		it("defaults every optional field off the folder name", function()
			local root = newRoot()
			newTemplate("Model", Vector3.new(4, 4, 4), newEntryFolder("Blimp", root))

			local definitions = VehicleCatalog.ReadRegistry(root)
			local definition = definitions[1]

			expect(definition.DisplayName).to.equal("Blimp")
			expect(definition.MaxLive).to.equal(VehicleConstants.Limits.MaxLivePerVehicle)
			expect(definition.DespawnOnOwnerLeave).to.equal(true)
		end)

		it("honours the four authored overrides", function()
			local root = newRoot()
			local template = newTemplate("Model", Vector3.new(4, 4, 4), newEntryFolder("Blimp", root))
			template:SetAttribute(VehicleConstants.Attributes.DisplayName, "Sky Barge")
			template:SetAttribute(VehicleConstants.Attributes.Kind, "Airship")
			template:SetAttribute(VehicleConstants.Attributes.MaxLive, 1)
			template:SetAttribute(VehicleConstants.Attributes.DespawnOnOwnerLeave, false)

			local definitions = VehicleCatalog.ReadRegistry(root)
			local definition = definitions[1]

			-- The ID stays the folder name regardless -- renaming the display label must never
			-- invalidate a berth that named the vehicle.
			expect(definition.Id).to.equal("Blimp")
			expect(definition.DisplayName).to.equal("Sky Barge")
			expect(definition.Kind).to.equal("Airship")
			expect(definition.MaxLive).to.equal(1)
			expect(definition.DespawnOnOwnerLeave).to.equal(false)
		end)

		it("ignores a MaxLive somebody typed as zero", function()
			local root = newRoot()
			local template = newTemplate("Model", Vector3.new(4, 4, 4), newEntryFolder("Blimp", root))
			template:SetAttribute(VehicleConstants.Attributes.MaxLive, 0)

			local definitions = VehicleCatalog.ReadRegistry(root)
			expect(definitions[1].MaxLive).to.equal(VehicleConstants.Limits.MaxLivePerVehicle)
		end)

		it("ignores a display name that is only whitespace", function()
			local root = newRoot()
			local template = newTemplate("Model", Vector3.new(4, 4, 4), newEntryFolder("Blimp", root))
			template:SetAttribute(VehicleConstants.Attributes.DisplayName, "   ")

			local definitions = VehicleCatalog.ReadRegistry(root)
			expect(definitions[1].DisplayName).to.equal("Blimp")
		end)

		it("measures the template once, at scan time", function()
			local root = newRoot()
			newTemplate("Model", Vector3.new(10, 20, 30), newEntryFolder("Blimp", root))

			local definitions = VehicleCatalog.ReadRegistry(root)
			expect(definitions[1].Size.X >= 10).to.equal(true)
			expect(definitions[1].Size.Z >= 30).to.equal(true)
		end)
	end)

	describe("SplitList", function()
		it("trims and drops empties", function()
			local parsed = VehicleCatalog.SplitList("Blimp, Skiff ,, Barge")
			expect(#parsed).to.equal(3)
			expect(parsed[1]).to.equal("Blimp")
			expect(parsed[2]).to.equal("Skiff")
			expect(parsed[3]).to.equal("Barge")
		end)

		it("reads nil and empty as no restriction at all", function()
			expect(#VehicleCatalog.SplitList(nil)).to.equal(0)
			expect(#VehicleCatalog.SplitList("")).to.equal(0)
			expect(#VehicleCatalog.SplitList("  ,  ")).to.equal(0)
		end)
	end)

	describe("ordering", function()
		it("sorts by display name so the Dev Menu list is stable across scans", function()
			local root = newRoot()
			newTemplate("Model", Vector3.new(4, 4, 4), newEntryFolder("Zephyr", root))
			newTemplate("Model", Vector3.new(4, 4, 4), newEntryFolder("Albatross", root))

			local definitions = VehicleCatalog.ReadRegistry(root)
			expect(definitions[1].DisplayName).to.equal("Albatross")
			expect(definitions[2].DisplayName).to.equal("Zephyr")
		end)
	end)
end
