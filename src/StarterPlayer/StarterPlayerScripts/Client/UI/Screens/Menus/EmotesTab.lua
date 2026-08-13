--!strict
--[[
	EmotesTab.lua

	Owns: the character menu's emote loadout editor -- the EmoteConstants.LoadoutSize wheel slots and
	every emote this player has unlocked, with a click to put one in the selected slot.

	WHY THIS EXISTS HERE. The Emote System shipped complete on both sides -- unlock tracking,
	persistence, the Emote_RequestSetLoadoutSlot remote, and the radial wheel that plays whatever is
	in a slot -- with no way for a player to ever CHANGE a slot. The loadout every player has is the
	one Constants' DefaultLoadout gave them, and unlocking an emote outside it did nothing visible.
	One click here is the whole missing half.

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
local Tab = require(script.Parent.Parent.Parent.Components.Tab)
local Button = require(script.Parent.Parent.Parent.Components.Button)
local ClientStateModule = require(script.Parent.Parent.Parent.State.ClientState)

local Children = Fusion.Children
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

local SLOT_ROW_HEIGHT = 40
local SLOT_BUTTON_WIDTH = 108
local EMOTE_BUTTON_WIDTH = 150
local EMOTE_BUTTON_HEIGHT = Tokens.Control.StepButtonSize

local function displayNameFor(emoteId: Types.EmoteId): string
	local definition = EmoteRegistry.Get(emoteId)
	-- An id with no definition is a retired emote still sitting in a saved loadout
	-- (Types.PlayerProfile.emoteLoadout's own header calls out that this can happen). Shows the id
	-- rather than hiding the slot, so a player can see WHY that slot does nothing and replace it.
	return if definition then definition.DisplayName else emoteId
end

local function EmotesTab(scope: Scope, props: EmotesTabProps): Frame
	local state = props.State
	local selectedSlot = scope:Value(1)

	local slotButtons: { Instance } = {
		scope:New "UIListLayout" {
			FillDirection = Enum.FillDirection.Horizontal,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			Padding = UDim.new(0, Tokens.Space.XS),
			SortOrder = Enum.SortOrder.LayoutOrder,
			Wraps = true,
		},
	}
	for slot = 1, EmoteConstants.LoadoutSize do
		table.insert(
			slotButtons,
			Tab(scope, {
				Text = scope:Computed(function(use)
					local emoteId = use(state.EmoteLoadout)[slot]
					return if emoteId then `{slot}. {displayNameFor(emoteId)}` else `{slot}. empty`
				end),
				Selected = scope:Computed(function(use)
					return use(selectedSlot) == slot
				end),
				Size = UDim2.fromOffset(SLOT_BUTTON_WIDTH, Tokens.Control.StepButtonSize),
				LayoutOrder = slot,
				OnActivated = function()
					selectedSlot:set(slot)
				end,
			})
		)
	end

	-- The unlocked set is a dict (ClientState keeps it that way for O(1) wheel lookups), and a dict
	-- has no order -- sorted by id here so the grid doesn't reshuffle itself between opens.
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

	local emoteButtons = scope:ForPairs(unlockedIds, function(_use, innerScope: Scope, index: number, emoteId)
		return emoteId,
			Button(innerScope, {
				Text = displayNameFor(emoteId),
				Variant = "Secondary",
				Size = UDim2.fromOffset(EMOTE_BUTTON_WIDTH, EMOTE_BUTTON_HEIGHT),
				LayoutOrder = index,
				OnActivated = function()
					props.OnAssign(peek(selectedSlot), emoteId)
				end,
			})
	end)

	return scope:New "Frame" {
		Name = "EmotesTab",
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
			Label(scope, {
				Text = "Wheel Slots",
				Scale = "CardTitle",
				LayoutOrder = 1,
			}),
			Label(scope, {
				Text = "Pick a slot, then an emote below. The wheel plays whatever sits here.",
				Scale = "Detail",
				Color = Tokens.Color.TextSecondary,
				LayoutOrder = 2,
			}),
			scope:New "Frame" {
				Name = "SlotGrid",
				-- Two rows of a wrapping horizontal layout at LoadoutSize = 8; sized off the constant
				-- rather than hardcoded to two so a changed loadout size doesn't clip silently.
				Size = UDim2.new(1, 0, 0, SLOT_ROW_HEIGHT * math.ceil(EmoteConstants.LoadoutSize / 4)),
				BackgroundTransparency = 1,
				LayoutOrder = 3,

				[Children] = slotButtons,
			},
			Label(scope, {
				Text = "Unlocked",
				Scale = "CardTitle",
				LayoutOrder = 4,
			}),
			Label(scope, {
				Text = "No emotes unlocked yet.",
				Scale = "Detail",
				Color = Tokens.Color.TextDisabled,
				LayoutOrder = 5,
				Visible = scope:Computed(function(use)
					return not use(hasUnlocked)
				end),
			}),
			scope:New "ScrollingFrame" {
				Name = "Unlocked",
				Size = UDim2.new(1, 0, 1, -(SLOT_ROW_HEIGHT * math.ceil(EmoteConstants.LoadoutSize / 4) + 100)),
				BackgroundTransparency = 1,
				BorderSizePixel = 0,
				ScrollingDirection = Enum.ScrollingDirection.Y,
				AutomaticCanvasSize = Enum.AutomaticSize.Y,
				CanvasSize = UDim2.fromScale(0, 0),
				ScrollBarThickness = 3,
				ScrollBarImageColor3 = Tokens.Border.Standard.Color,
				ScrollBarImageTransparency = Tokens.Border.Standard.Transparency,
				LayoutOrder = 6,

				[Children] = {
					scope:New "UIPadding" {
						PaddingRight = UDim.new(0, Tokens.Space.S),
					},
					scope:New "UIListLayout" {
						FillDirection = Enum.FillDirection.Horizontal,
						Padding = UDim.new(0, Tokens.Space.XS),
						SortOrder = Enum.SortOrder.LayoutOrder,
						Wraps = true,
					},
					emoteButtons,
				},
			},
		},
	} :: Frame
end

return EmotesTab
