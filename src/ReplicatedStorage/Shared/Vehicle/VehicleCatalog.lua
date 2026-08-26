--!strict
--[[
	VehicleCatalog.lua

	Owns: turning what a builder put in the registry folder into a list of validated
	VehicleTypes.VehicleDefinition -- resolving which Model is the template, reading the four optional
	tuning Attributes off it, measuring it once, and saying WHY each rejected entry was rejected.
	Nothing here clones, parents, tags or spawns anything; it is the whole read side of
	VehicleConstants.lua's authoring contract and nothing else.

	SEPARATE FROM VehicleConstants.lua for the same reason BlimpTagging.lua is separate from
	BlimpConstants.lua: the constants file is the contract a BUILDER reads and has to stay readable as
	one. The moment resolution logic lives beside it, the folder shape stops being findable in the
	noise. Same split, same reason.

	REJECTIONS ARE RETURNED, NOT LOGGED HERE, and that is the difference between this being a
	debugging aid and being a dead end. A builder who drops a folder into the registry and sees
	nothing appear in the Dev Menu has no reason to go looking in a server log -- so every rejected
	entry comes back as a { Path, Reason } pair that VehicleManager both logs AND puts in the tab,
	next to the catalog it is missing from. This function is the only place that can tell the
	difference between "empty folder", "no Model inside", "Model with no parts" and "two Models and
	neither is named Model", and throwing that away at the point of detection is how a system ends up
	with one useless "no vehicles found" message.

	READS ATTRIBUTES OFF THE TEMPLATE, NEVER OFF THE FOLDER. One place to look, and it survives the
	folder-less shape (Vehicles/Blimp being the Model itself) with no branching. A builder who sets
	VehicleDisplayName on the folder gets the default, which is the folder name -- i.e. exactly what
	they were trying to say -- so the failure mode of guessing wrong here is silent agreement.

	Does not own: where the registry root IS (Server/Systems/VehicleManager.lua resolves that against
	VehicleConstants.Registry.SearchOrder -- this function is handed a root and never looks one up),
	the spawn itself, or berths (Server/Vehicles/VehicleBerths.lua).
]]

local VehicleConstants = require(script.Parent.VehicleConstants)
local VehicleTypes = require(script.Parent.VehicleTypes)

local VehicleCatalog = {}

type VehicleDefinition = VehicleTypes.VehicleDefinition
type RegistryRejection = VehicleTypes.RegistryRejection

-- Reads one optional string Attribute, treating an empty/whitespace-only string as absent. A builder
-- who clears a text field leaves "" behind rather than nil, and a vehicle displayed as an empty row is
-- a worse answer than one displayed under its folder name.
local function stringAttribute(instance: Instance, name: string): string?
	local raw = instance:GetAttribute(name)
	if typeof(raw) ~= "string" then
		return nil
	end
	local trimmed = string.match(raw :: string, "^%s*(.-)%s*$")
	if trimmed == nil or #trimmed == 0 then
		return nil
	end
	return trimmed
end

-- Reads one optional positive-integer Attribute. Non-numbers, non-finite values and anything below 1
-- fall back rather than being honoured: an Attribute is a text field a person types into, and a
-- vehicle with MaxLive 0 is one nobody can ever spawn, which produces no error anywhere.
local function positiveIntegerAttribute(instance: Instance, name: string, fallback: number): number
	local raw = instance:GetAttribute(name)
	if typeof(raw) ~= "number" then
		return fallback
	end
	local value = raw :: number
	if value ~= value or value == math.huge or value < 1 then
		return fallback
	end
	return math.floor(value)
end

local function booleanAttribute(instance: Instance, name: string, fallback: boolean): boolean
	local raw = instance:GetAttribute(name)
	if typeof(raw) ~= "boolean" then
		return fallback
	end
	return raw :: boolean
end

-- Splits a comma-separated Attribute into trimmed, non-empty entries. Shared with VehicleBerths, which
-- parses the berth accept-list the same way -- one parser so "Blimp, Skiff" and "Blimp,Skiff" can
-- never mean different things in two places.
function VehicleCatalog.SplitList(raw: string?): { string }
	local out: { string } = {}
	if raw == nil then
		return out
	end
	for piece in string.gmatch(raw, "[^,]+") do
		local trimmed = string.match(piece, "^%s*(.-)%s*$")
		if trimmed ~= nil and #trimmed > 0 then
			table.insert(out, trimmed)
		end
	end
	return out
