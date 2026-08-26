--!strict
--[[
	KitEditor/init.lua

	Owns: the mounted, admin-gated Kit Editor's root -- ScreenGui > Root Panel > Header + a two-column
	Body row (Sidebar | PropertyEditor). A new sibling top-level screen (mounted from UI/init.lua
	alongside MoveEditor/DevMenu/...), not a DevMenu tab or a Move Editor tab -- the Race Traits +
	Bloodline Abilities plan's own design: Race Traits and Bloodlines share one authoring primitive
	(KitAbilityDefinition) and one screen, with the sidebar merging both content types into one column
	rather than splitting into two screens that would duplicate the Effects-list sub-editor for
	nothing.

	Owns the actual state every panel below reads/writes: IsOpen, StatusText, RaceTraits, Bloodlines,
	Draft, plus the BindableEvents that make up KitEditorHandle (Types.lua). This root constructs
	Sidebar/PropertyEditor directly and wires them with plain closures, mirroring MoveEditor/init.lua's
	own "screen exposes state/signals, client module drives from outside" shape -- only THIS screen's
	own outer Mount crosses the boundary Client/DevTools/KitEditor/KitEditorClient.lua needs signals for.

	A field edit updates Draft immediately (optimistic -- PropertyEditor reads the same Draft, so it
	feels instant) and ALSO fires DraftFieldChanged, which KitEditorClient.lua debounces into the
	actual UpdateRaceTraitDraft/UpdateBloodlineDraft network call and reconciles back into Draft once
	the server responds (see Constants.KitEditor.DraftDebounceSeconds).

	No 3D preview viewport, no hotbar-binding UI -- v1 has nothing to preview and traits/bloodlines
	never occupy a hotbar slot (the Race Traits + Bloodline Abilities plan's own explicit non-goal).

	Does not own: authorization (KitEditorSystem.lua re-checks server-side regardless of whether this
	screen is even visible) or the actual RemoteFunction calls (KitEditorClient.lua).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local RaceTraitTypes = require(ReplicatedStorage.Shared.Race.RaceTraitTypes)
local BloodlineTypes = require(ReplicatedStorage.Shared.Bloodline.BloodlineTypes)

local Tokens = require(script.Parent.Parent.Parent.Tokens)
local ScreenFrame = require(script.Parent.Parent.Parent.Components.ScreenFrame)
local Stack = require(script.Parent.Parent.Parent.Components.Stack)
local Inset = require(script.Parent.Parent.Parent.Components.Inset)

local KitEditorTypes = require(script.Types)
local Sidebar = require(script.Sidebar)
local PropertyEditor = require(script.PropertyEditor)

type Scope = Fusion.Scope<typeof(Fusion)>

export type KitEditorHandle = KitEditorTypes.KitEditorHandle
export type KitDraft = KitEditorTypes.KitDraft

local KitEditor = {}

local SIDEBAR_WIDTH = 260
local CONTENT_WIDTH = 600
local ROOT_WIDTH = SIDEBAR_WIDTH + Tokens.Space.M + CONTENT_WIDTH + Tokens.Space.L * 2
local ROOT_HEIGHT = 700

-- The band heights are Components/ScreenFrame.lua's; what is left is the two columns' shared height
-- once the body's own inset comes off. Same shape Screens/DevTools/DevMenu/init.lua's pair takes, and for the
-- same reason: both columns get one number and each splits it internally however it likes.
local _, BODY_BAND_HEIGHT = ScreenFrame.BodySize(ROOT_WIDTH, ROOT_HEIGHT)
local BODY_HEIGHT = BODY_BAND_HEIGHT - Tokens.Space.M - Tokens.Space.L

function KitEditor.Mount(scope: Scope, playerGui: PlayerGui): KitEditorTypes.KitEditorHandle
	local isOpen = scope:Value(false)
	local statusText = scope:Value("")
	local raceTraits: Fusion.Value<{ RaceTraitTypes.RaceTraitDefinition }> =
		scope:Value({} :: { RaceTraitTypes.RaceTraitDefinition })
	local bloodlines: Fusion.Value<{ BloodlineTypes.BloodlineDefinition }> =
		scope:Value({} :: { BloodlineTypes.BloodlineDefinition })
	local draft: Fusion.Value<KitDraft?> = scope:Value(nil :: KitDraft?)
	local savedFingerprint = scope:Value("")
	local selectedGroup: Fusion.Value<KitEditorTypes.KitDraftKind> =
		scope:Value("RaceTrait" :: KitEditorTypes.KitDraftKind)

	local isDirty = scope:Computed(function(use)
		local current = use(draft)
		if not current then
			return false
		end
		local payload = if current.Kind == "RaceTrait" then current.Trait else current.Bloodline
		return KitEditorTypes.Fingerprint(payload :: any) ~= use(savedFingerprint)
	end)

	local closeRequestedEvent = Instance.new("BindableEvent")
	local newRaceTraitRequestedEvent = Instance.new("BindableEvent")
	local newBloodlineRequestedEvent = Instance.new("BindableEvent")
	local selectRaceTraitRequestedEvent = Instance.new("BindableEvent")
	local selectBloodlineRequestedEvent = Instance.new("BindableEvent")
	local deleteRaceTraitRequestedEvent = Instance.new("BindableEvent")
	local deleteBloodlineRequestedEvent = Instance.new("BindableEvent")
	local draftFieldChangedEvent = Instance.new("BindableEvent")
	local saveRequestedEvent = Instance.new("BindableEvent")

	local selectedId = scope:Computed(function(use)
		local current = use(draft)
		if not current then
			return nil
		end
		return if current.Kind == "RaceTrait" then current.Trait.TraitId else current.Bloodline.BloodlineId
	end)

	local sidebarRoot = Sidebar.Mount(scope, SIDEBAR_WIDTH, BODY_HEIGHT, {
		RaceTraits = raceTraits,
		Bloodlines = bloodlines,
		SelectedId = selectedId,
		OnNewRaceTrait = function()
			selectedGroup:set("RaceTrait")
			newRaceTraitRequestedEvent:Fire()
		end,
		OnNewBloodline = function()
			selectedGroup:set("Bloodline")
			newBloodlineRequestedEvent:Fire()
		end,
		OnSelectRaceTrait = function(traitId: string)
			selectedGroup:set("RaceTrait")
			selectRaceTraitRequestedEvent:Fire(traitId)
		end,
		OnSelectBloodline = function(bloodlineId: string)
			selectedGroup:set("Bloodline")
			selectBloodlineRequestedEvent:Fire(bloodlineId)
		end,
		OnDeleteRaceTrait = function(traitId: string)
			deleteRaceTraitRequestedEvent:Fire(traitId)
		end,
		OnDeleteBloodline = function(bloodlineId: string)
			deleteBloodlineRequestedEvent:Fire(bloodlineId)
		end,
	})

	local propertyEditorRoot = PropertyEditor.Mount(scope, {
		Draft = draft,
		Width = CONTENT_WIDTH,
		Height = BODY_HEIGHT,
		StatusText = statusText,
		IsDirty = isDirty,
		OnFieldChanged = function(newDraft: KitDraft)
			-- Optimistic: PropertyEditor reads `draft` directly, so setting it here (before the
			-- network round trip even starts) is what makes an edit feel instant -- same contract
			-- MoveEditor/init.lua's own OnFieldChanged documents.
			draft:set(newDraft)
			draftFieldChangedEvent:Fire(newDraft)
		end,
		OnSave = function()
			saveRequestedEvent:Fire()
		end,
	})

	ScreenFrame.Mount(scope, playerGui, {
		Name = "KitEditor",
		Size = UDim2.fromOffset(ROOT_WIDTH, ROOT_HEIGHT),
		IsOpen = isOpen,
		-- No frame-level tabs: the Race Trait / Bloodline split is not a view switch. Both lists are on
		-- screen at once in the sidebar and `selectedGroup` follows whichever one you last touched, so
		-- a tab strip would be claiming a choice the player never makes.
		Title = "Kit Editor",
		Wordmark = "KIT EDITOR",
		StatusText = statusText,
		-- Fires the signal rather than writing IsOpen -- KitEditorClient owns the open state, same
		-- contract MoveEditorClient's setOpen has.
		OnClose = function()
			closeRequestedEvent:Fire()
		end,

		Body = Stack.Row(scope, {
			Name = "Body",
			Gap = Tokens.Space.M,
			Children = {
				Inset(scope, { Top = Tokens.Space.M, Bottom = Tokens.Space.L, X = Tokens.Space.L }),
				sidebarRoot,
				propertyEditorRoot,
			},
		}),
	})

	return {
		IsOpen = isOpen,
		StatusText = statusText,
		RaceTraits = raceTraits,
		Bloodlines = bloodlines,
		Draft = draft,
		SavedFingerprint = savedFingerprint,
		IsDirty = isDirty,
		SelectedGroup = selectedGroup,
		CloseRequested = closeRequestedEvent.Event,
		NewRaceTraitRequested = newRaceTraitRequestedEvent.Event,
		NewBloodlineRequested = newBloodlineRequestedEvent.Event,
		SelectRaceTraitRequested = selectRaceTraitRequestedEvent.Event,
		SelectBloodlineRequested = selectBloodlineRequestedEvent.Event,
		DeleteRaceTraitRequested = deleteRaceTraitRequestedEvent.Event,
		DeleteBloodlineRequested = deleteBloodlineRequestedEvent.Event,
		DraftFieldChanged = draftFieldChangedEvent.Event,
		SaveRequested = saveRequestedEvent.Event,
	}
end

return KitEditor
