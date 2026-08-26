--!strict
--[[
	ArtsTab.lua

	Owns: the character menu's Arts section -- the art trees, every art inside the selected one, what
	each costs and what it's gated behind, how much mastery the player has ground into it, and the
	two actions that change any of it: unlock, and equip to a hotbar slot.

	This is the only UI ArtSystem has. The System, ArtTreeManager, the tree roster and the
	Move-Editor-authored arts underneath them all shipped without a surface, which meant an unlocked
	art was unreachable in play: nothing bound it to a key. The slot strip at the top of this tab is
	that missing link (Types.PlayerProfile.equippedArts <- Art_Equip <- this file), and it is why
	ArtSystem.UseArt has a caller.

	THE ROW IS A LEDGER LINE. Each art is one row: name and gate on the left, then two fixed numeric
	columns (qi cost, tier gate) that line up vertically down the whole list, then the single action.
	That column alignment is the entire point of the shape -- comparing two arts means comparing their
	costs, and costs you have to hunt for on differently-sized cards are not comparable.

	The rows DO carry a 1px edge, added 2026-08-20 after the user reported that containers were not
	readable as containers. They originally relied on a fill alone, at a wash faint enough that a row
	over the panel's surface texture had no discernible boundary at all -- which made a list of five
	arts read as one block of floating text. The border is Tokens.Border.Hairline on an ordinary row
	and steps up to the accent tint on the one that is equipped, so the edge carries state instead of
	being pure decoration.

	THE SERVER'S REFUSAL IS THE ONE SHOWN. Every row's locked state comes from
	Types.ArtCatalogueEntry.LockedReason, which ArtSystem.CanUnlock produced server-side -- this file
	translates the reason CODE to player-facing words (lockedReasonText below) and never re-derives
	the rule itself. That is the whole point of the reason travelling with the row: a client that
	computed its own gates would eventually disagree with the server about which arts are available,
	and the player would be told one thing and refused another.

	WHY A TREE PICKER AND NOT ALL FOUR TREES AT ONCE: a player may WALK only trees their faction
	opens (ArtTreeManager.IsTreeOpenTo), but may SEE all of them -- ArtConstants' own header calls
	that out as what makes a tree a goal rather than a surprise. So every tree is listed and
	selectable, and a tree the player can't walk still renders its arts, each carrying the
	WrongFaction refusal the server sent.

	Does not own: any network call. Selecting a slot or pressing Unlock/Equip fires a plain callback
	prop, which Screens/Menus/init.lua turns into a signal that Client/CharacterMenu/
	CharacterMenuClient.lua actually sends -- the same "screen exposes state/signals, client module
	drives from outside" boundary Screens/Settings and Screens/DevTools/DevMenu already hold to.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local ArtConstants = require(ReplicatedStorage.Shared.ArtConstants)
local Types = require(ReplicatedStorage.Shared.Types)

local Tokens = require(script.Parent.Parent.Parent.Tokens)
local Label = require(script.Parent.Parent.Parent.Components.Label)
local TrackedLabel = require(script.Parent.Parent.Parent.Components.TrackedLabel)
local Button = require(script.Parent.Parent.Parent.Components.Button)
local Tab = require(script.Parent.Parent.Parent.Components.Tab)
local Bar = require(script.Parent.Parent.Parent.Components.Bar)
local ScrollArea = require(script.Parent.Parent.Parent.Components.ScrollArea)
local SectionHeading = require(script.Parent.Parent.Parent.Components.SectionHeading)
local Stack = require(script.Parent.Parent.Parent.Components.Stack)

local Children = Fusion.Children
local peek = Fusion.peek

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>

export type ArtsTabProps = {
	Width: number,
	Height: number,
	Visible: UsedAs<boolean>,
	LayoutOrder: number,
	-- The catalogue as the server sent it (Types.ArtCatalogueResult.Trees), refetched on every menu
	-- open and after every successful unlock -- LockedReason on each row is only true as of the
	-- moment it was fetched.
	Trees: UsedAs<{ Types.ArtCatalogueTree }>,
	-- Live per-art mastery from Art_StateUpdated, separate from the catalogue above because it
	-- changes on every confirmed use (mid-fight), where the catalogue only changes on an unlock.
	Mastery: UsedAs<{ [string]: number }>,
	-- Slot index -> ArtId, from the same Art_StateUpdated payload.
	Equipped: UsedAs<{ [number]: string }>,
	OnUnlock: (artId: string) -> (),
	-- artId nil clears the slot.
	OnEquip: (slot: number, artId: string?) -> (),
}

local SLOT_STRIP_HEIGHT = 38
local TREE_STRIP_HEIGHT = 34
local GAP = Tokens.Space.S

local ROW_HEIGHT = 66
local ROW_PADDING_X = Tokens.Space.M
local ACTION_WIDTH = 104
local ACTION_HEIGHT = 34
local STAT_WIDTH = 44
local COLUMN_GAP = Tokens.Space.M
local MASTERY_BAR_HEIGHT = 2
-- Two numeric columns, not three. Mastery gets the underline and the subtitle line instead of a
-- column of its own: qi cost and tier gate are what a player COMPARES between two arts (and so must
-- line up vertically), where mastery is a fact about the one row you're already reading. A third
-- column bought that alignment for a number nobody cross-references, and cost the name column the
-- ~55px that let a long art name and its gate line fit without truncating.
local STAT_COLUMN_COUNT = 2
-- Width the fixed right-hand side of a row occupies: the action control, both numeric columns, and
-- the three gaps separating them from each other and from the flexing name column.
local FIXED_COLUMNS_WIDTH = ACTION_WIDTH + COLUMN_GAP * (STAT_COLUMN_COUNT + 1) + STAT_WIDTH * STAT_COLUMN_COUNT

-- Reason CODE -> the sentence a player reads. Every key is a string ArtSystem.CanUnlock can
-- actually return; an unrecognized code falls through to the code itself rather than to silence,
-- so a future refusal reason shows up as something odd on screen instead of a row that looks
-- available and then refuses.
local LOCKED_REASON_TEXT: { [string]: string } = {
	WrongFaction = "Your faction cannot walk this tree",
	TierTooLow = "Tier too low",
	PrerequisiteNotMastered = "Master the form below it first",
	BrokenPrerequisite = "Unavailable -- its prerequisite is missing",
	ProfileNotLoaded = "Profile still loading",
	UnknownArt = "This art no longer exists",
	RateLimited = "Slow down",
}

local function lockedReasonText(reason: string): string
	return LOCKED_REASON_TEXT[reason] or reason
end

-- One of the row's fixed numeric columns: a tracked caps caption over a mono value, both centred, at a width shared by every row so the columns line up down the whole list. `offsetRight`
-- is the column's distance from the row's right edge -- laid out from the right because the action
-- control is the fixed anchor and the name column is the one that flexes.
local function statColumn(
	scope: Scope,
	caption: string,
	value: UsedAs<string>,
	color: UsedAs<Color3>,
	offsetRight: number
): Frame
	return scope:New "Frame" {
		Name = `Column{caption}`,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -offsetRight, 0.5, 0),
		Size = UDim2.fromOffset(STAT_WIDTH, 36),
		BackgroundTransparency = 1,

		[Children] = {
			TrackedLabel(scope, {
				Text = caption,
				Scale = "Chip",
				Color = Tokens.Color.TextSecondary,
				AnchorPoint = Vector2.new(0.5, 0),
				Position = UDim2.fromScale(0.5, 0),
			}),
			Label(scope, {
				Text = value,
				Scale = "Numeral",
				Color = color,
				AnchorPoint = Vector2.new(0.5, 1),
				Position = UDim2.fromScale(0.5, 1),
				Size = UDim2.new(1, 0, 0, 18),
				TextXAlignment = Enum.TextXAlignment.Center,
			}),
		},
	} :: Frame
end

-- One art. Four states, and each is a different thing to a player: EQUIPPED (on the bar right now),
-- UNLOCKED (owned, not on the bar), UNLOCKABLE (earned, one press away), and LOCKED (gated, with the
-- server's own reason spelled out under the name).
local function artRow(
	scope: Scope,
	entry: Types.ArtCatalogueEntry,
	layoutOrder: number,
	selectedSlot: UsedAs<number>,
	props: ArtsTabProps
): Frame
	local mastery = scope:Computed(function(use)
		return use(props.Mastery)[entry.ArtId] or 0
	end)

	local isEquipped = scope:Computed(function(use)
		for _, artId in pairs(use(props.Equipped)) do
			if artId == entry.ArtId then
				return true
			end
		end
		return false
	end)

	-- Unlocked is read from the LIVE mastery map, not from the catalogue row's own Unlocked flag:
	-- mastery arrives over Art_StateUpdated the instant an unlock commits, where the catalogue is a
	-- snapshot that could still be in flight. A key present means unlocked (ArtSystem's own
	-- "unlocked is having a mastery entry" rule), so this stays correct for mastery 0.
	local isUnlocked = scope:Computed(function(use)
		return use(props.Mastery)[entry.ArtId] ~= nil or entry.Unlocked
	end)

	-- LockedReason is a property of the CATALOGUE SNAPSHOT, not live state -- the whole catalogue is
	-- refetched (and every row rebuilt) after any unlock -- so branching on it at construction is
	-- safe here in a way that branching on isUnlocked/isEquipped would not be.
	local isGated = entry.LockedReason ~= nil

	local nameColor = scope:Computed(function(use)
		if isGated and not use(isUnlocked) then
			return Tokens.Color.TextDisabled
		end
		return if use(isUnlocked) then Tokens.Color.TextPrimary else Tokens.Color.TextSecondary
	end)

	local subtitleText = scope:Computed(function(use)
		if use(isEquipped) then
			return `Node {entry.Node}  --  on your bar`
		end
		if use(isUnlocked) then
			return `Node {entry.Node}  --  {use(mastery)} uses toward the next form`
		end
		if entry.LockedReason then
			return `Node {entry.Node}  --  {lockedReasonText(entry.LockedReason)}`
		end
		return `Node {entry.Node}  --  ready to unlock`
	end)

	local subtitleColor = scope:Computed(function(use)
		if use(isUnlocked) then
			return Tokens.Color.TextSecondary
		end
		return if isGated then Tokens.Color.TextDisabled else Tokens.Color.Positive
	end)

	-- The action offered depends only on whether the art is owned: an owned art equips to whichever
	-- slot is selected above, an unowned one unlocks. One control, not two -- a row that offers
	-- Unlock AND Equip at once invites the wrong press, since exactly one is ever meaningful.
	local actionText = scope:Computed(function(use)
		if use(isEquipped) then
			return "Unequip"
		end
		if use(isUnlocked) then
			return `Slot {use(selectedSlot)}`
		end
		return "Unlock"
	end)

	local action: Instance
	if isGated then
		-- A gated row's button was always disabled, so it was a control that could never be pressed
		-- sitting exactly where a pressable one sits on every neighbouring row. This is bare tracked
		-- caps -- no fill, no border, nothing that could be mistaken for something to click. It was
		-- briefly a StatusTag, which was still wrong: a badge is a painted object and this is an
		-- absence, so the word alone is the honest rendering. The reason is on the subtitle line.
		action = TrackedLabel(scope, {
			Text = "LOCKED",
			Scale = "Chip",
			Color = Tokens.Color.TextDisabled,
		})
	else
		action = Button(scope, {
			Text = actionText,
			Variant = "Secondary",
			Size = UDim2.fromOffset(ACTION_WIDTH, ACTION_HEIGHT),
			OnActivated = function()
				if peek(isEquipped) then
					-- Clearing the slot this art actually occupies, which is not necessarily the one
					-- currently selected above -- unequipping from a different slot than the art sits
					-- in would silently do nothing.
					for slot, artId in pairs(peek(props.Equipped)) do
						if artId == entry.ArtId then
							props.OnEquip(slot, nil)
							return
						end
					end
					return
				end
				if peek(isUnlocked) then
					props.OnEquip(peek(selectedSlot), entry.ArtId)
					return
				end
				props.OnUnlock(entry.ArtId)
			end,
		})
	end

	local qiCostText = tostring(entry.QiCost)
	local tierText = `{entry.RequiredTier}+`

	return scope:New "Frame" {
		Name = `Art_{entry.ArtId}`,
		Size = UDim2.new(1, 0, 0, ROW_HEIGHT),
		LayoutOrder = layoutOrder,
		BackgroundColor3 = scope:Computed(function(use)
			return if use(isEquipped) then Tokens.Color.SurfaceElevated else Tokens.Color.Surface
		end),
		-- An equipped art is the only row that lifts off the list; everything else sits at the wash
		-- level so the column alignment, not a box, is what organizes the eye.
		BackgroundTransparency = scope:Computed(function(use)
			if use(isEquipped) then
				return 0
			end
			return if use(isUnlocked) then 0.35 else 0.6
		end),
		BorderSizePixel = 0,

		[Children] = {
			scope:New "UICorner" {
				CornerRadius = Tokens.Radius.Sharp,
			},
			-- The row's own edge. Accent on the equipped row, the panel-edge tint on an owned one,
			-- and the faint inset tint on everything else -- so the border strength IS the row's
			-- state, read before any of its text is.
			scope:New "UIStroke" {
				Color = scope:Computed(function(use)
					if use(isEquipped) then
						return Tokens.Border.Accent.Color
					end
					return if use(isUnlocked) then Tokens.Border.Standard.Color else Tokens.Border.Hairline.Color
				end),
				Thickness = 1,
				Transparency = scope:Computed(function(use)
					if use(isEquipped) then
						return Tokens.Border.Accent.Transparency
					end
					return if use(isUnlocked)
						then Tokens.Border.Standard.Transparency
						else Tokens.Border.Hairline.Transparency
				end),
			},
			scope:New "UIPadding" {
				PaddingLeft = UDim.new(0, ROW_PADDING_X),
				PaddingRight = UDim.new(0, ROW_PADDING_X),
			},

			-- Name column. Flexes with the row; every column to its right is fixed.
			scope:New "Frame" {
				Name = "Identity",
				Size = UDim2.new(1, -FIXED_COLUMNS_WIDTH, 1, 0),
				BackgroundTransparency = 1,

				[Children] = {
					Label(scope, {
						Text = entry.DisplayName,
						Scale = "BodyLarge",
						Color = nameColor,
						AnchorPoint = Vector2.new(0, 0),
						Position = UDim2.fromOffset(0, 11),
						Size = UDim2.new(1, 0, 0, 20),
					}),
					Label(scope, {
						Text = subtitleText,
						Scale = "Detail",
						Color = subtitleColor,
						AnchorPoint = Vector2.new(0, 0),
						Position = UDim2.fromOffset(0, 33),
						Size = UDim2.new(1, 0, 0, 16),
					}),
					-- The mastery underline: progress toward the next form in the tree, drawn as the
					-- name column's own bottom edge. Reads as an underline rather than as a meter,
					-- which is right for something that only matters once the art is owned.
					Bar(scope, {
						Value = mastery,
						Max = ArtConstants.MasteryToUnlockNext,
						FillColor = Tokens.Color.AccentSecondary,
						FillColorSecondary = Tokens.Color.AccentSecondary,
						AnchorPoint = Vector2.new(0, 1),
						Position = UDim2.new(0, 0, 1, -8),
						Size = UDim2.new(0.72, 0, 0, MASTERY_BAR_HEIGHT),
					}),
				},
			},

			statColumn(scope, "QI", qiCostText, Tokens.VitalColor.Qi, ACTION_WIDTH + COLUMN_GAP * 2 + STAT_WIDTH),
			statColumn(scope, "TIER", tierText, Tokens.Color.TextSecondary, ACTION_WIDTH + COLUMN_GAP),

			scope:New "Frame" {
				Name = "Action",
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.fromScale(1, 0.5),
				Size = UDim2.fromOffset(ACTION_WIDTH, ACTION_HEIGHT),
				BackgroundTransparency = 1,

				[Children] = {
					-- Right-aligned inside a fixed holder so the Locked chip (content-sized) and the
					-- Button (fixed-width) both land on the same right edge -- see
					-- Components/SectionHeading.lua's Accessory holder for the same shape and the same
					-- reason.
					scope:New "UIListLayout" {
						FillDirection = Enum.FillDirection.Horizontal,
						HorizontalAlignment = Enum.HorizontalAlignment.Right,
						VerticalAlignment = Enum.VerticalAlignment.Center,
						SortOrder = Enum.SortOrder.LayoutOrder,
					},
					action,
				},
			},
		},
	} :: Frame
end

local function ArtsTab(scope: Scope, props: ArtsTabProps): Frame
	local selectedTreeId: Fusion.Value<string?> = scope:Value(nil :: string?)
	local selectedSlot = scope:Value(1)

	-- Falls back to the FIRST tree in the catalogue whenever nothing is explicitly selected (the
	-- initial open) or the selected tree is no longer in the payload (an art roster edited live
	-- underneath an open menu). Resolving this here, rather than seeding selectedTreeId when the
	-- catalogue arrives, keeps the fallback correct at every later moment too instead of only at the
	-- one instant the seed ran.
	local activeTree = scope:Computed(function(use): Types.ArtCatalogueTree?
		local trees = use(props.Trees)
		local wanted = use(selectedTreeId)
		for _, tree in ipairs(trees) do
			if tree.TreeId == wanted then
				return tree
			end
		end
		return trees[1]
	end)

	local treeTabs = scope:ForPairs(props.Trees, function(_use, innerScope: Scope, index: number, tree)
		return tree.TreeId,
			Tab(innerScope, {
				Text = tree.DisplayName,
				Selected = innerScope:Computed(function(use)
					local active = use(activeTree)
					return active ~= nil and active.TreeId == tree.TreeId
				end),
				Size = UDim2.fromOffset(150, TREE_STRIP_HEIGHT),
				LayoutOrder = index,
				OnActivated = function()
					selectedTreeId:set(tree.TreeId)
				end,
			})
	end)

	local treeDescription = scope:Computed(function(use)
		local active = use(activeTree)
		if not active then
			return "No art trees are available yet."
		end
		local gate = if active.Faction == nil then "Open to every cultivator." else `{active.Faction} sects only.`
		return `{active.Description}  {gate}`
	end)

	local activeArts = scope:Computed(function(use): { Types.ArtCatalogueEntry }
		local active = use(activeTree)
		return if active then active.Arts else {}
	end)

	local rows = scope:ForPairs(activeArts, function(_use, innerScope: Scope, index: number, entry)
		return entry.ArtId, artRow(innerScope, entry, index, selectedSlot, props)
	end)

	local hasArts = scope:Computed(function(use)
		return #use(activeArts) > 0
	end)

	local knownNote = scope:Computed(function(use)
		local arts = use(activeArts)
		local mastered = use(props.Mastery)
		local known = 0
		for _, entry in ipairs(arts) do
			if mastered[entry.ArtId] ~= nil or entry.Unlocked then
				known += 1
			end
		end
		return `{known} / {#arts} known`
	end)

	local slotNote = scope:Computed(function(use)
		local slot = use(selectedSlot)
		local artId = use(props.Equipped)[slot]
		return if artId then `slot {slot} -- {artId}` else `slot {slot} -- empty`
	end)

	-- The slot strip: which of the hotbar slots the row action targets, and what is already in each.
	-- Doubles as the loadout readout -- there is nowhere else in the game a player can see what their
	-- own bar holds by name.
	local slotButtons: { Instance } = {
		scope:New "UIListLayout" {
			FillDirection = Enum.FillDirection.Horizontal,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			Padding = UDim.new(0, Tokens.Space.XS),
			SortOrder = Enum.SortOrder.LayoutOrder,
		},
	}
	local slotCount = ArtConstants.EquipSlotCount
	for slot = 1, slotCount do
		table.insert(
			slotButtons,
			Tab(scope, {
				Text = scope:Computed(function(use)
					local artId = use(props.Equipped)[slot]
					-- The ArtId, not a resolved DisplayName: the catalogue this tab happens to be
					-- showing only carries the SELECTED tree's arts, so a slot holding an art from
					-- another tree has no name to look up here. The id is at least honest, and the row
					-- for that art shows "on your bar" in its own tree.
					return if artId then `{slot}. {artId}` else `{slot}. empty`
				end),
				Selected = scope:Computed(function(use)
					return use(selectedSlot) == slot
				end),
				-- Equal shares of the strip minus each chip's share of the gaps between them, so the
				-- run always ends flush with the column's right edge however many slots exist.
				Size = UDim2.new(1 / slotCount, -Tokens.Space.XS * (slotCount - 1) / slotCount, 0, SLOT_STRIP_HEIGHT),
				LayoutOrder = slot,
				OnActivated = function()
					selectedSlot:set(slot)
				end,
			})
		)
	end

	return Stack.New(scope, {
		Name = "ArtsTab",
		Size = UDim2.fromOffset(props.Width, props.Height),
		Gap = GAP,
		Visible = props.Visible,
		LayoutOrder = props.LayoutOrder,

		Children = {
			SectionHeading(scope, {
				Text = "Hotbar Slots",
				Note = slotNote,
				LayoutOrder = 1,
			}),
			scope:New "Frame" {
				Name = "SlotStrip",
				Size = UDim2.new(1, 0, 0, SLOT_STRIP_HEIGHT),
				BackgroundTransparency = 1,
				LayoutOrder = 2,

				[Children] = slotButtons,
			},

			scope:New "Frame" {
				Name = "TreeStrip",
				Size = UDim2.new(1, 0, 0, TREE_STRIP_HEIGHT),
				BackgroundTransparency = 1,
				LayoutOrder = 3,

				[Children] = {
					scope:New "UIListLayout" {
						FillDirection = Enum.FillDirection.Horizontal,
						Padding = UDim.new(0, Tokens.Space.XS),
						SortOrder = Enum.SortOrder.LayoutOrder,
					},
					treeTabs,
				},
			},
			Label(scope, {
				Text = treeDescription,
				Scale = "Detail",
				Color = Tokens.Color.TextSecondary,
				Size = UDim2.fromScale(1, 0),
				AutoHeight = true,
				LineHeight = Tokens.Leading.Prose,
				LayoutOrder = 4,
			}),

			SectionHeading(scope, {
				Text = "Arts",
				Note = knownNote,
				LayoutOrder = 5,
			}),
			Label(scope, {
				-- An empty tree is the NORMAL state of a fresh install: arts are Move-Editor-authored
				-- content (ArtConstants' "the trees are content, not code"), so a server with no
				-- authored arts yet has empty trees rather than a broken catalogue. Says so, rather
				-- than showing an unexplained blank.
				Text = "No arts have been authored into this tree yet.",
				Scale = "Detail",
				Color = Tokens.Color.TextSecondary,
				Size = UDim2.new(1, 0, 0, 20),
				LayoutOrder = 6,
				Visible = scope:Computed(function(use)
					return not use(hasArts)
				end),
			}),
			-- Takes whatever the six children above it left. This was the worst of the ten allowance
			-- sites: a six-term sum that included DESCRIPTION_ALLOWANCE, a GUESS at how tall an
			-- auto-height, server-authored tree description would render -- so a two-line description
			-- where one was budgeted pushed the rows off the bottom of the tab with nothing reporting
			-- it. The description is now measured by the engine and the rows take what is left.
			Stack.Fill(
				scope,
				ScrollArea(scope, {
					Name = "Rows",
					Size = UDim2.fromScale(1, 1),
					LayoutOrder = 7,

					Children = {
						scope:New "UIPadding" {
							PaddingRight = UDim.new(0, Tokens.Space.S),
						},
						scope:New "UIListLayout" {
							FillDirection = Enum.FillDirection.Vertical,
							Padding = UDim.new(0, Tokens.Space.XS),
							SortOrder = Enum.SortOrder.LayoutOrder,
						},
						rows,
					},
				})
			),
		},
	})
end

return ArtsTab
