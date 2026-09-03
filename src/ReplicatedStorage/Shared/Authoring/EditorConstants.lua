--!strict
--[[
	EditorConstants.lua

	Owns: the tuning surface for this game's two in-game, admin-gated CONTENT EDITORS -- the Move
	Creation System (Constants.MoveEditor) and the shared Race Traits / Bloodline editor
	(Constants.KitEditor). Schema versions, per-field authoring bounds, draft debounce, DataStore
	retry/backoff, per-remote call budgets, and each editor's own remote names.

	These two are one module because KitEditor's own comment already said what the relationship is:
	it "mirrors Constants.MoveEditor field-for-field" -- same debounce reasoning between a
	PropertyEditor field edit and the UpdateDraft round trip it triggers, same retry shape. Two
	tables that are deliberately kept parallel are cheaper to keep parallel when a reviewer can see
	both at once. Lifted out of Constants.lua; Constants.MoveEditor and Constants.KitEditor each
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
	(Shared/Combat/MoveTypes.lua, Shared/Kit/KitTypes.lua), or the validation that enforces them
	(MoveRegistryManager.Validate, KitValidation.lua).
]]

local EditorConstants = {}

-- Move Creation System (Server/Combat/MoveRegistryManager.lua, Server/Systems/MoveEditorSystem.lua,
-- Client/UI/Screens/DevTools/MoveEditor/) -- an in-game, admin-gated editor for authoring new combat moves
-- as data (MoveTypes.MoveDefinition) rather than hand-written Constants.lua tables + bespoke
-- server/client code per move. Same "own DataStore config, own tuning surface" split
-- Constants.BugReport/Constants.PlayerData already establish -- CustomMoveDataStoreName itself
-- lives in Server/Config/StorageConfig.lua, never here (see that file's own header).
EditorConstants.MoveEditor = {
	-- v2 (2026-08-12) added, all additively: the twelve-shape Dimensions bag (Shared/HitboxShapes.
	-- lua) alongside the original Size/Radius, Offset rotation, the multi-clip animation timeline
	-- (Shared/AnimationTimeline.lua), and the Object Stun block (Types.ObjectStunConfig). No
	-- migration pass exists or is needed -- MoveRegistryManager.Validate reconstructs every v2 field
	-- from a v1 record's own values (Dimensions from Size/Radius, a one-clip timeline from
	-- AnimationId, no Object Stun), so a v1 record loads and behaves exactly as it always did. The
	-- version is bumped anyway, per PlayerDataSystem's own convention, so a future BREAKING change
	-- has a real boundary to branch on.
	SchemaVersion = 2,

	-- Client-side debounce (MoveEditorClient.lua) between a PropertyEditor field edit and the
	-- UpdateDraft RemoteFunction call it triggers -- long enough that rapidly clicking a NumericField
	-- stepper doesn't fire one round trip per click, short enough that the live 3D preview and the
	-- in-memory registry both still feel instantaneous to the admin editing it.
	DraftDebounceSeconds = 0.15,

	-- Per-field authoring bounds for the Object Stun block (Types.ObjectStunConfig), and the
	-- starting values a freshly-enabled Object Stun gets. ONE table read by three consumers that
	-- must not disagree: MoveRegistryManager.Validate clamps against Limits, PropertyEditor's own
	-- ObjectStunEditor renders NumericField Min/Max from the same Limits, and both the editor and
	-- the validator build a brand-new config from Defaults -- so a value the UI lets an admin type
	-- can never be one the server silently rewrites.
	--
	-- The equivalent tables for the other two new sub-schemas deliberately live with their own
	-- modules instead (HitboxShapes.FIELD_SPECS, AnimationTimeline.Limits) because those modules own
	-- geometry/scheduling semantics that the bounds are part of. Object Stun has no such module on
	-- the shared side -- its runtime is server-only -- so its bounds live here with the rest of the
	-- editor's configuration.
	ObjectStun = {
		Limits = {
			MinSurfaceExtentStuds = { Min = 0, Max = 20 },
			ProbeDistanceStuds = { Min = 0.5, Max = 12 },
			RequiredClearanceStuds = { Min = 0, Max = 40 },
			MinTravelStuds = { Min = 0, Max = 60 },
			MinImpactSpeed = { Min = 0, Max = 200 },
			MaxImpactAngleDegrees = { Min = 5, Max = 90 },
			MaxTravelSeconds = { Min = 0.1, Max = 6 },
			StunSeconds = { Min = 0, Max = 8 },
			RagdollSeconds = { Min = 0, Max = 8 },
			BonusDamage = { Min = 0, Max = 200 },
			BonusPostureDamage = { Min = 0, Max = 200 },
			ReboundVelocity = { Min = 0, Max = 150 },
			PinSeconds = { Min = 0, Max = 6 },
			CameraShakeScale = { Min = 0, Max = 4 },
			CooldownSeconds = { Min = 0, Max = 30 },
			MaxTriggersPerMove = { Min = 1, Max = 10 },
			FollowUpDelaySeconds = { Min = 0, Max = 3 },
			FollowUpTeleportDistanceStuds = { Min = 2, Max = 20 },
			-- The follow-up's own timing/damage reuse the parent move's own clamp band rather than
			-- getting a second, subtly-different one -- see MoveRegistryManager's CLAMP_MIN/MAX_
			-- SECONDS and CLAMP_MIN/MAX_DAMAGE, which the follow-up validator calls directly.
			FollowUpMaxTargets = { Min = 1, Max = 20 },
		},

		-- What "Enable Object Stun" starts as: a wall-slam that requires a real launch (three studs
		-- of clearance behind the target at the moment of the hit, four studs actually travelled, a
		-- solid 35 studs/second on contact, within 55 degrees of head-on), pins them briefly, and
		-- deals a modest bonus. Deliberately conservative on the causation gates -- the first time
		-- an author enables this, it should fire when they slam someone into a wall and stay quiet
		-- otherwise, because a mechanic that triggers spuriously on the first try reads as broken.
		Defaults = {
			Surfaces = { Walls = true, Floors = false, Ceilings = false, Props = false },
			RequireAnchored = true,
			RequirePartTag = "",
			MinSurfaceExtentStuds = 3,
			ProbeDistanceStuds = 2.5,
			RequiredClearanceStuds = 3,
			MinTravelStuds = 4,
			MinImpactSpeed = 35,
			MaxImpactAngleDegrees = 55,
			MaxTravelSeconds = 1.5,

			StunSeconds = 1.2,
			RagdollSeconds = 0.8,
			BonusDamage = 8,
			BonusPostureDamage = 12,
			ReboundVelocity = 0,
			PinSeconds = 0.6,
			VictimAnimationId = "",
			AttackerAnimationId = "",
			SoundId = "",
			EffectColor = Color3.fromRGB(255, 180, 90),
			CameraShakeScale = 1,

			CooldownSeconds = 2,
			MaxTriggersPerMove = 1,
		},

		-- What "Enable Follow-Up" starts as: a fast, tight, close-range punish into the pinned
		-- target, thrown a quarter-second after impact. Small Box rather than the parent move's own
		-- shape for the reason Types.ObjectStunFollowUp's header gives -- a follow-up is a different
		-- attack, not a repeat of the launcher.
		FollowUpDefaults = {
			DelaySeconds = 0.25,
			AnimationId = "",
			WindupSeconds = 0.1,
			ActiveSeconds = 0.15,
			RecoverySeconds = 0.25,
			Damage = 12,
			PostureDamage = 10,
			MaxTargets = 1,
			Shape = "Box",
			OffsetX = 0,
			OffsetY = 0,
			OffsetZ = -3,
			TeleportAttacker = false,
			TeleportDistanceStuds = 5,
		},
	},

	-- Admin-only, same trust model as Constants.Debug.DevMenu -- every RemoteFunction below is
	-- gated by MoveEditorSystem's own checkMoveEditorPreconditions (AdminConfig.AuthorizedUserIds +
	-- a dedicated rate-limit bucket), mirroring DevMenuSystem.lua's own checkDevMenuPreconditions.
	RemoteNames = {
		ListMoves = "MoveEditor_ListMoves",
		GetMove = "MoveEditor_GetMove",
		UpdateDraft = "MoveEditor_UpdateDraft",
		SaveMove = "MoveEditor_SaveMove",
		DeleteMove = "MoveEditor_DeleteMove",
		TestFireMove = "MoveEditor_TestFireMove",
		SpawnPreviewDummy = "MoveEditor_SpawnPreviewDummy",
		-- "Default" moves (every hand-authored weapon Basic/Heavy/Finisher stage plus DashPunch/
		-- DashHit/AirSlam) -- Server/Combat/DefaultMoveRegistry.lua's live Constants-mutating sibling
		-- to ListMoves/UpdateDraft above, formerly DevMenu's "Hitbox Timing"/"Standalone Attacks"
		-- Tuning-tab tools. No DeleteMove/TestFireMove equivalent exists for a Default move -- see
		-- DefaultMoveRegistry.lua's own header for why (never deletable, no TestFireMove dispatch
		-- path). SaveDefaultMove DOES persist -- unlike a hand-copy-to-Constants.lua-only edit, an
		-- admin's live-tuned Default move value survives a server restart via a small
		-- DataStore-backed override record (MoveEditorSystem.lua's own header) keyed by MoveId, kept
		-- in the SAME DataStore as custom moves (StorageConfig.CustomMoveDataStoreName) under a
		-- "DefaultOverride_<MoveId>" key so it never collides with a "Move_<MoveId>" custom-move
		-- record.
		ListDefaultMoves = "MoveEditor_ListDefaultMoves",
		UpdateDefaultMoveDraft = "MoveEditor_UpdateDefaultMoveDraft",
		SaveDefaultMove = "MoveEditor_SaveDefaultMove",
		ResetDefaultMove = "MoveEditor_ResetDefaultMove",
		-- Fire-and-forget (RemoteEvent, not RemoteFunction -- no response needed): tells the server
		-- the admin's own editor screen just opened/closed, so it can freeze/unfreeze their character
		-- via the existing AdminActionSystem.SetFrozen (the same mechanism/Humanoid Attribute an
		-- admin's own "Frozen" DevMenu toggle already uses) -- editing a move's numbers shouldn't
		-- leave the admin's own character walking around or swinging mid-edit.
		SetEditorOpen = "MoveEditor_SetEditorOpen",
		-- Puts the open move in one of the player's own hotbar slots, for live-fire testing.
		--
		-- It is an ART EQUIP, not a second kind of binding: an art IS a move carrying a
		-- MoveTypes.MoveArtBinding (see ArtTreeManager.lua's header -- an art's ArtId is its MoveId),
		-- so a slot has exactly one occupant and one owner, ArtSystem, whose equippedArts already
		-- persists. This remote exists only because ArtSystem.Equip refuses an art the player has not
		-- UNLOCKED, and an admin testing a form they authored ten seconds ago has not earned it --
		-- see ArtSystem.DevGrantAndEquip, which is the only unlock bypass in the codebase.
		EquipArtSlot = "MoveEditor_EquipArtSlot",
	},
}

-- Race Traits + Bloodline Abilities plan -- the shared admin editor for both Race Traits and
-- Bloodline stages (Server/Systems/KitEditorSystem.lua, Client/UI/Screens/DevTools/KitEditor/, not built yet).
-- Mirrors Constants.MoveEditor above field-for-field: same DataStore retry/backoff shape (Shared/
-- DataStoreRetry.lua), same debounce reasoning between a PropertyEditor field edit and the
-- UpdateDraft round trip it triggers.
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
		-- registry, the same "Save is explicit only" contract Constants.MoveEditor.RemoteNames.
		-- UpdateDraft already establishes for moves.
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
