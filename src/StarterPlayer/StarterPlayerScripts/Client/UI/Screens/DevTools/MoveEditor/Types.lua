--!strict
--[[
	MoveEditor/Types.lua

	Owns: MoveEditorHandle, the one shape UI/init.lua and Client/DevTools/MoveEditor/MoveEditorClient.lua
	both need to agree on -- the "screen exposes state/signals, client module drives from outside"
	boundary DevMenu/Types.lua's own header documents, applied to this screen's single top-level
	Mount call.

	Unlike DevMenu's Sidebar/ContentArea split, MoveList.lua/PropertyEditor.lua/PreviewViewport.lua
	do NOT get their own exposed sub-handles here -- init.lua constructs all three directly and
	wires them with plain closures (OnNew/OnSelect/OnFieldChanged/...), since init.lua is never
	called before they exist (unlike DevMenuClient.lua, which doesn't exist yet at the moment
	DevMenu/init.lua's OWN Mount runs). Only this outer boundary -- crossed later, by
	MoveEditorClient.lua -- needs BindableEvent-backed signals.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local MoveTypes = require(ReplicatedStorage.Shared.MoveTypes)
local MoveStats = require(ReplicatedStorage.Shared.MoveStats)

-- The customization-form section nav (Sidebar.lua's Sections group / PropertyEditor.lua's
-- per-section content panes) is keyed off this closed union rather than a plain string so a nav
-- item and its matching content pane can never drift to mismatched spellings. Shared here (not
-- declared in either file) so neither of those two siblings has to require the other just for this
-- type.
export type SectionId =
	"BasicInfo"
	| "Hitbox"
	| "Offset"
	| "Timing"
	| "Damage"
	| "Animation"
	| "Movement"
	| "Knockback"
	-- Instead of ordinary Knockback, hold the victim on the attacker's fist and let a follow-up throw
	-- them (MoveTypes.MoveGrabConfig, authored by GrabSystem's own "Enable Grab" toggle in
	-- PropertyEditor.lua). Same optional-sub-table status as Knockback right above it -- off by
	-- default, hidden for a Default move.
	| "Grab"
	| "Projectile"
	-- The reaction to knocking a target INTO world geometry (Shared/Types.ObjectStunConfig, authored
	-- by ObjectStunEditor.lua). Like Movement/Knockback/Projectile it is an OPTIONAL sub-table, so it
	-- gets the same nav status dot and the same hidden-for-a-Default-move treatment they do.
	| "ObjectStun"
	-- Promotes this move to an ArtSystem art (MoveTypes.MoveArtBinding). Like the optional
	-- sub-tables above it is off by default and hidden for a Default move -- a Default move is a
	-- built-in weapon stage, not something a player unlocks in a tree.
	| "Art"
	-- Read-only, unlike every section above it: StatsPanel.lua reports what the move does rather than
	-- authoring any field of it. Last in the nav for exactly that reason.
	| "Stats"

export type MoveEditorHandle = {
	IsOpen: Fusion.Value<boolean>,
	-- Fired by the screen's own "X" close button -- UNLIKE DevMenu/init.lua's identical button
	-- (which sets IsOpen directly, since nothing there needs to react to a close), this one routes
	-- through a signal because MoveEditorClient.lua needs to hear about EVERY open/close transition
	-- to unfreeze the admin's character (see MoveEditorClient.lua's own setOpen helper) -- the
	-- keybind toggle already goes through that same helper, so the close button has to as well or
	-- closing via the X button would leave the admin frozen.
	CloseRequested: RBXScriptSignal,
	StatusText: Fusion.Value<string>,
	-- Which section of the authoring form is open, owned by Sidebar.lua's own nav and normally
	-- written only by clicking that nav. Exposed on the handle so MoveEditorClient.lua can JUMP it on
	-- a rejected Save: a save validates the whole record at once, so the section that failed is very
	-- often not the one the admin is looking at, and a status line naming a section they then have to
	-- go find is barely better than the bare reason code it replaced. See Copy.Failures.
	SelectedSection: Fusion.Value<SectionId>,
	-- Whether the F1 shortcut list is up. Written only by MoveEditorClient.lua, which owns every key
	-- this editor binds -- ShortcutsOverlay.lua itself is pure render and has no input of its own.
	-- Deliberately independent of IsOpen: closing the list must not close the editor behind it, which
	-- is exactly what a shared flag would do to a layered Escape.
	ShortcutsOpen: Fusion.Value<boolean>,
	-- Every move currently known client-side -- populated once by MoveEditorClient after ListMoves,
	-- patched in place (never a blind full re-fetch) after a successful Save/Delete so unrelated
	-- rows' own local UI state (e.g. a delete Armed timer) survives a save elsewhere in the list.
	MovesDisplay: Fusion.Value<{ MoveTypes.MoveDefinition }>,
	-- The move currently open in PropertyEditor/PreviewViewport -- nil when nothing is selected/
	-- being created yet. This is the SAME Fusion.Value both panels render from, so they can never
	-- drift out of sync with each other.
	Draft: Fusion.Value<MoveTypes.MoveDefinition?>,
	-- "Test on Dummy" is REAL AGAIN (2026-08-19, the Move Editor repair pass), rebuilt against the new
	-- 4-layer combat stack rather than revived as-was -- see Client/DevTools/MoveEditor/MoveEditorClient.lua's
	-- own header for the pipeline. Firing still goes through the ADMIN HOTBAR PATH (bind the move to a
	-- slot via ArtSystem.DevGrantAndEquip, press the key -- AttackRequestSystem.resolveRequest's
	-- ArtSystem-backed Hotbar case, which never stopped working); what was actually missing was a
	-- target to swing at and a way to hear back what happened, both restored now:
	-- SpawnTestDummyRequested/DespawnTestDummyRequested below reuse
	-- Server/Systems/DebugDummySystem.lua (the DevMenu Spawn tab's own training dummy, already a real
	-- HitboxEngine/DefenseSystem combatant -- see that module's header) rather than a second dummy
	-- implementation, and MoveEditorClient.lua listens to the SAME Combat_Feedback event
	-- CombatFeedbackClient.lua already uses for FX, filtered to this admin's own landed hits on the
	-- currently selected move, to append into TestSamples below.
	LastTestResultText: Fusion.Value<string>,
	-- Read by StatsPanel.lua as the OBSERVED series it plots against the move's own computed one. A
	-- plain accumulating array rather than a rolling window: a test fire is a deliberate, bounded
	-- action, and the panel's own "Clear" button is what resets it -- see StatsPanel's own header.
	TestSamples: Fusion.Value<{ MoveStats.TestSample }>,
	-- Fired by PropertyEditor.lua's toolbar single toggling "Spawn Dummy"/"Despawn Dummy" button --
	-- MoveEditorClient.lua routes it (Spawn or Despawn, based on its own HasTestDummy guess) through
	-- DevMenuSystem's own DevMenu_SpawnDummy/DevMenu_DespawnAllDebugDummies remotes
	-- (Server/Systems/DebugDummySystem.lua's public surface) rather than a Move-Editor-owned duplicate --
	-- see this handle's LastTestResultText header on why reusing the existing training dummy is the
	-- right call. Fire-and-forget, status text only, the same shape DevMenuClient.lua's own
	-- SpawnDebugDummyRequested/DespawnAllDebugDummiesRequested already use.
	ToggleTestDummyRequested: RBXScriptSignal,
	-- This client's own best-effort local guess at whether it currently has a dummy spawned -- flipped
	-- optimistically by MoveEditorClient.lua on a successful Spawn/Despawn response, never polled from
	-- the server. Drives the toolbar button's own label -- see PropertyEditorProps.HasTestDummy's own
	-- header on why a wrong guess is harmless.
	HasTestDummy: Fusion.Value<boolean>,

	NewMoveRequested: RBXScriptSignal,
	SelectMoveRequested: RBXScriptSignal<string>,
	DeleteMoveRequested: RBXScriptSignal<string>,
	-- (moveId, newDisplayName) from MoveList.lua's inline rename. Needs no remote of its own:
	-- MoveEditorClient.lua resolves the record, rewrites one field, and sends it through the EXISTING
	-- UpdateDraft -- a rename is an ordinary field edit that happens to be authored from the list
	-- instead of from the Basic Info section. Custom moves only.
	RenameMoveRequested: RBXScriptSignal<(string, string)>,
	-- Fires with the FULL, already-locally-updated draft after any single PropertyEditor field
	-- edit -- the whole record is the unit of update everywhere else in this feature
	-- (UpdateDraft/SaveMove both take a full MoveDefinition), so this mirrors that instead of
	-- exposing one signal per field.
	DraftFieldChanged: RBXScriptSignal<MoveTypes.MoveDefinition>,
	SaveRequested: RBXScriptSignal,
	-- Fired by PropertyEditor.lua's toolbar when the current Draft's Category == "Default" (in place
	-- of SaveRequested, which its toolbar hides for a Default move -- see that file's own header) --
	-- Client/DevTools/MoveEditor/MoveEditorClient.lua routes this to the ResetDefaultMove RemoteFunction and
	-- patches the result back into Draft/MovesDisplay, mirroring the Save/Delete result-patching
	-- pattern. Never fires for a custom move; a Default move can never be deleted, only reset.
	ResetRequested: RBXScriptSignal,

	-- Live mirror of Client/Combat/HotbarBindings.lua's slot->ArtId map, kept in sync by
	-- MoveEditorClient.lua (initial GetAll() + an OnChanged subscription) -- PropertyEditor.lua's
	-- toolbar reads this to show which slot(s), if any, the CURRENTLY SELECTED move already
	-- occupies. This screen never writes HotbarBindings directly (that stays MoveEditorClient.lua's
	-- job, same "screen exposes state/signals, client module drives from outside" boundary as
	-- everything else in this file) -- see BindHotbarSlotRequested below for the write path.
	HotbarBindings: Fusion.Value<{ [number]: string? }>,
	-- Fired by PropertyEditor.lua's toolbar's "bind to slot N" buttons, carrying (slot, moveId) for
	-- whichever move is currently selected -- MoveEditorClient.lua's handler calls the
	-- EquipArtSlot RemoteFunction (bind if this move doesn't already occupy that slot, unbind if it
	-- does) and reflects the result in StatusText. An equip, not client-only bookkeeping -- see
	-- HotbarBindings.lua's own header on why binding IS equipping now (ArtSystem.DevGrantAndEquip
	-- server-side); HotbarBindings itself only ever updates from the server's own Art_StateUpdated
	-- push, never optimistically from this signal.
	BindHotbarSlotRequested: RBXScriptSignal<(number, string)>,

	-- MoveTypes.Fingerprint of the last state the server confirmed as authoritative. Written by
	-- MoveEditorClient.lua on a successful New/Select/Save/Reset/Duplicate ONLY -- never on a
	-- debounced UpdateDraft reconcile, since that call never touched the DataStore.
	--
	-- HONEST LIMITATION, worth knowing before trusting IsDirty: GetMove returns MoveRegistryManager's
	-- LIVE in-memory registry, which handleUpdateDraft has already mutated with unsaved edits. So
	-- re-selecting a move that was edited-but-not-saved earlier in this same session reads as clean
	-- while the DataStore still holds the older values. IsDirty is therefore scoped to "changed since
	-- this editing session last saved or loaded it," not "differs from storage" -- closing that gap
	-- properly needs the server to report persisted-vs-live divergence, which is a feature rather
	-- than a polish item.
	SavedFingerprint: Fusion.Value<string>,
	-- How many DISTINCT moves have been edited but not saved this session. IsDirty below answers the
	-- same question for the OPEN move only, which is not the same question: the editor happily lets an
	-- admin retune three moves and close, and before this there was nothing anywhere that said two of
	-- them were about to be left behind. Maintained by MoveEditorClient.lua, which is the only module
	-- that sees every edit and every save.
	UnsavedCount: Fusion.Value<number>,
	-- The move whose row should be flashing "saved" right now, or "" for none. Set on a successful
	-- Save/Reset and cleared by MoveEditorClient.lua a moment later -- the timer lives there rather
	-- than in the row so a row rebuilt mid-flash (a MovesDisplay patch does exactly that) picks the
	-- flash back up instead of losing it, and so the whole feature is one value rather than per-row
	-- state that has to be found again.
	LastSavedMoveId: Fusion.Value<string>,
	IsDirty: Fusion.Computed<boolean>,
	-- Fired by PropertyEditor.lua's toolbar Duplicate button, by Ctrl+D, and by a move row's own ⊕
	-- tile. Custom moves only. Needs no remote of its own: MoveEditorClient.lua clones the record,
	-- blanks its MoveId, and sends it through the EXISTING UpdateDraft, where stampTrustedMetadata
	-- mints a fresh server-assigned MoveId for it -- the same path "+ New Move" already takes.
	--
	-- Carries the MoveId to copy, which is "" from the toolbar and Ctrl+D (both mean "the open
	-- draft") and a real id from a list row, since a row can be copied without being selected.
	DuplicateMoveRequested: RBXScriptSignal<string>,
}

-- The sections a Default move has no legitimate use for. Movement/Knockback/Grab/Projectile/
-- ObjectStun are consumed only by CombatSystem.ThrowCustomMove's own code path (see Server/Combat/
-- DefaultMoveRegistry.lua's header), and Art promotes a move into a tree the player unlocks, which
-- a built-in weapon stage is not. Sidebar.lua hides their NAV ITEMS and PropertyEditor.lua hides
-- their CONTENT PANES -- two different jobs off one list, which is why it lives here rather than in
-- either of them.
--
-- It lives here because it had ALREADY DRIFTED: both files hand-wrote the same table with only a
-- comment binding them together, and Art was added to one before the other, leaving a live nav item
-- that opened a blank pane. Adding a section to this list is now one edit, not two.
--
-- A hidden section is not merely disabled: there is nothing legitimate to navigate to, and showing
-- a live control that visibly does nothing is worse than showing none.
local HiddenForDefaultSections: { [SectionId]: boolean } = {
	Movement = true,
	Knockback = true,
	Grab = true,
	Projectile = true,
	ObjectStun = true,
	Art = true,
}

return {
	HiddenForDefaultSections = HiddenForDefaultSections,
}
