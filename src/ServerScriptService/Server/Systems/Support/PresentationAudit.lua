--!strict
--[[
	PresentationAudit.lua

	Owns: the Move Editor's NOTES about a move's presentation block (Shared/Combat/MovePresentationTypes
	.lua) -- the things that would otherwise fail silently at the moment a player should have heard or
	seen something:

	  * an asset id that does not resolve (no such asset, or not one this game may load), or resolves to
	    the wrong KIND (an Image where a Sound is wanted; a Decal id, whose Image id is a different number,
	    where a particle texture is wanted)
	  * a template name ReplicatedStorage[FXConstants.MovePresentation.TemplateFolder] does not hold
	  * a cue on a moment that can never fire for this move (a projectile moment on a melee move -- kept on
	    the record so switching the move back restores it, but inert, and the editor hides it)

	WHY SERVER-SIDE. Validate already refuses an id that is not SHAPED like an id; whether the asset behind
	a well-shaped id exists is a question only the platform answers, and MarketplaceService.GetProductInfo
	answers it on the server. Looked up once per id per server (cached), in the background: the first
	entry built after an id appears says "still being checked", and the next Preview reports the answer.
	The client side of the same failure -- PreloadAsync refusing an id -- is warned by AssetPreloader,
	labelled with the move and the moment.

	Describe is PURE (the lookups are injected) and specced; AssetStatus and TemplateExists are the live
	lookups MoveEditorSystem hands it.

	Does not own: validation (MovePresentationTypes.Validate), the other notes (MoveEditorSystem
	.DescribeMove), or preloading (Client/Loading/AssetPreloader.lua).
]]

local MarketplaceService = game:GetService("MarketplaceService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local FXConstants = require(ReplicatedStorage.Shared.FXConstants)
local Logger = require(ReplicatedStorage.Shared.Logger)
local MovePresentationTypes = require(ReplicatedStorage.Shared.Combat.MovePresentationTypes)
local MoveTypes = require(ReplicatedStorage.Shared.MoveTypes)

local logger = Logger.scope("PresentationAudit")

local PresentationAudit = {}

export type AssetStatus = "Ok" | "Pending" | "Missing" | "WrongType"

-- Enum.AssetType values GetProductInfo reports as AssetTypeId.
local AUDIO = 3
local IMAGE = 1
local DECAL = 13

local TYPE_NAMES: { [number]: string } = {
	[1] = "an Image",
	[3] = "an Audio asset",
	[4] = "a Mesh",
	[10] = "a Model",
	[13] = "a Decal",
	[24] = "an Animation",
}

type CacheEntry = { Status: "Pending" | "Resolved" | "Missing", TypeId: number? }
local cache: { [string]: CacheEntry } = {}

-- Whether `typeId` is the right kind of asset for a field of `kind`, and if not, what it is.
local function kindMismatch(kind: MovePresentationTypes.AssetKind, typeId: number?): string?
	if kind == "Sound" then
		if typeId == AUDIO then
			return nil
		end
	elseif typeId == IMAGE then
		return nil
	elseif typeId == DECAL then
		return "a Decal (its Image has a different id -- use that one)"
	end
	return if typeId then TYPE_NAMES[typeId] or `asset type {typeId}` else "an unknown asset type"
end

-- The live answer for one id -- see this file's header. Never yields.
function PresentationAudit.AssetStatus(assetId: string, kind: MovePresentationTypes.AssetKind): (AssetStatus, string?)
	local entry = cache[assetId]
	if entry == nil then
		cache[assetId] = { Status = "Pending" }
		local numeric = tonumber(string.match(assetId, "(%d+)$"))
		task.spawn(function()
			local ok, info = pcall(function()
				return MarketplaceService:GetProductInfo(numeric :: number, Enum.InfoType.Asset)
			end)
			if ok and typeof(info) == "table" then
				cache[assetId] = { Status = "Resolved", TypeId = (info :: any).AssetTypeId }
			else
				cache[assetId] = { Status = "Missing" }
				logger:debug("Presentation asset did not resolve", { assetId = assetId, error = tostring(info) })
			end
		end)
		return "Pending", nil
	end
	if entry.Status == "Pending" then
		return "Pending", nil
	end
	if entry.Status == "Missing" then
		return "Missing", nil
	end
	local mismatch = kindMismatch(kind, entry.TypeId)
	if mismatch then
		return "WrongType", mismatch
	end
	return "Ok", nil
end

function PresentationAudit.TemplateExists(name: string): boolean
	local folder = ReplicatedStorage:FindFirstChild(FXConstants.MovePresentation.TemplateFolder)
	return folder ~= nil and folder:FindFirstChild(name) ~= nil
end

local function labelOf(moment: string): string
	local definition = MovePresentationTypes.Moment(moment)
	return if definition then definition.Label else moment
end

-- The notes for `move`'s presentation, in moment order. PURE given its two lookups.
function PresentationAudit.Describe(
	move: MoveTypes.MoveDefinition,
	assetStatus: (
		assetId: string,
		kind: MovePresentationTypes.AssetKind
	) -> (AssetStatus, string?),
	templateExists: (name: string) -> boolean
): { string }
	local notes: { string } = {}
	local presentation = move.Presentation
	if presentation == nil then
		return notes
	end
	local isProjectile = MoveTypes.IsProjectile(move)
	local isDomain = MoveTypes.IsDomain(move)

	for _, moment in MovePresentationTypes.Moments do
		if
			presentation[moment.Name] and not MovePresentationTypes.IsMomentLive(moment.Name, isProjectile, isDomain)
		then
			local note = if moment.Group == "Domain"
				then `Presentation: the "{moment.Label}" cue only plays for a move that opens a realm -- it is kept, but this move never plays it.`
				else `Presentation: the "{moment.Label}" cue only plays for a projectile move -- it is kept, but this melee move never plays it.`
			table.insert(notes, note)
		end
	end

	for _, ref in MovePresentationTypes.AssetRefs(presentation) do
		local status, detail = assetStatus(ref.AssetId, ref.Kind)
		local where = `Presentation, {labelOf(ref.Moment)} {ref.Field}`
		if status == "Pending" then
			table.insert(
				notes,
				`{where}: {ref.AssetId} is still being checked -- preview again to see whether it loads.`
			)
		elseif status == "Missing" then
			table.insert(
				notes,
				`{where}: {ref.AssetId} does not resolve (no such asset, or not one this game can load), so it plays nothing.`
			)
		elseif status == "WrongType" then
			local wanted = if ref.Kind == "Sound" then "a sound" else "an image"
			table.insert(notes, `{where}: {ref.AssetId} is {detail or "the wrong kind of asset"}, not {wanted}.`)
		end
	end

	for _, ref in MovePresentationTypes.TemplateRefs(presentation) do
		if not templateExists(ref.Name) then
			table.insert(
				notes,
				`Presentation, {labelOf(ref.Moment)}: template "{ref.Name}" is not in ReplicatedStorage.{FXConstants.MovePresentation.TemplateFolder}, so nothing plays.`
			)
		end
	end
	return notes
end

-- Spec-only: forget every cached answer.
function PresentationAudit.ResetForTesting(): ()
	table.clear(cache)
end

return PresentationAudit
