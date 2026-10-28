--!strict
--[[
	WorldArchitect/BuildPanel.lua

	Owns: the Build tab -- procedural generation's controls (type, template pack, seed, area, turn, spacing, density,
	rotation jitter, ground following) and its preview-to-commit flow: Preview asks the server for the seeded layout and
	the viewport draws it as ghosts; Reroll draws a new seed and previews again; Cancel clears the ghosts; Commit asks
	the server to build it, which re-runs the SAME layout server-side rather than trusting the ghosts.

	The area centres on the editor camera's focus at the moment Preview is pressed, and the preview remembers that
	centre, so Commit builds exactly what was previewed even if the camera has moved since.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local ArchitectConstants = require(ReplicatedStorage.Shared.WorldArchitect.ArchitectConstants)
local ArchitectGenerator = require(ReplicatedStorage.Shared.WorldArchitect.ArchitectGenerator)

local Tokens = require(script.Parent.Parent.Parent.Parent.Tokens)
local Dropdown = require(script.Parent.Parent.Parent.Parent.Components.Dropdown)
local NumericField = require(script.Parent.Parent.Parent.Parent.Components.NumericField)
local Toggle = require(script.Parent.Parent.Parent.Parent.Components.Toggle)
local Kit = require(script.Parent.Parent.DevMenu.Kit)

local Style = require(script.Parent.Style)
local WorldArchitectTypes = require(script.Parent.Types)

type Scope = Fusion.Scope<typeof(Fusion)>
type Handle = WorldArchitectTypes.Handle

local peek = Fusion.peek
local Gen = ArchitectConstants.Generation

local DESCRIPTIONS: { [string]: string } = {
	SectCompound = "A walled sect compound: wall bays with leak windows, corner piers, a moon gate on the front axis, the "
		.. "main hall at the back, side halls facing the courtyard, a bell tower and a lantern-lined path. Width and depth "
		.. "of 64 or more; 128 fits everything.",
	RuinedQuarter = "The same compound after the Shattering: most pieces their ruins, wall bays missing, lanterns become "
		.. "rubble and fallen pillars, a Meridian shard broken through the courtyard.",
	Ruins = "Sect ruins scattered across the area, spaced so nothing overlaps.",
	Outpost = "A palisade perimeter with corner posts and a gate on the front edge, camp pieces inside.",
	Pathway = "A wandering flagstone path along the area's width, markers alternating along its sides.",
	Grove = "Trees, stones and shards gathered into one to three clumps.",
}

local function BuildPanel(scope: Scope, handle: Handle, visible: Fusion.UsedAs<boolean>): ScrollingFrame
	local function setting<T>(key: string): Fusion.Computed<T>
		return scope:Computed(function(use)
			return (use(handle.Generation) :: any)[key]
		end)
	end
	local function set(key: string, value: any): ()
		local updated = table.clone(peek(handle.Generation)) :: any
		updated[key] = value
		handle.Generation:set(updated)
		-- A setting changed under a preview: the ghosts no longer show what Commit would build.
		if peek(handle.GenerationPreview) then
			handle.Fire({ Kind = "CancelPreview", Quiet = true })
		end
	end
	local function number(
		label: string,
		key: string,
		order: number,
		min: number,
		max: number,
		steps: { number },
		decimals: number,
		slider: boolean?
	): Frame
		return Kit.Holder(
			scope,
			key,
			order,
			NumericField.Mount(scope, {
				Label = label,
				Value = setting(key),
				Min = min,
				Max = max,
				Steps = steps,
				Decimals = decimals,
				Slider = slider,
				Compact = true,
				OnChanged = function(value: number)
					set(key, value)
				end,
			})
		)
	end

	local TYPE_NAMES: { [string]: string } = {
		SectCompound = "Sect Compound",
		RuinedQuarter = "Ruined Quarter",
		Ruins = "Ruins (scatter)",
		Outpost = "Outpost",
		Pathway = "Pathway",
		Grove = "Grove",
	}
	local typeOptions: { Dropdown.DropdownOption } = {}
	for _, kind in Gen.Types do
		table.insert(typeOptions, { Value = kind, Text = TYPE_NAMES[kind] or kind })
	end
	local factionOptions: { Kit.Option } = {
		{ Value = "Celestial", Text = "CELESTIAL" },
		{ Value = "Demonic", Text = "DEMONIC" },
		{ Value = "Unbound", Text = "UNBOUND" },
	}
	local composing = scope:Computed(function(use)
		local kind = use(handle.Generation).Type
		return kind == "SectCompound" or kind == "RuinedQuarter"
	end)
	local packOptions: { Dropdown.DropdownOption } = { { Value = "", Text = "The type's own pack" } }
	for _, name in ArchitectGenerator.PackNames do
		table.insert(packOptions, { Value = name, Text = name })
	end

	local preview = handle.GenerationPreview
	local hasPreview = scope:Computed(function(use)
		return use(preview) ~= nil
	end)
	local previewText = scope:Computed(function(use)
		local p = use(preview)
		if p == nil then
			return ""
		end
		local refused: { string } = {}
		for reason, count in p.Refused do
			table.insert(refused, `{reason} {count}`)
		end
		table.sort(refused)
		local refusedText = if #refused > 0 then `\nRefused: {table.concat(refused, ", ")}` else ""
		local budget = if p.OverBudget
			then "\nOver the node budget: commit will be refused. Lower density or area."
			else ""
		return `Placed {p.Placed} of {p.Requested} · {p.NodeCount} nodes{refusedText}{budget}`
	end)

	return Kit.Page(scope, "Build", visible, {
		Kit.Heading(scope, "GENERATOR", 1),
		Kit.Holder(
			scope,
			"Type",
			2,
			Dropdown.Mount(scope, {
				Label = "Generator",
				Options = typeOptions,
				Value = setting("Type"),
				OnChanged = function(kind: string)
					set("Type", kind)
				end,
			})
		),
		Kit.Segmented(scope, {
			Options = factionOptions,
			Selected = setting("Faction"),
			OnPick = function(faction: string)
				set("Faction", faction)
			end,
			Order = 3,
			Visible = composing,
		}),
		Style.Prose(
			scope,
			scope:Computed(function(use)
				return DESCRIPTIONS[use(handle.Generation).Type] or ""
			end),
			4
		),
		Kit.Holder(
			scope,
			"Pack",
			5,
			Dropdown.Mount(scope, {
				Label = "Template pack",
				Options = packOptions,
				Value = setting("Pack"),
				OnChanged = function(value: string)
					set("Pack", value)
				end,
			})
		),
		Kit.Heading(scope, "LAYOUT", 10),
		number("Seed", "Seed", 11, 0, 2 ^ 31 - 1, { 1, 100 }, 0, false),
		number("Width", "AreaX", 12, Gen.MinArea, Gen.MaxArea, { 4, 16 }, 0),
		number("Depth", "AreaZ", 13, Gen.MinArea, Gen.MaxArea, { 4, 16 }, 0),
		number("Turn", "Yaw", 14, -180, 180, { 5, 45 }, 0),
		number("Spacing", "Spacing", 15, Gen.MinSpacing, Gen.MaxSpacing, { 1, 4 }, 1),
		number("Density", "Density", 16, 0, 1, { 0.05, 0.25 }, 2),
		number("Rotation jitter", "RotationJitter", 17, 0, 180, { 5, 45 }, 0),
		Kit.Holder(
			scope,
			"FollowGround",
			18,
			Toggle(scope, {
				Label = "Rest on the ground",
				Value = setting("FollowGround"),
				Hint = "Each placement drops to the ground under it; a point with no ground is refused.",
				OnChanged = function(value: boolean)
					set("FollowGround", value)
				end,
			})
		),
		Style.Prose(
			scope,
			"The area centres on the camera's focus. Spawn pads and existing construction are kept clear.",
			19
		),
		Kit.Row(scope, 20, {
			Kit.Button(scope, {
				Text = "PREVIEW",
				Order = 1,
				Size = Kit.Cell(2),
				OnActivated = function()
					handle.Fire({ Kind = "PreviewGeneration" })
				end,
			}),
			Kit.Button(scope, {
				Text = "REROLL",
				Order = 2,
				Size = Kit.Cell(2),
				OnActivated = function()
					set("Seed", math.random(0, 2 ^ 31 - 1))
					handle.Fire({ Kind = "PreviewGeneration" })
				end,
			}),
		}),
		Style.Prose(scope, previewText, 21, hasPreview, Tokens.Color.TextSecondary),
		Kit.Row(scope, 22, {
			Kit.Button(scope, {
				Text = "CANCEL",
				Order = 1,
				Size = Kit.Cell(2),
				OnActivated = function()
					handle.Fire({ Kind = "CancelPreview" })
				end,
			}),
			Kit.Button(scope, {
				Text = "COMMIT",
				Order = 2,
				Size = Kit.Cell(2),
				Disabled = scope:Computed(function(use)
					local p = use(preview)
					return p == nil or p.Placed == 0 or p.OverBudget
				end),
				OnActivated = function()
					handle.Fire({ Kind = "CommitGeneration" })
				end,
			}),
		}, hasPreview),
	})
end

return BuildPanel
