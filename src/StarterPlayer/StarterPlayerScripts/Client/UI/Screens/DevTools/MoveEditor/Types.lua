--!strict
--[[
	MoveEditor/Types.lua

	Owns: MoveEditorHandle -- the boundary between the Move Editor screen (MoveEditor/init.lua) and the
	module that drives it from outside (Client/DevTools/MoveEditor/MoveEditorClient.lua). Its own file so
	the driver can name the handle without requiring the whole screen's module graph for a type.

	The same split every screen here keeps: the SCREEN owns its Values and exposes signals; the DRIVER
	writes server-owned state into those Values and turns signals into remote calls. Nothing in the
	screen touches NetworkBridge.

	Does not own: the wire contract (Shared/Authoring/MoveEditorTypes.lua) or the move schema (MoveTypes).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local MoveEditorTypes = require(ReplicatedStorage.Shared.Authoring.MoveEditorTypes)
local MoveTypes = require(ReplicatedStorage.Shared.MoveTypes)

-- One contact a Test swing made, as the readout's HIT LOG shows it (see HitLog.lua).
export type HitLogEntry = {
	MoveId: string,
	-- DefenseTypes.OutcomeKind: Clean, Backstab, Blocked, GuardBroken, Parried, Evaded, Trade.
	Kind: string,
	Damage: number,
	GuardDrain: number,
	-- The attacker's landed-combo stage after this hit.
	ComboStage: number,
	-- Seconds from the swing starting (Attack_Started) to this contact.
	SinceSwing: number,
	Target: string,
}

export type MoveEditorHandle = {
	IsOpen: Fusion.Value<boolean>,
	-- The footer's answer to the last action ("Saved.", "Refused: Cooldown").
	StatusText: Fusion.Value<string>,

	-- Server-owned, written only by the driver.
	Entries: Fusion.Value<{ MoveEditorTypes.MoveEntry }>,
	-- Hotbar slot -> equipped art id, mirrored from Client/Combat/HotbarBindings.
	HotbarBindings: Fusion.Value<{ [number]: string? }>,
	-- Server-wide hitbox volume visualiser state (HitboxEngine.IsDebugVolumesEnabled).
	VolumesVisible: Fusion.Value<boolean>,

	-- Which move is open, and the draft being edited. The draft is written optimistically by the screen
	-- on every edit (so fields and plots react instantly) and reconciled by the driver when the server
	-- answers.
	SelectedId: Fusion.Value<string?>,
	Draft: Fusion.Value<MoveTypes.MoveDefinition?>,
	-- The open move's entry, and whether the draft differs from what is persisted.
	SelectedEntry: Fusion.Computed<MoveEditorTypes.MoveEntry?>,
	IsDirty: Fusion.Computed<boolean>,

	-- Which form tab is showing; writable so the driver can jump to the tab a refusal names.
	CurrentTab: Fusion.Value<string>,

	-- Undo/redo, owned by the screen (see init.lua's header). The driver binds the keys to Undo/Redo and
	-- calls ClearHistory after anything that replaces a move with server state the history never saw.
	CanUndo: Fusion.Computed<boolean>,
	CanRedo: Fusion.Computed<boolean>,
	Undo: () -> (),
	Redo: () -> (),
	ClearHistory: (moveId: string) -> (),

	CloseRequested: RBXScriptSignal<>,
	-- (moveId)
	SelectRequested: RBXScriptSignal<string>,
	NewRequested: RBXScriptSignal<>,
	DuplicateRequested: RBXScriptSignal<>,
	-- (draft) -- fired after the screen has already set Draft to it.
	DraftEdited: RBXScriptSignal<MoveTypes.MoveDefinition>,
	SaveRequested: RBXScriptSignal<>,
	RevertRequested: RBXScriptSignal<>,
	DeleteRequested: RBXScriptSignal<>,
	ResetDefaultRequested: RBXScriptSignal<>,
	TestRequested: RBXScriptSignal<>,
	-- (slot) -- binds the open art to that hotbar slot, or clears the slot if it already holds it.
	BindSlotRequested: RBXScriptSignal<number>,
	SpawnDummyRequested: RBXScriptSignal<>,
	-- (visible)
	VolumesToggled: RBXScriptSignal<boolean>,

	-- The test bench (TestBench.lua). DummyGuard mirrors the server's DebugDummySystem state; the bot
	-- choices are local until a spawn sends them.
	DummyGuard: Fusion.Value<boolean>,
	BotStyle: Fusion.Value<string>,
	BotDifficulty: Fusion.Value<string>,
	-- (enabled)
	DummyGuardToggled: RBXScriptSignal<boolean>,
	SpawnBotRequested: RBXScriptSignal<>,
	ClearBenchRequested: RBXScriptSignal<>,

	-- The hitbox drawn on the admin's own character (Client/DevTools/MoveEditor/HitboxWorldPreview.lua),
	-- and Place mode: the modal steps aside and the volume is dragged in the world with handles.
	ShowOnCharacter: Fusion.Value<boolean>,
	PlacementMode: Fusion.Value<boolean>,
	-- "Move" | "Rotate" | "Resize"
	PlacementTool: Fusion.Value<string>,
	-- Studs per snap step; 0 is free. Any non-zero step also snaps rotation (PlacementMath).
	PlacementSnap: Fusion.Value<number>,
	-- The screen's own edit path, for an editor outside the form (the Place mode gizmo): clones the
	-- draft, applies `mutate`, records undo, sets Draft and fires DraftEdited -- exactly a field edit.
	EditDraft: (mutate: (MoveTypes.MoveDefinition) -> ()) -> (),

	-- Contacts from Test swings of the open move, newest first (HitLog.lua). Written by the driver.
	HitLog: Fusion.Value<{ HitLogEntry }>,
	ClearHitLogRequested: RBXScriptSignal<>,

	-- (request) -- the Tools tab's bulk apply; the driver invokes MoveEditor_BulkScale with it.
	BulkScaleRequested: RBXScriptSignal<MoveEditorTypes.BulkScaleRequest>,

	-- The open move's saved versions (Tools tab), newest first; nil until loaded for this selection.
	HistoryVersions: Fusion.Value<{ MoveEditorTypes.HistoryVersion }?>,
	LoadHistoryRequested: RBXScriptSignal<>,
	-- (version)
	RestoreVersionRequested: RBXScriptSignal<number>,

	-- Studio-only source tools (Tools tab > SOURCE). ExportText is the generated module, once exported.
	ExportText: Fusion.Value<string?>,
	WriteToSourceRequested: RBXScriptSignal<>,
	RemoveFromSourceRequested: RBXScriptSignal<>,
	ExportSourceRequested: RBXScriptSignal<>,

	-- (moment) -- the Presentation tab's per-moment Preview: play the DRAFT's cue for that moment on this
	-- client, through the runtime's own path (Client/DevTools/MoveEditor/PresentationPreview.lua).
	PreviewCueRequested: RBXScriptSignal<string>,
}

return {}
