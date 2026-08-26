--!strict
--[[
	Menus/init.lua

	Owns: the character menu -- the player's own hub, on M. A pinned identity rail plus four tabs:
	Character (the sheet: vitals, condition, attributes, derived figures), Arts (the art trees,
	unlocking, and equipping to hotbar slots), Emotes (the wheel loadout), and Bounties (the Notoriety
	board). Plus the open/closed state, the tab selection, and every Value/signal the tab modules
	render from.

	THE LAYOUT IS A THREE-BAND FRAME, NOT A STACK OF CARDS, and that frame is now
	Components/ScreenFrame.lua rather than 120 lines of bands in this file. It was written here first,
	for this screen, and the argument for it (bands bleeding to the panel edge, nothing inside a band
	drawing a second box, no title bar because the tab strip says louder what the panel is) moved into
	that component's own header along with the code -- because the argument was never specific to the
	character menu, and three other screens were still each hand-rolling the parts of it they had
	copied. What is left here is what is actually this screen's: which tabs exist, what the body is,
	and every Value the tabs render from.

	THE BODY IS A ROW OF TWO, and it is the one thing about this screen's shape that no other screen
	shares: a fixed identity rail, then whatever is left for the selected tab. "Whatever is left" is
	Stack.Fill rather than `CONTENT_WIDTH = ROOT_WIDTH - RAIL_WIDTH` -- see Components/Stack.lua's
	header on why a computed remainder is a claim about a sibling's size and a flex item is not.

	The rail is pinned rather than being a fifth tab because everything on it is what you are holding
	in your head while reading any of the four -- an art's tier gate means nothing without your tier
	beside it. See IdentityRail.lua's own header.

	SCREEN EXPOSES STATE AND SIGNALS; THE CLIENT MODULE DRIVES IT. Every action that leaves this
	client (unlock an art, equip an art, assign an emote slot, reroll a bloodline) fires a
	BindableEvent rather than calling NetworkBridge here, and every piece of server-owned state the
	tabs render (Sheet, ArtTrees, ArtMastery, EquippedArts) is a Fusion.Value owned by this Mount but
	written to exclusively from outside by Client/CharacterMenu/CharacterMenuClient.lua -- the same
	boundary Screens/Settings/init.lua and Screens/DevTools/DevMenu/init.lua already hold. The close button is
	the one exception, exactly like theirs: IsOpen is owned here, so closing just sets it.

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
local ScreenFrame = require(script.Parent.Parent.Components.ScreenFrame)
local Stack = require(script.Parent.Parent.Components.Stack)
local Inset = require(script.Parent.Parent.Components.Inset)
local ClientStateModule = require(script.Parent.Parent.State.ClientState)

local IdentityRail = require(script.IdentityRail)
local CharacterTab = require(script.CharacterTab)
local ArtsTab = require(script.ArtsTab)
local EmotesTab = require(script.EmotesTab)
local BountyTab = require(script.BountyTab)

local peek = Fusion.peek

type Scope = Fusion.Scope<typeof(Fusion)>

export type MenuTabName = "Character" | "Arts" | "Emotes" | "Bounties"

export type MenusHandle = {
	IsOpen: Fusion.Value<boolean>,
	-- Transient one-line result of the last action ("Art unlocked.", "Not enough Qi.") -- written by
	-- CharacterMenuClient, which also clears it, the same shape SettingsHandle.StatusText has. Lives
	-- in the footer band, opposite the wordmark: an action's answer belongs at the frame's edge, not
	-- inside whichever tab happened to raise it.
	StatusText: Fusion.Value<string>,
	-- Server-owned state, written exclusively by CharacterMenuClient (see this file's header).
	-- Sheet is nil until the first Character_GetSheet/Character_SheetUpdated lands -- nil is a real
	-- state the rail and the Character tab render honestly, never a reason to invent zeros.
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
	-- Fires with no argument -- the server picks what you roll (BloodlineSystem.Spin), so there is
	-- nothing for the client to name. Available from the identity rail at any time, unlike the
	-- onboarding spin which is a one-shot beat in a flow that has already torn itself down.
	RerollBloodlineRequested: RBXScriptSignal<>,
	-- Fires (slot, emoteId).
	EmoteSlotAssigned: RBXScriptSignal<(number, string)>,
}

-- The panel, and the one column this screen pins inside it. The band heights are
-- Components/ScreenFrame.lua's own and are not restated here -- BodySize is a function of them, so
-- moving a band by two pixels can no longer leave a stale sum in this file (that is exactly the
-- failure docs/architecture/2026-08-20-ui-velocity-plan.md section 2.1 is about).
local ROOT_WIDTH = 760
local ROOT_HEIGHT = 620
local RAIL_WIDTH = 244

local BODY_WIDTH, BODY_HEIGHT = ScreenFrame.BodySize(ROOT_WIDTH, ROOT_HEIGHT)
-- The four tab modules each take an explicit pixel Width/Height rather than sizing themselves, so
-- these two survive the migration. They are the LAST arithmetic in this file, and they are honest
-- arithmetic: the content column really is the body minus the rail, and a tab really does draw
-- inside that column's own inset. What went away was the arithmetic that was a guess about a
-- sibling's height.
local TAB_WIDTH = BODY_WIDTH - RAIL_WIDTH - Tokens.Space.L * 2
local TAB_HEIGHT = BODY_HEIGHT - Tokens.Space.M - Tokens.Space.L

-- Typed as plain strings rather than as { MenuTabName }: Components/ScreenFrame.lua's tab state is
-- keyed by string (it has no way to know any one screen's tab union), and Luau treats array element
-- types as invariant, so a cast at the call site would be the thing that had to be written instead.
-- MenuTabName stays exported -- it is what the handle's consumers name a tab with.
local TAB_NAMES: { string } = { "Character", "Arts", "Emotes", "Bounties" }

local Menus = {}

function Menus.Mount(scope: Scope, playerGui: PlayerGui, clientState: ClientStateModule.ClientState): MenusHandle
	local isOpen = scope:Value(false)
	local statusText = scope:Value("")
	local sheet = scope:Value(nil :: Types.CharacterSheetPayload?)
	local artTrees = scope:Value({} :: { Types.ArtCatalogueTree })
	local artMastery = scope:Value({} :: { [string]: number })
	local equippedArts = scope:Value({} :: { [number]: string })
	-- Owns which tab is showing AND the one shared Computed per tab that both the strip button and
	-- the tab body read -- see Components/ScreenFrame.lua's header on why those must be the same
	-- object rather than two Computeds asking the same question independently.
	local tabs = ScreenFrame.NewTabState(scope, TAB_NAMES)

	local openedEvent = Instance.new("BindableEvent")
	local unlockArtEvent = Instance.new("BindableEvent")
	local equipArtEvent = Instance.new("BindableEvent")
	local emoteSlotEvent = Instance.new("BindableEvent")
	local rerollBloodlineEvent = Instance.new("BindableEvent")
	table.insert(scope, rerollBloodlineEvent)

	scope:Observer(isOpen):onChange(function()
		if peek(isOpen) then
			openedEvent:Fire()
		end
	end)

	local characterTab = CharacterTab(scope, {
		Width = TAB_WIDTH,
		Height = TAB_HEIGHT,
		Visible = tabs.Selected["Character"],
		LayoutOrder = 1,
		Sheet = sheet,
		State = clientState,
	})

	local artsTab = ArtsTab(scope, {
		Width = TAB_WIDTH,
		Height = TAB_HEIGHT,
		Visible = tabs.Selected["Arts"],
		LayoutOrder = 2,
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
		Width = TAB_WIDTH,
		Height = TAB_HEIGHT,
		Visible = tabs.Selected["Emotes"],
		LayoutOrder = 3,
		State = clientState,
		OnAssign = function(slot: number, emoteId: string)
			emoteSlotEvent:Fire(slot, emoteId)
		end,
	})

	local bountyTab = BountyTab.Mount(scope, {
		Width = TAB_WIDTH,
		Height = TAB_HEIGHT,
		Visible = tabs.Selected["Bounties"],
		LayoutOrder = 4,
	})

	ScreenFrame.Mount(scope, playerGui, {
		Name = "CharacterMenu",
		Size = UDim2.fromOffset(ROOT_WIDTH, ROOT_HEIGHT),
		IsOpen = isOpen,
		-- The only screen that opts in so far. This is the panel a player reads for minutes at a time
		-- rather than glances at, and the one they said was too small to read on their monitor -- see
		-- ModalScreen.lua's own header on why this and not more type size.
		AutoScale = true,
		Tabs = tabs,
		StatusText = statusText,
		OnClose = function()
			isOpen:set(false)
		end,

		Body = Stack.Row(scope, {
			Name = "Body",
			Children = {
				IdentityRail(scope, {
					Width = RAIL_WIDTH,
					Height = BODY_HEIGHT,
					LayoutOrder = 1,
					Sheet = sheet,
					State = clientState,
					Mastery = artMastery,
					OnRerollBloodline = function()
						rerollBloodlineEvent:Fire()
					end,
				}),
				-- Takes the body's width less the rail's, without being told what either of them is.
				Stack.Fill(
					scope,
					Stack.New(scope, {
						Name = "TabContent",
						LayoutOrder = 2,
						-- The structural backstop for the whole right-hand column, matching the rail's
						-- own. Every tab sizes itself from Width/Height, but a row that mis-measures --
						-- a long art name, a display name from another player's bounty -- must be
						-- clipped at the column edge rather than painting over the panel border.
						ClipsDescendants = true,
						Children = {
							Inset(scope, {
								Top = Tokens.Space.M,
								Bottom = Tokens.Space.L,
								X = Tokens.Space.L,
							}),
							-- Exactly one of these is Visible at a time, so the Stack's own layout has
							-- one child to place and puts it at the origin -- which is what every one of
							-- them expects. They are siblings rather than a swapped single child so a
							-- tab keeps its scroll position and its live subscriptions across a tab
							-- change (see BountyTab.lua's own remotes).
							characterTab,
							artsTab,
							emotesTab,
							bountyTab,
						},
					})
				),
			},
		}),
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
		RerollBloodlineRequested = rerollBloodlineEvent.Event,
	}
end

return Menus
