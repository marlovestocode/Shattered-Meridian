--!strict
--[[
	Menus/init.lua

	Owns: the character menu -- the player's own hub, on M. Four tabs: Character (the sheet:
	identity, tier progress, attributes, standing), Arts (the art trees, unlocking, and equipping to
	hotbar slots), Emotes (the wheel loadout), and Bounties (the Notoriety board). Plus the open/
	closed state, the tab selection, and every Value/signal the tab modules render from.

	WHAT THIS REPLACED, and why the shape changed. This screen used to be a single unnamed panel
	whose only content was the bounty board, opened by a raw UserInputService check hard-coded to M
	inside this file. Both of those were called out here as known gaps -- the header said routing the
	key through Types.KeybindAction "IS still worth doing... and it's the next step here", and the
	Menus category in ui-ux-philosophy.md listed inventory/progression/loadout panels as unbuildable
	because the Systems behind them were empty Init()s. ArtSystem, TierSystem, QiSystem,
	MeridianSystem, EmoteSystem and CharacterSheetSystem are all real now, so the panels have real
	data, and the keybind now goes through KeybindManager like every other action
	(Types.KeybindAction's "CharacterMenuToggle").

	SCREEN EXPOSES STATE AND SIGNALS; THE CLIENT MODULE DRIVES IT. Every action that leaves this
	client (unlock an art, equip an art, assign an emote slot) fires a BindableEvent rather than
	calling NetworkBridge here, and every piece of server-owned state the tabs render (Sheet,
	ArtTrees, ArtMastery, EquippedArts) is a Fusion.Value owned by this Mount but written to
	exclusively from outside by Client/CharacterMenu/CharacterMenuClient.lua -- the same boundary
	Screens/Settings/init.lua and Screens/DevMenu/init.lua already hold. The close button is the one
	exception, exactly like theirs: IsOpen is owned here, so closing just sets it.

	The two exceptions to "state comes from the driver" are deliberate. BountyTab.lua keeps its own
	two remotes (see its header), and CharacterTab/EmotesTab read ClientState directly for values
	already replicated there for the HUD and the emote wheel -- routing those through this handle
	would duplicate a channel that already exists rather than adding one.

	Every tab mounts up front and toggles on its own Visible rather than re-mounting on tab clicks --
	same idiom Screens/Settings/init.lua uses, and it's what lets BountyTab keep a live remote
	subscription regardless of which tab is showing.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Types = require(ReplicatedStorage.Shared.Types)

local Tokens = require(script.Parent.Parent.Tokens)
local ModalScreen = require(script.Parent.Parent.Components.ModalScreen)
local Label = require(script.Parent.Parent.Components.Label)
local Button = require(script.Parent.Parent.Components.Button)
local Tab = require(script.Parent.Parent.Components.Tab)
local ClientStateModule = require(script.Parent.Parent.State.ClientState)

local CharacterTab = require(script.CharacterTab)
local ArtsTab = require(script.ArtsTab)
local EmotesTab = require(script.EmotesTab)
local BountyTab = require(script.BountyTab)

local Children = Fusion.Children
local peek = Fusion.peek

type Scope = Fusion.Scope<typeof(Fusion)>

export type MenuTabName = "Character" | "Arts" | "Emotes" | "Bounties"

export type MenusHandle = {
	IsOpen: Fusion.Value<boolean>,
	-- Transient one-line result of the last action ("Art unlocked.", "Not enough Qi.") -- written by
	-- CharacterMenuClient, which also clears it, the same shape SettingsHandle.StatusText has.
	StatusText: Fusion.Value<string>,
	-- Server-owned state, written exclusively by CharacterMenuClient (see this file's header).
	-- Sheet is nil until the first Character_GetSheet/Character_SheetUpdated lands -- nil is a real
	-- state the Character tab renders honestly, never a reason to invent zeros.
	Sheet: Fusion.Value<Types.CharacterSheetPayload?>,
	ArtTrees: Fusion.Value<{ Types.ArtCatalogueTree }>,
	ArtMastery: Fusion.Value<{ [string]: number }>,
	EquippedArts: Fusion.Value<{ [number]: string }>,
	-- Fires whenever the panel transitions closed -> open, so the driver can refetch the catalogue
	-- and the sheet. An Observer on IsOpen rather than a call inside the keybind handler, so this
	-- stays correct for ANY future opener (a HUD button, a tutorial step) instead of only the key.
	Opened: RBXScriptSignal<>,
	-- Fires (artId).
	UnlockArtRequested: RBXScriptSignal<string>,
	-- Fires (slot, artId) -- artId nil clears the slot.
	EquipArtRequested: RBXScriptSignal<(number, string?)>,
	-- Fires (slot, emoteId).
	EmoteSlotAssigned: RBXScriptSignal<(number, string)>,
}

local ROOT_WIDTH = 720
local ROOT_HEIGHT = 560
local HEADER_HEIGHT = 36
local TAB_STRIP_HEIGHT = 36
local STATUS_HEIGHT = 20

-- Inner content budget: total minus UIPadding.L (top+bottom), minus the header/tab-strip/status
-- rows, minus the 3 UIListLayout gaps between header/strip/body/status -- the same "spell the math
-- out, don't guess" convention Screens/Settings/init.lua and Screens/DevMenu/init.lua both use.
local CONTENT_WIDTH = ROOT_WIDTH - Tokens.Space.L * 2
local CONTENT_HEIGHT = ROOT_HEIGHT
	- Tokens.Space.L * 2
	- HEADER_HEIGHT
	- TAB_STRIP_HEIGHT
	- STATUS_HEIGHT
	- Tokens.Space.M * 3

local TAB_NAMES: { MenuTabName } = { "Character", "Arts", "Emotes", "Bounties" }

local Menus = {}

function Menus.Mount(scope: Scope, playerGui: PlayerGui, clientState: ClientStateModule.ClientState): MenusHandle
	local isOpen = scope:Value(false)
	local statusText = scope:Value("")
	local sheet = scope:Value(nil :: Types.CharacterSheetPayload?)
	local artTrees = scope:Value({} :: { Types.ArtCatalogueTree })
	local artMastery = scope:Value({} :: { [string]: number })
	local equippedArts = scope:Value({} :: { [number]: string })
	local selectedTab = scope:Value("Character" :: MenuTabName)

	local openedEvent = Instance.new("BindableEvent")
	local unlockArtEvent = Instance.new("BindableEvent")
	local equipArtEvent = Instance.new("BindableEvent")
	local emoteSlotEvent = Instance.new("BindableEvent")

	scope:Observer(isOpen):onChange(function()
		if peek(isOpen) then
			openedEvent:Fire()
		end
	end)

	-- One Computed per tab, built once and shared by BOTH that tab's strip button (its Selected) and
	-- its body (its Visible) -- rather than each asking the question separately, which would leave two
	-- independent Computeds that could in principle disagree about which tab is showing.
	local tabSelected: { [MenuTabName]: Fusion.Computed<boolean> } = {}
	for _, name in ipairs(TAB_NAMES) do
		tabSelected[name] = scope:Computed(function(use)
			return use(selectedTab) == name
		end)
	end

	local tabButtons: { Instance } = {
		scope:New "UIListLayout" {
			FillDirection = Enum.FillDirection.Horizontal,
			Padding = UDim.new(0, Tokens.Space.S),
			SortOrder = Enum.SortOrder.LayoutOrder,
		},
	}
	for index, name in ipairs(TAB_NAMES) do
		table.insert(
			tabButtons,
			Tab(scope, {
				Text = name,
				-- Static text, so this is one of the few Tab call sites that can safely take the
				-- tracked-caps treatment -- see Tab.lua's own header on why it stays opt-in.
				TrackedCaps = true,
				Size = UDim2.new(1 / #TAB_NAMES, -Tokens.Space.S, 0, TAB_STRIP_HEIGHT),
				LayoutOrder = index,
				Selected = tabSelected[name],
				OnActivated = function()
					selectedTab:set(name)
				end,
			})
		)
	end

	local characterTab = CharacterTab(scope, {
		Width = CONTENT_WIDTH,
		Height = CONTENT_HEIGHT,
		Visible = tabSelected["Character"],
		LayoutOrder = 3,
		Sheet = sheet,
		State = clientState,
	})

	local artsTab = ArtsTab(scope, {
		Width = CONTENT_WIDTH,
		Height = CONTENT_HEIGHT,
		Visible = tabSelected["Arts"],
		LayoutOrder = 3,
		Trees = artTrees,
		Mastery = artMastery,
		Equipped = equippedArts,
		OnUnlock = function(artId: string)
			unlockArtEvent:Fire(artId)
		end,
		OnEquip = function(slot: number, artId: string?)
			equipArtEvent:Fire(slot, artId)
		end,
	})

	local emotesTab = EmotesTab(scope, {
		Width = CONTENT_WIDTH,
		Height = CONTENT_HEIGHT,
		Visible = tabSelected["Emotes"],
		LayoutOrder = 3,
		State = clientState,
		OnAssign = function(slot: number, emoteId: string)
			emoteSlotEvent:Fire(slot, emoteId)
		end,
	})

	local bountyTab = BountyTab.Mount(scope, {
		Width = CONTENT_WIDTH,
		Height = CONTENT_HEIGHT,
		Visible = tabSelected["Bounties"],
		LayoutOrder = 3,
	})

	ModalScreen(scope, playerGui, {
		Name = "CharacterMenu",
		Size = UDim2.fromOffset(ROOT_WIDTH, ROOT_HEIGHT),
		IsOpen = isOpen,

		Children = {
			scope:New "Frame" {
				Name = "Header",
				Size = UDim2.new(1, 0, 0, HEADER_HEIGHT),
				BackgroundTransparency = 1,
				LayoutOrder = 1,

				[Children] = {
					Label(scope, {
						Text = "Character",
						Scale = "Heading",
						AnchorPoint = Vector2.new(0, 0.5),
						Position = UDim2.fromScale(0, 0.5),
					}),
					Button(scope, {
						Text = "X",
						Size = UDim2.fromOffset(28, 28),
						AnchorPoint = Vector2.new(1, 0.5),
						Position = UDim2.fromScale(1, 0.5),
						OnActivated = function()
							isOpen:set(false)
						end,
					}),
				},
			},

			scope:New "Frame" {
				Name = "TabStrip",
				Size = UDim2.new(1, 0, 0, TAB_STRIP_HEIGHT),
				BackgroundTransparency = 1,
				LayoutOrder = 2,

				[Children] = tabButtons,
			},

			characterTab,
			artsTab,
			emotesTab,
			bountyTab,

			Label(scope, {
				Text = statusText,
				Scale = "Detail",
				Color = Tokens.Color.TextSecondary,
				Size = UDim2.new(1, 0, 0, STATUS_HEIGHT),
				LayoutOrder = 4,
			}),
		},
	})

	return {
		IsOpen = isOpen,
		StatusText = statusText,
		Sheet = sheet,
		ArtTrees = artTrees,
		ArtMastery = artMastery,
		EquippedArts = equippedArts,
		Opened = openedEvent.Event,
		UnlockArtRequested = unlockArtEvent.Event,
		EquipArtRequested = equipArtEvent.Event,
		EmoteSlotAssigned = emoteSlotEvent.Event,
	}
end

return Menus
