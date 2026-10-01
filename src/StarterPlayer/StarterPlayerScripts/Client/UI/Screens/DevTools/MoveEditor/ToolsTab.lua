--!strict
--[[
	MoveEditor/ToolsTab.lua

	Owns: the Tools tab -- the tools that act on MORE than the open move's inputs: bulk-scaling its whole
	group, its saved version history, and (in Studio) writing it into the game's source. The other four
	tabs are properties of one move; nothing here is, which is why it is its own tab rather than more
	fields on those.

	BULK scales the open move's GROUP -- the browser section it files under (a weapon, "Arts", a custom
	category) -- optionally narrowed to one stage of a weapon's string. The percentages turn into
	multipliers (1 + p/100) and the server applies them to every move's CURRENT live values, so applying
	twice compounds; the fields reset to 0 after each apply so a second press is a decision, not an
	accident. Both applies arm first (Fields.ArmedButton): they touch many moves at once.

	HISTORY lists the open move's saved versions (fetched on demand -- a DataStore read per selection
	would be wasted on every move nobody asks about), each with the server's summary of what it changed
	against the version before it. Restore makes a version LIVE, not saved -- the same review-then-Save
	contract as every other edit here -- and arms first, because it replaces the draft.

	SOURCE (Studio only -- the section is not even built in a live server, whose remotes would refuse
	NotStudio anyway) writes the open move into the game's source through scripts/move-writer.py, removes
	it from there, or shows the text so it can be copied by hand when the helper is not running.

	Does not own: what a bulk apply does (the server's MoveEditor_BulkScale, through the driver), which
	moves are in a group (the server decides; the stage list here is only what the entries say is
	present), or the result (the driver writes it into the entries and the footer).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Constants = require(ReplicatedStorage.Shared.Constants)
local MoveEditorTypes = require(ReplicatedStorage.Shared.Authoring.MoveEditorTypes)

local Tokens = require(script.Parent.Parent.Parent.Parent.Tokens)
local Button = require(script.Parent.Parent.Parent.Parent.Components.Button)
local Label = require(script.Parent.Parent.Parent.Parent.Components.Label)
local NumericFieldModule = require(script.Parent.Parent.Parent.Parent.Components.NumericField)
local Stack = require(script.Parent.Parent.Parent.Parent.Components.Stack)

local Fields = require(script.Parent.Fields)

local peek = Fusion.peek

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>
type MoveEntry = MoveEditorTypes.MoveEntry

export type ToolsContext = {
	Entry: UsedAs<MoveEntry?>,
	Entries: UsedAs<{ MoveEntry }>,
	OnBulkScale: (request: MoveEditorTypes.BulkScaleRequest) -> (),
	-- The open move's saved versions, newest first, once loaded (history is fetched on demand, not on
	-- every selection); nil until then.
	History: UsedAs<{ MoveEditorTypes.HistoryVersion }?>,
	OnLoadHistory: () -> (),
	OnRestoreVersion: (version: number) -> (),
	-- Studio only. Export's text, once asked for; nil hides the box.
	ExportText: UsedAs<string?>,
	OnWriteToSource: () -> (),
	OnRemoveFromSource: () -> (),
	OnExportSource: () -> (),
}

-- What the bulk section offers, in the order it lists them.
local BULK_FIELDS: { { Field: string, Label: string } } = {
	{ Field = "WindupSeconds", Label = "Windup" },
	{ Field = "ActiveSeconds", Label = "Active" },
	{ Field = "RecoverySeconds", Label = "Recovery" },
	{ Field = "Cooldown", Label = "Cooldown" },
	{ Field = "Damage", Label = "Damage" },
	{ Field = "PostureDamage", Label = "Posture damage" },
}

-- In percent. The server clamps the resulting multiplier to Constants.MoveEditor.BulkScaleLimits
-- (0.25x..4x), which is exactly this range.
local PERCENT_RANGE = { Min = -75, Max = 300 }
local ALL_STAGES = "All"

