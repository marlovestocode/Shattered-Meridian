--!strict
--[[
	Inventory/init.lua

	Owns: the inventory screen -- a ScreenFrame modal whose tabs ARE the inventory's sections
	(Shared/Inventory/InventoryConstants.Sections), each page an item list with a slot meter, beside one
	detail pane for whichever item is selected. docs/design/inventory.md section 7 is the design.

	Follows Screens/Settings/init.lua's boundary exactly: this screen renders and raises intents, and
	Client/Inventory/InventoryClient.lua drives it from outside. It never touches a remote. State goes in
	through SetSnapshot (the server's last full snapshot, verbatim); the one thing a player can DO here,
	discard, leaves through DiscardRequested as (itemId, count) and the client module turns it into a
	request the server re-validates. Nothing on this screen is authoritative -- a stale card is corrected by
	the next snapshot.

	SECTIONS ARE TABS, AND A TAB THAT HAS NOTHING IN IT IS NOT OFFERED. A section flagged HideWhenEmpty
	(Materials, Consumables, Relics) is hidden by ScreenFrame's own availability mechanism until it holds
	an item, so the strip never carries dead tabs and the first item of a new kind makes its tab appear
	with no screen change. Armaments and Resources are always there, with an empty state that says how to
	fill them.

	EVERY SECTION'S PAGE IS BUILT UP FRONT AND TOGGLES ITS OWN VISIBILITY, the same idiom Settings uses,
	rather than one page re-pointed at a different section. That keeps each page's heading static text
	(SectionHeading takes a string) and means switching tabs rebuilds nothing.

	THE LIST IS KEYED BY ITEM ID. A snapshot that changes one count rebuilds that one card, and a card
	reads its count from the section's live dictionary, so a coal gather ticking over never tears down the
	list or resets its scroll position.

	THE SELECTION IS ONE VALUE, NOT ONE PER PAGE. The detail pane shows the selected item if it lives in
	the tab that is showing, else that tab's first item, else its empty state -- derived, never written, so
	a discard that empties a stack or a tab change can never leave the pane describing something that is
	not on screen.

	Rarity is the grade's colour AND its name (Tokens.Rarity). Tile art is the item's initial until items
	carry authored art.

	Does not own: the snapshot (server), discard rules (InventorySystem), the open key or Escape
	(InventoryClient).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local InventoryConstants = require(ReplicatedStorage.Shared.Inventory.InventoryConstants)
local ItemCatalog = require(ReplicatedStorage.Shared.Inventory.ItemCatalog)

local Tokens = require(script.Parent.Parent.Tokens)
local ScreenFrame = require(script.Parent.Parent.Components.ScreenFrame)
local Stack = require(script.Parent.Parent.Components.Stack)
local Inset = require(script.Parent.Parent.Components.Inset)
local Label = require(script.Parent.Parent.Components.Label)
local ScrollArea = require(script.Parent.Parent.Components.ScrollArea)
local SectionHeading = require(script.Parent.Parent.Components.SectionHeading)
local SegmentMeter = require(script.Parent.Parent.Components.SegmentMeter)
local Selection = require(script.Parent.Parent.Components.Selection)
local StatRow = require(script.Parent.Parent.Components.StatRow)
local StatusTag = require(script.Parent.Parent.Components.StatusTag)
local ArmedButton = require(script.Parent.Parent.Components.ArmedButton)
local Divider = require(script.Parent.Parent.Components.Divider)

local Children = Fusion.Children
local OnEvent = Fusion.OnEvent
local peek = Fusion.peek

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>
type SectionDef = InventoryConstants.SectionDef
type SnapshotPayload = InventoryConstants.SnapshotPayload
type SnapshotSection = InventoryConstants.SnapshotSection

export type InventoryHandle = {
	IsOpen: Fusion.Value<boolean>,
	StatusText: Fusion.Value<string>,
	-- Written by InventoryClient with the server's latest snapshot.
	SetSnapshot: (payload: SnapshotPayload) -> (),
	-- Fires (itemId, count) -- the player confirmed a discard.
	DiscardRequested: RBXScriptSignal<(string, number)>,
}

local ROOT_WIDTH = 820
local ROOT_HEIGHT = 560
local DETAIL_WIDTH = 270
local COLUMN_GAP = Tokens.Space.L

local CARD_HEIGHT = 56
local CARD_GAP = Tokens.Space.XS
local CARD_PADDING = Tokens.Space.M
local TILE_SIZE = 40
local DETAIL_TILE_SIZE = 56
local CAP_METER_WIDTH = 72

local SECTION_EMPTY_TEXT: { [string]: string } = {
	Armaments = "No weapons yet. Find one in the world and hold E to take it up.",
	Resources = "Nothing gathered. Mine coal or collect water and it is carried here.",
}
local FALLBACK_EMPTY_TEXT = "Nothing here yet."

local function rarityColor(rarity: string): Color3
	return Tokens.Rarity[rarity] or Tokens.Color.TextSecondary
end

-- The entry order the player sees: highest rarity first, then name -- ItemCatalog.Compare. An id the
-- catalog does not know (an item since removed) is dropped here as well as on the server, so a
-- hand-built payload can never put a nameless card on screen.
local function sortedItemIds(section: SnapshotSection?): { string }
	local ids: { string } = {}
	if not section then
		return ids
	end
	for _, entry in section.Entries do
		if entry.Count > 0 and ItemCatalog.Resolve(entry.ItemId) ~= nil then
			table.insert(ids, entry.ItemId)
		end
	end
	table.sort(ids, function(a, b)
		local defA = ItemCatalog.Resolve(a)
		local defB = ItemCatalog.Resolve(b)
		if defA and defB then
			return ItemCatalog.Compare(defA, defB)
		end
		return a < b
	end)
	return ids
end

local function countsOf(section: SnapshotSection?): { [string]: number }
	local counts: { [string]: number } = {}
	if section then
		for _, entry in section.Entries do
			counts[entry.ItemId] = entry.Count
		end
	end
	return counts
end

-- The square that stands in for item art: the item's initial, bordered in its grade's colour.
local function tile(
	scope: Scope,
	letter: UsedAs<string>,
	color: UsedAs<Color3>,
	size: number,
	centredLeft: boolean
): Frame
	return scope:New "Frame" {
		Name = "Tile",
		AnchorPoint = if centredLeft then Vector2.new(0, 0.5) else Vector2.zero,
		Position = if centredLeft then UDim2.fromScale(0, 0.5) else UDim2.fromOffset(0, 0),
		Size = UDim2.fromOffset(size, size),
		BackgroundColor3 = Tokens.Wash.Inset.Color,
		BackgroundTransparency = Tokens.Wash.Inset.Transparency,
		BorderSizePixel = 0,

		[Children] = {
			scope:New "UIStroke" {
				Color = color,
				Thickness = 1,
				Transparency = 0.35,
			},
			Label(scope, {
				Text = letter,
				Scale = if size > TILE_SIZE then "Heading" else "CardTitle",
				Color = color,
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromScale(1, 1),
				TextXAlignment = Enum.TextXAlignment.Center,
			}),
		},
	} :: Frame
end

local function initialOf(def: ItemCatalog.ItemDef?): string
	if not def then
		return "?"
	end
	return string.upper(string.sub(def.DisplayName, 1, 1))
end

-- One row of the list. The whole card is the hit target, like Menus/EmotesTab's slot cards.
local function itemCard(
	scope: Scope,
	itemId: string,
	index: number,
	counts: Fusion.Computed<{ [string]: number }>,
	selectedId: Fusion.Value<string?>,
	activeId: Fusion.Computed<string?>
): TextButton
	local def = ItemCatalog.Resolve(itemId)
	local color = if def then rarityColor(def.Rarity) else Tokens.Color.TextSecondary
	local engagement = Selection.New(scope)
	local isHovering = engagement.Active

	local count = scope:Computed(function(use)
		return use(counts)[itemId] or 0
	end)
	local isActive = scope:Computed(function(use)
		return use(activeId) == itemId
	end)

	local countText = scope:Computed(function(use)
		-- A weapon (stack of one) has no quantity worth printing; everything else shows what is held.
		if def and def.MaxStack == 1 then
			return ""
		end
		return tostring(use(count))
	end)
	local hasCap = def ~= nil and def.MaxCarry ~= nil and def.MaxStack > 1
	local capMax = if def and def.MaxCarry then def.MaxCarry else 1

	local borderColor = scope:Computed(function(use)
		if use(isActive) then
			return Tokens.Border.Accent.Color
		end
		return if use(isHovering) then Tokens.Border.Standard.Color else Tokens.Border.Hairline.Color
	end)
	local borderTransparency = scope:Computed(function(use)
		if use(isActive) then
			return Tokens.Border.Accent.Transparency
		end
		return if use(isHovering) then Tokens.Border.Standard.Transparency else Tokens.Border.Hairline.Transparency
	end)

	local rightChildren: { Instance } = {
		Label(scope, {
			Text = countText,
			Scale = "Numeral",
			Color = Tokens.Color.TextPrimary,
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, 0, 0, 10),
			Size = UDim2.fromOffset(CAP_METER_WIDTH, 18),
			TextXAlignment = Enum.TextXAlignment.Right,
		}),
	}
	if hasCap then
		table.insert(
			rightChildren,
			SegmentMeter(scope, {
				Value = count,
				Max = capMax,
				Segments = 8,
				Size = UDim2.fromOffset(CAP_METER_WIDTH, 3),
				AnchorPoint = Vector2.new(1, 0),
				Position = UDim2.new(1, 0, 0, 34),
			})
		)
	end

	return scope:New "TextButton" {
		Name = `Item_{itemId}`,
		LayoutOrder = index,
		Size = UDim2.new(1, 0, 0, CARD_HEIGHT),
		AutoButtonColor = false,
		Text = "",
		BackgroundColor3 = scope:Computed(function(use)
			return if use(isActive) or use(isHovering) then Tokens.Color.SurfaceElevated else Tokens.Color.Surface
		end),
		BackgroundTransparency = 0,
		BorderSizePixel = 0,

		[OnEvent "SelectionGained"] = engagement.OnSelectionGained,
		[OnEvent "SelectionLost"] = engagement.OnSelectionLost,
		[OnEvent "MouseEnter"] = engagement.OnPointerEnter,
		[OnEvent "MouseLeave"] = engagement.OnPointerLeave,
		[OnEvent "Activated"] = function()
			selectedId:set(itemId)
		end,

		[Children] = {
			scope:New "UICorner" { CornerRadius = Tokens.Radius.Sharp },
			scope:New "UIStroke" {
				Color = borderColor,
				Thickness = 1,
				Transparency = borderTransparency,
			},
			Inset(scope, { X = CARD_PADDING }),

			-- Placed by hand: the card is a free-form button, not a layout.
			tile(scope, initialOf(def), color, TILE_SIZE, true),
			Label(scope, {
				Text = if def then def.DisplayName else itemId,
				Scale = "Body",
				Color = Tokens.Color.TextPrimary,
				Position = UDim2.fromOffset(TILE_SIZE + CARD_PADDING, 10),
				Size = UDim2.new(1, -(TILE_SIZE + CARD_PADDING + CAP_METER_WIDTH + CARD_PADDING), 0, 18),
			}),
			Label(scope, {
				Text = if def then string.upper(def.Rarity) else "",
				Scale = "Detail",
				Color = color,
				Position = UDim2.fromOffset(TILE_SIZE + CARD_PADDING, 30),
				Size = UDim2.new(1, -(TILE_SIZE + CARD_PADDING + CAP_METER_WIDTH + CARD_PADDING), 0, 16),
			}),
			scope:New "Frame" {
				Name = "Right",
				AnchorPoint = Vector2.new(1, 0),
				Position = UDim2.fromScale(1, 0),
				Size = UDim2.new(0, CAP_METER_WIDTH, 1, 0),
				BackgroundTransparency = 1,
				BorderSizePixel = 0,

				[Children] = rightChildren,
			},
		},
	} :: TextButton
end

-- One section's page: heading with the slot readout, the slot meter, the blurb, then the list (or its
-- empty state).
local function sectionPage(
	scope: Scope,
	def: SectionDef,
	visible: UsedAs<boolean>,
	section: Fusion.Computed<SnapshotSection?>,
	selectedId: Fusion.Value<string?>,
	activeId: Fusion.Computed<string?>
): Frame
	local itemIds = scope:Computed(function(use): { string }
		return sortedItemIds(use(section))
	end)
	local counts = scope:Computed(function(use): { [string]: number }
		return countsOf(use(section))
	end)
	local used = scope:Computed(function(use): number
		local current = use(section)
		return if current then current.Used else 0
	end)
	local limit = scope:Computed(function(use): number
		local current = use(section)
		return if current then current.Limit else def.Slots
	end)
	local isFull = scope:Computed(function(use)
		return use(used) >= use(limit) and use(limit) > 0
	end)
	local slotNote = scope:Computed(function(use)
		local text = `{use(used)} / {use(limit)} slots`
		return if use(isFull) then `{text} - FULL` else text
	end)
	local hasItems = scope:Computed(function(use)
		return #use(itemIds) > 0
	end)

	local cards = scope:ForPairs(itemIds, function(_use, innerScope: Scope, index: number, itemId: string)
		return itemId, itemCard(innerScope, itemId, index, counts, selectedId, activeId)
	end)

	return Stack.New(scope, {
		Name = `Page_{def.Id}`,
		Size = UDim2.fromScale(1, 1),
		Gap = Tokens.Space.S,
		Visible = visible,

		Children = {
			SectionHeading(scope, {
				Text = def.DisplayName,
				Note = slotNote,
				NoteColor = scope:Computed(function(use)
					return if use(isFull) then Tokens.Color.DangerBright else Tokens.Color.TextSecondary
				end),
				LayoutOrder = 1,
			}),
			SegmentMeter(scope, {
				Value = used,
				Max = limit,
				-- One block per slot, so the meter reads as a count of places rather than a percentage.
				Segments = def.Slots,
				FillColor = scope:Computed(function(use)
					return if use(isFull) then Tokens.Color.Danger else Tokens.Color.AccentSecondary
				end),
				Size = UDim2.new(1, 0, 0, 4),
				LayoutOrder = 2,
			}),
			Label(scope, {
				Text = def.Blurb,
				Scale = "Detail",
				Color = Tokens.Color.TextSecondary,
				Size = UDim2.new(1, 0, 0, 18),
				LayoutOrder = 3,
			}),
			Label(scope, {
				Text = SECTION_EMPTY_TEXT[def.Id] or FALLBACK_EMPTY_TEXT,
				Scale = "Detail",
				Color = Tokens.Color.TextDisabled,
				Size = UDim2.new(1, 0, 0, 40),
				AutoHeight = true,
				LineHeight = Tokens.Leading.Prose,
				LayoutOrder = 4,
				Visible = scope:Computed(function(use)
					return not use(hasItems)
				end),
			}),
			Stack.Fill(
				scope,
				ScrollArea(scope, {
					Name = "ItemList",
					Size = UDim2.fromScale(1, 1),
					LayoutOrder = 5,
					Visible = hasItems,

					Children = {
						Inset(scope, { Right = Tokens.Space.S }),
						scope:New "UIListLayout" {
							Padding = UDim.new(0, CARD_GAP),
							SortOrder = Enum.SortOrder.LayoutOrder,
						},
						cards,
					},
				})
			),
		},
	})
end

-- The right-hand pane: whatever the list has selected, in full.
local function detailPane(
	scope: Scope,
	activeId: Fusion.Computed<string?>,
	activeCount: Fusion.Computed<number>,
	onDiscard: (itemId: string, count: number) -> ()
): Frame
	local activeDef = scope:Computed(function(use): ItemCatalog.ItemDef?
		local id = use(activeId)
		return if id then ItemCatalog.Resolve(id) else nil
	end)
	local hasActive = scope:Computed(function(use)
		return use(activeDef) ~= nil
	end)
	local color = scope:Computed(function(use): Color3
		local def = use(activeDef)
		return if def then rarityColor(def.Rarity) else Tokens.Color.TextSecondary
	end)

	local carriedText = scope:Computed(function(use): string
		local def = use(activeDef)
		local count = use(activeCount)
		if not def then
			return ""
		end
		if def.MaxCarry then
			return `{count} / {def.MaxCarry}`
		end
		return tostring(count)
	end)
	local stackText = scope:Computed(function(use): string
		local def = use(activeDef)
		return if def then tostring(def.MaxStack) else ""
	end)
	local slotsText = scope:Computed(function(use): string
		local def = use(activeDef)
		if not def then
			return ""
		end
		return tostring(math.ceil(use(activeCount) / def.MaxStack))
	end)
	local canDiscard = scope:Computed(function(use)
		local def = use(activeDef)
		return def ~= nil and def.Discardable
	end)
	local cannotDiscard = scope:Computed(function(use)
		return use(hasActive) and not use(canDiscard)
	end)

	local filled = Stack.New(scope, {
		Name = "Filled",
		Size = UDim2.fromScale(1, 1),
		Gap = Tokens.Space.M,
		Visible = hasActive,

		Children = {
			-- Identity block: art, name, grade.
			scope:New "Frame" {
				Name = "Identity",
				Size = UDim2.new(1, 0, 0, DETAIL_TILE_SIZE),
				BackgroundTransparency = 1,
				BorderSizePixel = 0,
				LayoutOrder = 1,

				[Children] = {
					tile(
						scope,
						scope:Computed(function(use)
							return initialOf(use(activeDef))
						end),
						color,
						DETAIL_TILE_SIZE,
						false
					),
					Label(scope, {
						Text = scope:Computed(function(use)
							local def = use(activeDef)
							return if def then def.DisplayName else ""
						end),
						Scale = "CardTitle",
						Color = Tokens.Color.TextPrimary,
						Position = UDim2.fromOffset(DETAIL_TILE_SIZE + Tokens.Space.M, 4),
						Size = UDim2.new(1, -(DETAIL_TILE_SIZE + Tokens.Space.M), 0, 24),
					}),
					scope:New "Frame" {
						Name = "Grade",
						Position = UDim2.fromOffset(DETAIL_TILE_SIZE + Tokens.Space.M, 32),
						Size = UDim2.new(1, -(DETAIL_TILE_SIZE + Tokens.Space.M), 0, 20),
						BackgroundTransparency = 1,
						BorderSizePixel = 0,

						[Children] = StatusTag(scope, {
							Label = scope:Computed(function(use)
								local def = use(activeDef)
								return if def then def.Rarity else ""
							end),
							Color = color,
						}),
					},
				},
			},
			Label(scope, {
				Text = scope:Computed(function(use)
					local def = use(activeDef)
					return if def then def.Description else ""
				end),
				Scale = "Detail",
				Color = Tokens.Color.TextSecondary,
				Size = UDim2.new(1, 0, 0, 0),
				AutoHeight = true,
				LineHeight = Tokens.Leading.Prose,
				LayoutOrder = 2,
			}),
			Stack.New(scope, {
				Name = "Facts",
				Size = UDim2.new(1, 0, 0, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				Gap = 0,
				LayoutOrder = 3,

				Children = {
					StatRow(scope, { Caption = "Carried", Value = carriedText, LayoutOrder = 1 }),
					StatRow(scope, { Caption = "Per slot", Value = stackText, LayoutOrder = 2 }),
					StatRow(scope, { Caption = "Slots used", Value = slotsText, LayoutOrder = 3 }),
				},
			}),
			ArmedButton(scope, {
				Idle = "Discard all",
				Armed = "Confirm - cannot be undone",
				WindowSeconds = 3,
				Size = UDim2.new(1, 0, 0, Tokens.Control.RowHeight),
				LayoutOrder = 4,
				Visible = canDiscard,
				OnConfirm = function()
					local id = peek(activeId)
					if id then
						onDiscard(id, peek(activeCount))
					end
				end,
			}),
			Label(scope, {
				Text = "This cannot be discarded. It stays with you.",
				Scale = "Detail",
				Color = Tokens.Color.TextDisabled,
				Size = UDim2.new(1, 0, 0, 18),
				LayoutOrder = 5,
				Visible = cannotDiscard,
			}),
		},
	})

	return Stack.New(scope, {
		Name = "Detail",
		LayoutOrder = 3,
		Size = UDim2.new(0, DETAIL_WIDTH, 1, 0),
		Children = {
			filled,
			Label(scope, {
				Text = "Select an item to see it here.",
				Scale = "Detail",
				Color = Tokens.Color.TextDisabled,
				Size = UDim2.new(1, 0, 0, 20),
				Visible = scope:Computed(function(use)
					return not use(hasActive)
				end),
			}),
		},
	})
end

local function Inventory(scope: Scope, playerGui: PlayerGui): InventoryHandle
	local isOpen = scope:Value(false)
	local statusText = scope:Value("")
	local snapshot = scope:Value(nil :: SnapshotPayload?)
	local selectedId = scope:Value(nil :: string?)

	local discardEvent = Instance.new("BindableEvent")
	table.insert(scope, discardEvent)

	-- Each section's slice of the snapshot, one Computed per section so a page reads only its own.
	local sectionSlices: { [string]: Fusion.Computed<SnapshotSection?> } = {}
	local tabNames: { string } = {}
	local availability: { [string]: UsedAs<boolean> } = {}
	local idByTab: { [string]: string } = {}

	for _, def in InventoryConstants.Sections do
		local sectionId = def.Id
		local slice = scope:Computed(function(use): SnapshotSection?
			local payload = use(snapshot)
			if not payload then
				return nil
			end
			for _, candidate in payload.Sections do
				if candidate.Id == sectionId then
					return candidate
				end
			end
			return nil
		end)
		sectionSlices[sectionId] = slice
		table.insert(tabNames, def.DisplayName)
		idByTab[def.DisplayName] = sectionId
		if def.HideWhenEmpty then
			availability[def.DisplayName] = scope:Computed(function(use)
				return #sortedItemIds(use(slice)) > 0
			end)
		end
	end

	local tabs = ScreenFrame.NewTabState(scope, tabNames, availability)

	-- The selection the pane shows: the clicked item if it lives in the showing tab, else that tab's
	-- first item. Derived, so it can never describe something that is not on screen.
	local shownSlice = scope:Computed(function(use): SnapshotSection?
		local sectionId = idByTab[use(tabs.Shown)]
		local slice = if sectionId then sectionSlices[sectionId] else nil
		return if slice then use(slice) else nil
	end)
	local activeId = scope:Computed(function(use): string?
		local ids = sortedItemIds(use(shownSlice))
		local wanted = use(selectedId)
		if wanted and table.find(ids, wanted) then
			return wanted
		end
		return ids[1]
	end)
	local activeCount = scope:Computed(function(use): number
		local id = use(activeId)
		if not id then
			return 0
		end
		return countsOf(use(shownSlice))[id] or 0
	end)

	local pages: { Instance } = {}
	for _, def in InventoryConstants.Sections do
		table.insert(
			pages,
			sectionPage(scope, def, tabs.Selected[def.DisplayName], sectionSlices[def.Id], selectedId, activeId)
		)
	end

	local listColumn = scope:New "Frame" {
		Name = "Pages",
		LayoutOrder = 1,
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,

		[Children] = pages,
	}

	ScreenFrame.Mount(scope, playerGui, {
		Name = "Inventory",
		Size = UDim2.fromOffset(ROOT_WIDTH, ROOT_HEIGHT),
		IsOpen = isOpen,
		AutoScale = true,
		Tabs = tabs,
		Wordmark = "INVENTORY",
		StatusText = statusText,
		OnClose = function()
			isOpen:set(false)
		end,

		Body = Stack.Row(scope, {
			Name = "Body",
			Gap = COLUMN_GAP,
			Children = {
				Inset(scope, { Top = Tokens.Space.M, Bottom = Tokens.Space.L, X = Tokens.Space.L }),
				Stack.Fill(scope, listColumn),
				Divider.Plain(scope, {
					Size = UDim2.new(0, Tokens.Control.DividerThickness, 1, 0),
					LayoutOrder = 2,
					Tint = Tokens.Border.Standard,
				}),
				detailPane(scope, activeId, activeCount, function(itemId: string, count: number)
					discardEvent:Fire(itemId, count)
				end),
			},
		}),
	})

	return {
		IsOpen = isOpen,
		StatusText = statusText,
		SetSnapshot = function(payload: SnapshotPayload)
			snapshot:set(payload)
		end,
		DiscardRequested = discardEvent.Event,
	}
end

return { Mount = Inventory }
