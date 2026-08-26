--!strict
--[[
	KitEditor/Types.lua

	Owns: KitEditorHandle, the one shape UI/init.lua and Client/DevTools/KitEditor/KitEditorClient.lua share
	across the "screen exposes state/signals, client module drives from outside" boundary --
	Screens/DevTools/MoveEditor/Types.lua's own header names this same split for the identical reason. Every
	field on the handle is either state BOTH sides read (IsOpen, RaceTraits, Bloodlines, Draft), or a
	BindableEvent-backed signal the screen fires and the client module answers (NewRaceTraitRequested,
	SaveRequested, ...).

	KitDraft is the ONE thing this editor keeps open at a time, tagged by Kind so a plain Luau table
	can stand in for the union Race Trait/Bloodline content genuinely is -- Luau has no runtime
	discriminated union, so `draft.Kind` is what every reader branches on instead of an `is-a` check.

	Does not own: the actual RemoteFunction calls (KitEditorClient.lua) or authorization
	(KitEditorSystem.lua re-checks server-side regardless of whether this screen is even visible).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local RaceTraitTypes = require(ReplicatedStorage.Shared.Race.RaceTraitTypes)
local BloodlineTypes = require(ReplicatedStorage.Shared.Bloodline.BloodlineTypes)
local MoveTypes = require(ReplicatedStorage.Shared.MoveTypes)

local KitEditorTypes = {}

export type KitDraftKind = "RaceTrait" | "Bloodline"

export type RaceTraitDraft = {
	Kind: "RaceTrait",
	Trait: RaceTraitTypes.RaceTraitDefinition,
}

export type BloodlineDraft = {
	Kind: "Bloodline",
	Bloodline: BloodlineTypes.BloodlineDefinition,
}

export type KitDraft = RaceTraitDraft | BloodlineDraft

-- A deterministic string digest of any plain table of DataStore-safe primitives (string/number/
-- boolean, nested tables/arrays) -- what SavedFingerprint/IsDirty compare against, the same
-- "one string comparison per edit beats a full recursive deep-equal" reasoning MoveTypes.Fingerprint's
-- own header gives. Generic over any such table (not KitDraft-specific) because both RaceTraitDraft
-- and BloodlineDraft, and everything nested inside either, are already exactly that shape -- see
-- KitEditorSystem.lua's own header on why neither schema carries a Roblox-specific value type.
--
-- Keys are visited in SORTED order at every level (pairs() order is unspecified and can genuinely
-- differ between two structurally identical tables), and an array (a table whose only keys are a
-- contiguous 1..#t) is digested in INDEX order instead -- sorting "1", "2", "10" lexicographically
-- would put "10" before "2", corrupting an Effects list's own meaning.
-- The digest walk itself is Shared/MoveTypes.DigestValue. The copy that used to live here and
-- MoveTypes' own differed in COMPLEMENTARY directions -- this one knew about arrays and not about
-- Roblox value types, that one the reverse -- so neither was a subset of the other, and merging them
-- meant taking both halves rather than picking a winner. The Vector3/Color3/CFrame branches are
-- inert for a kit definition (KitEditorSystem's own header: "no Vector3/CFrame/Color3 anywhere in
-- either schema"), and the array branch is what this file contributed.

function KitEditorTypes.Fingerprint(value: { [any]: unknown }): string
	local out: { string } = {}
	MoveTypes.DigestValue(out, value)
	return table.concat(out)
end

export type KitEditorHandle = {
	IsOpen: Fusion.Value<boolean>,
	StatusText: Fusion.Value<string>,

	-- Every trait/bloodline currently known client-side -- populated once by KitEditorClient after
	-- ListRaceTraits/ListBloodlines, and patched in place on every successful UpdateDraft/Save/Delete
	-- reconcile, the same "patch in place, never a blind full re-fetch" reasoning
	-- MoveEditor/init.lua's own header gives for its identical MovesDisplay field.
	RaceTraits: Fusion.Value<{ RaceTraitTypes.RaceTraitDefinition }>,
	Bloodlines: Fusion.Value<{ BloodlineTypes.BloodlineDefinition }>,

	-- The ONE draft currently open, or nil. Written only through KitEditorClient.lua's own
	-- setOpenDraft (see that file's header) -- PropertyEditor.lua's field edits write here too, but
	-- ALWAYS alongside firing DraftFieldChanged, never in place of it.
	Draft: Fusion.Value<KitDraft?>,

	-- The fingerprint of whatever the server last handed back as AUTHORITATIVE (a successful New/
	-- Select/Save), written by KitEditorClient.lua only -- same "UpdateDraft only touches the live
	-- registry, Save is what reaches the DataStore" contract MoveEditor's own SavedFingerprint header
	-- describes.
	SavedFingerprint: Fusion.Value<string>,
	IsDirty: Fusion.Computed<boolean>,

	-- Sidebar.lua's own nav selection -- which of the two groups (RaceTrait/Bloodline) is being
	-- browsed. Independent of Draft: an admin can browse Bloodlines while a Race Trait is still open
	-- for editing.
	SelectedGroup: Fusion.Value<KitDraftKind>,

	-- Every signal below is the BindableEvent's own .Event (an RBXScriptSignal), not the BindableEvent
	-- itself -- matching MoveEditor/init.lua's own handle, which hands out exactly what a Connect()
	-- caller needs and nothing that could also Fire() it from the wrong side of the boundary.
	CloseRequested: RBXScriptSignal,
	NewRaceTraitRequested: RBXScriptSignal,
	NewBloodlineRequested: RBXScriptSignal,
	-- Fired with the id (TraitId or BloodlineId) of the row clicked.
	SelectRaceTraitRequested: RBXScriptSignal,
	SelectBloodlineRequested: RBXScriptSignal,
	DeleteRaceTraitRequested: RBXScriptSignal,
	DeleteBloodlineRequested: RBXScriptSignal,
	-- Fired with the new KitDraft every time PropertyEditor.lua commits a field edit -- debounced into
	-- an UpdateDraft call by KitEditorClient.lua, exactly like MoveEditor's own DraftFieldChanged.
	DraftFieldChanged: RBXScriptSignal,
	SaveRequested: RBXScriptSignal,
}

return KitEditorTypes
