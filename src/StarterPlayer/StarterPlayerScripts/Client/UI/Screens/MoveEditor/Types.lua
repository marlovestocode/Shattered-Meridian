--!strict
--[[
	MoveEditor/Types.lua

	Owns: MoveEditorHandle, the one shape UI/init.lua and Client/MoveEditor/MoveEditorClient.lua
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
	| "Projectile"
	-- The reaction to knocking a target INTO world geometry (Shared/Types.ObjectStunConfig, authored
	-- by ObjectStunEditor.lua). Like Movement/Knockback/Projectile it is an OPTIONAL sub-table, so it
	-- gets the same nav status dot and the same hidden-for-a-Default-move treatment they do.
	| "ObjectStun"
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
	-- Every move currently known client-side -- populated once by MoveEditorClient after ListMoves,
	-- patched in place (never a blind full re-fetch) after a successful Save/Delete so unrelated
	-- rows' own local UI state (e.g. a delete Armed timer) survives a save elsewhere in the list.
	MovesDisplay: Fusion.Value<{ MoveTypes.MoveDefinition }>,
	-- The move currently open in PropertyEditor/PreviewViewport -- nil when nothing is selected/
	-- being created yet. This is the SAME Fusion.Value both panels render from, so they can never
	-- drift out of sync with each other.
	Draft: Fusion.Value<MoveTypes.MoveDefinition?>,
	LastTestResultText: Fusion.Value<string>,
	-- Every hit observed since the last test-fire, appended by MoveEditorClient.lua from the same
	-- Combat_FeedbackEvent payloads that already drive LastTestResultText above, and read by
	-- StatsPanel.lua as the OBSERVED series it plots against the move's own computed one. A plain
	-- accumulating array rather than a rolling window: a test fire is a deliberate, bounded action, and
	-- the panel's own "Clear" button is what resets it -- see StatsPanel's own header.
	TestSamples: Fusion.Value<{ MoveStats.TestSample }>,

	NewMoveRequested: RBXScriptSignal,
	SelectMoveRequested: RBXScriptSignal<string>,
	DeleteMoveRequested: RBXScriptSignal<string>,
	-- Fires with the FULL, already-locally-updated draft after any single PropertyEditor field
	-- edit -- the whole record is the unit of update everywhere else in this feature
	-- (UpdateDraft/SaveMove both take a full MoveDefinition), so this mirrors that instead of
	-- exposing one signal per field.
	DraftFieldChanged: RBXScriptSignal<MoveTypes.MoveDefinition>,
	TestFireRequested: RBXScriptSignal,
	SaveRequested: RBXScriptSignal,
	-- Fired by PropertyEditor.lua's toolbar when the current Draft's Category == "Default" (in place
	-- of SaveRequested, which its toolbar hides for a Default move -- see that file's own header) --
	-- Client/MoveEditor/MoveEditorClient.lua routes this to the ResetDefaultMove RemoteFunction and
	-- patches the result back into Draft/MovesDisplay, mirroring the Save/Delete result-patching
	-- pattern. Never fires for a custom move; a Default move can never be deleted, only reset.
	ResetRequested: RBXScriptSignal,

	-- Live mirror of Client/Combat/HotbarBindings.lua's slot->MoveId map, kept in sync by
	-- MoveEditorClient.lua (initial GetAll() + an OnChanged subscription) -- PropertyEditor.lua's
	-- toolbar reads this to show which slot(s), if any, the CURRENTLY SELECTED move already
	-- occupies. This screen never writes HotbarBindings directly (that stays MoveEditorClient.lua's
	-- job, same "screen exposes state/signals, client module drives from outside" boundary as
	-- everything else in this file) -- see BindHotbarSlotRequested below for the write path.
	HotbarBindings: Fusion.Value<{ [number]: string? }>,
	-- Fired by PropertyEditor.lua's toolbar's "bind to slot N" buttons, carrying (slot, moveId) for
	-- whichever move is currently selected -- MoveEditorClient.lua's handler toggles
	-- HotbarBindings.Set/Clear (bind if this move doesn't already occupy that slot, unbind if it
	-- does) and reflects the result in StatusText. Purely client-side bookkeeping -- unlike every
	-- other signal above, nothing here ever reaches a RemoteFunction; only actually FIRING a bound
	-- move round-trips to the server (Combat_RequestFireHotbarMove).
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
	IsDirty: Fusion.Computed<boolean>,
	-- Fired by PropertyEditor.lua's toolbar Duplicate button and by Ctrl+D. Custom moves only.
	-- Needs no remote of its own: MoveEditorClient.lua clones the draft, blanks its MoveId, and sends
	-- it through the EXISTING UpdateDraft, where stampTrustedMetadata mints a fresh server-assigned
	-- MoveId for it -- the same path "+ New Move" already takes.
	DuplicateMoveRequested: RBXScriptSignal,
}

return {}
