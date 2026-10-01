--!strict
--[[
	MoveEditor/Readout.lua

	Owns: the Move Editor's right column -- everything about the open move that is a RESULT rather than
	an input: what it is and whether it is saved, where its volume sits against the body (HitboxPlot),
	what it does in time once the clip has had its say (TimelineBar), what that is worth in frames and
	hits (FrameData), what the server thinks an author
	should know (the entry's notes), and every action that commits, tests or throws work away.

	PINNED, NOT A TAB, for the character menu's reason (Screens/Menus/IdentityRail): the plots and the
	timeline are what an author is checking WHILE they edit any tab. A result that needed a tab switch to
	see would be a result nobody looks at.

	IRREVERSIBLE ACTIONS ARM FIRST. Delete, Reset to default and Revert each need a second press inside
	Constants.MoveEditor.ConfirmWindowSeconds; the button says so while armed. Save and Test are not
	irreversible and fire on the first press.

	Does not own: what any action does (the On* props -- the driver's), or the numbers (the entry, which
	the server computed).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local ArtConstants = require(ReplicatedStorage.Shared.ArtConstants)
local MoveEditorTypes = require(ReplicatedStorage.Shared.Authoring.MoveEditorTypes)
local MoveTypes = require(ReplicatedStorage.Shared.MoveTypes)

local Tokens = require(script.Parent.Parent.Parent.Parent.Tokens)
local Button = require(script.Parent.Parent.Parent.Parent.Components.Button)
local Inset = require(script.Parent.Parent.Parent.Parent.Components.Inset)
local Label = require(script.Parent.Parent.Parent.Parent.Components.Label)
local ScrollArea = require(script.Parent.Parent.Parent.Parent.Components.ScrollArea)
local SectionHeading = require(script.Parent.Parent.Parent.Parent.Components.SectionHeading)
local Stack = require(script.Parent.Parent.Parent.Parent.Components.Stack)
local StatusTag = require(script.Parent.Parent.Parent.Parent.Components.StatusTag)

local Fields = require(script.Parent.Fields)
local FrameData = require(script.Parent.FrameData)
local HitLog = require(script.Parent.HitLog)
local HitboxPlot = require(script.Parent.HitboxPlot)
local MoveEditorScreenTypes = require(script.Parent.Types)
local TestBench = require(script.Parent.TestBench)
local TimelineBar = require(script.Parent.TimelineBar)

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>
type MoveEntry = MoveEditorTypes.MoveEntry

export type ReadoutProps = {
	Width: number,
	LayoutOrder: number?,
	Entry: UsedAs<MoveEntry?>,
	Draft: Fusion.Value<MoveTypes.MoveDefinition?>,
	IsDirty: UsedAs<boolean>,
	HotbarBindings: UsedAs<{ [number]: string? }>,
	VolumesVisible: UsedAs<boolean>,
	CanUndo: UsedAs<boolean>,
	CanRedo: UsedAs<boolean>,
	OnUndo: () -> (),
	OnRedo: () -> (),
	OnSave: () -> (),
	OnTest: () -> (),
	OnRevert: () -> (),
	OnDuplicate: () -> (),
	OnDelete: () -> (),
	OnResetDefault: () -> (),
	OnBindSlot: (slot: number) -> (),
	OnSpawnDummy: () -> (),
	OnToggleVolumes: (visible: boolean) -> (),
	DummyGuard: UsedAs<boolean>,
	BotStyle: Fusion.Value<string>,
	BotDifficulty: Fusion.Value<string>,
	OnDummyGuard: (enabled: boolean) -> (),
	OnSpawnBot: () -> (),
	OnClearBench: () -> (),
	HitLog: UsedAs<{ MoveEditorScreenTypes.HitLogEntry }>,
	OnClearHitLog: () -> (),
}

local BUTTON_HEIGHT = Tokens.Control.StepButtonSize
local CHIP_ROW_HEIGHT = 20

-- A two-press button at the readout's half width -- Fields.ArmedButton.
local function armedButton(
	scope: Scope,
	idleText: string,
	armedText: string,
	order: number,
	disabled: UsedAs<boolean>?,
	visible: UsedAs<boolean>?,
	onConfirm: () -> ()
): Frame
	return Fields.ArmedButton(scope, {
		Idle = idleText,
		Armed = armedText,
		LayoutOrder = order,
		Disabled = disabled,
		Visible = visible,
		OnConfirm = onConfirm,
	})
end

local function halfButton(
	scope: Scope,
	text: string,
	variant: "Primary" | "Secondary",
	order: number,
	disabled: UsedAs<boolean>?,
	onActivated: () -> ()
): Instance
	return Button(scope, {
		Text = text,
		Variant = variant,
		Size = UDim2.new(0.5, -Tokens.Space.S / 2, 0, BUTTON_HEIGHT),
		LayoutOrder = order,
		Disabled = disabled,
		OnActivated = onActivated,
	})
end

-- Variant nil: its Disabled follows a Computed, and a Variant button reads its props once.
local function legacyHalfButton(
	scope: Scope,
	text: string,
	order: number,
	disabled: UsedAs<boolean>?,
	onActivated: () -> ()
): Instance
	return Button(scope, {
		Text = text,
		Size = UDim2.new(0.5, -Tokens.Space.S / 2, 0, BUTTON_HEIGHT),
		LayoutOrder = order,
		Disabled = disabled,
		OnActivated = onActivated,
	})
end

local function row(scope: Scope, order: number, children: { Instance }, visible: UsedAs<boolean>?): Frame
	return Stack.Row(scope, {
		Size = UDim2.new(1, 0, 0, BUTTON_HEIGHT),
		Gap = Tokens.Space.S,
		LayoutOrder = order,
		Visible = visible,
		Children = children,
	})
end

local function Readout(scope: Scope, props: ReadoutProps): Frame
	local hasEntry = scope:Computed(function(use)
		return use(props.Entry) ~= nil
	end)
	local isCustom = scope:Computed(function(use)
		local entry = use(props.Entry)
		return entry ~= nil and entry.Source == "Custom"
	end)
	local isDefault = scope:Computed(function(use)
		local entry = use(props.Entry)
		return entry ~= nil and entry.Source == "Default"
	end)
	local isArt = scope:Computed(function(use)
		local move = use(props.Draft)
		return use(isCustom) and move ~= nil and move.Art ~= nil
	end)
	local hasBalance = scope:Computed(function(use)
		local entry = use(props.Entry)
		return entry ~= nil and entry.Balance ~= nil
	end)
	local isShipped = scope:Computed(function(use)
		local entry = use(props.Entry)
		return entry ~= nil and entry.Shipped
	end)
	local notUndoable = scope:Computed(function(use)
		return not use(props.CanUndo)
	end)
	local notRedoable = scope:Computed(function(use)
		return not use(props.CanRedo)
	end)
	local notDirty = scope:Computed(function(use)
		return not use(props.IsDirty)
	end)

	local nameText = scope:Computed(function(use)
		local move = use(props.Draft)
		return if move then move.DisplayName else "No move open"
	end)
	local kindText = scope:Computed(function(use)
		local entry = use(props.Entry)
		if not entry then
			return ""
		end
		if entry.Source == "Default" then
			return "WEAPON MOVE"
		end
		return if entry.Move.Art then "ART" else "CUSTOM MOVE"
	end)
	local stateText = scope:Computed(function(use)
		local entry = use(props.Entry)
		if not entry then
			return ""
		end
		if entry.Source == "Custom" and entry.SavedFingerprint == nil then
			return "NEVER SAVED"
		end
		if use(props.IsDirty) then
			return "UNSAVED"
		end
		return if entry.Overridden then "SAVED  ·  TUNED" else "SAVED"
	end)
	local stateColor = scope:Computed(function(use)
		return if use(stateText) == "SAVED" or use(stateText) == "SAVED  ·  TUNED"
			then Tokens.Color.Positive
			else Tokens.Color.Warning
	end)

	local notes = scope:Computed(function(use)
		local entry = use(props.Entry)
		return if entry then entry.Notes else {}
	end)
	local noteRows = scope:ForPairs(notes, function(_use, innerScope: Scope, index: number, note: string)
		return index,
			Label(innerScope, {
				Text = `·  {note}`,
				Scale = "Detail",
				Color = Tokens.Color.Warning,
				Size = UDim2.fromScale(1, 0),
				AutoHeight = true,
				TextWrapped = true,
				LineHeight = Tokens.Leading.Prose,
				LayoutOrder = index,
			})
	end)
	local hasNotes = scope:Computed(function(use)
		return #use(notes) > 0
	end)

	local plotSize = math.floor((props.Width - Tokens.Space.M * 2 - Tokens.Space.S) / 2)

	local slotButtons: { Instance } = {}
	for slot = 1, ArtConstants.EquipSlotCount do
		table.insert(
			slotButtons,
			Button(scope, {
				Text = scope:Computed(function(use)
					local move = use(props.Draft)
					local holder = use(props.HotbarBindings)[slot]
					return if move and holder == move.MoveId then `[{slot}]` else tostring(slot)
				end),
				Size = UDim2.new(1 / ArtConstants.EquipSlotCount, -Tokens.Space.XS, 1, 0),
				LayoutOrder = slot,
				OnActivated = function()
					props.OnBindSlot(slot)
				end,
			})
		)
	end

	local content: { Instance } = {
		scope:New "UIListLayout" {
			FillDirection = Enum.FillDirection.Vertical,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, Tokens.Space.M),
		},
		Inset(scope, { Top = Tokens.Space.M, Bottom = Tokens.Space.XL, X = Tokens.Space.M }),

		-- Identity.
		Stack.New(scope, {
			Name = "Title",
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			Gap = Tokens.Space.XS,
			LayoutOrder = 10,
			Children = {
				Label(scope, {
					Text = nameText,
					Scale = "CardTitle",
					Color = Tokens.Color.TextPrimary,
					Size = UDim2.new(1, 0, 0, Tokens.Type.CardTitle.Size + Tokens.Space.XS),
					TextTruncate = Enum.TextTruncate.AtEnd,
					LayoutOrder = 10,
				}),
				Stack.Row(scope, {
					Size = UDim2.new(1, 0, 0, CHIP_ROW_HEIGHT),
					Gap = Tokens.Space.S,
					LayoutOrder = 20,
					Visible = hasEntry,
					Children = {
						StatusTag(scope, { Label = kindText, Color = Tokens.Color.AccentPrimary, LayoutOrder = 10 }),
						StatusTag(scope, { Label = stateText, Color = stateColor, LayoutOrder = 20 }),
						scope:New "Frame" {
							Name = "InSource",
							Size = UDim2.fromScale(0, 1),
							AutomaticSize = Enum.AutomaticSize.X,
							BackgroundTransparency = 1,
							LayoutOrder = 30,
							Visible = isShipped,
							[Fusion.Children] = StatusTag(scope, {
								Label = "IN SOURCE",
								Color = Tokens.Color.AccentSecondary,
							}),
						},
					},
				}),
			},
		}),

		-- Where the volume is.
		Stack.Row(scope, {
			Name = "Plots",
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			Gap = Tokens.Space.S,
			LayoutOrder = 20,
			Children = {
				HitboxPlot(scope, { View = "Top", Size = plotSize, Draft = props.Draft, LayoutOrder = 10 }),
				HitboxPlot(scope, { View = "Side", Size = plotSize, Draft = props.Draft, LayoutOrder = 20 }),
			},
		}),

		-- When it happens.
		SectionHeading(scope, { Text = "EFFECTIVE TIMELINE", LayoutOrder = 30, Visible = hasEntry }),
		TimelineBar(scope, { Entry = props.Entry, Draft = props.Draft, LayoutOrder = 40 }),

		-- What it is worth: frames, advantage, and how many of it a fight takes.
		SectionHeading(scope, { Text = "FRAME DATA", LayoutOrder = 50, Visible = hasBalance }),
		FrameData(scope, { Entry = props.Entry, LayoutOrder = 60 }),

		-- What the server wants the author to know.
		SectionHeading(scope, { Text = "NOTES", LayoutOrder = 70, Visible = hasNotes }),
		Stack.New(scope, {
			Name = "Notes",
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			Gap = Tokens.Space.XS,
			LayoutOrder = 80,
			Visible = hasNotes,
			Children = { noteRows :: any },
		}),

		-- Commit, test, throw away.
		SectionHeading(scope, { Text = "ACTIONS", LayoutOrder = 90, Visible = hasEntry }),
		row(scope, 100, {
			halfButton(scope, "Save", "Primary", 1, notDirty, props.OnSave),
			halfButton(scope, "Test", "Secondary", 2, nil, props.OnTest),
		}, hasEntry),
		row(scope, 110, {
			armedButton(scope, "Revert", "Revert? Again", 1, notDirty, nil, props.OnRevert),
			halfButton(scope, "Duplicate", "Secondary", 2, nil, props.OnDuplicate),
		}, hasEntry),
		row(scope, 115, {
			legacyHalfButton(scope, "Undo  (Ctrl+Z)", 1, notUndoable, props.OnUndo),
			legacyHalfButton(scope, "Redo  (Ctrl+Y)", 2, notRedoable, props.OnRedo),
		}, hasEntry),
		row(scope, 120, {
			armedButton(scope, "Delete", "Delete? Again", 1, nil, isCustom, props.OnDelete),
			armedButton(scope, "Reset to default", "Reset? Again", 2, nil, isDefault, props.OnResetDefault),
		}, hasEntry),

		-- Under a key.
		SectionHeading(scope, { Text = "HOTBAR SLOT", LayoutOrder = 130, Visible = isArt }),
		Stack.Row(scope, {
			Name = "Slots",
			Size = UDim2.new(1, 0, 0, BUTTON_HEIGHT),
			Gap = Tokens.Space.XS,
			LayoutOrder = 140,
			Visible = isArt,
			Children = slotButtons,
		}),

		-- What a Test is thrown at, and what it did.
		TestBench(scope, {
			LayoutOrder = 150,
			Visible = hasEntry,
			DummyGuard = props.DummyGuard,
			BotStyle = props.BotStyle,
			BotDifficulty = props.BotDifficulty,
			VolumesVisible = props.VolumesVisible,
			OnSpawnDummy = props.OnSpawnDummy,
			OnDummyGuard = props.OnDummyGuard,
			OnSpawnBot = props.OnSpawnBot,
			OnClearBench = props.OnClearBench,
			OnToggleVolumes = props.OnToggleVolumes,
		}),
		HitLog(scope, {
			LayoutOrder = 160,
			Visible = hasEntry,
			Entries = props.HitLog,
			OnClear = props.OnClearHitLog,
		}),
	}

	return ScrollArea(scope, {
		Name = "Readout",
		Size = UDim2.new(0, props.Width, 1, 0),
		LayoutOrder = props.LayoutOrder,
		BackgroundColor3 = Tokens.Wash.RailScrim.Color,
		BackgroundTransparency = Tokens.Wash.RailScrim.Transparency,
		Children = content,
	}) :: any
end

return Readout
