--!strict
--[[
	MoveEditorSystem.lua

	Owns: authorization + rate-limiting, every Constants.MoveEditor.RemoteNames RemoteFunction, and
	DataStore persistence for the Move Creation System -- the "System" half of the Manager/System
	pairing whose "Manager" half is Server/Combat/MoveRegistryManager.lua (the live in-memory
	registry itself). checkMoveEditorPreconditions is a thin wrapper over
	Server/Network/AdminGate.Check (auth + rate limit), with its own dedicated `rateLimiter` bucket
	passed in -- see AdminGate.lua's own header for why it never constructs or defaults one itself.
	wrapHandler is Shared/RemoteHandler.Scoped, bound once to this module's logger and error result.
	It used to be a local copy on the grounds that "generalizing that one too was ruled out during the
	Network-module design pass" -- the difference it claimed to have (a fixed error result) turned out
	to be a parameter WrapInvoke already took.

	Persistence shape: one DataStore key per move ("Move_<MoveId>") plus a small fixed-key index
	record ("MoveIndex" -> { MoveIds: {string} }, maintained via UpdateAsync for atomicity) since
	DataStore has no native "list all keys" and the authored-move count is small (tens, not
	thousands admins would ever hand-author). Every persisted record is schema-versioned
	(Constants.MoveEditor.SchemaVersion) mirroring PlayerDataSystem's own {SchemaVersion, ...}
	wrapper convention, even though no migration exists yet -- a real v2 schema change (e.g. v2's
	multi-hitbox array) has a documented, already-proven upgrade path to follow.

	"Save is explicit only" -- UpdateDraft mutates MoveRegistryManager's live in-memory table (so an
	edit takes effect immediately for TestFireMove, exactly HitboxTuning.lua's own live-mutation
	precedent) with NO DataStore write; only SaveMove persists. There is no autosave-on-keystroke --
	an unreviewed mid-edit value reaching disk, where another admin could load it, is worse than an
	admin losing an unsaved draft on crash (the tradeoff PlayerDataSystem's own autosave accepts for
	a fundamentally different case: protecting a single player's own progression, not a shared,
	admin-managed content registry).

	MoveId/Author/CreatedAt/UpdatedAt are ALWAYS stamped here from trusted server context
	(stampTrustedMetadata) before a client-submitted candidate ever reaches
	MoveRegistryManager.Validate -- a client can propose every other field, but never its own
	identity or authorship, the same "server owns truth" boundary DevMenuSystem enforces for every
	other admin action.

	Also owns the four ListDefaultMoves/UpdateDefaultMoveDraft/SaveDefaultMove/ResetDefaultMove
	RemoteFunctions -- the "Default" (formerly DevMenu Tuning-tab) half of the Move Editor, backed by
	Server/Combat/DefaultMoveRegistry.lua instead of MoveRegistryManager. Same authorization/
	rate-limit gate (checkMoveEditorPreconditions) and pcall-safety (wrapHandler) as every remote
	below. UpdateDraft/UpdateDefaultMoveDraft both stay in-memory-only (an edit takes effect
	immediately for TestFireMove/live combat with no DataStore round trip); UpdateDefaultMoveDraft
	ALSO skips stampTrustedMetadata entirely -- a Default move is never created and its identity is
	its fixed synthetic MoveId, never something a client request could legitimately propose changing
	-- but IS savable: SaveDefaultMove persists the move's CURRENT live values (read straight off
	DefaultMoveRegistry.Get, not a client-submitted candidate) to a small DataStore override record
	("DefaultOverride_<MoveId>", same mainStore as custom moves' "Move_<MoveId>" records, no separate
	index needed since a Default move's MoveId set is fixed/enumerable via DefaultMoveRegistry.List
	rather than open-ended like a custom move's), which loadDefaultMoveOverrides re-applies on every
	boot after DefaultMoveRegistry has captured its own pristine file defaults (see that module's own
	header for why the ordering matters for Reset). ResetDefaultMove both live-reverts AND clears
	that move's override record, so a Reset actually undoes a previous Save, not just the current
	session's live edits. A Default move is still never created/deleted -- see DefaultMoveRegistry.
	lua's own header for why (its MoveId set is fixed by Constants.Combat.Weapons/DashPunch/DashHit/
	AirSlam, not admin-authored).

	Does not own: the live in-memory registry itself, the MoveDefinition schema, or the Validate
	allow-list (MoveRegistryManager.lua), the admin whitelist (Server/Config/AdminConfig.lua), or
	Default-move field mutation/reset itself (DefaultMoveRegistry.lua).

	No longer owns (combat system removed): TestFireMove/SpawnPreviewDummy, the two admin actions that
	used to throw a move at (or spawn) a training dummy via CombatSystem.ThrowCustomMove/
	SpawnTrainingDummy. Move creation/editing/saving/validation/listing -- this module's actual core
	responsibility, per the header above -- is untouched by that removal.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local DataStoreService = game:GetService("DataStoreService")

local NetworkBridge = require(ReplicatedStorage.Shared.NetworkBridge)
local Constants = require(ReplicatedStorage.Shared.Constants)
local Types = require(ReplicatedStorage.Shared.Types)
local MoveTypes = require(ReplicatedStorage.Shared.MoveTypes)
local Logger = require(ReplicatedStorage.Shared.Logger)
local RateLimiter = require(ReplicatedStorage.Shared.RateLimiter)
local DataStoreRetry = require(ReplicatedStorage.Shared.DataStoreRetry)
local PlayerLifecycle = require(ReplicatedStorage.Shared.PlayerLifecycle)
local StorageConfig = require(script.Parent.Parent.Config.StorageConfig)
local AdminGate = require(script.Parent.Parent.Network.AdminGate)

local MoveRegistryManager = require(script.Parent.Parent.Combat.MoveRegistryManager)
local DefaultMoveRegistry = require(script.Parent.Parent.Combat.DefaultMoveRegistry)
local AdminActionSystem = require(script.Parent.AdminActionSystem)
local ArtSystem = require(script.Parent.ArtSystem)
-- For one post-load call: an art is a move, so the moves this System loads ARE the art roster,
-- and this is the only point in the boot where that roster is known to be complete.
local ArtTreeManager = require(script.Parent.Parent.Managers.ArtTreeManager)
local RemoteHandler = require(ReplicatedStorage.Shared.RemoteHandler)

local MoveEditorSystem = {}