end

-- Which Model under `entry` is the template, or nil plus the reason there isn't one. Three shapes are
-- accepted, in this order, and the order is the whole rule:
--   1. `entry` IS a Model -> it is the template. The folder-less shape.
--   2. exactly one Model child -> that one, whatever it is called.
--   3. several Model children -> the one named Registry.PreferredTemplateName, if present.
-- Only descendants ONE level down are considered. Deliberate: a Blimp's own gondola is a Model inside
-- the hull Model, and a recursive search would find it and cheerfully offer to spawn a detached
-- gondola.
local function resolveTemplate(entry: Instance): (Model?, string?)
	if entry:IsA("Model") then
		return entry :: Model, nil
	end

	local models: { Model } = {}
	for _, child in entry:GetChildren() do
		if child:IsA("Model") then
			table.insert(models, child :: Model)
		end
	end

	if #models == 0 then
		return nil, "No Model inside this folder"
	end
	if #models == 1 then
		return models[1], nil
	end

	for _, model in models do
		if model.Name == VehicleConstants.Registry.PreferredTemplateName then
			return model, nil
		end
	end

	return nil,
		string.format(
			"%d Models inside this folder and none is named %s",
			#models,
			VehicleConstants.Registry.PreferredTemplateName
		)
end

-- True when `model` has at least one BasePart anywhere beneath it. A Model of nothing but Attachments
-- and Scripts clones and parents perfectly happily and then produces an invisible, unspawnable,
-- un-pivotable nothing in the world -- which reads as "spawn is broken", not as "that model is empty".
local function hasAnyPart(model: Model): boolean
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			return true
		end
	end
	return false
end

-- Every vehicle under `root`, plus every entry that could not become one and why. Sorted by display
-- name so the Dev Menu's list order is stable across scans rather than following Explorer order,
-- which changes when a builder renames anything.
function VehicleCatalog.ReadRegistry(root: Instance): ({ VehicleDefinition }, { RegistryRejection })
	local definitions: { VehicleDefinition } = {}
	local rejections: { RegistryRejection } = {}

	for _, entry in root:GetChildren() do
		if not entry:IsA("Model") and not entry:IsA("Folder") then
			-- Not a rejection worth reporting: a builder keeping a Script, a Configuration or a note
			-- alongside their vehicles is normal, and reporting it would train them to ignore the list.
			continue
		end

		local template, templateFailure = resolveTemplate(entry)
		if not template then
			table.insert(rejections, {
				Path = entry.Name,
				Reason = templateFailure or "No template Model",
			})
			continue
		end

		if not hasAnyPart(template) then
			table.insert(rejections, {
				Path = entry.Name,
				Reason = "Template Model contains no BasePart",
			})
			continue
		end

		local _, size = template:GetBoundingBox()

		table.insert(definitions, {
			-- The ENTRY's name, never the template's -- see VehicleConstants' authoring contract. Every
			-- vehicle in the folder-ful shape has a template called "Model", so keying on the template
			-- would collapse the whole registry to one entry.
			Id = entry.Name,
			DisplayName = stringAttribute(template, VehicleConstants.Attributes.DisplayName) or entry.Name,
			Kind = stringAttribute(template, VehicleConstants.Attributes.Kind) or "Vehicle",
			Template = template,
			Size = size,
			MaxLive = positiveIntegerAttribute(
				template,
				VehicleConstants.Attributes.MaxLive,
				VehicleConstants.Limits.MaxLivePerVehicle
			),
			DespawnOnOwnerLeave = booleanAttribute(template, VehicleConstants.Attributes.DespawnOnOwnerLeave, true),
		})
	end

	table.sort(definitions, function(a, b)
		if a.DisplayName == b.DisplayName then
			return a.Id < b.Id
		end
		return a.DisplayName < b.DisplayName
	end)
	table.sort(rejections, function(a, b)
		return a.Path < b.Path
	end)

	return definitions, rejections
end

return VehicleCatalog
