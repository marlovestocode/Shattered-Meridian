--!strict
--[[
	EmotesTab.lua

	Owns: the character menu's emote loadout editor -- the EmoteConstants.LoadoutSize wheel slots as
	a grid of cards, every emote this player has unlocked below them, and one click to put one in the
	selected slot.

	WHY THIS EXISTS HERE. The Emote System shipped complete on both sides -- unlock tracking,
	persistence, the Emote_RequestSetLoadoutSlot remote, and the radial wheel that plays whatever is
	in a slot -- with no way for a player to ever CHANGE a slot. The loadout every player has is the
	one Constants' DefaultLoadout gave them, and unlocking an emote outside it did nothing visible.
	One click here is the whole missing half.

	THE SLOTS ARE CARDS, NOT A CHIP STRIP, because a wheel slot is a place rather than a filter. The
	previous version rendered them as a wrapping row of Tab chips reading "3. Cultivation Stance",
	which is the vocabulary this UI uses for "pick one of these views" -- and a player looking at
	their loadout is reading a board of eight positions, each either filled or empty, not choosing
	between eight tabs. The card carries the position number in its own box, the way the wheel itself
	shows it.

	Reads ClientState, not a fetch of its own: UnlockedEmoteIds and EmoteLoadout are already
	replicated there for the wheel (see ClientState.lua's own header on why those two are shared
	rather than screen-local), so this tab renders the same live state the wheel does and can never
	drift from it.

	NAMES COME FROM THE REGISTRY, ids do not. Shared/Emotes/EmoteRegistry.lua is the client-readable
	definition table the wheel already reads, so an unlocked emote renders under its authored display
	name here too rather than as a raw id.

	Does not own: the request. Clicking fires an OnAssign prop that Screens/Menus/init.lua turns into
	a signal for Client/CharacterMenu/CharacterMenuClient.lua to send -- same boundary every other
	tab in this screen holds.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local EmoteConstants = require(ReplicatedStorage.Shared.EmoteConstants)
local EmoteRegistry = require(ReplicatedStorage.Shared.Emotes.EmoteRegistry)
local Types = require(ReplicatedStorage.Shared.Types)

local Tokens = require(script.Parent.Parent.Parent.Tokens)
local Label = require(script.Parent.Parent.Parent.Components.Label)
local Button = require(script.Parent.Parent.Parent.Components.Button)
local ScrollArea = require(script.Parent.Parent.Parent.Components.ScrollArea)
local SectionHeading = require(script.Parent.Parent.Parent.Components.SectionHeading)
local Stack = require(script.Parent.Parent.Parent.Components.Stack)
local ClientStateModule = require(script.Parent.Parent.Parent.State.ClientState)

local Children = Fusion.Children
local OnEvent = Fusion.OnEvent
local peek = Fusion.peek

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>

export type EmotesTabProps = {
	Width: number,
	Height: number,
	Visible: UsedAs<boolean>,
	LayoutOrder: number,
	State: ClientStateModule.ClientState,
	OnAssign: (slot: number, emoteId: Types.EmoteId) -> (),
}

local HINT_HEIGHT = 20
local GAP = Tokens.Space.S

local SLOT_COLUMNS = 2
local SLOT_CARD_HEIGHT = 62
local SLOT_CARD_GAP = Tokens.Space.S
local SLOT_KEY_SIZE = 32
local SLOT_CARD_PADDING = Tokens.Space.M

local EMOTE_COLUMNS = 3
local EMOTE_BUTTON_HEIGHT = 36
local EMOTE_GAP = Tokens.Space.XS

local SLOT_ROWS = math.ceil(EmoteConstants.LoadoutSize / SLOT_COLUMNS)
local SLOT_GRID_HEIGHT = SLOT_ROWS * SLOT_CARD_HEIGHT + (SLOT_ROWS - 1) * SLOT_CARD_GAP

local function displayNameFor(emoteId: Types.EmoteId): string
	local definition = EmoteRegistry.Get(emoteId)
	-- An id with no definition is a retired emote still sitting in a saved loadout
	-- (Types.PlayerProfile.emoteLoadout's own header calls out that this can happen). Shows the id
	-- rather than hiding the slot, so a player can see WHY that slot does nothing and replace it.
	return if definition then definition.DisplayName else emoteId
end

-- One wheel position. The whole card is the hit target rather than a control inside it: selecting a
-- slot is the only thing a card does, so anything smaller than the card would be a smaller target
-- for no reason (and Tokens.Control.TouchTargetSize exists because this UI skews touch).
local function slotCard(
	scope: Scope,
	slot: number,
	state: ClientStateModule.ClientState,
	selectedSlot: Fusion.Value<number>
): TextButton
	local isHovering = scope:Value(false)

	local assignedId = scope:Computed(function(use): Types.EmoteId?
		return use(state.EmoteLoadout)[slot]
	end)
	local isAssigned = scope:Computed(function(use)
		return use(assignedId) ~= nil
	end)
	local isSelected = scope:Computed(function(use)
		return use(selectedSlot) == slot
	end)

	local nameText = scope:Computed(function(use)
		local emoteId = use(assignedId)
		return if emoteId then displayNameFor(emoteId) else "Empty"
	end)
	local stateText = scope:Computed(function(use)
		return if use(isAssigned) then "On the wheel" else "Nothing assigned"
	end)

	local borderColor = scope:Computed(function(use)
		if use(isSelected) then
			return Tokens.Border.Accent.Color
		end
		return if use(isAssigned) or use(isHovering) then Tokens.Border.Standard.Color else Tokens.Border.Hairline.Color
	end)
	local borderTransparency = scope:Computed(function(use)
		if use(isSelected) then
			return Tokens.Border.Accent.Transparency
		end
		return if use(isAssigned) or use(isHovering)
			then Tokens.Border.Standard.Transparency
			else Tokens.Border.Hairline.Transparency
	end)

	local keyColor = scope:Computed(function(use)
		return if use(isAssigned) then Tokens.Color.AccentPrimaryBright else Tokens.Color.TextDisabled
	end)

	return scope:New "TextButton" {
		Name = `Slot{slot}`,
		LayoutOrder = slot,
		AutoButtonColor = false,
		Text = "",
		BackgroundColor3 = scope:Computed(function(use)
			return if use(isSelected) or use(isHovering) then Tokens.Color.SurfaceElevated else Tokens.Color.Surface
		end),
		BackgroundTransparency = scope:Computed(function(use)
			return if use(isAssigned) or use(isSelected) then 0 else 0.4
		end),
		BorderSizePixel = 0,

		[OnEvent "MouseEnter"] = function()
			isHovering:set(true)
		end,
		[OnEvent "MouseLeave"] = function()
			isHovering:set(false)
		end,
		[OnEvent "Activated"] = function()
			selectedSlot:set(slot)
		end,

		[Children] = {
			scope:New "UICorner" {
				CornerRadius = Tokens.Radius.Sharp,
			},
			scope:New "UIStroke" {
				Color = borderColor,
				Thickness = 1,
				Transparency = borderTransparency,
			},
			scope:New "UIPadding" {
				PaddingLeft = UDim.new(0, SLOT_CARD_PADDING),
				PaddingRight = UDim.new(0, SLOT_CARD_PADDING),
			},

			Label(scope, {
				Text = nameText,
				Scale = "Body",
				Color = scope:Computed(function(use)
					return if use(isAssigned) then Tokens.Color.TextPrimary else Tokens.Color.TextDisabled
				end),
				AnchorPoint = Vector2.new(0, 0),
				Position = UDim2.fromOffset(0, 12),
				Size = UDim2.new(1, -(SLOT_KEY_SIZE + Tokens.Space.M), 0, 18),
			}),
			Label(scope, {
				Text = stateText,
				Scale = "Detail",
				Color = Tokens.Color.TextSecondary,
				AnchorPoint = Vector2.new(0, 0),
				Position = UDim2.fromOffset(0, 33),
				Size = UDim2.new(1, -(SLOT_KEY_SIZE + Tokens.Space.M), 0, 16),
			}),

			-- The position number, boxed the way the wheel itself shows it -- this is the one thing
			-- on the card that maps to something the player does with their hand.
			scope:New "Frame" {
				Name = "Key",
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.fromScale(1, 0.5),
				Size = UDim2.fromOffset(SLOT_KEY_SIZE, SLOT_KEY_SIZE),
				BackgroundColor3 = Tokens.Wash.Inset.Color,
				BackgroundTransparency = Tokens.Wash.Inset.Transparency,
				BorderSizePixel = 0,

				[Children] = {
					scope:New "UIStroke" {
						Color = borderColor,
						Thickness = 1,
						Transparency = borderTransparency,
					},
					Label(scope, {
						Text = tostring(slot),
						Scale = "Numeral",
						Color = keyColor,
						AnchorPoint = Vector2.new(0.5, 0.5),
						Position = UDim2.fromScale(0.5, 0.5),
						Size = UDim2.fromScale(1, 1),
						TextXAlignment = Enum.TextXAlignment.Center,
					}),
				},
			},
		},
	} :: TextButton
end

local function EmotesTab(scope: Scope, props: EmotesTabProps): Frame
	local state = props.State
	local selectedSlot = scope:Value(1)

	local slotChildren: { Instance } = {
		scope:New "UIGridLayout" {
			CellSize = UDim2.new(1 / SLOT_COLUMNS, -SLOT_CARD_GAP / 2, 0, SLOT_CARD_HEIGHT),
			CellPadding = UDim2.fromOffset(SLOT_CARD_GAP, SLOT_CARD_GAP),
			SortOrder = Enum.SortOrder.LayoutOrder,
		},
	}
	for slot = 1, EmoteConstants.LoadoutSize do
		table.insert(slotChildren, slotCard(scope, slot, state, selectedSlot))
	end

	-- The unlocked set is a dict (ClientState keeps it that way for O(1) wheel lookups), and a dict
	-- has no order -- sorted by display name here so the grid doesn't reshuffle itself between opens.
	local unlockedIds = scope:Computed(function(use): { Types.EmoteId }
		local ids: { Types.EmoteId } = {}
		for emoteId in pairs(use(state.UnlockedEmoteIds)) do
			table.insert(ids, emoteId)
		end
		table.sort(ids, function(a, b)
			return displayNameFor(a) < displayNameFor(b)
		end)
		return ids
	end)

	local hasUnlocked = scope:Computed(function(use)
		return #use(unlockedIds) > 0
	end)
	local unlockedNote = scope:Computed(function(use)
		return `{#use(unlockedIds)} known`
	end)
	local selectedNote = scope:Computed(function(use)
		return `slot {use(selectedSlot)} selected`
	end)

	local emoteButtons = scope:ForPairs(unlockedIds, function(_use, innerScope: Scope, index: number, emoteId)
		return emoteId,
			Button(innerScope, {
				Text = displayNameFor(emoteId),
				Variant = "Secondary",
				LayoutOrder = index,
				OnActivated = function()
					props.OnAssign(peek(selectedSlot), emoteId)
				end,
			})
	end)

	return Stack.New(scope, {
		Name = "EmotesTab",
		Size = UDim2.fromOffset(props.Width, props.Height),
		Gap = GAP,
		Visible = props.Visible,
		LayoutOrder = props.LayoutOrder,

		Children = {
			SectionHeading(scope, {
				Text = "Wheel Slots",
				Note = selectedNote,
				LayoutOrder = 1,
			}),
			Label(scope, {
				Text = "Pick a slot, then an emote below. The wheel plays whatever sits here.",
				Scale = "Detail",
				Color = Tokens.Color.TextSecondary,
				Size = UDim2.new(1, 0, 0, HINT_HEIGHT),
				LayoutOrder = 2,
			}),
			scope:New "Frame" {
				Name = "SlotGrid",
				-- Sized off EmoteConstants.LoadoutSize rather than hardcoded to four rows, so a
				-- changed loadout size grows the grid instead of clipping it silently.
				Size = UDim2.new(1, 0, 0, SLOT_GRID_HEIGHT),
				BackgroundTransparency = 1,
				LayoutOrder = 3,

				[Children] = slotChildren,
			},

			SectionHeading(scope, {
				Text = "Unlocked",
				Note = unlockedNote,
				LayoutOrder = 4,
			}),
			Label(scope, {
				Text = "No emotes unlocked yet.",
				Scale = "Detail",
				Color = Tokens.Color.TextSecondary,
				Size = UDim2.new(1, 0, 0, 20),
				LayoutOrder = 5,
				Visible = scope:Computed(function(use)
					return not use(hasUnlocked)
				end),
			}),
			-- Takes whatever the two headings, the hint and the slot grid left. That used to be a
			-- five-term HEADER_ALLOWANCE sum which a changed EmoteConstants.LoadoutSize could quietly
			-- invalidate -- see Components/Stack.lua's header.
			Stack.Fill(
				scope,
				ScrollArea(scope, {
					Name = "Unlocked",
					Size = UDim2.fromScale(1, 1),
					LayoutOrder = 6,

					Children = {
						scope:New "UIPadding" {
							PaddingRight = UDim.new(0, Tokens.Space.S),
						},
						scope:New "UIGridLayout" {
							CellSize = UDim2.new(
								1 / EMOTE_COLUMNS,
								-EMOTE_GAP * (EMOTE_COLUMNS - 1) / EMOTE_COLUMNS,
								0,
								EMOTE_BUTTON_HEIGHT
							),
							CellPadding = UDim2.fromOffset(EMOTE_GAP, EMOTE_GAP),
							SortOrder = Enum.SortOrder.LayoutOrder,
						},
						emoteButtons,
					},
				})
			),
		},
	})
end

return EmotesTab
