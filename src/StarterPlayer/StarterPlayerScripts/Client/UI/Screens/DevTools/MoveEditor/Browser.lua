--!strict
--[[
	MoveEditor/Browser.lua

	Owns: the Move Editor's left rail -- every move the game knows, grouped the way an author thinks
	about them, filterable, and each row saying at a glance whether it has unsaved work.

	GROUPS, IN THIS ORDER: Arts first (the content players actually cast), then custom categories, then
	uncategorised custom moves, then one group per roster weapon, then the standalone attacks. The groups
	come from the server (MoveEditorTypes.MoveEntry.Group) rather than from a rule here, so the rail and
	the server can never disagree about where a move lives.

	WEAPON GROUPS START COLLAPSED. A roster weapon carries fifteen-odd Default moves, and five weapons
	of them open at once bury the handful of authored moves the rail is mostly used to reach. A filter
	expands every group, since a search that hides its own matches in a closed group is not a search.

	A ROW STATES ITS SAVE STATE WITH SHAPE AND WORD, NOT HUE ALONE (docs/ui-ux-philosophy.md): a bronze
	chip reading UNSAVED, NEW or TUNED. The open row reads its live IsDirty rather than its entry's, so the
	chip appears on the keystroke, not a debounce later.

	ROWS ARE A scope:ForPairs, NEVER A Computed THAT RETURNS INSTANCES. A Computed that builds Instances
	has no scope to put them in, so every recompute leaves the previous row set orphaned -- a leak per
	edit. ForPairs gives each pair its own inner scope and cleans it when the pair goes, which is why it
	is this codebase's dynamic-list primitive (ForValues keys by value identity, and every entry table is
	fresh from the server on each answer, so it would rebuild every row every time).

	A ROW SAYS ITS TYPE (2026-10-07): a quiet MELEE / SHOT / REALM tag beside the name, so a list of thirty
	custom moves can be read for what each one is without opening it. NEW ASKS THE TYPE: "+ New" opens a row
	of three (Melee, Projectile, Domain) and the move is created as that type. The filter has a clear button,
	Ctrl+F lands in it (the driver, through FilterBox), and the order the rows are shown in is written to
	Order, which the arrow keys step through.

	Does not own: what selecting or creating does (the OnSelect/OnNew props -- the driver's business).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local MoveEditorTypes = require(ReplicatedStorage.Shared.Authoring.MoveEditorTypes)
local MoveTypes = require(ReplicatedStorage.Shared.MoveTypes)

local Tokens = require(script.Parent.Parent.Parent.Parent.Tokens)
local Button = require(script.Parent.Parent.Parent.Parent.Components.Button)
local Inset = require(script.Parent.Parent.Parent.Parent.Components.Inset)
local Label = require(script.Parent.Parent.Parent.Parent.Components.Label)
local ScrollArea = require(script.Parent.Parent.Parent.Parent.Components.ScrollArea)
local Selection = require(script.Parent.Parent.Parent.Parent.Components.Selection)
local Stack = require(script.Parent.Parent.Parent.Parent.Components.Stack)
local StatusTag = require(script.Parent.Parent.Parent.Parent.Components.StatusTag)
local Tab = require(script.Parent.Parent.Parent.Parent.Components.Tab)
local TextField = require(script.Parent.Parent.Parent.Parent.Components.TextField)
local TrackedLabel = require(script.Parent.Parent.Parent.Parent.Components.TrackedLabel)

local Children = Fusion.Children
local OnEvent = Fusion.OnEvent
local peek = Fusion.peek

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>
type MoveEntry = MoveEditorTypes.MoveEntry

export type BrowserProps = {
	Width: number,
	LayoutOrder: number?,
	Entries: UsedAs<{ MoveEntry }>,
	SelectedId: UsedAs<string?>,
	-- The open draft's live dirty state -- see this file's header.
	IsDirty: UsedAs<boolean>,
	OnSelect: (moveId: string) -> (),
	-- (kind) -- "Melee", "Projectile" or "Domain".
	OnNew: (kind: string) -> (),
	-- Written with the move ids of the rows on show, top to bottom (the arrow keys' order).
	Order: Fusion.Value<{ string }>?,
	-- Written with the filter's text box once it exists, so a shortcut can focus it.
	FilterBox: Fusion.Value<TextBox?>?,
}

local ROW_HEIGHT = 30
local GROUP_HEIGHT = 30
local ACCENT_WIDTH = 2
local TYPE_WIDTH = 44
local STATE_WIDTH = 76

-- What a row's type tag says (see this file's header).
local function typeOf(move: MoveTypes.MoveDefinition): string
	if move.Domain ~= nil then
		return "REALM"
	end
	return if move.Projectile ~= nil then "SHOT" else "MELEE"
end

local NEW_KINDS = {
	{ Kind = "Melee", Text = "Melee" },
	{ Kind = "Projectile", Text = "Projectile" },
	{ Kind = "Domain", Text = "Domain" },
}

-- Groups that are not a weapon's, in rail order. Anything else a custom move names sits between
-- "Arts" and "Custom", alphabetised; weapon groups follow in the server's own roster order.
local GROUP_ORDER_HEAD = "Arts"
local GROUP_ORDER_CUSTOM = "Custom"
local GROUP_ORDER_TAIL = "Standalone"

type Row = {
	Key: string,
	Kind: "Group" | "Move",
	Group: string,
	-- Group rows.
	Count: number?,
	Collapsed: boolean?,
	-- Move rows.
	Entry: MoveEntry?,
}

-- What a row's chip says about its save state, or nil for a clean saved move.
local function stateOf(entry: MoveEntry, dirty: boolean): string?
	if entry.Source == "Custom" and entry.SavedFingerprint == nil then
		return "NEW"
	end
	if dirty then
		return "UNSAVED"
	end
	if entry.Overridden then
		return "TUNED"
	end
	return nil
end

local function entryIsDirty(entry: MoveEntry): boolean
	return entry.SavedFingerprint ~= MoveTypes.Fingerprint(entry.Move)
end

-- Orders groups: Arts, custom categories (alphabetical), Custom, weapons (first-seen order, which is
-- the server's roster order), Standalone.
local function orderGroups(entries: { MoveEntry }): { string }
	local customCategories: { string } = {}
	local weapons: { string } = {}
	local seen: { [string]: boolean } = {}
	local hasArts, hasCustom, hasStandalone = false, false, false
	for _, entry in ipairs(entries) do
		local group = entry.Group
		if seen[group] then
			continue
		end
		seen[group] = true
		if group == GROUP_ORDER_HEAD then
			hasArts = true
		elseif group == GROUP_ORDER_CUSTOM then
			hasCustom = true
		elseif group == GROUP_ORDER_TAIL then
			hasStandalone = true
		elseif entry.Source == "Default" then
			table.insert(weapons, group)
		else
			table.insert(customCategories, group)
		end
	end
	table.sort(customCategories)
	local ordered: { string } = {}
	if hasArts then
		table.insert(ordered, GROUP_ORDER_HEAD)
	end
	for _, group in customCategories do
		table.insert(ordered, group)
	end
	if hasCustom then
		table.insert(ordered, GROUP_ORDER_CUSTOM)
	end
	for _, group in weapons do
		table.insert(ordered, group)
	end
	if hasStandalone then
		table.insert(ordered, GROUP_ORDER_TAIL)
	end
	return ordered
end

local function matches(entry: MoveEntry, filter: string): boolean
	if filter == "" then
		return true
	end
	local move = entry.Move
	return string.find(string.lower(move.DisplayName), filter, 1, true) ~= nil
		or string.find(string.lower(move.MoveId), filter, 1, true) ~= nil
		or string.find(string.lower(entry.Group), filter, 1, true) ~= nil
end

local function groupRow(scope: Scope, row: Row, order: number, onToggle: () -> ()): Instance
	local selection = Selection.New(scope)
	return scope:New "TextButton" {
		Name = `Group_{row.Group}`,
		Size = UDim2.new(1, 0, 0, GROUP_HEIGHT),
		LayoutOrder = order,
		AutoButtonColor = false,
		Text = "",
		BackgroundColor3 = Tokens.Wash.AccentBloom.Color,
		BackgroundTransparency = scope:Computed(function(use)
			return if use(selection.Active) then Tokens.Wash.AccentBloom.Transparency else 1
		end),
		BorderSizePixel = 0,

		[OnEvent "Activated"] = onToggle,
		[OnEvent "MouseEnter"] = selection.OnPointerEnter,
		[OnEvent "MouseLeave"] = selection.OnPointerLeave,
		[OnEvent "SelectionGained"] = selection.OnSelectionGained,
		[OnEvent "SelectionLost"] = selection.OnSelectionLost,

		[Children] = {
			Inset(scope, { X = Tokens.Space.S }),
			TrackedLabel(scope, {
				Text = string.upper(row.Group),
				Scale = "Chip",
				Color = Tokens.Color.AccentSecondary,
				AnchorPoint = Vector2.new(0, 0.5),
				Position = UDim2.fromScale(0, 0.5),
			}),
			Label(scope, {
				Text = `{row.Count}  {if row.Collapsed then "+" else "-"}`,
				Scale = "NumeralSmall",
				Color = Tokens.Color.TextDisabled,
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.fromScale(1, 0.5),
				Size = UDim2.fromOffset(60, GROUP_HEIGHT),
				TextXAlignment = Enum.TextXAlignment.Right,
			}),
			-- The group's closing hairline, pinned rather than laid out.
			scope:New "Frame" {
				Name = "Rule",
				AnchorPoint = Vector2.new(0, 1),
				Position = UDim2.fromScale(0, 1),
				Size = UDim2.new(1, 0, 0, Tokens.Control.DividerThickness),
				BackgroundColor3 = Tokens.Border.Hairline.Color,
				BackgroundTransparency = Tokens.Border.Hairline.Transparency,
				BorderSizePixel = 0,
			},
		},
	}
end

local function moveRow(scope: Scope, entry: MoveEntry, order: number, props: BrowserProps): Instance
	local moveId = entry.Move.MoveId
	local selection = Selection.New(scope)
	local isSelected = scope:Computed(function(use)
		return use(props.SelectedId) == moveId
	end)
	local stateText = scope:Computed(function(use)
		local dirty = if use(isSelected) then use(props.IsDirty) else entryIsDirty(entry)
		return stateOf(entry, dirty) or ""
	end)

	return scope:New "TextButton" {
		Name = `Move_{moveId}`,
		Size = UDim2.new(1, 0, 0, ROW_HEIGHT),
		LayoutOrder = order,
		AutoButtonColor = false,
		Text = "",
		BackgroundColor3 = scope:Computed(function(use)
			return if use(isSelected) then Tokens.Wash.AccentFill.Color else Tokens.Wash.AccentBloom.Color
		end),
		BackgroundTransparency = scope:Computed(function(use)
			if use(isSelected) then
				return Tokens.Wash.AccentFill.Transparency
			end
			return if use(selection.Active) then Tokens.Wash.AccentBloom.Transparency else 1
		end),
		BorderSizePixel = 0,

		[OnEvent "Activated"] = function()
			props.OnSelect(moveId)
		end,
		[OnEvent "MouseEnter"] = selection.OnPointerEnter,
		[OnEvent "MouseLeave"] = selection.OnPointerLeave,
		[OnEvent "SelectionGained"] = selection.OnSelectionGained,
		[OnEvent "SelectionLost"] = selection.OnSelectionLost,

		[Children] = {
			scope:New "Frame" {
				Name = "Accent",
				Size = UDim2.new(0, ACCENT_WIDTH, 1, 0),
				BackgroundColor3 = Tokens.Color.AccentPrimary,
				BackgroundTransparency = scope:Computed(function(use)
					return if use(isSelected) then 0 else 1
				end),
				BorderSizePixel = 0,
			},
			Label(scope, {
				Text = entry.Move.DisplayName,
				Scale = "Body",
				Color = scope:Computed(function(use)
					return if use(isSelected) then Tokens.Color.TextPrimary else Tokens.Color.TextSecondary
				end),
				AnchorPoint = Vector2.new(0, 0.5),
				Position = UDim2.new(0, Tokens.Space.M, 0.5, 0),
				Size = UDim2.new(1, -(Tokens.Space.M + STATE_WIDTH + TYPE_WIDTH), 1, 0),
				TextTruncate = Enum.TextTruncate.AtEnd,
			}),
			Label(scope, {
				Text = typeOf(entry.Move),
				Scale = "NumeralSmall",
				Color = if entry.Move.Domain ~= nil
					then Tokens.Color.AccentPrimary
					elseif entry.Move.Projectile ~= nil then Tokens.VitalColor.Qi
					else Tokens.Color.TextDisabled,
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.new(1, -STATE_WIDTH, 0.5, 0),
				Size = UDim2.fromOffset(TYPE_WIDTH, ROW_HEIGHT),
				TextXAlignment = Enum.TextXAlignment.Right,
			}),
			scope:New "Frame" {
				Name = "State",
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.new(1, -Tokens.Space.S, 0.5, 0),
				Size = UDim2.fromOffset(0, 18),
				AutomaticSize = Enum.AutomaticSize.X,
				BackgroundTransparency = 1,

				[Children] = StatusTag(scope, {
					Label = stateText,
					Color = Tokens.Color.AccentSecondary,
					Visible = scope:Computed(function(use)
						return use(stateText) ~= ""
					end),
				}),
			},
		},
	}
end

local function Browser(scope: Scope, props: BrowserProps): Frame
	local filterText = scope:Value("")
	-- Group -> collapsed. Absent means "not yet decided", which resolves to collapsed for a weapon
	-- group and open for everything else -- see this file's header.
	local collapsed = scope:Value({} :: { [string]: boolean })

	local filter = scope:Computed(function(use)
		return string.lower((string.gsub(use(filterText), "^%s+", "")))
	end)

	local rows = scope:Computed(function(use): { Row }
		local entries = use(props.Entries)
		local query = use(filter)
		local collapsedMap = use(collapsed)
		local selectedId = use(props.SelectedId)

		local byGroup: { [string]: { MoveEntry } } = {}
		local weaponGroup: { [string]: boolean } = {}
		for _, entry in ipairs(entries) do
			if matches(entry, query) then
				local list = byGroup[entry.Group]
				if not list then
					list = {}
					byGroup[entry.Group] = list
				end
				table.insert(list, entry)
			end
			if entry.Source == "Default" and entry.Group ~= GROUP_ORDER_TAIL then
				weaponGroup[entry.Group] = true
			end
		end

		local result: { Row } = {}
		for _, group in orderGroups(entries) do
			local list = byGroup[group]
			if not list then
				continue
			end
			local isClosed = collapsedMap[group]
			if isClosed == nil then
				isClosed = weaponGroup[group] == true
				-- A closed group never hides the open move.
				for _, entry in list do
					if entry.Move.MoveId == selectedId then
						isClosed = false
						break
					end
				end
			end
			if query ~= "" then
				isClosed = false
			end
			table.insert(result, {
				Key = `g:{group}:{#list}:{isClosed}`,
				Kind = "Group",
				Group = group,
				Count = #list,
				Collapsed = isClosed,
			})
			if not isClosed then
				for _, entry in list do
					table.insert(result, {
						-- The fingerprint is in the key so an entry whose content changed is rebuilt
						-- rather than left showing its old name or state.
						Key = `m:{entry.Move.MoveId}:{entry.SavedFingerprint or ""}:{entry.Move.DisplayName}:{entry.Overridden}`,
						Kind = "Move",
						Group = group,
						Entry = entry,
					})
				end
			end
		end
		return result
	end)

	local function toggleGroup(group: string, currentlyCollapsed: boolean)
		local nextMap = table.clone(peek(collapsed))
		nextMap[group] = not currentlyCollapsed
		collapsed:set(nextMap)
	end

	-- The arrow keys' order: the move rows on show, top to bottom (collapsed groups' moves are not on show).
	local order = props.Order
	if order then
		scope:Observer(rows):onBind(function()
			local ids: { string } = {}
			for _, row in peek(rows) do
				if row.Kind == "Move" and row.Entry then
					table.insert(ids, row.Entry.Move.MoveId)
				end
			end
			order:set(ids)
		end)
	end

	local rowInstances = scope:ForPairs(rows, function(_use, innerScope: Scope, index: number, row: Row)
		if row.Kind == "Group" then
			return row.Key .. "#" .. index,
				groupRow(innerScope, row, index, function()
					toggleGroup(row.Group, row.Collapsed == true)
				end)
		end
		return row.Key .. "#" .. index, moveRow(innerScope, row.Entry :: MoveEntry, index, props)
	end)

	-- The whole inventory, and how much of it has unsaved work -- the one standing fact about the rail
	-- as a whole, so it sits on the rail's own header. The open row counts its live IsDirty, like its
	-- chip does.
	local countText = scope:Computed(function(use)
		local entries = use(props.Entries)
		local selectedId = use(props.SelectedId)
		local unsaved = 0
		for _, entry in ipairs(entries) do
			local dirty = if entry.Move.MoveId == selectedId then use(props.IsDirty) else entryIsDirty(entry)
			if dirty then
				unsaved += 1
			end
		end
		return if unsaved > 0 then `{#entries} · {unsaved} unsaved` else `{#entries}`
	end)

	local choosingKind = scope:Value(false)
	local kindButtons: { Instance } = {}
	for index, choice in NEW_KINDS do
		table.insert(
			kindButtons,
			Button(scope, {
				Text = choice.Text,
				Size = UDim2.new(1 / #NEW_KINDS, -Tokens.Space.XS, 1, 0),
				LayoutOrder = index,
				OnActivated = function()
					choosingKind:set(false)
					props.OnNew(choice.Kind)
				end,
			})
		)
	end

	local filterBox = TextField(scope, {
		Text = filterText,
		PlaceholderText = "Filter by name, id or group  (Ctrl+F)",
		MaxLength = 40,
		Size = UDim2.fromScale(0, 1),
		LayoutOrder = 1,
	})
	if props.FilterBox then
		props.FilterBox:set(filterBox)
	end

	return Stack.New(scope, {
		Name = "Browser",
		Size = UDim2.new(0, props.Width, 1, 0),
		LayoutOrder = props.LayoutOrder,
		Gap = Tokens.Space.S,
		BackgroundColor3 = Tokens.Wash.RailScrim.Color,
		BackgroundTransparency = Tokens.Wash.RailScrim.Transparency,
		Children = {
			Inset(scope, { Top = Tokens.Space.M, Bottom = Tokens.Space.M, X = Tokens.Space.M }),
			Stack.Row(scope, {
				Name = "Header",
				Size = UDim2.new(1, 0, 0, Tokens.Control.StepButtonSize),
				AlignY = Enum.VerticalAlignment.Center,
				Gap = Tokens.Space.S,
				LayoutOrder = 1,
				Children = {
					TrackedLabel(scope, {
						Text = "MOVES",
						Scale = "Eyebrow",
						Color = Tokens.Color.TextPrimary,
						LayoutOrder = 1,
					}),
					Stack.Fill(
						scope,
						Label(scope, {
							Text = countText,
							Scale = "Detail",
							Color = Tokens.Color.TextDisabled,
							Size = UDim2.fromScale(0, 1),
							TextTruncate = Enum.TextTruncate.AtEnd,
							LayoutOrder = 2,
						})
					),
					Tab(scope, {
						Text = "+ New",
						Selected = choosingKind,
						Size = UDim2.fromOffset(72, Tokens.Control.StepButtonSize - 4),
						LayoutOrder = 3,
						OnActivated = function()
							choosingKind:set(not peek(choosingKind))
						end,
					}),
				},
			}),
			-- New asks the type first (see this file's header).
			Stack.Row(scope, {
				Name = "NewKinds",
				Size = UDim2.new(1, 0, 0, Tokens.Control.StepButtonSize - 4),
				Gap = Tokens.Space.XS,
				LayoutOrder = 2,
				Visible = choosingKind,
				Children = kindButtons,
			}),
			Stack.Row(scope, {
				Name = "Filter",
				Size = UDim2.new(1, 0, 0, Tokens.Control.StepButtonSize),
				Gap = Tokens.Space.XS,
				LayoutOrder = 3,
				Children = {
					Stack.Fill(scope, filterBox),
					Button(scope, {
						Text = "Clear",
						Size = UDim2.new(0, 56, 1, 0),
						LayoutOrder = 2,
						Disabled = scope:Computed(function(use)
							return use(filterText) == ""
						end),
						OnActivated = function()
							filterText:set("")
						end,
					}),
				},
			}),
			Stack.Fill(
				scope,
				ScrollArea(scope, {
					Name = "Rows",
					Size = UDim2.fromScale(1, 0),
					LayoutOrder = 4,
					Children = {
						scope:New "UIListLayout" {
							FillDirection = Enum.FillDirection.Vertical,
							SortOrder = Enum.SortOrder.LayoutOrder,
						},
						rowInstances :: any,
					},
				})
			),
		},
	})
end

return Browser
