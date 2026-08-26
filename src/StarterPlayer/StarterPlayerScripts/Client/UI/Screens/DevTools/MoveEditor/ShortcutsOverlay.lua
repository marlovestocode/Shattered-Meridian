--!strict
--[[
	ShortcutsOverlay.lua

	Owns: the F1 panel listing every shortcut the Move Editor answers to -- key column on the left,
	what it does on the right, grouped by where the shortcut applies (the editor itself, a numeric
	field, the move list).

	It exists because this tool grew a lot of bindings that nothing announces. Ctrl+S/Ctrl+D were
	discoverable from the empty-state card's one-line footer and nothing else was: scroll-to-nudge,
	Shift/Alt step multipliers, drag-to-scrub, Up/Down while typing, undo/redo, double-click-to-rename.
	Every one of those is invisible until someone happens to try it, which for an admin tool means
	effectively never.

	A SECOND ModalScreen rather than a pane inside the editor's own root, mounted as a sibling: the
	editor's root is a fixed three-column layout with no free space, and the overlay has to be able to
	sit ON TOP of it while the editor stays open behind (an admin reading this list is reading it
	ABOUT the form they are looking at). Components/ModalScreen.lua already owns the ScreenGui +
	centered Panel shell both use, so this costs a Size and an IsOpen rather than a second copy of
	that chrome.

	Owns no state and no input. `IsOpen` is handed in and written by Client/DevTools/MoveEditor/
	MoveEditorClient.lua, which owns every key this editor binds -- same "screen renders, client module
	drives" boundary MoveEditor/Types.lua's header documents for everything else here.

	Does not own the CONTENT either: every row comes from Copy.Shortcuts, so adding a binding is one
	edit in the module that already owns this screen's prose. See that table's own header.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Tokens = require(script.Parent.Parent.Parent.Parent.Tokens)
local Label = require(script.Parent.Parent.Parent.Parent.Components.Label)
local Divider = require(script.Parent.Parent.Parent.Parent.Components.Divider)
local ModalScreen = require(script.Parent.Parent.Parent.Parent.Components.ModalScreen)
local ScrollArea = require(script.Parent.Parent.Parent.Parent.Components.ScrollArea)
local Copy = require(script.Parent.Copy)
local EditorTokens = require(script.Parent.EditorTokens)

local Children = Fusion.Children

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>

export type ShortcutsOverlayProps = {
	IsOpen: UsedAs<boolean>,
}

local WIDTH = 520
local HEIGHT = 560
-- Wide enough for the longest key string this list carries ("Click the number"), fixed rather than
-- auto so every description in every group starts on the same vertical line -- which is the entire
-- reason this is a two-column grid and not one padded string per row.
local KEY_COLUMN_WIDTH = 132
local ROW_GAP = Tokens.Space.XS

local ShortcutsOverlayModule = {}

-- ScrollArea is a ScrollingFrame with automatic canvas sizing and nothing else -- it owns no layout,
-- so every caller supplies its own. Prepended here rather than inline in the mount body so that body
-- reads as content.
local function withListLayout(scope: Scope, children: { Instance }): { Instance }
	local out: { Instance } = {
		scope:New "UIListLayout" {
			FillDirection = Enum.FillDirection.Vertical,
			HorizontalAlignment = Enum.HorizontalAlignment.Left,
			Padding = UDim.new(0, ROW_GAP),
			SortOrder = Enum.SortOrder.LayoutOrder,
		},
	}
	for _, child in ipairs(children) do
		table.insert(out, child)
	end
	return out
end

local function shortcutRow(scope: Scope, row: Copy.ShortcutRow, layoutOrder: number, width: number): Frame
	return scope:New "Frame" {
		Name = "Shortcut",
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		LayoutOrder = layoutOrder,

		[Children] = {
			scope:New "UIListLayout" {
				FillDirection = Enum.FillDirection.Horizontal,
				VerticalAlignment = Enum.VerticalAlignment.Top,
				Padding = UDim.new(0, Tokens.Space.S),
				SortOrder = Enum.SortOrder.LayoutOrder,
			},
			Label(scope, {
				Text = row.Keys,
				Scale = "Detail",
				-- The editor's own accent, so a key reads as a thing you press rather than as more
				-- prose. Same violet every other piece of this screen's chrome uses.
				Color = EditorTokens.Accent,
				Size = UDim2.fromOffset(KEY_COLUMN_WIDTH, 0),
				AutoHeight = true,
				LayoutOrder = 1,
			}),
			Label(scope, {
				Text = row.Description,
				Scale = "Detail",
				Color = Tokens.Color.TextSecondary,
				-- AutoHeight, so a two-sentence description wraps instead of being clipped -- several
				-- of them are two sentences, and which ones is Copy.Shortcuts' business to change
				-- freely without this file being re-measured.
				Size = UDim2.fromOffset(width - KEY_COLUMN_WIDTH - Tokens.Space.S, 0),
				AutoHeight = true,
				LineHeight = Tokens.Leading.Prose,
				LayoutOrder = 2,
			}),
		},
	} :: Frame
end

function ShortcutsOverlayModule.Mount(scope: Scope, playerGui: PlayerGui, props: ShortcutsOverlayProps): Frame
	local innerWidth = WIDTH - Tokens.Space.L * 2

	local groupChildren: { Instance } = {}
	local order = 0
	for _, group in ipairs(Copy.Shortcuts) do
		order += 1
		table.insert(
			groupChildren,
			Label(scope, {
				Text = group.Title,
				Scale = "Body",
				Color = Tokens.Color.TextPrimary,
				Size = UDim2.new(1, 0, 0, Tokens.Type.Body.Size + Tokens.Space.XS),
				-- Spaced away from the group above it, but not from its own first row -- the gap is
				-- what makes the grouping readable at a glance, so it belongs above the heading only.
				LayoutOrder = order,
			})
		)
		for _, row in ipairs(group.Rows) do
			order += 1
			table.insert(groupChildren, shortcutRow(scope, row, order, innerWidth))
		end
		order += 1
		table.insert(groupChildren, Divider.Plain(scope, { LayoutOrder = order }))
	end

	return ModalScreen(scope, playerGui, {
		Name = "MoveEditorShortcuts",
		Size = UDim2.fromOffset(WIDTH, HEIGHT),
		IsOpen = props.IsOpen,

		Children = {
			Label(scope, {
				Text = "Shortcuts",
				Scale = "Heading",
				Color = Tokens.Color.TextPrimary,
				Size = UDim2.new(1, 0, 0, Tokens.Type.Heading.Size + Tokens.Space.XS),
				LayoutOrder = 1,
			}),
			Label(scope, {
				Text = "F1 or Esc closes this.",
				Scale = "Detail",
				Color = Tokens.Color.TextSecondary,
				Size = UDim2.new(1, 0, 0, Tokens.Type.Detail.Size + Tokens.Space.XS),
				LayoutOrder = 2,
			}),
			ScrollArea(scope, {
				Name = "ShortcutList",
				-- Spelled out rather than guessed, the same discipline every other panel in this screen
				-- follows: the modal's own vertical padding, the title row, the hint row, and the two
				-- gaps the list layout puts under them.
				Size = UDim2.fromOffset(
					innerWidth,
					HEIGHT
						- Tokens.Space.L * 2
						- (Tokens.Type.Heading.Size + Tokens.Space.XS)
						- (Tokens.Type.Detail.Size + Tokens.Space.XS)
						- Tokens.Space.M * 2
				),
				LayoutOrder = 3,
				Children = withListLayout(scope, groupChildren),
			}),
		},
	})
end

return ShortcutsOverlayModule