local function ToolsTab(scope: Scope, tools: ToolsContext, visible: UsedAs<boolean>): ScrollingFrame
	local percents: { [string]: Fusion.Value<number> } = {}
	for _, spec in BULK_FIELDS do
		percents[spec.Field] = scope:Value(0)
	end
	local stage = scope:Value(ALL_STAGES)

	local group = scope:Computed(function(use): string?
		local entry = use(tools.Entry)
		return if entry then entry.Group else nil
	end)
	-- The stages the group's entries carry, in the order the browser lists them (roster order), with
	-- "All" first. Only Default weapon moves carry a stage, so a custom group offers "All" alone.
	local stages = scope:Computed(function(use): { string }
		local result = { ALL_STAGES }
		local name = use(group)
		for _, entry in use(tools.Entries) do
			if entry.Group == name and entry.Stage and not table.find(result, entry.Stage) then
				table.insert(result, entry.Stage)
			end
		end
		return result
	end)
	-- A stage the newly opened group does not have falls back to All.
	scope:Observer(stages):onChange(function()
		if not table.find(peek(stages), peek(stage)) then
			stage:set(ALL_STAGES)
		end
	end)

	local nothingToScale = scope:Computed(function(use)
		if use(group) == nil then
			return true
		end
		for _, value in percents do
			if use(value) ~= 0 then
				return false
			end
		end
		return true
	end)

	local function apply(save: boolean): ()
		local name = peek(group)
		if not name then
			return
		end
		local scale: MoveEditorTypes.BulkScaleFactors = {}
		for field, value in percents do
			local percent = peek(value)
			if percent ~= 0 then
				(scale :: any)[field] = 1 + percent / 100
			end
		end
		local chosen = peek(stage)
		tools.OnBulkScale({
			Group = name,
			Stage = if chosen == ALL_STAGES then nil else chosen,
			Scale = scale,
			Save = save,
		})
		for _, value in percents do
			value:set(0)
		end
	end

	local stageButtons = scope:ForPairs(stages, function(_use, innerScope: Scope, index: number, name: string)
		return index,
			Button(innerScope, {
				Text = innerScope:Computed(function(use)
					return if use(stage) == name then `[{name}]` else name
				end),
				Size = UDim2.fromOffset(if #name > 6 then 96 else 64, Tokens.Control.StepButtonSize),
				LayoutOrder = index,
				OnActivated = function()
					stage:set(name)
				end,
			})
	end)

	local children: { Instance } = {
		Fields.Heading(scope, "BULK", 1),
		Fields.Fact(
			scope,
			"Group",
			scope:Computed(function(use)
				return use(group) or "-"
			end),
			2
		),
		Fields.Prose(
			scope,
			"Scales every move in this group by the percentages below. It multiplies each move's CURRENT live values, so applying twice compounds; the fields clear after each apply.",
			3
		),
		Stack.Row(scope, {
			Name = "Stages",
			Size = UDim2.new(1, 0, 0, Tokens.Control.StepButtonSize),
			Gap = Tokens.Space.XS,
			LayoutOrder = 4,
			Children = { stageButtons :: any },
		}),
	}
	for index, spec in BULK_FIELDS do
		table.insert(
			children,
			NumericFieldModule.Mount(scope, {
				Label = spec.Label,
				Value = percents[spec.Field],
				Min = PERCENT_RANGE.Min,
				Max = PERCENT_RANGE.Max,
				Steps = { 1, 5 },
				Decimals = 0,
				Unit = "%",
				LayoutOrder = 10 + index,
				OnChanged = function(value: number)
					percents[spec.Field]:set(value)
				end,
			})
		)
	end
	table.insert(
		children,
		Stack.Row(scope, {
			Name = "BulkApply",
			Size = UDim2.new(1, 0, 0, Tokens.Control.StepButtonSize),
			Gap = Tokens.Space.S,
			LayoutOrder = 30,
			Children = {
				Fields.ArmedButton(scope, {
					Idle = "Apply (live)",
					Armed = "Apply? Again",
					LayoutOrder = 1,
					Disabled = nothingToScale,
					OnConfirm = function()
						apply(false)
					end,
				}),
				Fields.ArmedButton(scope, {
					Idle = "Apply & Save",
					Armed = "Save all? Again",
					LayoutOrder = 2,
					Disabled = nothingToScale,
					OnConfirm = function()
						apply(true)
					end,
				}),
			},
		})
	)

	-- History ----------------------------------------------------------------------------------------

	local loaded = scope:Computed(function(use)
		return use(tools.History) ~= nil
	end)
	local versions = scope:Computed(function(use): { MoveEditorTypes.HistoryVersion }
		return use(tools.History) or {}
	end)
	local noVersions = scope:Computed(function(use)
		return use(loaded) and #use(versions) == 0
	end)
	local versionRows = scope:ForPairs(
		versions,
		function(_use, innerScope: Scope, index: number, version: MoveEditorTypes.HistoryVersion)
			return index,
				Stack.New(innerScope, {
					Name = `Version{version.Version}`,
					Size = UDim2.fromScale(1, 0),
					AutomaticSize = Enum.AutomaticSize.Y,
					Gap = Tokens.Space.XS,
					LayoutOrder = 50 + index,
					Children = {
						Stack.Row(innerScope, {
							Name = "Head",
							Size = UDim2.new(1, 0, 0, Tokens.Control.StepButtonSize),
							Gap = Tokens.Space.S,
							LayoutOrder = 1,
							Children = {
								Label(innerScope, {
									Text = `v{version.Version}  ·  {os.date("%Y-%m-%d %H:%M", version.SavedAt)}  ·  {version.AdminName}`,
									Scale = "NumeralSmall",
									Color = Tokens.Color.TextPrimary,
									Size = UDim2.new(1, -120, 1, 0),
									TextTruncate = Enum.TextTruncate.AtEnd,
									LayoutOrder = 1,
								}),
								Fields.ArmedButton(innerScope, {
									Idle = "Restore",
									Armed = "Restore? Again",
									LayoutOrder = 2,
									Size = UDim2.new(0, 112, 1, 0),
									OnConfirm = function()
										tools.OnRestoreVersion(version.Version)
									end,
								}),
							},
						}),
						Label(innerScope, {
							Text = version.Summary,
							Scale = "Detail",
							Color = Tokens.Color.TextSecondary,
							Size = UDim2.fromScale(1, 0),
							AutoHeight = true,
							TextWrapped = true,
							LineHeight = Tokens.Leading.Prose,
							LayoutOrder = 2,
						}),
					},
				})
		end
	)

	table.insert(children, Fields.Heading(scope, "HISTORY", 40))
	table.insert(
		children,
		Fields.Prose(
			scope,
			`The last {Constants.MoveEditor.HistoryDepth} saves of this move. Restore makes a version live, not saved: review it, then Save.`,
			41
		)
	)
	table.insert(
		children,
		Button(scope, {
			Text = scope:Computed(function(use)
				return if use(loaded) then "Reload history" else "Load history"
			end),
			Size = UDim2.new(0.5, 0, 0, Tokens.Control.StepButtonSize),
			LayoutOrder = 42,
			OnActivated = tools.OnLoadHistory,
		})
	)
	table.insert(children, Fields.Prose(scope, "No saved versions yet.", 43, noVersions))
	table.insert(children, versionRows :: any)

	-- Source (Studio only) ------------------------------------------------------------------------------

	if RunService:IsStudio() then
		local isShipped = scope:Computed(function(use)
			local entry = use(tools.Entry)
			return entry ~= nil and entry.Shipped
		end)
		local notShipped = scope:Computed(function(use)
			return not use(isShipped)
		end)
		local hasExport = scope:Computed(function(use)
			return use(tools.ExportText) ~= nil
		end)

		table.insert(children, Fields.Heading(scope, "SOURCE", 60))
		table.insert(
			children,
			Fields.Prose(
				scope,
				"Writes this move into src/ as a Lua file Rojo syncs in. It ships with the build and lives in git; its DataStore copy is removed. Needs python scripts/move-writer.py running and Allow HTTP Requests on.",
				61
			)
		)
		table.insert(
			children,
			Fields.Fact(
				scope,
				"In source",
				scope:Computed(function(use)
					return if use(isShipped) then "Yes" else "No"
				end),
				62
			)
		)
		table.insert(
			children,
			Stack.Row(scope, {
				Name = "SourceActions",
				Size = UDim2.new(1, 0, 0, Tokens.Control.StepButtonSize),
				Gap = Tokens.Space.S,
				LayoutOrder = 63,
				Children = {
					Button(scope, {
						Text = "Write to source",
						Variant = "Primary",
						Size = UDim2.new(1 / 3, -Tokens.Space.S, 1, 0),
						LayoutOrder = 1,
						OnActivated = tools.OnWriteToSource,
					}),
					Button(scope, {
						Text = "Export",
						Variant = "Secondary",
						Size = UDim2.new(1 / 3, -Tokens.Space.S, 1, 0),
						LayoutOrder = 2,
						OnActivated = tools.OnExportSource,
					}),
					Fields.ArmedButton(scope, {
						Idle = "Remove from source",
						Armed = "Remove? Again",
						LayoutOrder = 3,
						Size = UDim2.fromScale(1 / 3, 1),
						Disabled = notShipped,
						OnConfirm = tools.OnRemoveFromSource,
					}),
				},
			})
		)
		-- Read-only and selectable: the text is for copying out, not for editing here.
		table.insert(
			children,
			scope:New "TextBox" {
				Name = "ExportText",
				Size = UDim2.new(1, 0, 0, 240),
				LayoutOrder = 64,
				Visible = hasExport,
				Text = scope:Computed(function(use)
					return use(tools.ExportText) or ""
				end),
				TextEditable = false,
				ClearTextOnFocus = false,
				MultiLine = true,
				TextWrapped = false,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextYAlignment = Enum.TextYAlignment.Top,
				FontFace = Tokens.Type.NumeralSmall.Face,
				TextSize = Tokens.Type.NumeralSmall.Size,
				TextColor3 = Tokens.Color.TextSecondary,
				BackgroundColor3 = Tokens.Wash.Inset.Color,
				BackgroundTransparency = Tokens.Wash.Inset.Transparency,
				BorderSizePixel = 0,
				ClipsDescendants = true,
			}
		)
	end

	return Fields.Page(scope, "ToolsTab", visible, children)
end

return ToolsTab
