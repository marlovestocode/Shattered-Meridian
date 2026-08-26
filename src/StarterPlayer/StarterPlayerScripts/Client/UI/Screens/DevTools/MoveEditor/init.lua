--!strict
--[[
	MoveEditor/init.lua

	Owns: the mounted, admin-gated Move Creation System editor's root -- ScreenGui > Root Panel >
	Header + a three-column Body row (Sidebar | PropertyEditor | PreviewViewport). A new sibling
	top-level screen to DevMenu (mounted from UI/init.lua alongside it), not a 5th DevMenu tab --
	DevMenu's own root has a fixed 744x600 budget sized for its existing 4-tab strip, too small for
	a move list + a full property form + a live 3D viewport side by side.

	Sidebar.lua (not a bare MoveList.Mount call, as before the website-style redesign) now owns BOTH
	the Moves list and the section nav PropertyEditor.lua's content pane is split by -- see that
	file's own header for why those two navigation axes live in one merged column instead of two.

	Owns the actual state every panel below reads/writes: IsOpen, StatusText, MovesDisplay, Draft,
	LastTestResultText, plus the BindableEvents that make up MoveEditorHandle (Types.lua). This
	root constructs Sidebar/PropertyEditor/PreviewViewport directly and wires them with plain
	closures (OnNew/OnSelect/OnDelete/OnFieldChanged/OnSave/OnReset) -- unlike DevMenu's own
	Sidebar/ContentArea split, those three panels get no BindableEvent handle of their own, since
	this root constructs all three itself and is never called before they exist. Only THIS screen's
	own outer Mount crosses the "not created yet" boundary Client/DevTools/MoveEditor/MoveEditorClient.lua
	needs signals for -- see Types.lua's header. Sidebar.Mount's own return value (which owns
	SelectedSection, the one piece of state PropertyEditor.lua needs from it) isn't part of that
	boundary either, for the same "constructed here, never called before it exists" reason.

	A field edit updates Draft immediately (optimistic -- both PropertyEditor and PreviewViewport
	read the same Draft, so both feel instant) and ALSO fires DraftFieldChanged, which
	MoveEditorClient.lua debounces into the actual UpdateDraft network call and reconciles back into
	Draft once the server responds (see Constants.MoveEditor.DraftDebounceSeconds' own header).

	Does not own: authorization (MoveEditorSystem.lua re-checks server-side regardless of whether
	this screen is even visible) or the actual RemoteFunction calls (MoveEditorClient.lua).

	Also owns hotbarBindings/bindHotbarSlotRequestedEvent (2026-08-10, the Move Creation System
	hotbar pass) -- PropertyEditor.lua's toolbar reads the former to show which slot(s) the
	currently-selected move already occupies and fires the latter (via its own OnBindHotbarSlot
	closure above, which resolves the signal's MoveId argument from `draft`) when an admin clicks a
	slot button. MoveEditorClient.lua's handler for this one DOES touch a RemoteFunction
	(EquipArtSlot, ArtSystem.DevGrantAndEquip server-side) -- binding to a slot is an equip, not
	client-side bookkeeping, since an art IS a move; see Client/Combat/HotbarBindings.lua's own
	header.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local MoveTypes = require(ReplicatedStorage.Shared.MoveTypes)
local MoveStats = require(ReplicatedStorage.Shared.MoveStats)

local Tokens = require(script.Parent.Parent.Parent.Tokens)
local ScreenFrame = require(script.Parent.Parent.Parent.Components.ScreenFrame)
local Stack = require(script.Parent.Parent.Parent.Components.Stack)
local Inset = require(script.Parent.Parent.Parent.Components.Inset)
local ShortcutsOverlay = require(script.ShortcutsOverlay)
local Label = require(script.Parent.Parent.Parent.Components.Label)

local MoveEditorTypes = require(script.Types)
local EditorTokens = require(script.EditorTokens)
local Sidebar = require(script.Sidebar)
local PropertyEditor = require(script.PropertyEditor)
local PreviewViewport = require(script.PreviewViewport)

local Children = Fusion.Children
local peek = Fusion.peek

type Scope = Fusion.Scope<typeof(Fusion)>

export type MoveEditorHandle = MoveEditorTypes.MoveEditorHandle

local MoveEditor = {}

local SIDEBAR_WIDTH = 260
local CONTENT_WIDTH = 600
local PREVIEW_WIDTH = 420
local ROOT_WIDTH = SIDEBAR_WIDTH + Tokens.Space.M * 2 + CONTENT_WIDTH + PREVIEW_WIDTH + Tokens.Space.L * 2
local ROOT_HEIGHT = 760

-- The band heights are Components/ScreenFrame.lua's; this is what the three columns share once the
-- body's own inset comes off. Same pair Screens/DevTools/DevMenu/init.lua and Screens/DevTools/KitEditor/init.lua take.
local _, BODY_BAND_HEIGHT = ScreenFrame.BodySize(ROOT_WIDTH, ROOT_HEIGHT)
local BODY_HEIGHT = BODY_BAND_HEIGHT - Tokens.Space.M - Tokens.Space.L
-- The inventory readout's own row height, in the tab strip band.
local READOUT_HEIGHT = 20

function MoveEditor.Mount(scope: Scope, playerGui: PlayerGui): MoveEditorTypes.MoveEditorHandle
	local isOpen = scope:Value(false)
	local statusText = scope:Value("")
	local movesDisplay: Fusion.Value<{ MoveTypes.MoveDefinition }> = scope:Value({} :: { MoveTypes.MoveDefinition })
	local draft: Fusion.Value<MoveTypes.MoveDefinition?> = scope:Value(nil :: MoveTypes.MoveDefinition?)
	local lastTestResultText = scope:Value("")
	-- Owned here (not by StatsPanel) for the same reason `draft` is: MoveEditorClient.lua appends to
	-- it from outside this screen entirely, so it has to live on the handle -- see Types.lua's own
	-- MoveEditorHandle.TestSamples.
	local testSamples: Fusion.Value<{ MoveStats.TestSample }> = scope:Value({} :: { MoveStats.TestSample })
	local hotbarBindings: Fusion.Value<{ [number]: string? }> = scope:Value({} :: { [number]: string? })

	-- The fingerprint of whatever the server last handed back as AUTHORITATIVE -- written by
	-- MoveEditorClient.lua on a successful New/Select/Save/Reset/Duplicate, and deliberately NOT on a
	-- debounced UpdateDraft reconcile. UpdateDraft only mutates the server's in-memory registry; the
	-- DataStore is untouched until Save, and "there is work the DataStore doesn't have" is precisely
	-- what isDirty below reports.
	local savedFingerprint = scope:Value("")
	-- Both written only by MoveEditorClient.lua -- see their own headers in Types.lua.
	local unsavedCount = scope:Value(0)
	local lastSavedMoveId = scope:Value("")
	local isDirty = scope:Computed(function(use)
		local current = use(draft)
		if not current then
			return false
		end
		return MoveTypes.Fingerprint(current) ~= use(savedFingerprint)
	end)

	local closeRequestedEvent = Instance.new("BindableEvent")
	local newMoveRequestedEvent = Instance.new("BindableEvent")
	local selectMoveRequestedEvent = Instance.new("BindableEvent")
	local deleteMoveRequestedEvent = Instance.new("BindableEvent")
	local draftFieldChangedEvent = Instance.new("BindableEvent")
	local saveRequestedEvent = Instance.new("BindableEvent")
	local resetRequestedEvent = Instance.new("BindableEvent")
	local bindHotbarSlotRequestedEvent = Instance.new("BindableEvent")
	local duplicateMoveRequestedEvent = Instance.new("BindableEvent")
	local renameMoveRequestedEvent = Instance.new("BindableEvent")
	local toggleTestDummyRequestedEvent = Instance.new("BindableEvent")
	-- This client's own best-effort guess, per HasTestDummy's own header -- MoveEditorClient.lua is
	-- the only writer (on a successful Spawn/Despawn response).
	local hasTestDummy = scope:Value(false)

	local selectedMoveId = scope:Computed(function(use)
		local currentDraft = use(draft)
		return if currentDraft then currentDraft.MoveId else nil
	end)

	local sidebar = Sidebar.Mount(scope, SIDEBAR_WIDTH, BODY_HEIGHT, {
		MovesDisplay = movesDisplay,
		SelectedMoveId = selectedMoveId,
		Draft = draft,
		OnNew = function()
			newMoveRequestedEvent:Fire()
		end,
		OnSelect = function(moveId: string)
			selectMoveRequestedEvent:Fire(moveId)
		end,
		LastSavedMoveId = lastSavedMoveId,
		OnDelete = function(moveId: string)
			deleteMoveRequestedEvent:Fire(moveId)
		end,
		OnRename = function(moveId: string, newName: string)
			renameMoveRequestedEvent:Fire(moveId, newName)
		end,
		OnDuplicate = function(moveId: string)
			duplicateMoveRequestedEvent:Fire(moveId)
		end,
	})

	local propertyEditorRoot = PropertyEditor.Mount(scope, CONTENT_WIDTH, BODY_HEIGHT, {
		Draft = draft,
		LastTestResultText = lastTestResultText,
		SelectedSection = sidebar.SelectedSection,
		HotbarBindings = hotbarBindings,
		TestSamples = testSamples,
		IsDirty = isDirty,
		OnNew = function()
			newMoveRequestedEvent:Fire()
		end,
		OnDuplicate = function()
			-- "" means "whatever is open" -- the toolbar button has no move in hand the way a list row
			-- does, and resolving the draft here would duplicate a lookup MoveEditorClient must do
			-- anyway (it needs the freshest record, including edits this screen has not sent yet).
			duplicateMoveRequestedEvent:Fire("")
		end,
		OnFieldChanged = function(newDraft: MoveTypes.MoveDefinition)
			-- Optimistic: both this panel and PreviewViewport read `draft` directly, so setting it
			-- here (before the network round trip even starts) is what makes an edit feel instant.
			draft:set(newDraft)
			draftFieldChangedEvent:Fire(newDraft)
		end,
		OnSave = function()
			saveRequestedEvent:Fire()
		end,
		OnReset = function()
			resetRequestedEvent:Fire()
		end,
		HasTestDummy = hasTestDummy,
		OnToggleTestDummy = function()
			toggleTestDummyRequestedEvent:Fire()
		end,
		OnBindHotbarSlot = function(slot: number)
			-- Resolved here (not passed down as a prop) since init.lua already owns `draft` -- the
			-- same "screen exposes state/signals, client module drives from outside" boundary this
			-- whole file's header documents. Silently does nothing with no move selected -- the
			-- toolbar that hosts these buttons is only ever Visible while hasDraft is true anyway
			-- (PropertyEditor.lua's own toolbar Visible prop), so this is defensive, not reachable
			-- from the UI in practice.
			local currentDraft = peek(draft)
			if currentDraft and currentDraft.MoveId ~= "" then
				bindHotbarSlotRequestedEvent:Fire(slot, currentDraft.MoveId)
			end
		end,
	})

	-- A sibling ModalScreen, not a child of the editor's root -- see ShortcutsOverlay.lua's header.
	-- Mounted unconditionally and Visible-gated on its own value, like every other surface here.
	local shortcutsOpen = scope:Value(false)
	ShortcutsOverlay.Mount(scope, playerGui, { IsOpen = shortcutsOpen })

	local previewRoot = PreviewViewport.Mount(scope, PREVIEW_WIDTH, BODY_HEIGHT, {
		Draft = draft,
		IsOpen = isOpen,
	})

	ScreenFrame.Mount(scope, playerGui, {
		Name = "MoveEditor",
		Size = UDim2.fromOffset(ROOT_WIDTH, ROOT_HEIGHT),
		IsOpen = isOpen,
		-- No frame-level tabs: this editor's sections live in the Sidebar and scroll the middle column,
		-- with the move list and the preview persisting across every one of them.
		Title = "Move Creation System",
		-- The inventory readout, pinned to the strip's right clear of the close control. It used to sit
		-- beside the title and the status line used to sit out here; they have swapped, because "12
		-- moves, 2 unsaved" is a standing fact about the panel and "Saved." is a transient answer to the
		-- last thing you did -- and the footer band is where this frame puts transient answers.
		HeaderAccessory = Stack.Row(scope, {
			Name = "InventoryReadout",
			Size = UDim2.fromOffset(0, READOUT_HEIGHT),
			AutomaticSize = Enum.AutomaticSize.X,
			Gap = Tokens.Space.S,
			AlignY = Enum.VerticalAlignment.Center,
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -(Tokens.Control.CloseButtonClearance + ScreenFrame.BandPaddingX), 0.5, 0),
			Children = {
				-- The dot is the SECOND signal for the same fact the text beside it already states, per
				-- Tokens.Color's rule that hue is never the only carrier: someone who cannot distinguish
				-- the amber still reads "2 unsaved".
				scope:New "Frame" {
					Name = "UnsavedDot",
					Size = UDim2.fromOffset(6, 6),
					BackgroundColor3 = EditorTokens.Dirty,
					BorderSizePixel = 0,
					LayoutOrder = 1,
					Visible = scope:Computed(function(use)
						return use(unsavedCount) > 0
					end),

					[Children] = scope:New "UICorner" { CornerRadius = UDim.new(0.5, 0) },
				},
				Label(scope, {
					-- Counts the whole known inventory, Default moves included -- an admin asking "how
					-- much is in here" means everything the editor can open, not just the section they
					-- happen to be looking at.
					Text = scope:Computed(function(use)
						local total = #use(movesDisplay)
						local pending = use(unsavedCount)
						if pending == 0 then
							return `{total} moves`
						end
						return `{total} moves · {pending} unsaved`
					end),
					Scale = "Detail",
					Color = scope:Computed(function(use)
						return if use(unsavedCount) > 0 then EditorTokens.Dirty else Tokens.Color.TextSecondary
					end),
					Size = UDim2.fromOffset(160, READOUT_HEIGHT),
					TextXAlignment = Enum.TextXAlignment.Right,
					LayoutOrder = 2,
				}),
			},
		}),
		Wordmark = "MOVE EDITOR",
		StatusText = statusText,
		-- Fires the signal rather than writing IsOpen -- MoveEditorClient's setOpen is the one place
		-- this screen's open state is written.
		OnClose = function()
			closeRequestedEvent:Fire()
		end,

		Body = Stack.Row(scope, {
			Name = "Body",
			Gap = Tokens.Space.M,
			Children = {
				Inset(scope, { Top = Tokens.Space.M, Bottom = Tokens.Space.L, X = Tokens.Space.L }),
				sidebar.Root,
				propertyEditorRoot,
				previewRoot,
			},
		}),
	})

	return {
		IsOpen = isOpen,
		CloseRequested = closeRequestedEvent.Event,
		StatusText = statusText,
		-- Sidebar's own value, handed straight out rather than mirrored -- PropertyEditor already reads
		-- this exact Fusion.Value, so a second copy could only drift from it.
		SelectedSection = sidebar.SelectedSection,
		ShortcutsOpen = shortcutsOpen,
		MovesDisplay = movesDisplay,
		Draft = draft,
		LastTestResultText = lastTestResultText,
		TestSamples = testSamples,
		NewMoveRequested = newMoveRequestedEvent.Event,
		SelectMoveRequested = selectMoveRequestedEvent.Event,
		DeleteMoveRequested = deleteMoveRequestedEvent.Event,
		DraftFieldChanged = draftFieldChangedEvent.Event,
		SaveRequested = saveRequestedEvent.Event,
		ResetRequested = resetRequestedEvent.Event,
		HotbarBindings = hotbarBindings,
		BindHotbarSlotRequested = bindHotbarSlotRequestedEvent.Event,
		SavedFingerprint = savedFingerprint,
		IsDirty = isDirty,
		UnsavedCount = unsavedCount,
		LastSavedMoveId = lastSavedMoveId,
		DuplicateMoveRequested = duplicateMoveRequestedEvent.Event,
		RenameMoveRequested = renameMoveRequestedEvent.Event,
		ToggleTestDummyRequested = toggleTestDummyRequestedEvent.Event,
		HasTestDummy = hasTestDummy,
	}
end

return MoveEditor
