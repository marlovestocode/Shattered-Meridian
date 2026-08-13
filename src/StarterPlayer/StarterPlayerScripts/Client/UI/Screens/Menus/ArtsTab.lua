--!strict
--[[
	ArtsTab.lua

	Owns: the character menu's Arts section -- the art trees, every art inside the selected one, what
	each costs and what it's gated behind, how much mastery the player has ground into it, and the
	two actions that change any of it: unlock, and equip to a hotbar slot.

	This is the first UI ArtSystem has ever had. The System, ArtTreeManager, the tree roster and the
	Move-Editor-authored arts underneath them all shipped without a surface, which meant an unlocked
	art was unreachable in play: nothing bound it to a key. The equip row at the top of this tab is
	that missing link (Types.PlayerProfile.equippedArts <- Art_Equip <- this file), and it is why
	ArtSystem.UseArt finally has a caller.

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
	drives from outside" boundary Screens/Settings and Screens/DevMenu already hold to.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local ArtConstants = require(ReplicatedStorage.Shared.ArtConstants)
local Types = require(ReplicatedStorage.Shared.Types)

local Tokens = require(script.Parent.Parent.Parent.Tokens)
local Panel = require(script.Parent.Parent.Parent.Components.Panel)
local Label = require(script.Parent.Parent.Parent.Components.Label)
local Button = require(script.Parent.Parent.Parent.Components.Button)
local Tab = require(script.Parent.Parent.Parent.Components.Tab)
local Bar = require(script.Parent.Parent.Parent.Components.Bar)

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

local TREE_STRIP_HEIGHT = 30
local SLOT_STRIP_HEIGHT = 46
local ROW_HEIGHT = 78
local MASTERY_BAR_HEIGHT = 4
-- Vertical budget the tree description (auto-height, one or two lines) and the empty-state line are
-- allowed between the tree strip and the scrolling rows -- the same "spell the layout math out
-- rather than guessing a magic number" convention Screens/Settings/init.lua's own CONTENT_HEIGHT
-- uses. The two never both render at their maximum: an empty tree has no rows to scroll anyway.
local DESCRIPTION_ALLOWANCE = 40

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

-- One art. Four visual states, and each is a different thing to a player: EQUIPPED (on the bar
-- right now), UNLOCKED (owned, not on the bar), UNLOCKABLE (earned, one press away), and LOCKED
-- (gated, with the server's own reason spelled out underneath).
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

	local accent = scope:Computed(function(use)
		if use(isEquipped) then
			return Tokens.Color.AccentSecondary
		end
		if use(isUnlocked) then
			return Tokens.Color.AccentPrimary
		end
		return Tokens.Border.Standard.Color
	end)

	local statusText = scope:Computed(function(use)
		if use(isEquipped) then
			return "Equipped"
		end
		if use(isUnlocked) then
			return `Mastery {use(mastery)} / {ArtConstants.MasteryToUnlockNext}`
		end
		if entry.LockedReason then
			return lockedReasonText(entry.LockedReason)
		end
		return "Ready to unlock"
	end)

	local statusColor = scope:Computed(function(use)
		if use(isUnlocked) then
			return Tokens.Color.TextSecondary
		end
		return if entry.LockedReason then Tokens.Color.TextDisabled else Tokens.Color.Positive
	end)

	-- The action offered depends only on whether the art is owned: an owned art equips to whichever
	-- slot is selected above, an unowned one unlocks (and is disabled outright when the server gave a
	-- reason it can't be). One button, not two -- a row that offers Unlock AND Equip at once invites
	-- the wrong press, since exactly one of them is ever meaningful.
	local actionText = scope:Computed(function(use)
		if use(isEquipped) then
			return "Unequip"
		end
		if use(isUnlocked) then
			return `To slot {use(selectedSlot)}`
		end
		return "Unlock"
	end)

	local actionDisabled = scope:Computed(function(use)
		if use(isUnlocked) then
			return false
		end
		return entry.LockedReason ~= nil
	end)

	return Panel(scope, {
		Name = `Art_{entry.ArtId}`,
		Size = UDim2.new(1, 0, 0, ROW_HEIGHT),
		LayoutOrder = layoutOrder,
		-- A reactive BackgroundColor3 rather than Panel's own `Elevated` flag: that flag is a plain
		-- boolean read once at construction (see Panel.lua), so binding a Computed to it would make
		-- every row permanently elevated -- a Fusion state object is always truthy.
		BackgroundColor3 = scope:Computed(function(use)
			return if use(isEquipped) then Tokens.Color.SurfaceElevated else Tokens.Color.Surface
		end),
		BorderColor3 = accent,
		BorderTransparency = scope:Computed(function(use)
			return if use(isUnlocked) then 0.35 else Tokens.Border.Standard.Transparency
		end),

		Children = {
			scope:New "UIPadding" {
				PaddingTop = UDim.new(0, Tokens.Space.S),
				PaddingBottom = UDim.new(0, Tokens.Space.S),
				PaddingLeft = UDim.new(0, Tokens.Space.M),
				PaddingRight = UDim.new(0, Tokens.Space.M),
			},
			Label(scope, {
				Text = entry.DisplayName,
				Scale = "BodyLarge",
				Color = scope:Computed(function(use)
					return if use(isUnlocked) then Tokens.Color.TextPrimary else Tokens.Color.TextSecondary
				end),
				AnchorPoint = Vector2.new(0, 0),
				Position = UDim2.fromOffset(0, 0),
			}),
			-- Everything the decision needs, on one line: how deep in the tree it sits, what a cast
			-- costs, and the tier it wants.
			Label(scope, {
				Text = `Node {entry.Node}  |  {entry.QiCost} Qi  |  Tier {entry.RequiredTier}+`,
				Scale = "Detail",
				Color = Tokens.Color.TextSecondary,
				AnchorPoint = Vector2.new(0, 0),
				Position = UDim2.fromOffset(0, 22),
			}),
			Label(scope, {
				Text = statusText,
				Scale = "Detail",
				Color = statusColor,
				AnchorPoint = Vector2.new(0, 0),
				Position = UDim2.fromOffset(0, 40),
			}),
			-- Mastery only means something once the art is owned; on a locked row the bar would just be
			-- an empty track implying progress the player can't make yet.
			Bar(scope, {
				Value = mastery,
				Max = ArtConstants.MasteryToUnlockNext,
				FillColor = Tokens.Color.AccentSecondary,
				AnchorPoint = Vector2.new(0, 1),
				Position = UDim2.new(0, 0, 1, 0),
				Size = UDim2.new(0.5, 0, 0, MASTERY_BAR_HEIGHT),
			}),
			Button(scope, {
				Text = actionText,
				Variant = "Secondary",
				Size = UDim2.fromOffset(120, Tokens.Control.StepButtonSize),
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.fromScale(1, 0.5),
				Disabled = actionDisabled,
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
			}),
		},
	}) :: Frame
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

	-- The slot strip: which of the five hotbar slots the "To slot N" action targets, and what is
	-- already in each. Doubles as the loadout readout -- there is nowhere else in the game a player
	-- can see what their own bar holds by name.
	local slotButtons: { Instance } = {
		scope:New "UIListLayout" {
			FillDirection = Enum.FillDirection.Horizontal,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			Padding = UDim.new(0, Tokens.Space.XS),
			SortOrder = Enum.SortOrder.LayoutOrder,
		},
	}
	for slot = 1, ArtConstants.EquipSlotCount do
		table.insert(
			slotButtons,
			Tab(scope, {
				Text = scope:Computed(function(use)
					local artId = use(props.Equipped)[slot]
					-- The ArtId, not a resolved DisplayName: the catalogue this tab happens to be
					-- showing only carries the SELECTED tree's arts, so a slot holding an art from
					-- another tree has no name to look up here. The id is at least honest, and the row
					-- for that art shows "Equipped" in its own tree.
					return if artId then `{slot}. {artId}` else `{slot}. empty`
				end),
				Selected = scope:Computed(function(use)
					return use(selectedSlot) == slot
				end),
				Size = UDim2.fromOffset(118, Tokens.Control.StepButtonSize),
				LayoutOrder = slot,
				OnActivated = function()
					selectedSlot:set(slot)
				end,
			})
		)
	end

	return scope:New "Frame" {
		Name = "ArtsTab",
		Size = UDim2.fromOffset(props.Width, props.Height),
		BackgroundTransparency = 1,
		Visible = props.Visible,
		LayoutOrder = props.LayoutOrder,

		[Children] = {
			scope:New "UIListLayout" {
				FillDirection = Enum.FillDirection.Vertical,
				HorizontalAlignment = Enum.HorizontalAlignment.Left,
				Padding = UDim.new(0, Tokens.Space.S),
				SortOrder = Enum.SortOrder.LayoutOrder,
			},
			scope:New "Frame" {
				Name = "SlotStrip",
				Size = UDim2.new(1, 0, 0, SLOT_STRIP_HEIGHT),
				BackgroundTransparency = 1,
				LayoutOrder = 1,

				[Children] = slotButtons,
			},
			scope:New "Frame" {
				Name = "TreeStrip",
				Size = UDim2.new(1, 0, 0, TREE_STRIP_HEIGHT),
				BackgroundTransparency = 1,
				LayoutOrder = 2,

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
				Size = UDim2.new(1, 0, 0, 0),
				AutoHeight = true,
				LineHeight = Tokens.Leading.Prose,
				LayoutOrder = 3,
			}),
			Label(scope, {
				-- An empty tree is the NORMAL state of a fresh install: arts are Move-Editor-authored
				-- content (ArtConstants' "the trees are content, not code"), so a server with no authored
				-- arts yet has empty trees rather than a broken catalogue. Says so, rather than showing
				-- an unexplained blank.
				Text = "No arts have been authored into this tree yet.",
				Scale = "Detail",
				Color = Tokens.Color.TextDisabled,
				Size = UDim2.new(1, 0, 0, 20),
				LayoutOrder = 4,
				Visible = scope:Computed(function(use)
					return not use(hasArts)
				end),
			}),
			scope:New "ScrollingFrame" {
				Name = "Rows",
				Size = UDim2.new(
					1,
					0,
					1,
					-(SLOT_STRIP_HEIGHT + TREE_STRIP_HEIGHT + DESCRIPTION_ALLOWANCE + Tokens.Space.S * 4)
				),
				BackgroundTransparency = 1,
				BorderSizePixel = 0,
				ScrollingDirection = Enum.ScrollingDirection.Y,
				AutomaticCanvasSize = Enum.AutomaticSize.Y,
				CanvasSize = UDim2.fromScale(0, 0),
				ScrollBarThickness = 3,
				ScrollBarImageColor3 = Tokens.Border.Standard.Color,
				ScrollBarImageTransparency = Tokens.Border.Standard.Transparency,
				LayoutOrder = 5,

				[Children] = {
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
			},
		},
	} :: Frame
end

return ArtsTab
