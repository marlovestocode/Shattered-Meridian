--!strict
--[[
	MoveEditor/init.lua

	Owns: the Move Editor screen -- the admin tool that authors every combat move as data -- and the
	Values and signals on its handle (Types.lua). Rebuilt from nothing on 2026-09-29 alongside the schema,
	the registries and the server System; see docs/design/move-editor-guide.md for how it is used.

	THE FRAME IS Components/ScreenFrame, like every modal here: a tab strip, a body, a footer carrying the
	answer to the last action. The body is a row of three, and the reason for each column is what it is
	FOR while an author works:

	    Browser (rail)   every move, grouped, with its save state -- where you go to pick
	    Form (tabs)      Hitbox / Timing / Impact / Identity -- the inputs, one concern per tab
	    Readout (rail)   plots, the effective timeline, notes, actions -- the RESULTS of those inputs

	Both rails are pinned, so a result is never a tab switch away from the input that caused it (the
	character menu's IdentityRail argument). The form takes whatever the rails leave (Stack.Fill), not a
	width computed from theirs.

	NO CARDS. Groups inside a column are separated by a bronze SectionHeading and spacing, never by a
	bordered box inside the panel's own border -- ScreenFrame's header, and the reason the old editor's
	Section-card stack was the first thing this rebuild removed.

	EDITS ARE OPTIMISTIC AND FLOW ONE WAY. A field edit clones the draft, mutates the clone, sets Draft
	(so every field, both plots and the dirty chip update the same frame) and fires DraftEdited; the
	driver debounces that into a Preview and writes the server's answer back. Nothing in this screen
	calls a remote.

	UNDO LIVES HERE, not in the driver: it is a property of the edits this screen makes, and an undo is
	just one more edit -- it sets Draft and fires DraftEdited like any field, so the driver previews it
	with no special case. Every edit records the draft it replaced (Shared/Authoring/DraftHistory.lua,
	one stack per move, a burst of edits coalesced into one step). The server's own answers written back
	into Draft are not edits and are never recorded.

	Does not own: any network call, authorization, or what an action does -- Client/DevTools/MoveEditor/
	MoveEditorClient.lua drives this screen from outside.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Constants = require(ReplicatedStorage.Shared.Constants)
local DraftHistory = require(ReplicatedStorage.Shared.Authoring.DraftHistory)
local MoveEditorTypes = require(ReplicatedStorage.Shared.Authoring.MoveEditorTypes)
local MoveTypes = require(ReplicatedStorage.Shared.MoveTypes)
local TrainingBotConstants = require(ReplicatedStorage.Shared.TrainingBot.TrainingBotConstants)

local Tokens = require(script.Parent.Parent.Parent.Tokens)
local Inset = require(script.Parent.Parent.Parent.Components.Inset)
local Label = require(script.Parent.Parent.Parent.Components.Label)
local ScreenFrame = require(script.Parent.Parent.Parent.Components.ScreenFrame)
local Stack = require(script.Parent.Parent.Parent.Components.Stack)

local Browser = require(script.Browser)
local Fields = require(script.Fields)
local HitboxTab = require(script.HitboxTab)
local IdentityTab = require(script.IdentityTab)
local ImpactTab = require(script.ImpactTab)
local MoveEditorScreenTypes = require(script.Types)
local Readout = require(script.Readout)
local TimingTab = require(script.TimingTab)

local peek = Fusion.peek

type Scope = Fusion.Scope<typeof(Fusion)>
type MoveEntry = MoveEditorTypes.MoveEntry

export type MoveEditorHandle = MoveEditorScreenTypes.MoveEditorHandle

local MoveEditor = {}

local ROOT_WIDTH = 1240
local ROOT_HEIGHT = 780
local BROWSER_WIDTH = 272
local READOUT_WIDTH = 344

local TAB_NAMES: { string } = { "Hitbox", "Timing", "Impact", "Identity" }

function MoveEditor.Mount(scope: Scope, playerGui: PlayerGui): MoveEditorHandle
	local isOpen = scope:Value(false)
	local statusText = scope:Value("")
	local entries = scope:Value({} :: { MoveEntry })
	local hotbarBindings = scope:Value({} :: { [number]: string? })
	local volumesVisible = scope:Value(false)
	local dummyGuard = scope:Value(false)
	local botStyle = scope:Value(TrainingBotConstants.DefaultStyle :: string)
	local botDifficulty = scope:Value(TrainingBotConstants.DefaultDifficulty :: string)
	local hitLog = scope:Value({} :: { MoveEditorScreenTypes.HitLogEntry })
	local selectedId = scope:Value(nil :: string?)
	local draft = scope:Value(nil :: MoveTypes.MoveDefinition?)
	local tabs = ScreenFrame.NewTabState(scope, TAB_NAMES)

	local selectedEntry = scope:Computed(function(use): MoveEntry?
		local id = use(selectedId)
		if not id then
			return nil
		end
		for _, entry in ipairs(use(entries)) do
			if entry.Move.MoveId == id then
				return entry
			end
		end
		return nil
	end)
	local isDirty = scope:Computed(function(use)
		local current = use(draft)
		if not current then
			return false
		end
		local entry = use(selectedEntry)
		-- No entry yet is a brand-new move the server has not answered for: unsaved by definition.
		return entry == nil or entry.SavedFingerprint ~= MoveTypes.Fingerprint(current)
	end)
	local isDefault = scope:Computed(function(use)
		local entry = use(selectedEntry)
		return entry ~= nil and entry.Source == "Default"
	end)
	local hasDraft = scope:Computed(function(use)
		return use(draft) ~= nil
	end)

	-- Raw BindableEvents need registering with the scope to be cleaned up with it (Studio hot reload
	-- re-runs Mount) -- see Screens/Menus/init.lua.
	local function signal(): BindableEvent
		local event = Instance.new("BindableEvent")
		table.insert(scope, event)
		return event
	end
	local closeRequested = signal()
	local selectRequested = signal()
	local newRequested = signal()
	local duplicateRequested = signal()
	local draftEdited = signal()
	local saveRequested = signal()
	local revertRequested = signal()
	local deleteRequested = signal()
	local resetDefaultRequested = signal()
	local testRequested = signal()
	local bindSlotRequested = signal()
	local spawnDummyRequested = signal()
	local volumesToggled = signal()
	local dummyGuardToggled = signal()
	local spawnBotRequested = signal()
	local clearBenchRequested = signal()
	local clearHitLogRequested = signal()

	local history = DraftHistory.new(Constants.MoveEditor.UndoDepth, Constants.MoveEditor.UndoCoalesceSeconds)
	-- DraftHistory is plain data; this bumps whenever it changes so CanUndo/CanRedo recompute.
	local historyVersion = scope:Value(0)
	local function historyChanged(): ()
		historyVersion:set(peek(historyVersion) + 1)
	end
	local function canStep(ask: (DraftHistory.History, string) -> boolean)
		return scope:Computed(function(use)
			use(historyVersion)
			local current = use(draft)
			return current ~= nil and current.MoveId ~= "" and ask(history, current.MoveId)
		end)
	end
	local canUndo = canStep(DraftHistory.CanUndo)
	local canRedo = canStep(DraftHistory.CanRedo)

	-- Replaces the draft with one the history handed back, exactly as an edit would.
	local function step(take: (DraftHistory.History, string, MoveTypes.MoveDefinition) -> MoveTypes.MoveDefinition?)
		local current = peek(draft)
		if not current or current.MoveId == "" then
			return
		end
		local target = take(history, current.MoveId, current)
		if not target then
			return
		end
		historyChanged()
		draft:set(target)
		draftEdited:Fire(target)
	end
	local function undo(): ()
		step(DraftHistory.Undo)
	end
	local function redo(): ()
		step(DraftHistory.Redo)
	end

	local context: Fields.FormContext = {
		Draft = draft,
		IsDefault = isDefault,
		Entry = selectedEntry,
		Edit = function(mutate)
			local current = peek(draft)
			if not current then
				return
			end
			local nextDraft = MoveTypes.Clone(current)
			mutate(nextDraft)
			-- A move the server has not named yet has nowhere to file its history.
			if current.MoveId ~= "" then
				history:Record(current.MoveId, current, os.clock())
				historyChanged()
			end
			draft:set(nextDraft)
			draftEdited:Fire(nextDraft)
		end,
	}

	local function pageVisible(name: string)
		return scope:Computed(function(use)
			return use(tabs.Selected[name]) and use(hasDraft)
		end)
	end

	local form = Stack.New(scope, {
		Name = "Form",
		LayoutOrder = 2,
		ClipsDescendants = true,
		Children = {
			Inset(scope, { Top = Tokens.Space.M, X = Tokens.Space.L }),
			-- Exactly one page is visible at a time, so the Stack places it at the origin; a page is a
			-- full-height ScrollArea.
			HitboxTab(scope, context, pageVisible("Hitbox")),
			TimingTab(scope, context, pageVisible("Timing")),
			ImpactTab(scope, context, pageVisible("Impact")),
			IdentityTab(scope, context, pageVisible("Identity")),
			Label(scope, {
				Text = "Pick a move on the left, or make a new one.",
				Scale = "Body",
				Color = Tokens.Color.TextDisabled,
				Size = UDim2.new(1, 0, 0, Tokens.Control.RowHeight),
				Visible = scope:Computed(function(use)
					return not use(hasDraft)
				end),
			}),
		},
	})

	ScreenFrame.Mount(scope, playerGui, {
		Name = "MoveEditor",
		Size = UDim2.fromOffset(ROOT_WIDTH, ROOT_HEIGHT),
		IsOpen = isOpen,
		-- No HeaderAccessory: the tab run spans the whole strip, so anything pinned there sits on top of
		-- the last tab. The move count and unsaved count live in the browser rail's own header instead.
		Tabs = tabs,
		Wordmark = "MOVE EDITOR",
		StatusText = statusText,
		-- A signal, not a write: the driver arms the unsaved-work confirmation before anything closes.
		OnClose = function()
			closeRequested:Fire()
		end,
		Body = Stack.Row(scope, {
			Name = "Body",
			Children = {
				Browser(scope, {
					Width = BROWSER_WIDTH,
					LayoutOrder = 1,
					Entries = entries,
					SelectedId = selectedId,
					IsDirty = isDirty,
					OnSelect = function(moveId: string)
						selectRequested:Fire(moveId)
					end,
					OnNew = function()
						newRequested:Fire()
					end,
				}),
				Stack.Fill(scope, form),
				Readout(scope, {
					Width = READOUT_WIDTH,
					LayoutOrder = 3,
					Entry = selectedEntry,
					Draft = draft,
					IsDirty = isDirty,
					HotbarBindings = hotbarBindings,
					VolumesVisible = volumesVisible,
					CanUndo = canUndo,
					CanRedo = canRedo,
					OnUndo = undo,
					OnRedo = redo,
					OnSave = function()
						saveRequested:Fire()
					end,
					OnTest = function()
						testRequested:Fire()
					end,
					OnRevert = function()
						revertRequested:Fire()
					end,
					OnDuplicate = function()
						duplicateRequested:Fire()
					end,
					OnDelete = function()
						deleteRequested:Fire()
					end,
					OnResetDefault = function()
						resetDefaultRequested:Fire()
					end,
					OnBindSlot = function(slot: number)
						bindSlotRequested:Fire(slot)
					end,
					OnSpawnDummy = function()
						spawnDummyRequested:Fire()
					end,
					OnToggleVolumes = function(visible: boolean)
						volumesToggled:Fire(visible)
					end,
					DummyGuard = dummyGuard,
					BotStyle = botStyle,
					BotDifficulty = botDifficulty,
					OnDummyGuard = function(enabled: boolean)
						dummyGuardToggled:Fire(enabled)
					end,
					OnSpawnBot = function()
						spawnBotRequested:Fire()
					end,
					OnClearBench = function()
						clearBenchRequested:Fire()
					end,
					HitLog = hitLog,
					OnClearHitLog = function()
						clearHitLogRequested:Fire()
					end,
				}),
			},
		}),
	})

	return {
		IsOpen = isOpen,
		StatusText = statusText,
		Entries = entries,
		HotbarBindings = hotbarBindings,
		VolumesVisible = volumesVisible,
		SelectedId = selectedId,
		Draft = draft,
		SelectedEntry = selectedEntry,
		IsDirty = isDirty,
		CurrentTab = tabs.Current,
		CanUndo = canUndo,
		CanRedo = canRedo,
		Undo = undo,
		Redo = redo,
		ClearHistory = function(moveId: string)
			history:Clear(moveId)
			historyChanged()
		end,
		CloseRequested = closeRequested.Event,
		SelectRequested = selectRequested.Event,
		NewRequested = newRequested.Event,
		DuplicateRequested = duplicateRequested.Event,
		DraftEdited = draftEdited.Event,
		SaveRequested = saveRequested.Event,
		RevertRequested = revertRequested.Event,
		DeleteRequested = deleteRequested.Event,
		ResetDefaultRequested = resetDefaultRequested.Event,
		TestRequested = testRequested.Event,
		BindSlotRequested = bindSlotRequested.Event,
		SpawnDummyRequested = spawnDummyRequested.Event,
		VolumesToggled = volumesToggled.Event,
		DummyGuard = dummyGuard,
		BotStyle = botStyle,
		BotDifficulty = botDifficulty,
		DummyGuardToggled = dummyGuardToggled.Event,
		SpawnBotRequested = spawnBotRequested.Event,
		ClearBenchRequested = clearBenchRequested.Event,
		HitLog = hitLog,
		ClearHitLogRequested = clearHitLogRequested.Event,
	} :: any
end

return MoveEditor
