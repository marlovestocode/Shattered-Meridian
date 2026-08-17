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
	own outer Mount crosses the "not created yet" boundary Client/MoveEditor/MoveEditorClient.lua
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
	slot button. Unlike every OTHER signal this file owns, MoveEditorClient.lua's handler for this
	one never touches a RemoteFunction -- Client/Combat/HotbarBindings.lua is purely client-side
	bookkeeping, see that module's own header.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local MoveTypes = require(ReplicatedStorage.Shared.MoveTypes)
local MoveStats = require(ReplicatedStorage.Shared.MoveStats)

local Tokens = require(script.Parent.Parent.Tokens)
local Panel = require(script.Parent.Parent.Components.Panel)
local Label = require(script.Parent.Parent.Components.Label)
local Button = require(script.Parent.Parent.Components.Button)
local Divider = require(script.Parent.Parent.Components.Divider)

local MoveEditorTypes = require(script.Types)
local Sidebar = require(script.Sidebar)
local PropertyEditor = require(script.PropertyEditor)
local PreviewViewport = require(script.PreviewViewport)

local Children = Fusion.Children
local peek = Fusion.peek

type Scope = Fusion.Scope<typeof(Fusion)>

export type MoveEditorHandle = MoveEditorTypes.MoveEditorHandle

local MoveEditor = {}

local HEADER_HEIGHT = 36
local SIDEBAR_WIDTH = 260
local CONTENT_WIDTH = 600
local PREVIEW_WIDTH = 420
local BODY_WIDTH = SIDEBAR_WIDTH + Tokens.Space.M * 2 + CONTENT_WIDTH + PREVIEW_WIDTH
local ROOT_SIZE = UDim2.fromOffset(BODY_WIDTH + Tokens.Space.L * 2, 760)
local BODY_HEIGHT = 760 - Tokens.Space.L * 2 - HEADER_HEIGHT - Tokens.Space.M

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
		OnDelete = function(moveId: string)
			deleteMoveRequestedEvent:Fire(moveId)
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
			duplicateMoveRequestedEvent:Fire()
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

	local previewRoot = PreviewViewport.Mount(scope, PREVIEW_WIDTH, BODY_HEIGHT, {
		Draft = draft,
		IsOpen = isOpen,
	})

	scope:New "ScreenGui" {
		Name = "MoveEditor",
		ResetOnSpawn = false,
		Enabled = isOpen,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Parent = playerGui,

		[Children] = Panel(scope, {
			Name = "Root",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = ROOT_SIZE,
			Elevated = true,
			CornerAccent = true,

			Children = {
				scope:New "UIPadding" {
					PaddingTop = UDim.new(0, Tokens.Space.L),
					PaddingBottom = UDim.new(0, Tokens.Space.L),
					PaddingLeft = UDim.new(0, Tokens.Space.L),
					PaddingRight = UDim.new(0, Tokens.Space.L),
				},
				scope:New "UIListLayout" {
					FillDirection = Enum.FillDirection.Vertical,
					HorizontalAlignment = Enum.HorizontalAlignment.Left,
					Padding = UDim.new(0, Tokens.Space.M),
					SortOrder = Enum.SortOrder.LayoutOrder,
				},

				scope:New "Frame" {
					Name = "Header",
					Size = UDim2.new(1, 0, 0, HEADER_HEIGHT),
					BackgroundTransparency = 1,
					LayoutOrder = 1,

					[Children] = {
						Label(scope, {
							Text = "Move Creation System",
							Scale = "Heading",
							AnchorPoint = Vector2.new(0, 0.5),
							Position = UDim2.fromScale(0, 0.5),
						}),
						Label(scope, {
							Text = statusText,
							Scale = "Body",
							Color = Tokens.Color.TextSecondary,
							AnchorPoint = Vector2.new(1, 0.5),
							Position = UDim2.new(1, -Tokens.Control.CloseButtonClearance, 0.5, 0),
							TextXAlignment = Enum.TextXAlignment.Right,
						}),
						Button(scope, {
							Text = "X",
							Size = UDim2.fromOffset(28, 28),
							AnchorPoint = Vector2.new(1, 0.5),
							Position = UDim2.fromScale(1, 0.5),
							OnActivated = function()
								closeRequestedEvent:Fire()
							end,
						}),
					},
				},

				-- The header/body seam -- docs/ui-ux-philosophy.md's own "layered depth" panel
				-- language, made literal as a hairline rule between the two bands instead of relying
				-- on padding alone to separate them.
				Divider.Plain(scope, { LayoutOrder = 2, Tint = Tokens.Border.Lit }),

				scope:New "Frame" {
					Name = "Body",
					Size = UDim2.fromOffset(BODY_WIDTH, BODY_HEIGHT),
					BackgroundTransparency = 1,
					LayoutOrder = 3,

					[Children] = {
						scope:New "UIListLayout" {
							FillDirection = Enum.FillDirection.Horizontal,
							HorizontalAlignment = Enum.HorizontalAlignment.Left,
							Padding = UDim.new(0, Tokens.Space.M),
							SortOrder = Enum.SortOrder.LayoutOrder,
						},
						sidebar.Root,
						propertyEditorRoot,
						previewRoot,
					},
				},
			},
		}),
	}

	return {
		IsOpen = isOpen,
		CloseRequested = closeRequestedEvent.Event,
		StatusText = statusText,
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
		DuplicateMoveRequested = duplicateMoveRequestedEvent.Event,
	}
end

return MoveEditor
