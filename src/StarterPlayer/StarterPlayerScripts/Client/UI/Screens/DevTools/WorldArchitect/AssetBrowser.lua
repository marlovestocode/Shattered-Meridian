--!strict
--[[
	WorldArchitect/AssetBrowser.lua

	Owns: the Assets tab -- the searchable library of everything the Place tool can drop (the five primitives, the
	built-in starter templates, the admins' saved templates), filtered by category, favourites or this session's
	recents; the focused asset's live 3D preview and metadata; and the template library's management: save the selection
	as a template, rename, duplicate, overwrite with the selection, delete.

	THE PREVIEW IS THE REAL BUILD. It assembles the asset with Shared/WorldArchitect/ArchitectBuild -- the same function
	the server's materializer uses -- into a ViewportFrame, framed to the asset's bounds, so what the admin sees here is
	exactly what Place will make. A saved template's nodes are fetched on first focus (Intent "FetchTemplate").

	Favourites and recents are per session (the console's Values), not persisted.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local ArchitectBuild = require(ReplicatedStorage.Shared.WorldArchitect.ArchitectBuild)
local ArchitectConstants = require(ReplicatedStorage.Shared.WorldArchitect.ArchitectConstants)
local ArchitectTransform = require(ReplicatedStorage.Shared.WorldArchitect.ArchitectTransform)

local Tokens = require(script.Parent.Parent.Parent.Parent.Tokens)
local Label = require(script.Parent.Parent.Parent.Parent.Components.Label)
local TextField = require(script.Parent.Parent.Parent.Parent.Components.TextField)
local Dropdown = require(script.Parent.Parent.Parent.Parent.Components.Dropdown)
local Kit = require(script.Parent.Parent.DevMenu.Kit)

local Style = require(script.Parent.Style)
local WorldArchitectTypes = require(script.Parent.Types)

type Scope = Fusion.Scope<typeof(Fusion)>
type Handle = WorldArchitectTypes.Handle

local peek = Fusion.peek

type Entry = {
	Key: string,
	Name: string,
	Category: string,
	Detail: string,
	Description: string,
	Tags: { string },
	Saved: boolean,
	Version: number,
	Author: string?,
	Type: string,
	Faction: string,
	Region: string,
	Variant: string,
}

local ROW_HEIGHT = 48
local PREVIEW_HEIGHT = 170

local function primitiveEntries(): { Entry }
	local out: { Entry } = {}
	for _, shape in ArchitectConstants.Shapes do
		local size = WorldArchitectTypes.PrimitiveSize[shape]
		table.insert(out, {
			Key = WorldArchitectTypes.PrimitivePrefix .. shape,
			Name = shape,
			Category = "Primitives",
			Detail = `Primitive · {size.X}×{size.Y}×{size.Z}`,
			Description = "A single part. Shape, size, material and role can all be changed in the inspector.",
			Tags = { "primitive" },
			Saved = false,
			Version = 1,
			Author = nil,
			Type = "Primitive",
			Faction = "Any",
			Region = "Any",
			Variant = "Intact",
		})
	end
	return out
end

local PRIMITIVES = primitiveEntries()

local function entriesOf(templates: { WorldArchitectTypes.TemplateSummary }): { Entry }
	local out = table.clone(PRIMITIVES)
	for _, summary in templates do
		local e = summary.Extent
		local detail = { summary.Category }
		if summary.Faction ~= "Any" then
			table.insert(detail, summary.Faction)
		end
		if summary.Variant == "Ruined" then
			table.insert(detail, "Ruined")
		end
		table.insert(
			detail,
			`{summary.Footprint.X}×{summary.Footprint.Y} mod · {summary.NodeCount} nodes · {math.round(e.Y)} tall`
		)
		table.insert(out, {
			Key = summary.Id,
			Name = summary.Name,
			Category = summary.Category,
			Detail = table.concat(detail, " · "),
			Description = summary.Description,
			Tags = summary.Tags,
			Saved = not summary.Builtin,
			Version = summary.Version,
			Author = summary.Author,
			Type = summary.Type,
			Faction = summary.Faction,
			Region = summary.Region,
			Variant = summary.Variant,
		})
	end
	return out
end

local function matches(entry: Entry, query: string): boolean
	if query == "" then
		return true
	end
	local haystack = string.lower(entry.Name .. " " .. entry.Category .. " " .. table.concat(entry.Tags, " "))
	return string.find(haystack, string.lower(query), 1, true) ~= nil
end

-- A ViewportFrame showing `records`, framed to their bounds from a three-quarter view.
local function previewViewport(scope: Scope, handle: Handle, order: number): Frame
	local camera = scope:New "Camera" {
		FieldOfView = 40,
	} :: Camera
	local viewport = scope:New "ViewportFrame" {
		Name = "Preview",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Tokens.Color.Background,
		BackgroundTransparency = 0.2,
		BorderSizePixel = 0,
		CurrentCamera = camera,
		Ambient = Color3.fromRGB(150, 150, 165),
		LightColor = Color3.fromRGB(220, 225, 240),
		LightDirection = Vector3.new(-1, -2, -0.6),
		[Fusion.Children] = camera,
	} :: ViewportFrame
	local model: Model? = nil
	local function rebuild()
		if model then
			model:Destroy()
			model = nil
		end
		local key = peek(handle.FocusedAsset)
		if key == nil then
			return
		end
		local records = WorldArchitectTypes.AssetRecords(key, peek(handle.TemplateCache) :: any)
		if records == nil then
			return
		end
		local built = ArchitectBuild.Assemble(records, "Preview")
		built.Parent = viewport
		model = built
		local low, high = ArchitectTransform.Bounds(records)
		if low and high then
			local center = (low + high) / 2
			local radius = math.max((high - low).Magnitude / 2, 1)
			local distance = radius / math.tan(math.rad(camera.FieldOfView / 2)) * 1.1
			local direction = Vector3.new(1, 0.75, 1).Unit
			camera.CFrame = CFrame.lookAt(center + direction * distance, center)
		end
	end
	scope:Observer(handle.FocusedAsset):onChange(rebuild)
	scope:Observer(handle.TemplateCache):onChange(rebuild)
	table.insert(scope, function()
		if model then
			model:Destroy()
		end
	end)
	return scope:New "Frame" {
		Name = "PreviewHolder",
		Size = UDim2.new(1, 0, 0, PREVIEW_HEIGHT),
		BackgroundTransparency = 1,
		LayoutOrder = order,
		[Fusion.Children] = {
			viewport,
			scope:New "UIStroke" {
				Color = Tokens.Border.Standard.Color,
				Transparency = Tokens.Border.Standard.Transparency,
			},
		},
	} :: Frame
end

local function AssetBrowser(scope: Scope, handle: Handle, visible: Fusion.UsedAs<boolean>): ScrollingFrame
	local query = scope:Value("")
	-- The library filters. "All" passes everything; a faction filter also keeps faction-less (Any) pieces, which fit
	-- every faction's compound, and a region filter keeps region-less ones.
	local typeFilter = scope:Value("All")
	local factionFilter = scope:Value("All")
	local variantFilter = scope:Value("All")
	local regionFilter = scope:Value("All")
	-- The save form's metadata.
	local newType = scope:Value("Assembly")
	local newFaction = scope:Value("Any")
	local newRegion = scope:Value("Any")
	local newVariant = scope:Value("Intact")
	local category = scope:Value("All")
	local newName = scope:Value("")
	local newCategory = scope:Value("Saved")
	local newDescription = scope:Value("")
	local newTags = scope:Value("")

	local entries = scope:Computed(function(use)
		return entriesOf(use(handle.Templates))
	end)

	local categoryOptions = scope:Computed(function(use)
		local seen: { [string]: boolean } = {}
		local names: { string } = {}
		for _, entry in use(entries) do
			if not seen[entry.Category] then
				seen[entry.Category] = true
				table.insert(names, entry.Category)
			end
		end
		table.sort(names)
		local options = {
			{ Value = "All", Text = "All assets" },
			{ Value = "Favorites", Text = "Favourites" },
			{ Value = "Recent", Text = "Recently placed" },
		}
		for _, name in names do
			table.insert(options, { Value = name, Text = name })
		end
		return options
	end)

	local filtered = scope:Computed(function(use)
		local text = use(query)
		local cat = use(category)
		local favorites = use(handle.Favorites)
		local recent = use(handle.Recent)
		local out: { Entry } = {}
		if cat == "Recent" then
			local byKey: { [string]: Entry } = {}
			for _, entry in use(entries) do
				byKey[entry.Key] = entry
			end
			for _, key in recent do
				if byKey[key] and matches(byKey[key], text) then
					table.insert(out, byKey[key])
				end
			end
			return out
		end
		local kind, faction, variant, region =
			use(typeFilter), use(factionFilter), use(variantFilter), use(regionFilter)
		for _, entry in use(entries) do
			local inCategory = cat == "All" or (cat == "Favorites" and favorites[entry.Key]) or entry.Category == cat
			local passes = (kind == "All" or entry.Type == kind)
				and (faction == "All" or entry.Faction == faction or entry.Faction == "Any")
				and (variant == "All" or entry.Variant == variant)
				and (region == "All" or entry.Region == region or entry.Region == "Any")
			if inCategory and passes and matches(entry, text) then
				table.insert(out, entry)
			end
		end
		return out
	end)

	local focused = scope:Computed(function(use)
		local key = use(handle.FocusedAsset)
		for _, entry in use(entries) do
			if entry.Key == key then
				return entry
			end
		end
		return nil
	end)
	local focusedSaved = scope:Computed(function(use)
		local entry = use(focused)
		return entry ~= nil and entry.Saved
	end)
	local hasFocus = scope:Computed(function(use)
		return use(focused) ~= nil
	end)
	local hasSelection = scope:Computed(function(use)
		return #use(handle.Selection) > 0
	end)

	local rows = scope:ForPairs(filtered, function(_use, inner: Scope, index: number, entry: Entry)
		local isFocused = inner:Computed(function(use)
			return use(handle.FocusedAsset) == entry.Key
		end)
		local isActive = inner:Computed(function(use)
			return use(handle.ActiveAsset) == entry.Key and use(handle.Tool) == "Place"
		end)
		local row = inner:New "TextButton" {
			Name = "Asset",
			Size = UDim2.new(1, 0, 0, ROW_HEIGHT),
			BackgroundColor3 = inner:Computed(function(use)
				return if use(isActive) then Tokens.Color.FactionCelestial else Tokens.Color.AccentPrimary
			end),
			BackgroundTransparency = inner:Computed(function(use)
				return if use(isActive) then 0.8 elseif use(isFocused) then 0.86 else 1
			end),
			AutoButtonColor = false,
			Text = "",
			LayoutOrder = index,
			[Fusion.OnEvent "Activated"] = function()
				if peek(handle.FocusedAsset) == entry.Key then
					handle.Fire({ Kind = "BeginPlace", Asset = entry.Key })
				else
					handle.Fire({ Kind = "FocusAsset", Asset = entry.Key })
				end
			end,
			[Fusion.Children] = {
				Label(inner, {
					Text = entry.Name,
					Scale = "BodyLarge",
					Color = Tokens.Color.TextPrimary,
					Position = UDim2.fromOffset(Tokens.Space.S, 4),
					Size = UDim2.new(1, -64, 0, Tokens.Type.BodyLarge.Size + 4),
					TextTruncate = Enum.TextTruncate.AtEnd,
				}),
				Label(inner, {
					Text = entry.Detail .. (if entry.Saved then " · saved" else ""),
					Scale = "Detail",
					Color = Style.Quiet,
					Position = UDim2.fromOffset(Tokens.Space.S, 26),
					Size = UDim2.new(1, -64, 0, Tokens.Type.Detail.Size + 4),
					TextTruncate = Enum.TextTruncate.AtEnd,
				}),
				inner:New "TextButton" {
					Name = "Favorite",
					AnchorPoint = Vector2.new(1, 0.5),
					Position = UDim2.new(1, -Tokens.Space.S, 0.5, 0),
					Size = UDim2.fromOffset(28, 28),
					BackgroundTransparency = 1,
					Text = inner:Computed(function(use)
						return if use(handle.Favorites)[entry.Key] then "★" else "☆"
					end),
					TextColor3 = Tokens.Color.AccentSecondary,
					TextSize = 18,
					FontFace = Tokens.Type.Body.Face,
					[Fusion.OnEvent "Activated"] = function()
						handle.Fire({ Kind = "ToggleFavorite", Asset = entry.Key })
					end,
				},
				inner:New "Frame" {
					Name = "Rule",
					AnchorPoint = Vector2.new(0, 1),
					Position = UDim2.fromScale(0, 1),
					Size = UDim2.new(1, 0, 0, 1),
					BackgroundColor3 = Tokens.Border.Hairline.Color,
					BackgroundTransparency = Tokens.Border.Hairline.Transparency,
					BorderSizePixel = 0,
				},
			},
		}
		return index, row
	end)

	local function text(value: Fusion.Value<string>, placeholder: string, order: number): Frame
		return Kit.Holder(
			scope,
			placeholder,
			order,
			TextField(scope, {
				Text = value,
				PlaceholderText = placeholder,
				MaxLength = ArchitectConstants.Limits.MaxDescriptionLength,
				Size = UDim2.new(1, 0, 0, Kit.ButtonHeight),
			})
		)
	end

	local function tagsOf(raw: string): { string }
		local out: { string } = {}
		for tag in string.gmatch(raw, "[^,]+") do
			local trimmed = string.match(tag, "^%s*(.-)%s*$") or ""
			if trimmed ~= "" and #out < ArchitectConstants.Limits.MaxTags then
				table.insert(out, string.sub(trimmed, 1, ArchitectConstants.Limits.MaxTagLength))
			end
		end
		return out
	end

	local function meta(): { [string]: any }
		return {
			Name = peek(newName),
			Category = if peek(newCategory) == "" then "Saved" else peek(newCategory),
			Description = peek(newDescription),
			Tags = tagsOf(peek(newTags)),
			Type = peek(newType),
			Faction = peek(newFaction),
			Region = peek(newRegion),
			Variant = peek(newVariant),
		}
	end

	local function chips(options: { { string } }): { Kit.Option }
		local out: { Kit.Option } = {}
		for _, option in options do
			table.insert(out, { Value = option[1], Text = option[2] })
		end
		return out
	end
	local regionOptions: { Dropdown.DropdownOption } = { { Value = "All", Text = "Every region" } }
	local formRegionOptions: { Dropdown.DropdownOption } = {}
	for _, region in ArchitectConstants.Regions do
		local label = (ArchitectConstants.RegionNames :: any)[region]
		table.insert(formRegionOptions, { Value = region, Text = label })
		if region ~= "Any" then
			table.insert(regionOptions, { Value = region, Text = label })
		end
	end

	-- Fill the form from the focused asset so Rename / Duplicate start from what is there.
	scope:Observer(handle.FocusedAsset):onChange(function()
		local entry = peek(focused)
		if entry then
			newName:set(if entry.Saved then entry.Name else entry.Name .. " (copy)")
			newCategory:set(if entry.Category == "Primitives" then "Saved" else entry.Category)
			newDescription:set(entry.Description)
			newTags:set(table.concat(entry.Tags, ", "))
			if entry.Type ~= "Primitive" then
				newType:set(entry.Type)
				newFaction:set(entry.Faction)
				newRegion:set(entry.Region)
				newVariant:set(entry.Variant)
			end
		end
	end)

	return Kit.Page(scope, "Assets", visible, {
		text(query, "Search assets, categories, tags", 1),
		-- One dropdown per distinct option list: saving a template in a new category rebuilds it.
		Kit.Holder(
			scope,
			"Category",
			2,
			scope:ForValues(
				scope:Computed(function(use)
					return { use(categoryOptions) }
				end),
				function(_use, inner: Scope, options: { Dropdown.DropdownOption })
					return Dropdown.Mount(inner, {
						Label = "Show",
						Options = options,
						Value = category,
						OnChanged = function(value: string)
							category:set(value)
						end,
					})
				end
			) :: any
		),
		Kit.Segmented(scope, {
			Options = chips({
				{ "All", "ALL" },
				{ "Kit", "KIT" },
				{ "Assembly", "BUILD" },
				{ "Landmark", "MARK" },
				{ "Dressing", "DRESS" },
			}),
			Selected = typeFilter,
			OnPick = function(value: string)
				typeFilter:set(value)
			end,
			Order = 3,
		}),
		Kit.Segmented(scope, {
			Options = chips({
				{ "All", "ALL" },
				{ "Celestial", "CELEST" },
				{ "Demonic", "DEMON" },
				{ "Unbound", "UNBOUND" },
			}),
			Selected = factionFilter,
			OnPick = function(value: string)
				factionFilter:set(value)
			end,
			Order = 4,
		}),
		Kit.Segmented(scope, {
			Options = chips({ { "All", "BOTH" }, { "Intact", "INTACT" }, { "Ruined", "RUINS" } }),
			Selected = variantFilter,
			OnPick = function(value: string)
				variantFilter:set(value)
			end,
			Order = 5,
		}),
		Kit.Holder(
			scope,
			"Region",
			6,
			Dropdown.Mount(scope, {
				Label = "Region",
				Options = regionOptions,
				Value = regionFilter,
				OnChanged = function(value: string)
					regionFilter:set(value)
				end,
			})
		),
		Style.Prose(scope, "Click an asset to preview it, click it again to place it. ★ keeps it in Favourites.", 7),
		Kit.Group(scope, 8, { rows :: any }, nil, 0),
		Kit.Heading(scope, "SELECTED ASSET", 10, hasFocus),
		previewViewport(scope, handle, 11),
		Style.Prose(
			scope,
			scope:Computed(function(use)
				local entry = use(focused)
				if entry == nil then
					return ""
				end
				local by = if entry.Author then ` · by {entry.Author}` else ""
				local tags = if #entry.Tags > 0 then `\nTags: {table.concat(entry.Tags, ", ")}` else ""
				return `{entry.Name} — {entry.Detail} · v{entry.Version}{by}\n{entry.Description}{tags}`
			end),
			12,
			hasFocus,
			Tokens.Color.TextSecondary
		),
		Kit.Button(scope, {
			Text = "PLACE",
			Order = 13,
			Visible = hasFocus,
			OnActivated = function()
				local entry = peek(focused)
				if entry then
					handle.Fire({ Kind = "BeginPlace", Asset = entry.Key })
				end
			end,
		}),
		Kit.Heading(scope, "TEMPLATE LIBRARY", 20),
		Style.Prose(
			scope,
			"Name the template here, then save the current selection as a new template, or apply the name to the focused asset.",
			21
		),
		text(newName, "Template name", 22),
		text(newCategory, "Category", 23),
		text(newDescription, "Description", 24),
		text(newTags, "Tags, comma separated", 25),
		Kit.Segmented(scope, {
			Options = chips({
				{ "Kit", "KIT" },
				{ "Assembly", "BUILD" },
				{ "Landmark", "MARK" },
				{ "Dressing", "DRESS" },
			}),
			Selected = newType,
			OnPick = function(value: string)
				newType:set(value)
			end,
			Order = 26,
		}),
		Kit.Segmented(scope, {
			Options = chips({
				{ "Any", "ANY" },
				{ "Celestial", "CELEST" },
				{ "Demonic", "DEMON" },
				{ "Unbound", "UNBOUND" },
			}),
			Selected = newFaction,
			OnPick = function(value: string)
				newFaction:set(value)
			end,
			Order = 27,
		}),
		Kit.Segmented(scope, {
			Options = chips({ { "Intact", "INTACT" }, { "Ruined", "RUINED" } }),
			Selected = newVariant,
			OnPick = function(value: string)
				newVariant:set(value)
			end,
			Order = 28,
		}),
		Kit.Holder(
			scope,
			"FormRegion",
			29,
			Dropdown.Mount(scope, {
				Label = "Region",
				Options = formRegionOptions,
				Value = newRegion,
				OnChanged = function(value: string)
					newRegion:set(value)
				end,
			})
		),
		Kit.Button(scope, {
			Text = "SAVE SELECTION AS NEW TEMPLATE",
			Order = 30,
			Disabled = scope:Computed(function(use)
				return not use(hasSelection) or use(newName) == ""
			end),
			OnActivated = function()
				handle.Fire({ Kind = "SaveTemplate", Meta = meta() })
			end,
		}),
		Kit.Row(scope, 31, {
			Kit.Button(scope, {
				Text = "DUPLICATE AS NEW",
				Order = 1,
				Size = Kit.Cell(2),
				Disabled = scope:Computed(function(use)
					local entry = use(focused)
					return entry == nil or entry.Category == "Primitives" or use(newName) == ""
				end),
				OnActivated = function()
					local entry = peek(focused)
					if entry then
						handle.Fire({ Kind = "DuplicateTemplate", Id = entry.Key, Meta = meta() })
					end
				end,
			}),
			Kit.Button(scope, {
				Text = "RENAME / RETAG",
				Order = 2,
				Size = Kit.Cell(2),
				Disabled = scope:Computed(function(use)
					return not use(focusedSaved) or use(newName) == ""
				end),
				OnActivated = function()
					local entry = peek(focused)
					if entry then
						handle.Fire({ Kind = "RenameTemplate", Id = entry.Key, Meta = meta() })
					end
				end,
			}),
		}, hasFocus),
		Kit.Row(scope, 32, {
			Kit.Armed(scope, {
				Idle = "OVERWRITE WITH SELECTION",
				Armed = "CONFIRM OVERWRITE",
				Order = 1,
				Size = Kit.Cell(2),
				Disabled = scope:Computed(function(use)
					return not use(hasSelection)
				end),
				OnConfirm = function()
					local entry = peek(focused)
					if entry then
						handle.Fire({ Kind = "SaveTemplate", ReplaceId = entry.Key, Meta = meta() })
					end
				end,
			}),
			Kit.Armed(scope, {
				Idle = "DELETE TEMPLATE",
				Armed = "CONFIRM DELETE",
				Order = 2,
				Size = Kit.Cell(2),
				OnConfirm = function()
					local entry = peek(focused)
					if entry then
						handle.Fire({ Kind = "DeleteTemplate", Id = entry.Key })
					end
				end,
			}),
		}, focusedSaved),
	})
end

return AssetBrowser
