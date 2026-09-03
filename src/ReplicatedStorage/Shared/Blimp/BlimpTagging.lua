--!strict
--[[
	BlimpTagging.lua

	Owns: the airship half of the read side of BlimpConstants.lua's authoring contract -- this blimp's
	flight tuning, its fuel tuning, its furnace station and its thrust emitters -- plus the ONE binding
	of Shared/Vessel/VesselTagging.lua that supplies everything else (stations, the model walk, where a
	mounted body stands, and which way that makes the bow).

	SEPARATE FROM BlimpConstants.lua for the same reason ParkourTagging.lua is separate from
	ParkourConstants.lua: the constants file is the contract a BUILDER reads, and it must stay readable
	as a contract. The moment resolution logic lives beside it, the tag names stop being findable in the
	noise. Same split, same reason, and BlimpSystem requires both.

	THE GENERIC RULES ARE NOT REPEATED HERE. Which part wins when one carries both the Helm and Handhold
	tags, what a second helm on one model means, how the stand side is detected when a builder authored
	no Stand Attachment, and why the bow is derived from where the pilot ends up looking rather than
	authored separately -- all of that is Shared/Vessel/VesselTagging.lua's, and its header is where the
	arguments (and the bugs behind them) are written down. What is left in this file is exactly the part
	that is about AIRSHIPS: an altitude band, a coal-and-water furnace, and a set of emitters that burn
	under thrust.

	Does not own: the tag NAMES (BlimpConstants.Tags), which model is currently registered
	(Server/Systems/BlimpSystem.lua's own registry), or the grip Attachments -- those are looked up by
	Shared/Vessel/VesselArmPose.lua at pose time, on the station part it is already holding, because the
	pose is per-frame client work and routing it through here would mean caching geometry the solver
	re-reads anyway.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Logger = require(ReplicatedStorage.Shared.Logger)
local VesselTagging = require(ReplicatedStorage.Shared.Vessel.VesselTagging)
local BlimpConstants = require(script.Parent.BlimpConstants)
local BlimpTypes = require(script.Parent.BlimpTypes)

local logger = Logger.scope("BlimpTagging")

local vessel = VesselTagging.New({
	Scope = "Blimp",
	ModelTag = BlimpConstants.Tags.Model,
	HelmTag = BlimpConstants.Tags.Helm,
	HandholdTag = BlimpConstants.Tags.Handhold,
	StandAttachment = BlimpConstants.Attachments.Stand,
	ForwardYawAttribute = BlimpConstants.ModelAttributes.ForwardYaw,
	DefaultStandReach = BlimpConstants.Mount.DefaultStandReach,
})

local BlimpTagging = {}

export type Station = VesselTagging.Station

-- Re-exposed under this layer's own name rather than made call sites reach for two modules. These are
-- the vessel binding verbatim -- read Shared/Vessel/VesselTagging.lua for what each one does.
BlimpTagging.ResolveStations = vessel.ResolveStations
BlimpTagging.ModelOf = vessel.ModelOf
BlimpTagging.ResolveStandOffset = vessel.ResolveStandOffset
BlimpTagging.ResolveForwardYaw = vessel.ResolveForwardYaw

-- Every ParticleEmitter that should burn while the pilot is under power: all of them, beneath every part
-- in `model` carrying the Exhaust tag.
--
-- A TAG RATHER THAN "every emitter in the model", because those are not the same set and the difference
-- is invisible until it bites: a blimp with an ambient smoke plume off the furnace, or dust motes in the
-- gondola, would have them cut out every time the pilot eased off the throttle. The tag says which
-- emitters are THRUST, which is a thing only the builder knows.
function BlimpTagging.ResolveExhaustEmitters(model: Model): { ParticleEmitter }
	return vessel.ResolveEmitters(model, BlimpConstants.Tags.Exhaust)
end

-- This blimp's flight tuning: BlimpConstants.Drive, with any per-model Attribute overrides applied. Read
-- once at registration rather than per tick -- retuning a live blimp means re-registering it, which is
-- what CollectionService:RemoveTag/AddTag already does for free from the Tag Editor.
--
-- Only the five numbers a builder can plausibly want per-hull are overridable. The acceleration ramps and
-- the bank are NOT: they are what makes every blimp in the game feel like the same class of object, and a
-- per-model override on them is how two blimps end up feeling like two different games.
function BlimpTagging.ResolveTuning(model: Model): BlimpTypes.DriveTuning
	local drive = BlimpConstants.Drive
	local attributes = BlimpConstants.ModelAttributes

	local minAltitude = vessel.PositiveOverride(model, attributes.MinAltitude, drive.MinAltitude)
	local maxAltitude = vessel.PositiveOverride(model, attributes.MaxAltitude, drive.MaxAltitude)
	if maxAltitude <= minAltitude then
		logger:warn("Altitude band is inverted; falling back to the defaults", {
			model = model:GetFullName(),
			min = minAltitude,
			max = maxAltitude,
		})
		minAltitude = drive.MinAltitude
		maxAltitude = drive.MaxAltitude
	end

	return {
		-- Filled in by ResolveForwardYaw, which needs geometry this function deliberately does not take.
		ForwardYawRadians = 0,
		CruiseSpeed = vessel.PositiveOverride(model, attributes.CruiseSpeed, drive.CruiseSpeed),
		ReverseSpeed = drive.ReverseSpeed,
		Acceleration = drive.Acceleration,
		TurnRate = vessel.PositiveOverride(model, attributes.TurnRate, drive.TurnRate),
		TurnAcceleration = drive.TurnAcceleration,
		ClimbSpeed = vessel.PositiveOverride(model, attributes.ClimbSpeed, drive.ClimbSpeed),
		ClimbAcceleration = drive.ClimbAcceleration,
		BankRadiansPerTurnRate = drive.BankRadiansPerTurnRate,
		MinAltitude = minAltitude,
		MaxAltitude = maxAltitude,
	}
end

-- The furnace -- the ONE station both coal and water are loaded at, or nil if a builder hasn't tagged
-- one -- see BlimpConstants.Tags.Furnace's own comment on why there is no separate water-tank tag, and
-- on what "absent" means (this hull reads as having no fuel system at all, never as "cannot fly").
-- Resolved once at registration, like every other tag lookup in this file.
function BlimpTagging.ResolveFuelStation(model: Model): BasePart?
	return vessel.ResolveSingleTagged(model, BlimpConstants.Tags.Furnace, "furnace")
end

-- This blimp's fuel tuning: BlimpConstants.Fuel, with any per-model Attribute overrides applied -- same
-- per-hull-override shape as ResolveTuning above, read once at registration for the same reason. A
-- Minimum that ends up above its own Capacity (an override typo, most likely) can never be satisfied --
-- the hull would be permanently grounded regardless of how full its tank gets -- so that pairing falls
-- back to the shipped defaults entirely rather than shipping an unflyable blimp.
function BlimpTagging.ResolveFuelTuning(model: Model): BlimpTypes.FuelTuning
	local fuel = BlimpConstants.Fuel
	local attributes = BlimpConstants.ModelAttributes

	local coalCapacity = vessel.PositiveOverride(model, attributes.CoalCapacity, fuel.CoalCapacity)
	local coalMinimum = vessel.PositiveOverride(model, attributes.CoalMinimum, fuel.CoalMinimum)
	if coalMinimum > coalCapacity then
		logger:warn("Coal minimum exceeds coal capacity; falling back to the defaults", {
			model = model:GetFullName(),
			minimum = coalMinimum,
			capacity = coalCapacity,
		})
		coalCapacity = fuel.CoalCapacity
		coalMinimum = fuel.CoalMinimum
	end

	local waterCapacity = vessel.PositiveOverride(model, attributes.WaterCapacity, fuel.WaterCapacity)
	local waterMinimum = vessel.PositiveOverride(model, attributes.WaterMinimum, fuel.WaterMinimum)
	if waterMinimum > waterCapacity then
		logger:warn("Water minimum exceeds water capacity; falling back to the defaults", {
			model = model:GetFullName(),
			minimum = waterMinimum,
			capacity = waterCapacity,
		})
		waterCapacity = fuel.WaterCapacity
		waterMinimum = fuel.WaterMinimum
	end

	return {
		CoalCapacity = coalCapacity,
		WaterCapacity = waterCapacity,
		CoalMinimum = coalMinimum,
		WaterMinimum = waterMinimum,
		CoalBurnPerSecond = vessel.PositiveOverride(model, attributes.CoalBurnRate, fuel.CoalBurnPerSecond),
		WaterBurnPerSecond = vessel.PositiveOverride(model, attributes.WaterBurnRate, fuel.WaterBurnPerSecond),
	}
end

return BlimpTagging
