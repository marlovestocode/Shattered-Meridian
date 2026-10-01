--!strict
--[[
	EditorConstants.lua

	Owns: the tuning surface for this game's two in-game, admin-gated CONTENT EDITORS -- the Move
	Editor (Constants.MoveEditor) and the shared Race Traits / Bloodline editor
	(Constants.KitEditor). Schema versions, per-field authoring bounds, draft debounce, DataStore
	retry/backoff, per-remote call budgets, and each editor's own remote names.

	These two are one module because they are the same kind of thing -- an editor's schema version,
	its draft debounce and its remote names -- and two tables kept deliberately parallel are cheaper
	to keep parallel when a reviewer can see both at once. Lifted out of Constants.lua; Constants.MoveEditor and Constants.KitEditor each
	re-export their own sub-table here, so no call site changed and neither name widened.

	NOT the place for a feature's RUNTIME config just because that feature also has an editor.
	Constants.Kit -- the ability system's own remote pair and rate limit -- went to
	Shared/Kit/KitConstants.lua instead, next to KitTypes/KitValidation, even though its Limits table
	is read by the KitEditor: two of its three keys are wire/runtime concerns, and a runtime remote
	name filed under "EditorConstants" is a name that lies. The rule this file follows is the one
	that sorted them: an editor's OWN tuning belongs here, the content it edits belongs to the
	domain that owns that content at runtime.

	Does not own: the DataStore NAMES either editor writes to (Server/Config/StorageConfig.lua, and
	deliberately never here -- see that file's own header), the schemas being authored
	(Shared/MoveTypes.lua, Shared/Kit/KitTypes.lua), or the validation that enforces them
	(MoveRegistryManager.Validate, KitValidation.lua).
]]

local EditorConstants = {}

-- The Move Editor (Server/Systems/MoveEditorSystem.lua, Server/Combat/MoveRegistryManager.lua,
-- Client/UI/Screens/DevTools/MoveEditor/) -- the admin-gated tool that authors combat moves as data
-- (MoveTypes.MoveDefinition). CustomMoveDataStoreName lives in Server/Config/StorageConfig.lua, never
-- here (see that file's own header).
EditorConstants.MoveEditor = {
	-- v3 (2026-09-29, the ground-up rebuild): the schema became HitboxEngine's own vocabulary -- seven
	-- shapes, Width/Height/Length/Radius/InnerRadius/AngleDegrees, an authored AttachmentPart and
	-- LocksMovement -- and every block with no runtime (Projectile, Movement, ObjectStun, Slam,
	-- ArcDegrees, the clip timeline, Knockback.RagdollSeconds) was deleted. v1/v2 records are upgraded
	-- on load by Server/Systems/Support/MoveRecordCodec.lua; nothing rewrites them until their next save.
	-- Still 3 after 2026-09-30's Projectile block (a real, flown move type this time): it is an optional
	-- block a v3 record either carries or does not, so it needed no version -- see MoveRecordCodec's header.
	SchemaVersion = 3,

	-- Between a field edit and the Preview round trip it triggers: long enough that dragging a stepper
	-- does not fire one invoke per click, short enough that the live registry (and a Test swing) never
	-- lags what the admin is looking at.
	DraftDebounceSeconds = 0.15,

	-- The editor's own per-admin call budget. Wider than Constants.NetworkBudget's general one on
	-- purpose: a debounced Preview while dragging a field runs at up to 1/DraftDebounceSeconds per second
	-- on its own, and a throttled Preview is an edit that silently never went live.
	MaxCallsPerSecond = 12,

	-- The frame rate the readout's frame data counts in. 60 is the fighting-game convention and what the
	-- server's Heartbeat runs at; it is a unit for the author, not a simulation rate.
	FrameRate = 60,

	-- Undo/redo (Shared/Authoring/DraftHistory.lua): steps kept per move, and the window inside which a
	-- burst of edits -- a stepper held down, a hitbox dragged in Place mode -- counts as one step. The
	-- window slides, so it bounds the gap between two edits, not the length of the burst.
	UndoDepth = 50,
	UndoCoalesceSeconds = 0.4,

	-- Bulk edit (MoveEditor_BulkScale): the multiplier range one call may apply per field (the UI's
	-- -75%..+300%), and how many moves one call may touch -- a bound on the per-call work and DataStore
	-- writes, since the rate limit counts the call once however many moves it scales.
	BulkScaleLimits = { Min = 0.25, Max = 4 },
	BulkScaleMaxMoves = 64,

	-- Saved versions kept per move ("MoveHistory_<id>" in the move DataStore), oldest dropped first.
	HistoryDepth = 10,

	-- Studio-only "Write to source": where scripts/move-writer.py listens. Localhost only -- the helper
	-- binds 127.0.0.1, and Phase 0a (2026-09-29) confirmed a Studio play-mode server can reach it.
	SourceWriter = {
		Url = "http://localhost:34880",
	},

	-- How long an irreversible action (Delete, Revert, closing with unsaved work) stays armed after its
	-- first press. The second press inside the window commits; anything else disarms.
	ConfirmWindowSeconds = 3,

	-- Every authorable bound, in ONE table read by both sides: MoveRegistryManager.Validate clamps
	-- against it and the editor renders each field's Min/Max from it, so a value the UI lets an admin
	-- type can never be one the server silently rewrites. Grab and Art bounds are NOT repeated here --
	-- GrabConstants.Limits and ArtConstants.Limits own them, next to the runtimes they bound.
	Limits = {
		-- Windup/Active/Recovery. The ceiling is well inside HitboxEngineConstants.MaxSwingSeconds so no
		-- authorable swing can be expired by the engine as a runaway.
		PhaseSeconds = { Min = 0.01, Max = 3 },
		CooldownSeconds = { Min = 0, Max = 60 },
		-- Offset from the anchor, per axis. Forward is -Z.
		OffsetStuds = { Min = -15, Max = 15 },
		RotationDegrees = { Min = -180, Max = 180 },
		-- Tighter than HitboxTypes' own "nothing absurd" engine clamp on purpose: the engine guards
		-- against math.huge, this guards against an author typing a hitbox the size of a district.
		Dimensions = {
			Width = { Min = 0.1, Max = 40 },
			Height = { Min = 0.1, Max = 40 },
			Length = { Min = 0.1, Max = 60 },
			Radius = { Min = 0.1, Max = 30 },
			InnerRadius = { Min = 0, Max = 30 },
			AngleDegrees = { Min = 1, Max = 360 },
		},
		Damage = { Min = 0, Max = 200 },
		PostureDamage = { Min = 0, Max = 200 },
		MaxTargets = { Min = 1, Max = 20 },
		KnockbackVelocity = { Min = 0, Max = 150 },
		-- Free text that reaches a DataStore record -- bounded so one paste cannot blow the per-key budget.
		DisplayNameLength = 48,
		CategoryLength = 32,
		DescriptionLength = 400,
		AnimationIdLength = 120,
	},

	-- What "New move" starts as: a plain one-target box a few studs in front of the root, on a readable
	-- tempo. Every value is inside Limits; MoveEditorSystem.spec pins that.
	NewMoveTemplate = {
		DisplayName = "New Move",
		Shape = "Box",
		Dimensions = { Width = 4, Height = 5, Length = 5, Radius = 2, InnerRadius = 0, AngleDegrees = 90 },
		OffsetZ = -3,
		WindupSeconds = 0.3,
		ActiveSeconds = 0.15,
		RecoverySeconds = 0.35,
		Cooldown = 0.8,
		Damage = 10,
		PostureDamage = 8,
		MaxTargets = 1,
	},

	-- Every remote is admin-gated in MoveEditorSystem through Server/Network/AdminGate (whitelist + this
	-- System's own rate-limit bucket).
	RemoteNames = {
		-- The whole catalogue in one invoke: every custom move and every Default move as MoveEditorTypes
		-- entries. Doubles as the authorization check -- a rejection means "not admin".
		Open = "MoveEditor_Open",
		-- Validates a draft and makes it LIVE (the registry for a custom move, the override layer for a
		-- Default one) with no DataStore write. A draft with no MoveId creates the move.
		Preview = "MoveEditor_Preview",
		-- Validates a draft, makes it live and persists it.
		Save = "MoveEditor_Save",
		-- Throws away unsaved work: the live move goes back to exactly what is persisted (a custom move
		-- that was never saved stops existing).
		Revert = "MoveEditor_Revert",
		-- Custom moves only: removes it from the registry and the DataStore.
		Delete = "MoveEditor_Delete",
		-- Default moves only: drops the override, live and persisted, so the move is its weapon-built
		-- self again.
		ResetDefault = "MoveEditor_ResetDefault",
		-- Throws the open move from the admin's own character through AttackRequestSystem.ThrowMove.
		TestFire = "MoveEditor_TestFire",
		-- Puts an art in one of the admin's own hotbar slots -- an ART EQUIP through
		-- ArtSystem.DevGrantAndEquip (the one unlock bypass), since a slot has exactly one owner.
		EquipArtSlot = "MoveEditor_EquipArtSlot",
		-- Fire-and-forget: the editor opened or closed, so the server freezes/unfreezes the admin through
		-- AdminActionSystem.SetFrozen.
		SetEditorOpen = "MoveEditor_SetEditorOpen",
		-- Multiplies chosen timing/impact fields of every move in one browser group (optionally one stage
		-- of a weapon's string), live or live-and-saved. Scales CURRENT live values, so it is cumulative.
		BulkScale = "MoveEditor_BulkScale",
		-- A move's saved versions, newest first, each with a server-written summary of what it changed.
		History = "MoveEditor_History",
		-- Makes one saved version LIVE again (a Preview, not a Save) so the admin can review it and Save.
		RestoreVersion = "MoveEditor_RestoreVersion",
		-- STUDIO ONLY (created in every build; outside Studio each refuses NotStudio). Write the live move
		-- into src/ as a ModuleScript through scripts/move-writer.py and drop its DataStore copy; remove that
		-- file again; or just return the text it would write.
		WriteToSource = "MoveEditor_WriteToSource",
		RemoveFromSource = "MoveEditor_RemoveFromSource",
		ExportSource = "MoveEditor_ExportSource",
	},
}

-- Race Traits + Bloodline Abilities plan -- the shared admin editor for both Race Traits and
-- Bloodline stages (Server/Systems/KitEditorSystem.lua, Client/UI/Screens/DevTools/KitEditor/, not built yet).
-- Shares Constants.MoveEditor's shape: same DataStore retry/backoff (Shared/DataStoreRetry.lua), same
-- debounce reasoning between a PropertyEditor field edit and the UpdateDraft round trip it triggers.
EditorConstants.KitEditor = {
	SchemaVersion = 1,
	DraftDebounceSeconds = 0.15,

	-- Admin-only, same trust model as Constants.MoveEditor above -- every RemoteFunction below is
	-- gated by KitEditorSystem's own checkKitEditorPreconditions (AdminGate.Check + a dedicated
	-- rate-limit bucket). One roster of five actions PER content type (Race Traits, Bloodlines) --
	-- List/Get/UpdateDraft/Save/Delete -- rather than two separately-named sets, since the two share
	-- one screen and the naming already disambiguates which content type each acts on.
	RemoteNames = {
		ListRaceTraits = "KitEditor_ListRaceTraits",
		GetRaceTrait = "KitEditor_GetRaceTrait",
		-- In-memory only, no DataStore write -- takes effect immediately in RaceManager's live
		-- registry, the same "Save is explicit only" contract Constants.MoveEditor.RemoteNames.Preview
		-- keeps for moves.
		UpdateRaceTraitDraft = "KitEditor_UpdateRaceTraitDraft",
		SaveRaceTrait = "KitEditor_SaveRaceTrait",
		DeleteRaceTrait = "KitEditor_DeleteRaceTrait",

		ListBloodlines = "KitEditor_ListBloodlines",
		GetBloodline = "KitEditor_GetBloodline",
		UpdateBloodlineDraft = "KitEditor_UpdateBloodlineDraft",
		SaveBloodline = "KitEditor_SaveBloodline",
		DeleteBloodline = "KitEditor_DeleteBloodline",
	},
}

return EditorConstants
