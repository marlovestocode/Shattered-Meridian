--!strict
--[[
	MoveRegistryManager.lua

	Owns: the LIVE, in-memory registry of custom moves (MoveTypes.MoveDefinition, keyed by MoveId), and
	Validate -- the one gate every untrusted move-shaped table passes before it can reach the combat
	stack. A client's draft, a DataStore record (already upgraded by MoveRecordCodec) and a Default-move
	override all go through the identical function, so a DataStore read is trusted no more than a network
	payload.

	TWO KINDS OF WRONG, TWO ANSWERS. A structural error -- no MoveId, an unknown Shape, a timing field that
	is not a number -- is a hard reject with a reason code, because the table is not a move and the author
	needs to be told. An in-range numeric error is CLAMPED against Constants.MoveEditor.Limits (the same
	table the editor renders its field bounds from), because a windup of 3.4 when the ceiling is 3 is a
	value error inside an otherwise coherent move, not a reason to refuse the whole save.

	The optional blocks follow the same split: absent is valid (nil), present-but-not-a-table is a hard
	reject (the author clearly meant to author one), and the numbers inside are clamped. Grab reads its
	bounds from GrabConstants.Limits and Art from ArtConstants.Limits -- each runtime owns its own range.
	Projectile (the move type) goes through ProjectileTypes.Validate, whose Limits the editor renders too,
	and Presentation through MovePresentationTypes.Validate, and Domain through DomainTypes.Validate, the
	same way.

	Upsert/Delete touch memory only. That is what makes a Preview take effect on the very next swing with
	no DataStore round trip; MoveEditorSystem decides when anything is persisted.

	Does not own: authorization, remotes or persistence (MoveEditorSystem), the wire encoding
	(MoveTypes.ToWire) or upgrading old records into it (Server/Systems/Support/MoveRecordCodec.lua).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ArtConstants = require(ReplicatedStorage.Shared.ArtConstants)
local Constants = require(ReplicatedStorage.Shared.Constants)
local GrabConstants = require(ReplicatedStorage.Shared.Grab.GrabConstants)
local HitboxTypes = require(ReplicatedStorage.Shared.HitboxEngine.HitboxTypes)
local Logger = require(ReplicatedStorage.Shared.Logger)
local DomainTypes = require(ReplicatedStorage.Shared.Domain.DomainTypes)
local MovePresentationTypes = require(ReplicatedStorage.Shared.Combat.MovePresentationTypes)
local MoveTypes = require(ReplicatedStorage.Shared.MoveTypes)
local ProjectileTypes = require(ReplicatedStorage.Shared.HitboxEngine.ProjectileTypes)
local Sanitize = require(ReplicatedStorage.Shared.Sanitize)
local WeaponAssets = require(ReplicatedStorage.Shared.Combat.WeaponAssets)

local MoveRegistryManager = {}

local logger = Logger.scope("MoveRegistryManager")

local LIMITS = Constants.MoveEditor.Limits

type Range = { Min: number, Max: number }

local moves: { [string]: MoveTypes.MoveDefinition } = {}

-- Called with a MoveId after every Upsert/Delete -- the one seam Server/Combat/MovePresentationSystem.lua
-- reads to keep the client catalogue in step, whichever writer (the editor, the source library, a spec)
-- changed the registry. pcall'd per listener: a publisher erroring must never fail a registry write.
local changedListeners: { (moveId: string) -> () } = {}

local function notifyChanged(moveId: string): ()
	for _, listener in changedListeners do
		local ok, err = pcall(listener, moveId)
		if not ok then
			logger:warn("OnChanged listener failed", { moveId = moveId, error = tostring(err) })
		end
	end
end

local function isNonEmptyString(value: unknown): boolean
	return typeof(value) == "string" and (value :: string) ~= ""
end

-- Clamps into `range`, or nil for anything that is not a real number (NaN included -- Sanitize's own
-- contract). The caller decides whether nil is a reject or a fallback.
local function clamp(value: unknown, range: Range): number?
	return Sanitize.ClampNumber(value, range.Min, range.Max)
end

local function clampOr(value: unknown, range: Range, fallback: number): number
	return Sanitize.ClampNumberOr(value, range.Min, range.Max, math.clamp(fallback, range.Min, range.Max))
end

-- Geometry -------------------------------------------------------------------------------------------

local DIMENSION_FIELDS = { "Width", "Height", "Length", "Radius", "InnerRadius", "AngleDegrees" }

-- Every field is populated whatever the shape (HitboxTypes.Dimensions is one flat bag), clamped into the
-- authoring bounds; a missing field takes the engine default. The one cross-field rule is the engine's
-- own: an Arc hub wider than its rim is an inside-out annulus that can never contain anything.
local function validateDimensions(raw: unknown): MoveTypes.MoveDimensions?
	if typeof(raw) ~= "table" then
		return nil
	end
	local source = raw :: { [string]: unknown }
	local defaults = HitboxTypes.DefaultDimensions() :: any
	local result = {} :: any
	for _, field in DIMENSION_FIELDS do
		result[field] = clampOr(source[field], LIMITS.Dimensions[field], defaults[field])
	end
	if result.InnerRadius > result.Radius then
		result.InnerRadius = result.Radius
	end
	return result :: MoveTypes.MoveDimensions
end

local function isAttachmentPoint(value: unknown): boolean
	return table.find(MoveTypes.AttachmentPoints, value :: any) ~= nil
end

-- Optional blocks ------------------------------------------------------------------------------------

local function validateKnockback(raw: unknown): (MoveTypes.MoveKnockback?, string?)
	if raw == nil then
		return nil, nil
	end
	if typeof(raw) ~= "table" then
		return nil, "InvalidKnockback"
	end
	local candidate = raw :: { [string]: unknown }
	local up = clamp(candidate.UpVelocity, LIMITS.KnockbackVelocity)
	local horizontal = clamp(candidate.HorizontalVelocity, LIMITS.KnockbackVelocity)
	if up == nil or horizontal == nil then
		return nil, "InvalidKnockback"
	end
	if candidate.StartsAirCombo ~= nil and typeof(candidate.StartsAirCombo) ~= "boolean" then
		return nil, "InvalidKnockback"
	end
	return {
		UpVelocity = up,
		HorizontalVelocity = horizontal,
		StartsAirCombo = candidate.StartsAirCombo == true,
	},
		nil
end

-- An authored grab animation: optional, a string or nothing, normalised the same way the move's own
-- AnimationId is. Returns false for a value that is not a string at all.
local function grabAnimation(value: unknown): (string?, boolean)
	if value == nil then
		return "", true
	end
	if typeof(value) ~= "string" then
		return nil, false
	end
	return WeaponAssets.NormalizeAssetId(Sanitize.BoundedString(value, LIMITS.AnimationIdLength)), true
end

-- Mode is strict on identity (a name GrabConstants.Modes does not know is refused rather than silently
-- held some other way); an absent one is the default mode, which is what every grab saved before modes
-- existed means. Anything else on the candidate (an old record's AttachOffset included) is ignored.
local function validateGrab(raw: unknown): (MoveTypes.MoveGrabConfig?, string?)
	if raw == nil then
		return nil, nil
	end
	if typeof(raw) ~= "table" then
		return nil, "InvalidGrab"
	end
	local candidate = raw :: { [string]: unknown }
	local limits = GrabConstants.Limits
	local hold = clamp(candidate.HoldSeconds, limits.HoldSeconds)
	local up = clamp(candidate.ThrowUpVelocity, limits.ThrowUpVelocity)
	local horizontal = clamp(candidate.ThrowHorizontalVelocity, limits.ThrowHorizontalVelocity)
	local impact = clamp(candidate.ThrowImpactDamage, limits.ThrowImpactDamage)
	local selfDamage = clamp(candidate.ThrowSelfDamage, limits.ThrowSelfDamage)
	if hold == nil or up == nil or horizontal == nil or impact == nil or selfDamage == nil then
		return nil, "InvalidGrab"
	end
	local modeName = if candidate.Mode == nil then GrabConstants.DefaultMode else candidate.Mode
	if typeof(modeName) ~= "string" or GrabConstants.Modes[modeName] == nil then
		return nil, "InvalidGrab"
	end
	local victimAnimation, victimOk = grabAnimation(candidate.VictimAnimation)
	local attackerAnimation, attackerOk = grabAnimation(candidate.AttackerAnimation)
	local throwAnimation, throwOk = grabAnimation(candidate.ThrowAnimation)
	local victimThrowAnimation, victimThrowOk = grabAnimation(candidate.VictimThrowAnimation)
	if not victimOk or not attackerOk or not throwOk or not victimThrowOk then
		return nil, "InvalidGrab"
	end
	-- Optional, and left absent when absent (GrabSystem reads nil as the clip's end), so a grab saved
	-- before it existed round-trips unchanged; present, it must be a number.
	local releaseAt: number? = nil
	if candidate.ThrowReleaseAt ~= nil then
		releaseAt = clamp(candidate.ThrowReleaseAt, limits.ThrowReleaseAt)
		if releaseAt == nil then
			return nil, "InvalidGrab"
		end
	end
	return {
		Mode = modeName :: any,
		VictimAnimation = victimAnimation,
		AttackerAnimation = attackerAnimation,
		VictimThrowAnimation = victimThrowAnimation,
		ThrowAnimation = throwAnimation,
		ThrowReleaseAt = releaseAt,
		HoldSeconds = hold,
		ThrowUpVelocity = up,
		ThrowHorizontalVelocity = horizontal,
		ThrowImpactDamage = impact,
		ThrowSelfDamage = selfDamage,
	},
		nil
end

-- Strict on identity, lenient on numbers. TreeId must name a real ArtConstants.ArtTrees entry (a typo'd
-- tree would file the art somewhere nothing renders, worse than a visible save failure); Node/QiCost/
-- RequiredTier clamp. A prerequisite naming the move itself can never be unlocked and is rejected; one
-- naming some OTHER art is not checked for existence here -- load order is not guaranteed, so that audit
-- belongs to ArtTreeManager reading the whole registry at once.
local function validateArt(raw: unknown, moveId: string): (MoveTypes.MoveArtBinding?, string?)
	if raw == nil then
		return nil, nil
	end
	if typeof(raw) ~= "table" then
		return nil, "InvalidArt"
	end
	local candidate = raw :: { [string]: unknown }
	if not isNonEmptyString(candidate.TreeId) then
		return nil, "InvalidArtTreeId"
	end
	local treeId = candidate.TreeId :: string
	local treeExists = false
	for _, tree in ipairs(ArtConstants.ArtTrees) do
		if tree.TreeId == treeId then
			treeExists = true
			break
		end
	end
	if not treeExists then
		return nil, "UnknownArtTree"
	end

	local prerequisite: string? = nil
	if candidate.Prerequisite ~= nil and candidate.Prerequisite ~= "" then
		if typeof(candidate.Prerequisite) ~= "string" then
			return nil, "InvalidArtPrerequisite"
		end
		if candidate.Prerequisite == moveId then
			return nil, "SelfReferentialArtPrerequisite"
		end
		prerequisite = candidate.Prerequisite :: string
	end

	local limits = ArtConstants.Limits
	return {
		TreeId = treeId,
		Node = math.floor(clampOr(candidate.Node, limits.Node, limits.Node.Min)),
		QiCost = clampOr(candidate.QiCost, limits.QiCost, limits.QiCost.Min),
		RequiredTier = math.floor(clampOr(candidate.RequiredTier, limits.RequiredTier, limits.RequiredTier.Min)),
		Prerequisite = prerequisite,
	},
		nil
end

-- Validate -------------------------------------------------------------------------------------------

-- The gate. `candidate` is `unknown` on purpose: a client argument, a decoded record and a spec literal
-- are all treated identically. It is the MoveTypes.ToWire shape plus the identity stamps
-- (Author/CreatedAt/UpdatedAt) MoveEditorSystem adds from trusted context before calling this.
--
-- Returns (move, nil) or (nil, reasonCode). Reason codes are stable strings the editor turns into prose
-- (Client/UI/Screens/DevTools/MoveEditor/Copy.lua) -- rename one there too, or it reads as "unknown".
function MoveRegistryManager.Validate(candidate: unknown): (MoveTypes.MoveDefinition?, string?)
	if typeof(candidate) ~= "table" then
		return nil, "InvalidShape"
	end
	local raw = candidate :: { [string]: unknown }

	if not isNonEmptyString(raw.MoveId) then
		return nil, "InvalidMoveId"
	end
	local moveId = raw.MoveId :: string
	if typeof(raw.DisplayName) ~= "string" then
		return nil, "InvalidDisplayName"
	end
	local displayName = Sanitize.BoundedString(raw.DisplayName, LIMITS.DisplayNameLength)
	if string.match(displayName, "^%s*$") then
		return nil, "InvalidDisplayName"
	end
	if not isNonEmptyString(raw.Author) then
		return nil, "InvalidAuthor"
	end
	if typeof(raw.CreatedAt) ~= "number" or typeof(raw.UpdatedAt) ~= "number" then
		return nil, "InvalidTimestamp"
	end

	if not HitboxTypes.IsShapeKind(raw.Shape) then
		return nil, "InvalidShapeKind"
	end
	local dimensions = validateDimensions(raw.Dimensions)
	if not dimensions then
		return nil, "MissingDimensions"
	end

	local offsetX = clamp(raw.OffsetX, LIMITS.OffsetStuds)
	local offsetY = clamp(raw.OffsetY, LIMITS.OffsetStuds)
	local offsetZ = clamp(raw.OffsetZ, LIMITS.OffsetStuds)
	if offsetX == nil or offsetY == nil or offsetZ == nil then
		return nil, "InvalidOffset"
	end
	-- Absent rotation is legal and means none.
	local rotation = Vector3.new(
		clampOr(raw.OffsetPitch, LIMITS.RotationDegrees, 0),
		clampOr(raw.OffsetYaw, LIMITS.RotationDegrees, 0),
		clampOr(raw.OffsetRoll, LIMITS.RotationDegrees, 0)
	)

	local attachment: MoveTypes.MoveAttachmentPoint = "Root"
	if raw.AttachmentPart ~= nil then
		if not isAttachmentPoint(raw.AttachmentPart) then
			return nil, "InvalidAttachmentPart"
		end
		attachment = raw.AttachmentPart :: MoveTypes.MoveAttachmentPoint
	end

	local windup = clamp(raw.WindupSeconds, LIMITS.PhaseSeconds)
	local active = clamp(raw.ActiveSeconds, LIMITS.PhaseSeconds)
	local recovery = clamp(raw.RecoverySeconds, LIMITS.PhaseSeconds)
	local cooldown = clamp(raw.Cooldown, LIMITS.CooldownSeconds)
	if windup == nil or active == nil or recovery == nil or cooldown == nil then
		return nil, "InvalidTiming"
	end

	local damage = clamp(raw.Damage, LIMITS.Damage)
	local postureDamage = clamp(raw.PostureDamage, LIMITS.PostureDamage)
	if damage == nil or postureDamage == nil then
		return nil, "InvalidDamage"
	end

	local maxTargets: number? = nil
	if raw.MaxTargets ~= nil then
		local clamped = clamp(raw.MaxTargets, LIMITS.MaxTargets)
		if clamped == nil then
			return nil, "InvalidMaxTargets"
		end
		maxTargets = math.floor(clamped)
	end

	-- Whole levels only: GuardMeter.DrainFor multiplies by it, and a fractional weight class is not
	-- something an author means.
	local powerLevel: number? = nil
	if raw.PowerLevel ~= nil then
		local clamped =
			Sanitize.ClampNumber(raw.PowerLevel, MoveTypes.PowerLevelLimits.Min, MoveTypes.PowerLevelLimits.Max)
		powerLevel = if clamped then math.floor(clamped + 0.5) else nil
	end

	if raw.AnimationId ~= nil and typeof(raw.AnimationId) ~= "string" then
		return nil, "InvalidAnimationId"
	end
	-- Normalised here, once, so a bare id pasted from the Creator Dashboard is stored in the form every
	-- reader expects rather than failing at load time in the one reader that forgot to normalise.
	local animationId = WeaponAssets.NormalizeAssetId(Sanitize.BoundedString(raw.AnimationId, LIMITS.AnimationIdLength))

	local knockback, knockbackError = validateKnockback(raw.Knockback)
	if knockbackError then
		return nil, knockbackError
	end
	local grab, grabError = validateGrab(raw.Grab)
	if grabError then
		return nil, grabError
	end
	local art, artError = validateArt(raw.Art, moveId)
	if artError then
		return nil, artError
	end

	-- The move type (MoveTypes.IsProjectile). ProjectileTypes owns its own gate, the way GrabConstants and
	-- ArtConstants own their ranges: strict on option names and value types, clamping on numbers.
	local projectile: MoveTypes.MoveProjectileConfig? = nil
	if raw.Projectile ~= nil then
		local spec, projectileError = ProjectileTypes.Validate(raw.Projectile)
		if not spec then
			return nil, projectileError or "InvalidProjectile"
		end
		projectile = spec
	end
	-- A grab welds the victim to the holder's hand. From a shot that landed across the arena that is a
	-- teleport, not a grab -- so a projectile move cannot carry one, and saying so beats flying it.
	if projectile and grab then
		return nil, "ProjectileCannotGrab"
	end

	-- The realm (MoveTypes.IsDomain). DomainTypes owns its own gate, the same arrangement: strict on option
	-- names, value types and move-id shape, clamping on numbers. Handed the move's own id so an effect that
	-- references the realm itself is refused rather than re-opening it on every pulse.
	local domain: MoveTypes.MoveDomainConfig? = nil
	if raw.Domain ~= nil then
		local spec, domainError = DomainTypes.Validate(raw.Domain, moveId)
		if not spec then
			return nil, domainError or "InvalidDomain"
		end
		domain = spec
	end
	-- A grab is a hold on one body; a realm is a law over many. The swing that opens a realm is its tell,
	-- and a tell that also welds its first victim to the caster's hand is two ultimates in one press.
	if domain and grab then
		return nil, "DomainCannotGrab"
	end

	-- Presentation: strict on moment/preset/id/colour identity, clamping on numbers, every asset id
	-- normalised -- MovePresentationTypes.Validate. It never meets a combat layer.
	local presentation, presentationError = MovePresentationTypes.Validate(raw.Presentation)
	if presentationError then
		return nil, presentationError
	end

	return {
		MoveId = moveId,
		DisplayName = displayName,
		-- Truncated, never rejected: an over-long note is a value error, and every record from before the
		-- field existed has to keep validating.
		Description = Sanitize.BoundedString(raw.Description, LIMITS.DescriptionLength),
		Category = Sanitize.BoundedString(raw.Category, LIMITS.CategoryLength),
		Author = raw.Author :: string,
		CreatedAt = raw.CreatedAt :: number,
		UpdatedAt = raw.UpdatedAt :: number,

		Shape = raw.Shape :: MoveTypes.MoveShape,
		Dimensions = dimensions,
		Offset = MoveTypes.ComposeOffset(Vector3.new(offsetX, offsetY, offsetZ), rotation),
		OffsetRotation = rotation,
		AttachmentPart = attachment,
		LocksMovement = raw.LocksMovement == true,
		LocksWindup = raw.LocksWindup == true,

		WindupSeconds = windup,
		ActiveSeconds = active,
		RecoverySeconds = recovery,
		Cooldown = cooldown,

		Damage = damage,
		PostureDamage = postureDamage,
		MaxTargets = maxTargets,
		PowerLevel = powerLevel,
		Feintable = if raw.Feintable == true then true else nil,

		AnimationId = animationId,

		Knockback = knockback,
		Grab = grab,
		Art = art,
		Projectile = projectile,
		Presentation = presentation,
		Domain = domain,
	},
		nil
end

-- The registry --------------------------------------------------------------------------------------

function MoveRegistryManager.Init(): ()
	moves = {}
end

-- Copies out, never the live table -- a caller mutating what it was handed must not reach back into
-- the registry.
function MoveRegistryManager.List(): { MoveTypes.MoveDefinition }
	local result = {}
	for _, move in pairs(moves) do
		table.insert(result, MoveTypes.Clone(move))
	end
	return result
end

function MoveRegistryManager.Get(moveId: string): MoveTypes.MoveDefinition?
	local move = moves[moveId]
	return if move then MoveTypes.Clone(move) else nil
end

-- `validated` must already have passed Validate; this trusts its caller on that.
function MoveRegistryManager.Upsert(validated: MoveTypes.MoveDefinition): ()
	moves[validated.MoveId] = MoveTypes.Clone(validated)
	notifyChanged(validated.MoveId)
end

function MoveRegistryManager.Delete(moveId: string): ()
	moves[moveId] = nil
	notifyChanged(moveId)
end

-- Subscribes to every Upsert/Delete; returns the unsubscribe. See changedListeners.
function MoveRegistryManager.OnChanged(listener: (moveId: string) -> ()): () -> ()
	table.insert(changedListeners, listener)
	return function()
		local index = table.find(changedListeners, listener)
		if index then
			table.remove(changedListeners, index)
		end
	end
end

-- Server-generated, never client-chosen, so two admins creating moves at once can never collide. The
-- slug is only for readable logs and DataStore keys; the suffix is what makes it unique. The "default:"
-- prefix is DefaultMoveRegistry's id space and a slug can never start with it (the colon is stripped).
function MoveRegistryManager.GenerateMoveId(displayName: string): string
	local base = displayName:lower():gsub("[^%w]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
	if base == "" then
		base = "move"
	end
	local candidate: string
	repeat
		candidate = base .. "-" .. tostring(math.random(1000, 9999))
	until moves[candidate] == nil
	return candidate
end

return MoveRegistryManager