local logger = Logger.scope("MoveEditorSystem")

local Config = Constants.MoveEditor

-- Own bucket, separate from DevMenuSystem's/CombatSystem's -- see DevMenuSystem.lua's identical
-- rateLimiter comment for why every dev-tool domain gets its own budget.
local rateLimiter = RateLimiter.New(Constants.NetworkBudget.MaxRemoteCallsPerSecondPerPlayer)

local INDEX_KEY = "MoveIndex"
local function recordKey(moveId: string): string
	return "Move_" .. moveId
end

-- No index needed for Default overrides (unlike recordKey/INDEX_KEY above) -- a Default move's
-- MoveId set is fixed and fully enumerable via DefaultMoveRegistry.List() at boot, so
-- loadDefaultMoveOverrides just probes one key per known move instead of maintaining a second
-- MoveIds-style index record.
local function defaultOverrideKey(moveId: string): string
	return "DefaultOverride_" .. moveId
end

-- Shared auth + rate-limit precondition -- Server/Network/AdminGate.lua's own Check, the module
-- this used to hand-duplicate (see that module's header).
local function checkMoveEditorPreconditions(player: Player, actionName: string): (boolean, string?)
	return AdminGate.Check(player, actionName, rateLimiter)
end

-- The pcall boundary every RemoteFunction handler below goes through, bound once to this module's own
-- logger and error result -- see Shared/RemoteHandler.Scoped. This used to be a ten-line local that
-- WAS that binding written out longhand, kept on the grounds that "generalizing that one too was
-- ruled out"; the only difference it actually had from WrapInvoke was baking in the two things
-- WrapInvoke already takes as parameters. Every call site below is unchanged.
local wrapHandler = RemoteHandler.Scoped(logger, { Success = false, Reason = "InternalError" })

-- Obtained lazily inside Init(), never at module load time -- keeps require()-ing this module
-- side-effect-free, same reasoning as BugReportSystem.lua's own mainStore.
local mainStore: DataStore? = nil

-- The retry/backoff wrapper every DataStore call below goes through, bound once to this module's own
-- logger and to the ONE policy (Constants.Storage.RetryPolicy). Five Systems each held this same
-- three-line local, differing only in which Constants table they read the same two numbers out of;
-- see Shared/DataStoreRetry.Scoped's own header. Call sites are unchanged -- still
-- withRetry(operationName, attempt).
local withRetry = DataStoreRetry.Scoped(logger, Constants.Storage.RetryPolicy)

-- DataStore/JSON carries no Roblox value types, so the three that appear on a live MoveDefinition
-- are decomposed here and rebuilt in candidateFromStoredRecord below:
--   * Vector3 Size          -> a plain {X,Y,Z} sub-table (nil for every non-Box shape).
--   * CFrame Offset         -> flat OffsetX/Y/Z plus OffsetRotationX/Y/Z DEGREES. Never the CFrame
--                              itself: MoveRegistryManager.Validate is the only thing allowed to
--                              decide what an author's six numbers mean (see buildOffset), and
--                              storing the composed matrix would let a hand-edited record smuggle
--                              in a rotation the degrees don't describe.
--   * Color3 EffectColor    -> flat R/G/B 0-255 integers.
-- Dimensions and each Animations clip are already flat tables of numbers/strings/booleans, so they
-- round-trip as-is; they're still written field-by-field rather than by table.clone so a future
-- field added to either type has to be considered here rather than silently riding along.
local function encodeDimensions(dimensions: MoveTypes.MoveDimensions): { [string]: any }
	return {
		Width = dimensions.Width,
		Height = dimensions.Height,
		Depth = dimensions.Depth,
		Length = dimensions.Length,
		Thickness = dimensions.Thickness,
		Radius = dimensions.Radius,
		InnerRadius = dimensions.InnerRadius,
		AngleDegrees = dimensions.AngleDegrees,
	}
end

local function encodeAnimations(clips: { MoveTypes.MoveAnimationClip }): { { [string]: any } }
	local encoded: { { [string]: any } } = {}
	for _, clip in ipairs(clips) do
		table.insert(encoded, {
			ClipId = clip.ClipId,
			Name = clip.Name,
			AnimationId = clip.AnimationId,
			Enabled = clip.Enabled,
			Order = clip.Order,
			StartMode = clip.StartMode,
			StartTime = clip.StartTime,
			StartPhase = clip.StartPhase,
			StartDelay = clip.StartDelay,
			StopMode = clip.StopMode,
			DurationSeconds = clip.DurationSeconds,
			Speed = clip.Speed,
			Weight = clip.Weight,
			FadeInSeconds = clip.FadeInSeconds,
			FadeOutSeconds = clip.FadeOutSeconds,
			Looped = clip.Looped,
			Priority = clip.Priority,
			Blend = clip.Blend,
			OnInterrupt = clip.OnInterrupt,
		})
	end
	return encoded
end

local function encodeKnockback(knockback: MoveTypes.MoveKnockback): { [string]: any }
	return {
		UpVelocity = knockback.UpVelocity,
		HorizontalVelocity = knockback.HorizontalVelocity,
		RagdollSeconds = knockback.RagdollSeconds,
		StartsAirCombo = knockback.StartsAirCombo == true,
	}
end

local function encodeObjectStun(objectStun: Types.ObjectStunConfig): { [string]: any }
	local encoded: { [string]: any } = {
		Enabled = objectStun.Enabled,
		Surfaces = {
			Walls = objectStun.Surfaces.Walls,
			Floors = objectStun.Surfaces.Floors,
			Ceilings = objectStun.Surfaces.Ceilings,
			Props = objectStun.Surfaces.Props,
		},
		RequireAnchored = objectStun.RequireAnchored,
		RequirePartTag = objectStun.RequirePartTag,
		MinSurfaceExtentStuds = objectStun.MinSurfaceExtentStuds,
		ProbeDistanceStuds = objectStun.ProbeDistanceStuds,
		RequiredClearanceStuds = objectStun.RequiredClearanceStuds,
		MinTravelStuds = objectStun.MinTravelStuds,
		MinImpactSpeed = objectStun.MinImpactSpeed,
		MaxImpactAngleDegrees = objectStun.MaxImpactAngleDegrees,
		MaxTravelSeconds = objectStun.MaxTravelSeconds,
		StunSeconds = objectStun.StunSeconds,
		RagdollSeconds = objectStun.RagdollSeconds,
		BonusDamage = objectStun.BonusDamage,
		BonusPostureDamage = objectStun.BonusPostureDamage,
		ReboundVelocity = objectStun.ReboundVelocity,
		PinSeconds = objectStun.PinSeconds,
		VictimAnimationId = objectStun.VictimAnimationId,
		AttackerAnimationId = objectStun.AttackerAnimationId,
		SoundId = objectStun.SoundId,
		EffectColorR = math.floor(objectStun.EffectColor.R * 255 + 0.5),
		EffectColorG = math.floor(objectStun.EffectColor.G * 255 + 0.5),
		EffectColorB = math.floor(objectStun.EffectColor.B * 255 + 0.5),
		CameraShakeScale = objectStun.CameraShakeScale,
		CooldownSeconds = objectStun.CooldownSeconds,
		MaxTriggersPerMove = objectStun.MaxTriggersPerMove,
	}

	local followUp = objectStun.FollowUp
	if followUp then
		local encodedFollowUp: { [string]: any } = {
			Enabled = followUp.Enabled,
			DelaySeconds = followUp.DelaySeconds,
			AnimationId = followUp.AnimationId,
			WindupSeconds = followUp.WindupSeconds,
			ActiveSeconds = followUp.ActiveSeconds,
			RecoverySeconds = followUp.RecoverySeconds,
			Damage = followUp.Damage,
			PostureDamage = followUp.PostureDamage,
			MaxTargets = followUp.MaxTargets,
			Shape = followUp.Shape,
			Dimensions = encodeDimensions(followUp.Dimensions),
			OffsetX = followUp.Offset.X,
			OffsetY = followUp.Offset.Y,
			OffsetZ = followUp.Offset.Z,
			OffsetRotationX = followUp.OffsetRotation.X,
			OffsetRotationY = followUp.OffsetRotation.Y,
			OffsetRotationZ = followUp.OffsetRotation.Z,
			TeleportAttacker = followUp.TeleportAttacker,
			TeleportDistanceStuds = followUp.TeleportDistanceStuds,
		}
		if followUp.Knockback then
			encodedFollowUp.Knockback = encodeKnockback(followUp.Knockback)
		end
		encoded.FollowUp = encodedFollowUp
	end

	return encoded
end

local function encodeMoveRecord(move: MoveTypes.MoveDefinition): { [string]: any }
	local encoded: { [string]: any } = {
		SchemaVersion = Config.SchemaVersion,
		MoveId = move.MoveId,
		DisplayName = move.DisplayName,
		Description = move.Description,
		Category = move.Category,
		Author = move.Author,
		CreatedAt = move.CreatedAt,
		UpdatedAt = move.UpdatedAt,
		Shape = move.Shape,
		Dimensions = encodeDimensions(move.Dimensions),
		Radius = move.Radius,
		OffsetX = move.Offset.X,
		OffsetY = move.Offset.Y,
		OffsetZ = move.Offset.Z,
		OffsetRotationX = move.OffsetRotation.X,
		OffsetRotationY = move.OffsetRotation.Y,
		OffsetRotationZ = move.OffsetRotation.Z,
		WindupSeconds = move.WindupSeconds,
		ActiveSeconds = move.ActiveSeconds,
		RecoverySeconds = move.RecoverySeconds,
		Cooldown = move.Cooldown,
		Damage = move.Damage,
		PostureDamage = move.PostureDamage,
		ArcDegrees = move.ArcDegrees,
		MaxTargets = move.MaxTargets,
		AnimationId = move.AnimationId,
		Animations = encodeAnimations(move.Animations),
	}
	if move.Size then
		encoded.Size = { X = move.Size.X, Y = move.Size.Y, Z = move.Size.Z }
	end
	if move.Movement then
		encoded.Movement = {
			LungeDistanceStuds = move.Movement.LungeDistanceStuds,
			LungeDurationSeconds = move.Movement.LungeDurationSeconds,
		}
	end
	if move.Knockback then
		encoded.Knockback = encodeKnockback(move.Knockback)
	end
	if move.Projectile then
		-- Already a flat table of numbers -- no Vector3/CFrame-style conversion needed, unlike Size.
		encoded.Projectile = { Speed = move.Projectile.Speed, MaxRange = move.Projectile.MaxRange }
	end
	if move.Grab then
		-- AttachOffset deliberately excluded -- validateGrab (MoveRegistryManager.lua) never reads it
		-- from a candidate; it always re-derives from GrabConstants.Defaults.AttachOffset, the same
		-- "author never edits this field" contract MoveGrabConfig's own header documents. Every other
		-- field is already a flat number, no Vector3/CFrame-style conversion needed.
		encoded.Grab = {
			HoldSeconds = move.Grab.HoldSeconds,
			ThrowUpVelocity = move.Grab.ThrowUpVelocity,
			ThrowHorizontalVelocity = move.Grab.ThrowHorizontalVelocity,
			ThrowImpactDamage = move.Grab.ThrowImpactDamage,
			ThrowSelfDamage = move.Grab.ThrowSelfDamage,
		}
	end
	if move.ObjectStun then
		encoded.ObjectStun = encodeObjectStun(move.ObjectStun)
	end
	if move.Art then
		-- Every field is already a flat string/number -- no Vector3/CFrame/Color3-style conversion
		-- needed, unlike Size/Offset/ObjectStun's EffectColor above.
		encoded.Art = {
			TreeId = move.Art.TreeId,
			Node = move.Art.Node,
			QiCost = move.Art.QiCost,
			RequiredTier = move.Art.RequiredTier,
			Prerequisite = move.Art.Prerequisite,
		}
	end
	return encoded
end

-- Rebuilds the Roblox value types encodeMoveRecord decomposed, then hands the result to
-- MoveRegistryManager.Validate -- the SAME strict allow-list gate a client-submitted candidate
-- passes through, so a DataStore read is trusted no more than network input (PlayerDataSystem.
-- DecodeProfile's own reasoning). Returns nil for anything not even table-shaped; Validate itself
-- handles every other structural failure, including a record from the v1 schema (no Dimensions, no
-- Animations, no ObjectStun), which it reconstructs from the v1 fields this decoder still passes
-- through untouched -- see MoveRegistryManager's own dimensionsFromCandidate. Grab/Art need no
-- explicit handling here (unlike Size/ObjectStun above): every one of their fields is already a
-- flat string/number, so the table.clone below already carries them through correctly -- validateGrab/
-- validateArt read candidate.Grab/candidate.Art directly with no Roblox-type reconstruction needed.
local function candidateFromStoredRecord(raw: unknown): { [string]: unknown }?
	if typeof(raw) ~= "table" then
		return nil
	end
	local record = raw :: { [string]: any }
	local candidate: { [string]: unknown } = table.clone(record)
	if typeof(record.Size) == "table" then
		candidate.Size = Vector3.new(record.Size.X, record.Size.Y, record.Size.Z)
	end
	if typeof(record.ObjectStun) == "table" then
		local objectStun: { [string]: any } = table.clone(record.ObjectStun)
		if
			typeof(objectStun.EffectColorR) == "number"
			and typeof(objectStun.EffectColorG) == "number"
			and typeof(objectStun.EffectColorB) == "number"
		then
			objectStun.EffectColor =
				Color3.fromRGB(objectStun.EffectColorR, objectStun.EffectColorG, objectStun.EffectColorB)
		end
		candidate.ObjectStun = objectStun
	end
	return candidate
end

-- A Default override record only ever needs the MUTABLE fields DefaultMoveRegistry.ApplyEdit
-- actually writes -- see that module's own header for the full list. Deliberately narrower than
-- encodeMoveRecord above: identity fields (MoveId/DisplayName/Category/Author/CreatedAt/UpdatedAt/
-- AnimationId) are never overridden for a Default move (BasicInfo/Animation render read-only in
-- PropertyEditor.lua for exactly this reason), so persisting them here would be dead weight.
local function encodeDefaultOverride(move: MoveTypes.MoveDefinition): { [string]: any }
	local encoded: { [string]: any } = {
		SchemaVersion = Config.SchemaVersion,
		Shape = move.Shape,
		Dimensions = encodeDimensions(move.Dimensions),
		Radius = move.Radius,
		OffsetX = move.Offset.X,
		OffsetY = move.Offset.Y,
		OffsetZ = move.Offset.Z,
		OffsetRotationX = move.OffsetRotation.X,
		OffsetRotationY = move.OffsetRotation.Y,
		OffsetRotationZ = move.OffsetRotation.Z,
		WindupSeconds = move.WindupSeconds,
		ActiveSeconds = move.ActiveSeconds,
		RecoverySeconds = move.RecoverySeconds,
		Cooldown = move.Cooldown,
		Damage = move.Damage,
		PostureDamage = move.PostureDamage,
		ArcDegrees = move.ArcDegrees,
		MaxTargets = move.MaxTargets,
	}
	if move.Size then
		encoded.Size = { X = move.Size.X, Y = move.Size.Y, Z = move.Size.Z }
	end
	return encoded
end

-- Overlays a persisted Default override record onto `current` (DefaultMoveRegistry.Get's own
-- projection, already carrying the correct MoveId/DisplayName/Category/Author/CreatedAt/UpdatedAt/
-- AnimationId -- see encodeDefaultOverride above for why those are never part of `raw`) to build the
-- full wire-shaped candidate DefaultMoveRegistry.ApplyEdit (and, underneath it,
-- MoveRegistryManager.Validate) expects. Returns nil for anything not even table-shaped; Validate
-- itself handles every other structural failure the same "DataStore read trusted no more than
-- network input" way candidateFromStoredRecord above does for a custom move.
local function candidateFromStoredDefaultOverride(
	current: MoveTypes.MoveDefinition,
	raw: unknown
): { [string]: unknown }?
	if typeof(raw) ~= "table" then
		return nil
	end
	local record = raw :: { [string]: any }

	local candidate: { [string]: unknown } = table.clone(current :: any)
	candidate.Offset = nil
	candidate.OffsetX = current.Offset.X
	candidate.OffsetY = current.Offset.Y
	candidate.OffsetZ = current.Offset.Z
	-- Same decompose-then-overlay treatment Offset already gets: the live value supplies the
	-- baseline so an override recorded before rotation existed still produces a coherent candidate,
	-- and the record overwrites only what it actually carries.
	candidate.OffsetRotation = nil
	candidate.OffsetRotationX = current.OffsetRotation.X
	candidate.OffsetRotationY = current.OffsetRotation.Y
	candidate.OffsetRotationZ = current.OffsetRotation.Z

	if record.Shape ~= nil then
		candidate.Shape = record.Shape
	end
	if typeof(record.Dimensions) == "table" then
		candidate.Dimensions = record.Dimensions
	end
	if typeof(record.Size) == "table" then
		candidate.Size = Vector3.new(record.Size.X, record.Size.Y, record.Size.Z)
	end
	if record.Radius ~= nil then
		candidate.Radius = record.Radius
	end
	if record.OffsetX ~= nil then
		candidate.OffsetX = record.OffsetX
	end
	if record.OffsetY ~= nil then
		candidate.OffsetY = record.OffsetY
	end
	if record.OffsetZ ~= nil then
		candidate.OffsetZ = record.OffsetZ
	end
	if record.OffsetRotationX ~= nil then
		candidate.OffsetRotationX = record.OffsetRotationX
	end
	if record.OffsetRotationY ~= nil then
		candidate.OffsetRotationY = record.OffsetRotationY
	end
	if record.OffsetRotationZ ~= nil then
		candidate.OffsetRotationZ = record.OffsetRotationZ
	end
	if record.WindupSeconds ~= nil then
		candidate.WindupSeconds = record.WindupSeconds
	end
	if record.ActiveSeconds ~= nil then
		candidate.ActiveSeconds = record.ActiveSeconds
	end
	if record.RecoverySeconds ~= nil then
		candidate.RecoverySeconds = record.RecoverySeconds
	end
	if record.Cooldown ~= nil then
		candidate.Cooldown = record.Cooldown
	end
	if record.Damage ~= nil then
		candidate.Damage = record.Damage
	end
	if record.PostureDamage ~= nil then
		candidate.PostureDamage = record.PostureDamage
	end
	if record.ArcDegrees ~= nil then
		candidate.ArcDegrees = record.ArcDegrees
	end
	if record.MaxTargets ~= nil then
		candidate.MaxTargets = record.MaxTargets
	end

	return candidate
end

-- Stamps MoveId/Author/CreatedAt (existing values for an already-known move, freshly-generated/
-- trusted-server-context values for a brand-new one) and always-fresh UpdatedAt onto a client-
-- submitted candidate -- a client may propose every OTHER field, but never its own identity or
-- authorship. This is what lets UpdateDraft/SaveMove double as "create," matching the plan's "+ New
-- Move" flow: a client sends a candidate with no MoveId (or an empty one) and gets a real,
-- server-assigned MoveId back in the response to adopt into its own local draft state.
local function stampTrustedMetadata(player: Player, raw: { [string]: unknown }): { [string]: unknown }
	local stamped = table.clone(raw)
	local rawMoveId = raw.MoveId
	local existing = if typeof(rawMoveId) == "string" and rawMoveId ~= ""
		then MoveRegistryManager.Get(rawMoveId)
		else nil
	if existing then
		stamped.MoveId = existing.MoveId
		stamped.Author = existing.Author
		stamped.CreatedAt = existing.CreatedAt
	else
		local displayName = if typeof(raw.DisplayName) == "string" then raw.DisplayName :: string else "Move"
		stamped.MoveId = MoveRegistryManager.GenerateMoveId(displayName)
		stamped.Author = player.Name
		stamped.CreatedAt = os.time()
	end
	stamped.UpdatedAt = os.time()
	return stamped
end

-- Atomic (UpdateAsync, not a separate Get-then-Set) so two admins saving/deleting different moves
-- at nearly the same moment can never clobber each other's index entry.
local function addToIndex(moveId: string): boolean
	if not mainStore then
		return false
	end
	local ok = withRetry("MoveEditor addToIndex UpdateAsync", function()
		(mainStore :: DataStore):UpdateAsync(INDEX_KEY, function(old: unknown)
			local moveIds: { string } = {}
			if typeof(old) == "table" and typeof((old :: any).MoveIds) == "table" then
				for _, existingId in ipairs((old :: any).MoveIds) do
					if typeof(existingId) == "string" then
						table.insert(moveIds, existingId)
					end
				end
			end
			local alreadyPresent = false
			for _, existingId in ipairs(moveIds) do
				if existingId == moveId then
					alreadyPresent = true
					break
				end
			end
			if not alreadyPresent then
				table.insert(moveIds, moveId)
			end
			return { MoveIds = moveIds }
		end)
	end)
	return ok
end

local function removeFromIndex(moveId: string): boolean
	if not mainStore then
		return false
	end
	local ok = withRetry("MoveEditor removeFromIndex UpdateAsync", function()
		(mainStore :: DataStore):UpdateAsync(INDEX_KEY, function(old: unknown)
			local moveIds: { string } = {}
			if typeof(old) == "table" and typeof((old :: any).MoveIds) == "table" then
				for _, existingId in ipairs((old :: any).MoveIds) do
					if typeof(existingId) == "string" and existingId ~= moveId then
						table.insert(moveIds, existingId)
					end
				end
			end
			return { MoveIds = moveIds }
		end)
	end)
	return ok
end

local function handleListMoves(player: Player): MoveTypes.MoveEditorListResult
	logger:debug("ListMoves received", { player = player.Name, userId = player.UserId })
	local allowed, reason = checkMoveEditorPreconditions(player, "ListMoves")
	if not allowed then
		return { Success = false, Reason = reason }
	end
	return { Success = true, Moves = MoveRegistryManager.List() }
end

local function handleGetMove(player: Player, rawMoveId: unknown): MoveTypes.MoveEditorMoveResult
	local allowed, reason = checkMoveEditorPreconditions(player, "GetMove")
	if not allowed then
		return { Success = false, Reason = reason }
	end
	if typeof(rawMoveId) ~= "string" then
		return { Success = false, Reason = "InvalidMoveId" }
	end
	local move = MoveRegistryManager.Get(rawMoveId)
	if not move then
		return { Success = false, Reason = "MoveNotFound" }
	end
	return { Success = true, Move = move }
end

-- In-memory only -- no DataStore write, see this file's header for why this is what makes an edit
-- take effect immediately in MoveRegistryManager's live registry.
local function handleUpdateDraft(player: Player, rawMove: unknown): MoveTypes.MoveEditorMoveResult
	logger:debug("UpdateDraft received", { player = player.Name, userId = player.UserId })
	local allowed, reason = checkMoveEditorPreconditions(player, "UpdateDraft")
	if not allowed then
		return { Success = false, Reason = reason }
	end
	if typeof(rawMove) ~= "table" then
		return { Success = false, Reason = "InvalidShape" }
	end
	local stamped = stampTrustedMetadata(player, rawMove :: { [string]: unknown })
	local validated, validateReason = MoveRegistryManager.Validate(stamped)
	if not validated then
		return { Success = false, Reason = validateReason }
	end
	MoveRegistryManager.Upsert(validated)
	return { Success = true, Move = validated }
end

local function handleSaveMove(player: Player, rawMove: unknown): MoveTypes.MoveEditorMoveResult
	logger:debug("SaveMove received", { player = player.Name, userId = player.UserId })
	local allowed, reason = checkMoveEditorPreconditions(player, "SaveMove")
	if not allowed then
		return { Success = false, Reason = reason }
	end
	if typeof(rawMove) ~= "table" then
		return { Success = false, Reason = "InvalidShape" }
	end
	local stamped = stampTrustedMetadata(player, rawMove :: { [string]: unknown })
	local validated, validateReason = MoveRegistryManager.Validate(stamped)
	if not validated then
		return { Success = false, Reason = validateReason }
	end
	MoveRegistryManager.Upsert(validated)

	if not mainStore then
		return { Success = false, Reason = "StorageError" }
	end
	local setOk = withRetry("MoveEditor SaveMove SetAsync", function()
		(mainStore :: DataStore):SetAsync(recordKey(validated.MoveId), encodeMoveRecord(validated))
	end)
	if not setOk then
		return { Success = false, Reason = "StorageError" }
	end

	if not addToIndex(validated.MoveId) then
		logger:error(
			"SaveMove: index update failed, move saved but may not list after a restart",
			{ moveId = validated.MoveId }
		)
	end

	logger:info("SaveMove accepted", { admin = player.Name, moveId = validated.MoveId })
	return { Success = true, Move = validated }
end

local function handleDeleteMove(player: Player, rawMoveId: unknown): MoveTypes.MoveEditorActionResult
	logger:debug("DeleteMove received", { player = player.Name, userId = player.UserId })
	local allowed, reason = checkMoveEditorPreconditions(player, "DeleteMove")
	if not allowed then
		return { Success = false, Reason = reason }
	end
	if typeof(rawMoveId) ~= "string" then
		return { Success = false, Reason = "InvalidMoveId" }
	end

	MoveRegistryManager.Delete(rawMoveId)

	if mainStore then
		withRetry("MoveEditor DeleteMove RemoveAsync", function()
			(mainStore :: DataStore):RemoveAsync(recordKey(rawMoveId))
		end)
		if not removeFromIndex(rawMoveId) then
			logger:error("DeleteMove: index update failed, record removed but may reappear after a restart", {
				moveId = rawMoveId,
			})
		end
	end

	logger:info("DeleteMove accepted", { admin = player.Name, moveId = rawMoveId })
	return { Success = true }
end

-- Default-move handlers -- backed by DefaultMoveRegistry.lua instead of MoveRegistryManager, see
-- this file's own header for why these three skip stampTrustedMetadata/DataStore entirely.
local function handleListDefaultMoves(player: Player): MoveTypes.MoveEditorListResult
	logger:debug("ListDefaultMoves received", { player = player.Name, userId = player.UserId })
	local allowed, reason = checkMoveEditorPreconditions(player, "ListDefaultMoves")
	if not allowed then
		return { Success = false, Reason = reason }
	end
	return { Success = true, Moves = DefaultMoveRegistry.List() }
end

-- Takes an explicit `moveId` (unlike UpdateDraft, which derives identity from the candidate via
-- stampTrustedMetadata) -- a Default move's identity is its fixed synthetic MoveId, never something a
-- client request legitimately proposes; DefaultMoveRegistry.ApplyEdit treats `moveId` as the sole
-- authority for which live Constants table gets mutated, ignoring whatever MoveId the candidate itself
-- carries.
local function handleUpdateDefaultMoveDraft(
	player: Player,
	rawMoveId: unknown,
	rawCandidate: unknown
): MoveTypes.MoveEditorMoveResult
	logger:debug("UpdateDefaultMoveDraft received", { player = player.Name, userId = player.UserId })
	local allowed, reason = checkMoveEditorPreconditions(player, "UpdateDefaultMoveDraft")
	if not allowed then
		return { Success = false, Reason = reason }
	end
	if typeof(rawMoveId) ~= "string" then
		return { Success = false, Reason = "InvalidMoveId" }
	end
	local updated, editReason = DefaultMoveRegistry.ApplyEdit(rawMoveId, rawCandidate)
	if not updated then
		return { Success = false, Reason = editReason }
	end
	return { Success = true, Move = updated }
end

-- Persists a Default move's CURRENT live values -- unlike SaveMove above, this reads straight off
-- DefaultMoveRegistry.Get rather than trusting a client-submitted candidate, since a Default move's
-- identity fields are never client-editable to begin with (see this file's own header) and its live
-- values are already the single source of truth (UpdateDefaultMoveDraft mutated them in place).
local function handleSaveDefaultMove(player: Player, rawMoveId: unknown): MoveTypes.MoveEditorMoveResult
	logger:debug("SaveDefaultMove received", { player = player.Name, userId = player.UserId })
	local allowed, reason = checkMoveEditorPreconditions(player, "SaveDefaultMove")
	if not allowed then
		return { Success = false, Reason = reason }
	end
	if typeof(rawMoveId) ~= "string" then
		return { Success = false, Reason = "InvalidMoveId" }
	end
	local current = DefaultMoveRegistry.Get(rawMoveId)
	if not current then
		return { Success = false, Reason = "MoveNotFound" }
	end

	if not mainStore then
		return { Success = false, Reason = "StorageError" }
	end
	local setOk = withRetry("MoveEditor SaveDefaultMove SetAsync", function()
		(mainStore :: DataStore):SetAsync(defaultOverrideKey(rawMoveId), encodeDefaultOverride(current))
	end)
	if not setOk then
		return { Success = false, Reason = "StorageError" }
	end

	logger:info("SaveDefaultMove accepted", { admin = player.Name, moveId = rawMoveId })
	return { Success = true, Move = current }
end

-- Both live-reverts (DefaultMoveRegistry.Reset, exactly as before) AND clears any persisted
-- override for this move -- without the RemoveAsync below, a Reset would only look permanent for
-- the rest of THIS server's lifetime; the next boot's loadDefaultMoveOverrides would silently
-- re-apply the old saved value, since nothing else ever deletes an override record. Best-effort on
-- the RemoveAsync (logged, never fails the response) -- same "the in-memory revert already
-- succeeded, don't make the admin re-click over a storage hiccup" tradeoff DeleteMove's own
-- removeFromIndex failure accepts.
local function handleResetDefaultMove(player: Player, rawMoveId: unknown): MoveTypes.MoveEditorMoveResult
	logger:debug("ResetDefaultMove received", { player = player.Name, userId = player.UserId })
	local allowed, reason = checkMoveEditorPreconditions(player, "ResetDefaultMove")
	if not allowed then
		return { Success = false, Reason = reason }
	end
	if typeof(rawMoveId) ~= "string" then
		return { Success = false, Reason = "InvalidMoveId" }
	end
	local reset = DefaultMoveRegistry.Reset(rawMoveId)
	if not reset then
		return { Success = false, Reason = "InvalidMoveId" }
	end

	if mainStore then
		local removeOk = withRetry("MoveEditor ResetDefaultMove RemoveAsync", function()
			(mainStore :: DataStore):RemoveAsync(defaultOverrideKey(rawMoveId))
		end)
		if not removeOk then
			logger:error("ResetDefaultMove: override RemoveAsync failed, may reappear after a restart", {
				moveId = rawMoveId,
			})
		end
	end

	logger:info("ResetDefaultMove accepted", { admin = player.Name, moveId = rawMoveId })
	return { Success = true, Move = reset }
end

-- The Move Editor toolbar's "bind to slot N" control. Thin: every real decision (is this actually
-- an art, has the admin earned it, which slot) lives in ArtSystem.DevGrantAndEquip -- this handler
-- only gates + shape-checks, the same split every other handler in this file already uses. A
-- hotbar slot has exactly one owner, ArtSystem's persisted equippedArts (see that module's own
-- header on why HotbarBindings.lua stopped being a second one), so binding here IS equipping.
local function handleEquipArtSlot(player: Player, rawSlot: unknown, rawArtId: unknown): MoveTypes.MoveEditorActionResult
	logger:debug("EquipArtSlot received", { player = player.Name, userId = player.UserId })
	local allowed, reason = checkMoveEditorPreconditions(player, "EquipArtSlot")
	if not allowed then
		return { Success = false, Reason = reason }
	end
	if typeof(rawSlot) ~= "number" then
		return { Success = false, Reason = "InvalidSlot" }
	end
	if rawArtId ~= nil and typeof(rawArtId) ~= "string" then
		return { Success = false, Reason = "InvalidArtId" }
	end
	local equipReason = ArtSystem.DevGrantAndEquip(player, rawSlot :: number, rawArtId :: string?)
	if equipReason then
		return { Success = false, Reason = equipReason }
	end
	return { Success = true }
end

-- Freezes/unfreezes the admin's own character while their editor screen is open/closed -- reuses
-- AdminActionSystem.SetFrozen (the exact mechanism/Humanoid Attribute an admin's own "Frozen"
-- DevMenu toggle already drives, checked at TOP priority by Server/Systems/RunSystem.lua's resolver)
-- rather than writing the Attribute directly, so this stays in sync with AdminActionSystem's own
-- overrideStates bookkeeping instead of fighting it. Fire-and-forget (RemoteEvent) -- the editor
-- screen doesn't need or wait for a response.
--
-- Deliberately does NOT route through checkMoveEditorPreconditions' shared rateLimiter:IsLimited
-- check the way every other Move Editor remote does -- only for the CLOSE (rawIsOpen == false) case.
-- This used to be symmetric with every other handler here, and that was the bug: rateLimiter's
-- budget (Constants.NetworkBudget.MaxRemoteCallsPerSecondPerPlayer) is shared across every Move
-- Editor remote, including the debounced-but-still-frequent UpdateDraft calls a busy editing session
-- fires, so an admin who had been actively tuning a move (or mashing Test on Dummy, which itself
-- toggles this exact remote) could get their CLOSE silently dropped. Nothing else ever clears
-- Constants.Attributes.Frozen once that happens -- the client had already flipped its own IsOpen to
-- false and shows the panel closed, so there is no error, no retry, and no visible reason to press
-- anything again -- reported as "randomly freezing myself." A dropped OPEN is harmless by comparison
-- (the admin's character just doesn't freeze that press, and pressing the keybind again retries it
-- for free), so only the unfreeze path is exempted: unfreezing your own character must never be
-- something a shared network budget can leave stuck.
local function handleSetEditorOpen(player: Player, rawIsOpen: unknown): ()
	if not AdminGate.IsAuthorized(player) then
		logger:warn("SetEditorOpen rejected: not authorized", { player = player.Name, userId = player.UserId })
		return
	end
	if typeof(rawIsOpen) ~= "boolean" then
		return
	end
	if rawIsOpen and rateLimiter:IsLimited(player) then
		logger:debug("SetEditorOpen rejected: rate limited", { player = player.Name, userId = player.UserId })
		return
	end
	AdminActionSystem.SetFrozen(player, rawIsOpen)
end

-- Loads every persisted move into MoveRegistryManager's live in-memory table -- backgrounded
-- (task.spawn from Init(), see BugReportSystem.lua's seedOpenReportCount for the identical
-- reasoning) so a slow full-index page-through never blocks Main.server.lua's synchronous boot
-- chain. A move that fails to decode/validate is skipped and logged, never crashes the load --
-- corrupt or hand-edited DataStore content degrades safely, same as PlayerDataSystem's own
-- DecodeProfile contract.
local function loadPersistedMoves(): ()
	if not mainStore then
		return
	end

	local indexOk, indexRaw = withRetry("MoveEditor loadPersistedMoves index GetAsync", function()
		return (mainStore :: DataStore):GetAsync(INDEX_KEY)
	end)
	if not indexOk then
		logger:error("loadPersistedMoves: index GetAsync failed, starting with an empty registry")
		return
	end
	if typeof(indexRaw) ~= "table" then
		logger:info("loadPersistedMoves: no existing move index, starting empty")
		return
	end

	local moveIds = (indexRaw :: { [string]: any }).MoveIds
	if typeof(moveIds) ~= "table" then
		return
	end

	local loadedCount = 0
	for _, rawMoveId in ipairs(moveIds :: { unknown }) do
		if typeof(rawMoveId) == "string" then
			local getOk, raw = withRetry("MoveEditor loadPersistedMoves record GetAsync", function()
				return (mainStore :: DataStore):GetAsync(recordKey(rawMoveId))
			end)
			if getOk and raw ~= nil then
				local candidate = candidateFromStoredRecord(raw)
				if candidate then
					-- COERCED, never rejected. A record written before Validate gained its
					-- reserved-category gate could legitimately be carrying the sentinel, and letting
					-- that record fail validation here would make a real, admin-authored move vanish
					-- from the registry on the next boot with no signal anywhere -- strictly worse than
					-- showing it uncategorised. The warn is what keeps the coercion visible rather than
					-- silent. (Note this runs BEFORE Validate, so the gate below never sees the
					-- sentinel and this call correctly leaves allowReservedCategory false.)
					if candidate.Category == MoveTypes.DefaultCategory then
						logger:warn(
							"loadPersistedMoves: stored move claims the reserved 'Default' category -- loading it as uncategorised",
							{ moveId = rawMoveId }
						)
						candidate.Category = ""
					end
					local validated, reason = MoveRegistryManager.Validate(candidate)
					if validated then
						MoveRegistryManager.Upsert(validated)
						loadedCount += 1
					else
						logger:warn(
							"loadPersistedMoves: skipped invalid record",
							{ moveId = rawMoveId, reason = reason }
						)
					end
				else
					logger:warn("loadPersistedMoves: skipped record with an invalid shape", { moveId = rawMoveId })
				end
			else
				logger:warn("loadPersistedMoves: skipped record that failed to fetch", { moveId = rawMoveId })
			end
		end
	end
	logger:info("loadPersistedMoves complete", { loadedCount = loadedCount })

	-- Audited HERE rather than in ArtTreeManager.Init, which is the only point where the art roster
	-- is complete -- see that function's own note. An art is a move, so "every move is loaded" and
	-- "every art exists" are the same moment. Never fatal: a broken prerequisite should cost that art
	-- its unlock path and show up in a log, not stop the server.
	for _, problem in ipairs(ArtTreeManager.AuditPrerequisites()) do
		logger:warn("Art prerequisite problem", { problem = problem })
	end
end

-- Sibling to loadPersistedMoves above, for Default moves -- no index to page through (see
-- defaultOverrideKey's own header for why), just one GetAsync per move DefaultMoveRegistry.List()
-- already knows about. Calling List() first is what makes DefaultMoveRegistry.lua's own
-- ensureDefaultsCaptured run BEFORE any override is applied here -- see that module's header for why
-- this ordering is what keeps Reset reverting to the true Constants.lua file value, never a
-- previously-applied override. A move whose override record fails to decode/validate is skipped and
-- logged, never crashes the load -- same degrade-safely contract loadPersistedMoves already applies
-- to a corrupt custom-move record.
local function loadDefaultMoveOverrides(): ()
	if not mainStore then
		return
	end

	local moves = DefaultMoveRegistry.List()
	local loadedCount = 0
	for _, move in ipairs(moves) do
		local getOk, raw = withRetry("MoveEditor loadDefaultMoveOverrides GetAsync", function()
			return (mainStore :: DataStore):GetAsync(defaultOverrideKey(move.MoveId))
		end)
		if getOk and raw ~= nil then
			local candidate = candidateFromStoredDefaultOverride(move, raw)
			if candidate then
				local updated, reason = DefaultMoveRegistry.ApplyEdit(move.MoveId, candidate)
				if updated then
					loadedCount += 1
				else
					logger:warn(
						"loadDefaultMoveOverrides: skipped invalid override",
						{ moveId = move.MoveId, reason = reason }
					)
				end
			else
				logger:warn(
					"loadDefaultMoveOverrides: skipped override with an invalid shape",
					{ moveId = move.MoveId }
				)
			end
		elseif not getOk then
			logger:warn("loadDefaultMoveOverrides: skipped override that failed to fetch", { moveId = move.MoveId })
		end
	end
	logger:info("loadDefaultMoveOverrides complete", { loadedCount = loadedCount })
end

-- Assumes MoveRegistryManager.Init() has already run (Main.server.lua calls it before this System's
-- own Init() -- see that file's boot-order comments) -- this function only POPULATES the
-- already-initialized registry.
function MoveEditorSystem.Init(): ()
	mainStore = DataStoreService:GetDataStore(StorageConfig.CustomMoveDataStoreName)

	task.spawn(loadPersistedMoves)
	task.spawn(loadDefaultMoveOverrides)

	local listRemote = NetworkBridge.CreateRemoteFunction(Config.RemoteNames.ListMoves)
	listRemote.OnServerInvoke = wrapHandler("ListMoves", handleListMoves)

	local getRemote = NetworkBridge.CreateRemoteFunction(Config.RemoteNames.GetMove)
	getRemote.OnServerInvoke = wrapHandler("GetMove", handleGetMove)

	local updateDraftRemote = NetworkBridge.CreateRemoteFunction(Config.RemoteNames.UpdateDraft)
	updateDraftRemote.OnServerInvoke = wrapHandler("UpdateDraft", handleUpdateDraft)

	local saveRemote = NetworkBridge.CreateRemoteFunction(Config.RemoteNames.SaveMove)
	saveRemote.OnServerInvoke = wrapHandler("SaveMove", handleSaveMove)

	local deleteRemote = NetworkBridge.CreateRemoteFunction(Config.RemoteNames.DeleteMove)
	deleteRemote.OnServerInvoke = wrapHandler("DeleteMove", handleDeleteMove)

	local listDefaultMovesRemote = NetworkBridge.CreateRemoteFunction(Config.RemoteNames.ListDefaultMoves)
	listDefaultMovesRemote.OnServerInvoke = wrapHandler("ListDefaultMoves", handleListDefaultMoves)

	local updateDefaultMoveDraftRemote = NetworkBridge.CreateRemoteFunction(Config.RemoteNames.UpdateDefaultMoveDraft)
	updateDefaultMoveDraftRemote.OnServerInvoke = wrapHandler("UpdateDefaultMoveDraft", handleUpdateDefaultMoveDraft)

	local saveDefaultMoveRemote = NetworkBridge.CreateRemoteFunction(Config.RemoteNames.SaveDefaultMove)
	saveDefaultMoveRemote.OnServerInvoke = wrapHandler("SaveDefaultMove", handleSaveDefaultMove)

	local resetDefaultMoveRemote = NetworkBridge.CreateRemoteFunction(Config.RemoteNames.ResetDefaultMove)
	resetDefaultMoveRemote.OnServerInvoke = wrapHandler("ResetDefaultMove", handleResetDefaultMove)

	local equipArtSlotRemote = NetworkBridge.CreateRemoteFunction(Config.RemoteNames.EquipArtSlot)
	equipArtSlotRemote.OnServerInvoke = wrapHandler("EquipArtSlot", handleEquipArtSlot)

	local setEditorOpenRemote = NetworkBridge.CreateRemoteEvent(Config.RemoteNames.SetEditorOpen)
	setEditorOpenRemote.OnServerEvent:Connect(function(player: Player, rawIsOpen: unknown)
		local ok, errorMessage = pcall(handleSetEditorOpen, player, rawIsOpen)
		if not ok then
			logger:error(
				"SetEditorOpen handler errored",
				{ player = player.Name, errorMessage = tostring(errorMessage) }
			)
		end
	end)

	PlayerLifecycle.BindAllPlayers({
		Scope = "MoveEditorSystem",
		OnPlayerRemoving = function(player: Player)
			rateLimiter:Clear(player)
		end,
	})

	logger:info("MoveEditorSystem.Init() complete")
end

-- Exported specifically so this System's regression tests can exercise the DataStore encode/decode
-- round-trip headlessly -- no live remote, no DataStore, just a MoveDefinition in and the record (or
-- the record back out) -- the same "pure logic gets its own export" precedent every other System in
-- this codebase already follows. This pairing is exactly what let Art/Grab silently stop persisting
-- despite validating and working live: encodeMoveRecord forgot to write them, and nothing caught it
-- until an admin restarted their server and found their edits gone. A round-trip test on this pair is
-- what a new optional MoveDefinition field (the next one being Slam -- see MoveRegistryManager.lua's
-- own note that it isn't validated/persisted yet) should be checked against before shipping.
MoveEditorSystem.EncodeMoveRecord = encodeMoveRecord
MoveEditorSystem.CandidateFromStoredRecord = candidateFromStoredRecord

return MoveEditorSystem
