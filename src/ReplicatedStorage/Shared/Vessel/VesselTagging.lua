--!strict
--[[
	VesselTagging.lua

	Owns: turning what a builder tagged in Studio into the answers EVERY crewed vehicle asks -- "which
	parts of this model are stations, and of what kind", "which tagged model does this part belong to",
	"where does a mounted body stand and which way does that make the bow", and the two small readers
	(one positive-number Attribute, one uniquely-tagged part) that every vehicle's own tuning resolver
	is built out of. Nothing here touches physics, welds or remotes.

	LIFTED OUT OF Shared/Blimp/BlimpTagging.lua when the Boat layer arrived. Every rule below was
	discovered on blimps and is written down in the past tense for that reason -- the bugs are real and
	the arguments are the originals. What changed is only WHICH tag names the rules are applied to,
	which is now a parameter.

	A FACTORY, NOT A MODULE OF FREE FUNCTIONS, and the binding is the point rather than a style choice.
	Every function here needs at least two of { model tag, helm tag, handhold tag, stand attachment
	name, forward-yaw attribute, default stand reach }, and threading six names through eight call sites
	is six chances to pass a boat's helm tag with a blimp's stand attachment. New() takes them once;
	Shared/Blimp/BlimpTagging.lua and Shared/Boat/BoatTagging.lua are each one such binding plus their
	own vehicle-specific resolvers.

	THE ONE PRECEDENCE RULE, resolved here so no caller reasons about it: a part carrying BOTH the Helm
	and Handhold tags is a HELM. A helm is the strictly more capable station and the strictly rarer tag,
	so a part with both is far likelier to be a rail that got swept into a bulk helm-tag than a helm
	somebody meant to demote -- and resolving it the other way would silently turn the only steerable
	station on a hull into a passenger rail, which is the failure a player reports as "the wheel does
	nothing".

	TWO HELMS ON ONE MODEL is a build error rather than a two-pilot feature, and is reported as one:
	ResolveStations keeps the first it finds in descendant order and logs the rest. Deliberately not an
	assert -- an undriveable hull in the middle of a playtest is worse than one with a second inert
	wheel, and the log says exactly which parts collided.

	Does not own: the tag NAMES (each vehicle's own Constants file), which model is currently registered
	(each vehicle's own System), any vehicle-specific tuning resolution (BlimpTagging.ResolveTuning /
	BoatTagging.ResolveTuning -- both of which call PositiveOverride below and own the rest themselves),
	or the grip Attachments, which are looked up by Shared/Vessel/VesselArmPose.lua at pose time on the
	station part it is already holding.
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Logger = require(ReplicatedStorage.Shared.Logger)
local VesselTypes = require(script.Parent.VesselTypes)

local VesselTagging = {}

export type Station = VesselTypes.Station

-- What one vehicle layer binds this to. Every field is a name a BUILDER types in Studio, except
-- DefaultStandReach, which is the fallback used only for a station with no authored Stand Attachment.
export type Config = {
	-- Prefixes the logger scope, so a warning about a mis-tagged hull says which vehicle's contract it
	-- was read against ("BlimpTagging", "BoatTagging").
	Scope: string,
	ModelTag: string,
	HelmTag: string,
	HandholdTag: string,
	-- The Attachment on a station part that says exactly where a mounted body stands and which way it
	-- faces. Absent on the part -> ResolveStandOffset detects a side; see its own header.
	StandAttachment: string,
	-- The Model Attribute, in DEGREES, that overrides the detected bow outright.
	ForwardYawAttribute: string,
	-- Studs from the station part's centre to a detected stand position.
	DefaultStandReach: number,
}

export type Tagging = {
	ResolveStations: (model: Model) -> ({ Station }, BasePart?),
	ResolveEmitters: (model: Model, tag: string) -> { ParticleEmitter },
	ResolveSingleTagged: (model: Model, tag: string, label: string) -> BasePart?,
	ModelOf: (instance: Instance?) -> Model?,
	PositiveOverride: (model: Model, attributeName: string, fallback: number) -> number,
	ResolveStandOffset: (station: BasePart, model: Model) -> CFrame,
	ResolveForwardYaw: (model: Model, root: BasePart, helm: BasePart?, standOffset: CFrame?) -> number,
}

-- How far up an ancestry to look for the model tag before giving up. A station part inside a hull is
-- realistically one to four levels deep (Model > Gondola > Controls > Wheel); the bound exists so a
-- mis-tagged part somewhere in a deep world hierarchy costs a fixed walk rather than one proportional
-- to how nested the map happens to be. Same reasoning, same shape as ParkourTagging's own
-- MAX_ANCESTOR_DEPTH.
local MAX_ANCESTOR_DEPTH = 8

-- Studs below a candidate stand position to look for hull to stand on. Generous: a helm mounted at
-- chest height on a raised bridge is still only a few studs above its own deck, and a cast too short
-- simply finds nothing and falls through to the outboard test.
local DECK_PROBE_STUDS = 14

-- Studs of horizontal offset from the hull's centre below which a station carries no usable sense of
-- which way is outboard -- a wheel mounted dead amidships. Small on purpose: this only has to beat
-- modelling noise, and any fitting a player can walk around is several studs off the centre of the
-- hull it is bolted to.
local MIN_OUTBOARD_STUDS = 3

-- The signed yaw, about world +Y, that rotates `fromLook` onto `toLook` once both are flattened to the
-- horizontal -- i.e. the angle A for which CFrame.Angles(0, A, 0) turns one into the other. Flattened
-- because a bow is a compass direction: a Stand Attachment tilted a few degrees by hand must not be
-- read as the hull wanting to drive into the ground.
local function yawBetween(fromLook: Vector3, toLook: Vector3): number
	local from = Vector3.new(fromLook.X, 0, fromLook.Z)
	local to = Vector3.new(toLook.X, 0, toLook.Z)
	if from.Magnitude < 1e-4 or to.Magnitude < 1e-4 then
		-- One of them points straight up or down, so there is no heading to read off it. Zero is the
		-- honest answer (no correction) rather than an arbitrary one.
		return 0
	end
	from = from.Unit
	to = to.Unit

	local angle = math.acos(math.clamp(from:Dot(to), -1, 1))
	-- The cross product's Y component is the turn's handedness -- positive is the direction a positive
	-- CFrame.Angles(0, A, 0) actually rotates.
	if from:Cross(to).Y < 0 then
		return -angle
	end
	return angle
end

-- Which way is OUTBOARD at this station: the horizontal direction from the hull's centre out to the
-- station itself, or nil for a station too near the centre for that to mean anything. Flattened for
-- the same reason yawBetween flattens -- a fitting mounted high in the rigging is still fore or aft of
-- the centre, and its height is not part of the answer.
local function outboardDirection(station: BasePart, model: Model): Vector3?
	local bounds = model:GetBoundingBox()
	local offset = station.Position - bounds.Position
	local flat = Vector3.new(offset.X, 0, offset.Z)
	if flat.Magnitude < MIN_OUTBOARD_STUDS then
		return nil
	end
	return flat.Unit
end

-- One vehicle layer's bound reader. See this file's header on why the tag names are bound once here
-- rather than passed per call.
function VesselTagging.New(config: Config): Tagging
	local logger = Logger.scope(config.Scope .. "Tagging")

	local tagging = {}

	-- Every station in `model`, in descendant order, with the both-tags and two-helms rules of this
	-- file's header already applied. Returns the helm separately because every caller that wants it
	-- wants it as "the one helm, or nil" and would otherwise re-scan the list for it.
	function tagging.ResolveStations(model: Model): ({ Station }, BasePart?)
		local stations: { Station } = {}
		local helm: BasePart? = nil

		for _, descendant in model:GetDescendants() do
			if not descendant:IsA("BasePart") then
				continue
			end
			local part = descendant :: BasePart

			local isHelm = CollectionService:HasTag(part, config.HelmTag)
			local isHandhold = CollectionService:HasTag(part, config.HandholdTag)
			if not isHelm and not isHandhold then
				continue
			end

			-- Helm wins a part carrying both -- see this file's header.
			if isHelm then
				if helm then
					logger:warn("Model has more than one helm; ignoring the extra", {
						model = model:GetFullName(),
						keeping = helm:GetFullName(),
						ignoring = part:GetFullName(),
					})
					-- Demoted rather than dropped: a second wheel is still somewhere a player can stand
					-- and hold on, and silently deleting a station a builder tagged would be a worse
					-- surprise than an extra handhold.
					if isHandhold then
						table.insert(stations, { Part = part, Kind = "Handhold" :: VesselTypes.StationKind })
					end
					continue
				end
				helm = part
				table.insert(stations, { Part = part, Kind = "Helm" :: VesselTypes.StationKind })
			else
				table.insert(stations, { Part = part, Kind = "Handhold" :: VesselTypes.StationKind })
			end
		end

		return stations, helm
	end

	-- Every ParticleEmitter beneath every part in `model` carrying `tag` -- a blimp's thrust exhaust, a
	-- boat's wake spray. Emitters rather than the tagged parts themselves, because that is what the
	-- caller actually toggles; returning the parts would push one more descendant walk onto every
	-- consumer, and the walk is the only work here.
	--
	-- THE TAG IS A PARAMETER, unlike every other name on this factory, because one hull can plausibly
	-- have several such sets (spray at the bow, foam at the stern) and binding one of them at New()
	-- would make the second one impossible to ask for without a second factory.
	--
	-- Resolved ONCE at registration, like the stations are. An emitter added to a live hull is not
	-- picked up until it re-registers, which the Tag Editor does for free (remove the tag, add it back)
	-- and which is the right trade for not carrying a DescendantAdded listener per hull for the whole
	-- session.
	function tagging.ResolveEmitters(model: Model, tag: string): { ParticleEmitter }
		local emitters: { ParticleEmitter } = {}
		for _, descendant in model:GetDescendants() do
			if not descendant:IsA("BasePart") then
				continue
			end
			if not CollectionService:HasTag(descendant, tag) then
				continue
			end
			for _, child in descendant:GetDescendants() do
				if child:IsA("ParticleEmitter") then
					table.insert(emitters, child :: ParticleEmitter)
				end
			end
		end
		return emitters
	end

	-- The ONE part in `model` carrying `tag`, or nil if a builder hasn't tagged one. `label` is what a
	-- warning calls it ("furnace", "capstan") -- passed in rather than derived from the tag string so
	-- the message reads as English rather than as a tag name.
	--
	-- Warns (and keeps the first) rather than erroring if a builder tags more than one part -- the same
	-- "an extra is a build error, not a feature" rule this file's header gives for a second Helm. An
	-- ABSENT tag is never an error here: every optional station in this codebase means "this hull does
	-- not have that fitting", not "this hull is broken".
	function tagging.ResolveSingleTagged(model: Model, tag: string, label: string): BasePart?
		local found: BasePart? = nil
		for _, descendant in model:GetDescendants() do
			if descendant:IsA("BasePart") and CollectionService:HasTag(descendant, tag) then
				if found then
					logger:warn("Model has more than one " .. label .. "; ignoring the extra", {
						model = model:GetFullName(),
						keeping = found:GetFullName(),
						ignoring = descendant:GetFullName(),
					})
					continue
				end
				found = descendant :: BasePart
			end
		end
		return found
	end

	-- The tagged Model this instance sits inside, or nil. Walks the ancestry rather than checking the
	-- instance itself only, because every caller holds a STATION PART (a prompt fired, a weld broke)
	-- and the tag that matters is on the model above it.
	function tagging.ModelOf(instance: Instance?): Model?
		local current = instance
		local depth = 0
		while current and depth < MAX_ANCESTOR_DEPTH do
			if current:IsA("Model") and CollectionService:HasTag(current, config.ModelTag) then
				return current
			end
			current = current.Parent
			depth += 1
		end
		return nil
	end

	-- Reads one optional positive-number Attribute override off the model, falling back to `fallback`.
	-- A non-number, or a number that is not finite and positive, is logged and ignored rather than
	-- honoured: an Attribute is a text field a person types into, and a hull with CruiseSpeed set to 0
	-- by a typo is an undriveable hull that produces no error anywhere.
	function tagging.PositiveOverride(model: Model, attributeName: string, fallback: number): number
		local raw = model:GetAttribute(attributeName)
		if raw == nil then
			return fallback
		end
		if typeof(raw) ~= "number" then
			logger:warn("Ignoring non-number tuning Attribute", {
				model = model:GetFullName(),
				attribute = attributeName,
			})
			return fallback
		end
		local value = raw :: number
		if value ~= value or value <= 0 or value == math.huge then
			logger:warn("Ignoring non-positive tuning Attribute", {
				model = model:GetFullName(),
				attribute = attributeName,
				value = value,
			})
			return fallback
		end
		return value
	end

	-- Where a mounted body sits, in `station`'s own space, and which way it faces.
	--
	-- An authored Stand Attachment wins outright -- that is the builder saying exactly where, and it is
	-- both the recommended way to finish a hull and the fix for any hull the default guesses wrong on.
	--
	-- The DEFAULT is the interesting part. A station part's Z axis is a modelling artefact, so "one
	-- step back from the wheel" has two candidate answers and no way to choose between them from the
	-- part alone. Two tests, in this order:
	--
	--   1. DECK. A ray dropped from each candidate. A side with nothing under it is not a side anybody
	--      can stand on, so if exactly one candidate has hull beneath it, that one wins outright.
	--   2. OUTBOARD. When both sides have deck -- a fitting on a continuous deck, which is the common
	--      case -- or neither does, stand on the HULL side of the fitting and face out over it. Right
	--      for a rail by inspection, and right for a wheel because a helm sits forward of the crew it
	--      commands, so facing outward from the hull's centre through the wheel is facing the bow.
	--
	-- TEST 1 USED TO BE THE WHOLE RULE, ranked by whose hit was NEAREST, and that was one bug that read
	-- as two. On any flat deck both rays hit at the same height, so the comparison was a tie, the tie
	-- fell to whichever candidate happened to be tested first, and the "detection" quietly collapsed to
	-- the +Z face of the wheel mesh -- the exact modelling artefact this function exists in order not to
	-- depend on. And because ResolveForwardYaw derives the bow from where the pilot ends up looking,
	-- losing that coin flip put the pilot on the wrong side of the wheel AND sent the hull astern on W,
	-- as two apparently unrelated bugs.
	--
	-- Both candidates face the station either way: a pilot with their back to the wheel was the first
	-- version's actual bug, and is never what anyone wants.
	function tagging.ResolveStandOffset(station: BasePart, model: Model): CFrame
		local authored = station:FindFirstChild(config.StandAttachment)
		if authored and authored:IsA("Attachment") then
			return (authored :: Attachment).CFrame
		end

		local reach = config.DefaultStandReach
		-- Both candidates look AT the station: from +Z that is the identity rotation (a CFrame's
		-- LookVector is its -Z), from -Z it is a half turn.
		local candidates = {
			CFrame.new(0, 0, reach),
			CFrame.new(0, 0, -reach) * CFrame.Angles(0, math.pi, 0),
		}

		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Include
		params.FilterDescendantsInstances = { model }
		params.RespectCanCollide = false

		-- Presence only, never distance -- see this function's header on what ranking by distance
		-- actually decided.
		local supported: { boolean } = {}
		local supportedCount = 0
		for index, candidate in candidates do
			local origin = (station.CFrame * candidate).Position
			local hit = Workspace:Raycast(origin, Vector3.new(0, -DECK_PROBE_STUDS, 0), params)
			supported[index] = hit ~= nil
			if hit then
				supportedCount += 1
			end
		end

		if supportedCount == 1 then
			return if supported[1] then candidates[1] else candidates[2]
		end

		local outboard = outboardDirection(station, model)
		if outboard then
			local best: CFrame? = nil
			local bestDot = -math.huge
			for _, candidate in candidates do
				-- The candidate's FACING, not its position: the winner is the one that looks outboard,
				-- which is by construction the one standing on the hull side of the fitting.
				local dot = (station.CFrame * candidate).LookVector:Dot(outboard)
				if dot > bestDot then
					bestDot = dot
					best = candidate
				end
			end
			if best then
				return best
			end
		end

		-- A station dead amidships with deck on both sides, or on neither. Nothing left to read; the
		-- arbitrary answer is all there is, and it is at least documented as arbitrary -- add a Stand
		-- Attachment.
		return candidates[1]
	end

	-- THE BOW IS WHERE THE PILOT LOOKS. That is the whole rule, and making it the rule rather than a
	-- second independent setting is what collapses two configuration problems into one: get the pilot
	-- standing right and the hull travels the way they are facing, necessarily. The first version of
	-- this had the two derived separately -- the stand side off the helm's Z axis, the bow off the root
	-- mesh's -- and shipped a blimp whose pilot stood the wrong side of the wheel AND flew backwards, as
	-- two apparently unrelated bugs. They were the same bug twice.
	--
	-- Precedence:
	--   1. The ForwardYaw Attribute on the Model, in degrees. Explicit, wins outright, and is the
	--      one-field answer to "my hull still travels the wrong way" -- type 180. Note it does NOT move
	--      the pilot, so a hull that needs this also wants its Stand Attachment turned to match.
	--   2. The pilot's own facing at the helm -- the Stand Attachment's if the builder placed one, the
	--      deck-detected default otherwise (see ResolveStandOffset). No authoring needed for the common
	--      case.
	--   3. No helm at all -> 0. A hull nobody can steer has no bow worth arguing about.
	--
	-- Returned as a hull-RELATIVE offset rather than a world direction, which is what keeps it valid as
	-- the hull turns -- a world "forward" would be correct only until the first steer input.
	function tagging.ResolveForwardYaw(model: Model, root: BasePart, helm: BasePart?, standOffset: CFrame?): number
		local raw = model:GetAttribute(config.ForwardYawAttribute)
		if typeof(raw) == "number" then
			local degrees = raw :: number
			if degrees == degrees and degrees ~= math.huge and degrees ~= -math.huge then
				return math.rad(degrees)
			end
			logger:warn("Ignoring unusable " .. config.ForwardYawAttribute, { model = model:GetFullName() })
		elseif raw ~= nil then
			logger:warn("Ignoring non-number " .. config.ForwardYawAttribute, { model = model:GetFullName() })
		end

		if helm and standOffset then
			return yawBetween(root.CFrame.LookVector, (helm.CFrame * standOffset).LookVector)
		end

		return 0
	end

	return tagging
end

return VesselTagging
