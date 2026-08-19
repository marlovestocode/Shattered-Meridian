--!strict
--[[
	MoveList.lua

	Owns: the Move Editor's left column -- a "+ New Move" header and a scrollable list of every
	known move, each row selectable and independently deletable. The list-of-items-with-per-row-
	actions template this file follows is the same one Screens/DevMenu/Sidebar.lua's own player
	roster already established (scope:ForPairs over a reactive array, re-keyed by MoveId, one
	ActionIcon-style action per row) -- generalized here from a Player-keyed roster to a
	MoveId-keyed move list.

	Delete reuses ActionIcon's "ResetData" glyph (a trash can -- the clearest "permanently discards
	something" reading in this UI's own glyph vocabulary, see that component's header) with its
	Armed two-press-confirm idiom, the same pattern Sidebar.lua's own Ban action uses for an
	irreversible action. Omitted entirely (not merely disabled) for a Category == "Default" move -- a
	Default move (Server/Combat/DefaultMoveRegistry.lua's live-Constants-backed projection, see that
	module's own header) can never be deleted, only reset, so there is no Delete action to offer.

	A "Default" | "Custom" filter tab sits above the list -- the two kinds never mix in one scroll
	(mixing a fixed, non-deletable Constants-backed attack with a hand-authored, deletable,
	DataStore-persisted one in the same list read as one homogenous collection when they are anything
	but). MovesDisplay itself is the UNION of both kinds (MoveEditorClient.lua fetches ListMoves AND
	ListDefaultMoves on open) -- this file's own job is purely presentational filtering on top of
	that already-merged array, never a second fetch.

	Does not own: the actual Save/Test-Fire/Delete network round trips -- OnNew/OnSelect/OnDelete are
	plain closures wired by Screens/MoveEditor/init.lua, which is what actually forwards a request to
	MoveEditorClient.lua (the "screen exposes state/signals, client module drives from outside"
	boundary lives one level up, at init.lua's own Mount -- see MoveEditor/Types.lua's header).

	Renders as a plain transparent Frame, not its own Panel -- Sidebar.lua now owns the ONE shared
	border/background around both this Moves group and the Sections group stacked below it, so a
	second nested border here would double up chrome inside a single visual sidebar card.

	The selected row's left accent bar + brightened text is the exact same "which one is active"
	language Sidebar.lua's own navItem uses for its Sections list -- one visual vocabulary for
	"selected" across both halves of the sidebar, not two.

	Each row is a small two-line card, not a bare name -- DisplayName on top, then a meta line of
	Category (when authored) plus small Movement/Knockback/Projectile glyphs (Components/
	SectionIcon.lua, only for whichever of the three the move actually has) so an admin can tell
	moves apart, and see at a glance whether one lunges/launches/travels, without opening each one.
	The SAME glyphs PropertyEditor.lua's own section cards and Sidebar.lua's own nav items use for
	these three -- one icon vocabulary across the whole editor, not a second one invented for the
	list.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local MoveTypes = require(ReplicatedStorage.Shared.MoveTypes)
local Tokens = require(script.Parent.Parent.Parent.Tokens)
local Label = require(script.Parent.Parent.Parent.Components.Label)
local Button = require(script.Parent.Parent.Parent.Components.Button)
local Tab = require(script.Parent.Parent.Parent.Components.Tab)
local TextField = require(script.Parent.Parent.Parent.Components.TextField)
local ActionIcon = require(script.Parent.Parent.Parent.Components.ActionIcon)
local SectionIcon = require(script.Parent.Parent.Parent.Components.SectionIcon)
local ScrollArea = require(script.Parent.Parent.Parent.Components.ScrollArea)

local Children = Fusion.Children
local OnEvent = Fusion.OnEvent
local peek = Fusion.peek

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>

export type MoveListProps = {
	MovesDisplay: UsedAs<{ MoveTypes.MoveDefinition }>,
	SelectedMoveId: UsedAs<string?>,
	OnNew: () -> (),
	OnSelect: (string) -> (),
	OnDelete: (string) -> (),
}

-- 44 -> 60: a bare name fit in 44, but the two-line card (name + category/glyph meta row) below
-- needs the extra height.
local ROW_HEIGHT = 60
-- Matches Sidebar.lua's own NAV_ACCENT_WIDTH -- the same left-accent-bar language for "this one is
-- selected," see file header.
local ROW_ACCENT_WIDTH = 4
-- How long a Delete press stays Armed before disarming itself if not confirmed -- same idea and
-- magnitude as Sidebar.lua's own Ban-arm window.
local DELETE_ARM_SECONDS = 3

local function MoveRow(scope: Scope, move: MoveTypes.MoveDefinition, layoutOrder: number, props: MoveListProps): Frame
	local isArmed = scope:Value(false)
	local isSelected = scope:Computed(function(use)
		return use(props.SelectedMoveId) == move.MoveId
	end)

	local backgroundColor = scope:Computed(function(use)
		return if use(isSelected) then Tokens.Wash.AccentFill.Color else Tokens.Color.Surface
	end)
	local backgroundTransparency = scope:Computed(function(use)
		return if use(isSelected) then Tokens.Wash.AccentFill.Transparency else 0
	end)
	local nameColor = scope:Computed(function(use)
		return if use(isSelected) then Tokens.Color.TextPrimary else Tokens.Color.TextSecondary
	end)

	-- A Default move has no Delete icon at all (see file header), so its content column can use the
	-- full row width; a Custom row still reserves a StepButtonSize-wide gutter on the right for it.
	local isDefaultMove = move.Category == MoveTypes.DefaultCategory
	local labelInset = ROW_ACCENT_WIDTH + Tokens.Space.S
	local contentWidth = if isDefaultMove
		then UDim2.new(1, -labelInset, 1, 0)
		else UDim2.new(1, -(labelInset + Tokens.Control.StepButtonSize + Tokens.Space.XS), 1, 0)

	-- Meta line: Category (only when the author actually set one) followed by whichever of
	-- Movement/Knockback/Projectile glyphs apply -- see file header.
	local metaChildren: { Instance } = {
		scope:New "UIListLayout" {
			FillDirection = Enum.FillDirection.Horizontal,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			Padding = UDim.new(0, Tokens.Space.XS),
			SortOrder = Enum.SortOrder.LayoutOrder,
		},
	}
	if move.Category ~= "" then
		table.insert(
			metaChildren,
			Label(scope, {
				Text = move.Category,
				Scale = "Detail",
				Color = Tokens.Color.TextSecondary,
				LayoutOrder = 1,
			})
		)
	end
	if move.Movement then
		table.insert(
			metaChildren,
			SectionIcon(scope, { Glyph = "Movement", Color = Tokens.Color.AccentPrimaryBright, LayoutOrder = 2 })
		)
	end
	if move.Knockback then
		table.insert(
			metaChildren,
			SectionIcon(scope, { Glyph = "Knockback", Color = Tokens.Color.AccentPrimaryBright, LayoutOrder = 3 })
		)
	end
	if move.Projectile then
		table.insert(
			metaChildren,
			SectionIcon(scope, { Glyph = "Projectile", Color = Tokens.Color.AccentPrimaryBright, LayoutOrder = 4 })
		)
	end

	local rowChildren: { Instance } = {
		scope:New "UICorner" { CornerRadius = Tokens.Radius.Sharp },
		scope:New "Frame" {
			Name = "AccentBar",
			Size = UDim2.new(0, ROW_ACCENT_WIDTH, 1, 0),
			BackgroundColor3 = Tokens.Color.AccentPrimary,
			BorderSizePixel = 0,
			Visible = isSelected,
		},
		scope:New "Frame" {
			Name = "Content",
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.new(0, labelInset, 0.5, 0),
			Size = contentWidth,
			BackgroundTransparency = 1,

			[Children] = {
				scope:New "UIListLayout" {
					FillDirection = Enum.FillDirection.Vertical,
					HorizontalAlignment = Enum.HorizontalAlignment.Left,
					VerticalAlignment = Enum.VerticalAlignment.Center,
					Padding = UDim.new(0, Tokens.Space.XS),
					SortOrder = Enum.SortOrder.LayoutOrder,
				},
				Label(scope, {
					Text = move.DisplayName,
					Scale = "BodyLarge",
					Color = nameColor,
					LayoutOrder = 1,
				}),
				scope:New "Frame" {
					Name = "Meta",
					Size = UDim2.fromOffset(0, 0),
					AutomaticSize = Enum.AutomaticSize.XY,
					BackgroundTransparency = 1,
					LayoutOrder = 2,

					[Children] = metaChildren,
				},
			},
		},
	}
	-- A Default move can never be deleted (see file header) -- no Delete icon at all, rather than a
	-- disabled one that would invite clicking.
	if not isDefaultMove then
		table.insert(
			rowChildren,
			ActionIcon(scope, {
				Glyph = "ResetData",
				Text = "Delete " .. move.DisplayName,
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.new(1, -Tokens.Space.XS, 0.5, 0),
				Armed = isArmed,
				OnActivated = function()
					if peek(isArmed) then
						isArmed:set(false)
						props.OnDelete(move.MoveId)
					else
						isArmed:set(true)
						task.delay(DELETE_ARM_SECONDS, function()
							isArmed:set(false)
						end)
					end
				end,
			})
		)
	end

	return scope:New "TextButton" {
		Name = move.MoveId,
		Size = UDim2.new(1, 0, 0, ROW_HEIGHT),
		BackgroundColor3 = backgroundColor,
		BackgroundTransparency = backgroundTransparency,
		BorderSizePixel = 0,
		AutoButtonColor = false,
		Text = "",
		LayoutOrder = layoutOrder,

		[OnEvent "Activated"] = function()
			props.OnSelect(move.MoveId)
		end,

		[Children] = rowChildren,
	} :: TextButton
end

type MoveFilter = "Default" | "Custom"

local FILTER_ROW_HEIGHT = Tokens.Control.StepButtonSize
-- Matches FILTER_ROW_HEIGHT so the search box and the filter tabs under it read as one
-- control group rather than two differently-proportioned rows.
local SEARCH_ROW_HEIGHT = Tokens.Control.StepButtonSize

local MoveListModule = {}

function MoveListModule.Mount(scope: Scope, width: number, height: number, props: MoveListProps): Frame
	-- Default vs. Custom moves never mix in one scroll -- see file header. Custom is the default tab
	-- (matches this list's pre-"Default moves" behavior for the common "author/edit a custom move"
	-- workflow); an admin who wants to retune a hand-authored attack switches tabs explicitly.
	local activeFilter: Fusion.Value<MoveFilter> = scope:Value("Custom" :: MoveFilter)
	local searchText = scope:Value("")

	local filteredMoves = scope:Computed(function(use)
		local filter = use(activeFilter)
		local query = string.lower(use(searchText))
		local all = use(props.MovesDisplay)
		local result: { MoveTypes.MoveDefinition } = {}
		for _, move in ipairs(all) do
			local isDefaultMove = move.Category == MoveTypes.DefaultCategory
			if (filter == "Default") == isDefaultMove then
				if query == "" then
					table.insert(result, move)
				else
					-- plain = true (the 4th string.find argument): an admin typing a move name has no
					-- reason to be writing Lua patterns, and a query containing "(" or "-" would
					-- otherwise raise a malformed-pattern error mid-keystroke rather than just matching
					-- nothing. Name AND category, since the Default list is largely distinguished by
					-- which weapon stage a move belongs to.
					local haystack = string.lower(move.DisplayName .. " " .. move.Category)
					if string.find(haystack, query, 1, true) then
						table.insert(result, move)
					end
				end
			end
		end
		return result
	end)

	-- ForPairs (not ForValues -- this codebase's only dynamic-list primitive; see Sidebar.lua's own
	-- player roster), re-keyed by MoveId rather than array index so a MovesDisplay/filter refresh
	-- reuses/updates the same row Instance instead of tearing down and rebuilding every row. Re-keying
	-- by MoveId means the UIListLayout below can no longer rely on child-insertion order to stay
	-- stable -- `index` (filteredMoves' own array position, which for Default moves mirrors
	-- DefaultMoveRegistry.enumerateDescriptors' fixed Primary-then-Secondary/Basic-then-Heavy-then-
	-- Finisher order exactly, and for Custom moves mirrors MovesDisplay's own insertion order) is
	-- threaded through as each row's explicit LayoutOrder, the same "ForPairs row needs its own
	-- LayoutOrder, the key alone doesn't give the UIListLayout one" precedent Screens/DevMenu/
	-- Sidebar.lua's own player roster (`10 + index`) already established. Without this, a row's
	-- on-screen position depended on Roblox's own child-insertion order into the parent Frame instead
	-- of this array's real order -- which a later ForPairs reconciliation (e.g. after Save/Reset
	-- patches one entry in place) is free to change, visibly reshuffling the list.
	local rows = scope:ForPairs(
		filteredMoves,
		function(_use, innerScope: Scope, index: number, move: MoveTypes.MoveDefinition)
			return move.MoveId, MoveRow(innerScope, move, index, props)
		end
	)

	local function filterTab(text: string, filterValue: MoveFilter, layoutOrder: number): TextButton
		return Tab(scope, {
			Text = text,
			Selected = scope:Computed(function(use)
				return use(activeFilter) == filterValue
			end),
			Size = UDim2.new(0.5, -Tokens.Space.XS / 2, 0, FILTER_ROW_HEIGHT),
			LayoutOrder = layoutOrder,
			OnActivated = function()
				activeFilter:set(filterValue)
			end,
		})
	end

	return scope:New "Frame" {
		Name = "MoveList",
		Size = UDim2.fromOffset(width, height),
		BackgroundTransparency = 1,

		[Children] = {
			-- No UIPadding here -- Sidebar.lua's own outer Panel already insets its ENTIRE content
			-- column (this group, the Divider, and the Sections group below it) by Tokens.Space.M on
			-- every side. A second UIPadding here would double up on top of that, needlessly shrinking
			-- every row's already-tight text/delete-icon clearance.
			scope:New "UIListLayout" {
				FillDirection = Enum.FillDirection.Vertical,
				HorizontalAlignment = Enum.HorizontalAlignment.Left,
				Padding = UDim.new(0, Tokens.Space.S),
				SortOrder = Enum.SortOrder.LayoutOrder,
			},
			scope:New "Frame" {
				Name = "Header",
				Size = UDim2.new(1, 0, 0, Tokens.Control.RowHeight),
				BackgroundTransparency = 1,
				LayoutOrder = 1,

				[Children] = {
					Label(scope, {
						Text = "Moves",
						Scale = "CardTitle",
						AnchorPoint = Vector2.new(0, 0.5),
						Position = UDim2.fromScale(0, 0.5),
					}),
					Button(scope, {
						-- Shorter than the old "+ New Move" -- Primary's own TrackedLabel rendering
						-- (tracked, upper-cased caps) needs more horizontal room per character than
						-- native Text does, and a Primary-styled button already reads as an action
						-- without a leading "+".
						Text = "New Move",
						-- Primary -- the one thing an admin would click to start in this column, same
						-- "the one CTA" reasoning the toolbar's own Save button already earns elsewhere
						-- in this editor. Static text, safe for Variant's own peek-once TrackedLabel
						-- rendering (see Button.lua's header).
						Variant = "Primary",
						Size = UDim2.fromOffset(110, Tokens.Control.StepButtonSize),
						AnchorPoint = Vector2.new(1, 0.5),
						Position = UDim2.fromScale(1, 0.5),
						OnActivated = props.OnNew,
					}),
				},
			},
			scope:New "Frame" {
				Name = "SearchRow",
				Size = UDim2.new(1, 0, 0, SEARCH_ROW_HEIGHT),
				BackgroundTransparency = 1,
				LayoutOrder = 2,

				-- No OnFocusLost: TextField two-way binds `Text` into the caller's own Value on every
				-- keystroke (see that component's own header), which is exactly what a search box wants
				-- -- filteredMoves below reads searchText, so the list narrows as the admin types rather
				-- than waiting for them to click away.
				[Children] = TextField(scope, {
					Text = searchText,
					PlaceholderText = "Search moves",
				}),
			},
			scope:New "Frame" {
				Name = "FilterRow",
				Size = UDim2.new(1, 0, 0, FILTER_ROW_HEIGHT),
				BackgroundTransparency = 1,
				LayoutOrder = 3,

				[Children] = {
					scope:New "UIListLayout" {
						FillDirection = Enum.FillDirection.Horizontal,
						Padding = UDim.new(0, Tokens.Space.XS),
						SortOrder = Enum.SortOrder.LayoutOrder,
					},
					filterTab("Custom", "Custom", 1),
					filterTab("Default", "Default", 2),
				},
			},
			ScrollArea(scope, {
				Name = "Rows",
				Size = UDim2.new(
					1,
					0,
					1,
					-(Tokens.Control.RowHeight + SEARCH_ROW_HEIGHT + FILTER_ROW_HEIGHT + Tokens.Space.S * 3)
				),
				LayoutOrder = 4,

				Children = {
					scope:New "UIPadding" {
						PaddingRight = UDim.new(0, Tokens.Space.XS),
					},
					scope:New "UIListLayout" {
						FillDirection = Enum.FillDirection.Vertical,
						Padding = UDim.new(0, Tokens.Space.XS),
						SortOrder = Enum.SortOrder.LayoutOrder,
					},
					rows,
				},
			}),
		},
	} :: Frame
end

return MoveListModule
