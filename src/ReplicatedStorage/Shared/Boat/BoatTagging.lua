--!strict
--[[
	BoatTagging.lua

	Owns: the boat half of the read side of BoatConstants.lua's authoring contract -- this hull's sailing
	tuning and its wake emitters -- plus the ONE binding of Shared/Vessel/VesselTagging.lua that supplies
	everything else (stations, the model walk, where a mounted body stands, and which way that makes the
	bow).

	SEPARATE FROM BoatConstants.lua for the reason ParkourTagging.lua is separate from
	ParkourConstants.lua: the constants file is the contract a BUILDER reads, and it must stay readable
	as a contract. The moment resolution logic lives beside it, the tag names stop being findable in the
	noise.

	THE GENERIC RULES ARE NOT REPEATED HERE. Which part wins when one carries both the Helm and Handhold
	tags, what a second helm on one model means, how the stand side is detected when a builder authored
	no Stand Attachment, and why the bow is derived from where the pilot ends up looking rather than
	authored separately -- all of that is Shared/Vessel/VesselTagging.lua's, and its header is where the
	arguments (and the bugs behind them) are written down. What is left in this file is exactly the part
	that is about BOATS.

	NOTE WHAT IS NOT HERE: the water. BoatConstants.Tags.Water goes on the WORLD, not on a vessel, so it
	is resolved by Server/Boat/BoatWater.lua against the whole DataModel rather than by walking one
	model's descendants. Everything in this file takes a Model; a function here that took none would be
	the tell that it did not belong.

	Does not own: the tag NAMES (BoatConstants.Tags), which model is currently registered
	(Server/Systems/BoatSystem.lua's own registry), the water (Server/Boat/BoatWater.lua), or the grip
	Attachments -- those are looked up by Shared/Vessel/VesselArmPose.lua at pose time, on the station
	part it is already holding.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local VesselTagging = require(ReplicatedStorage.Shared.Vessel.VesselTagging)
local BoatConstants = require(script.Parent.BoatConstants)
local BoatTypes = require(script.Parent.BoatTypes)

local vessel = VesselTagging.New({
	Scope = "Boat",
	ModelTag = BoatConstants.Tags.Model,
	HelmTag = BoatConstants.Tags.Helm,
	HandholdTag = BoatConstants.Tags.Handhold,
	StandAttachment = BoatConstants.Attachments.Stand,
	ForwardYawAttribute = BoatConstants.ModelAttributes.ForwardYaw,
	DefaultStandReach = BoatConstants.Mount.DefaultStandReach,
})

local BoatTagging = {}

export type Station = VesselTagging.Station

-- Re-exposed under this layer's own name rather than made call sites reach for two modules. These are
-- the vessel binding verbatim -- read Shared/Vessel/VesselTagging.lua for what each one does.
BoatTagging.ResolveStations = vessel.ResolveStations
BoatTagging.ModelOf = vessel.ModelOf
BoatTagging.ResolveStandOffset = vessel.ResolveStandOffset
BoatTagging.ResolveForwardYaw = vessel.ResolveForwardYaw

-- Every ParticleEmitter that should run while the hull is making way: all of them, beneath every part
-- carrying the Wake tag.
function BoatTagging.ResolveWakeEmitters(model: Model): { ParticleEmitter }
	return vessel.ResolveEmitters(model, BoatConstants.Tags.Wake)
end

-- This boat's sailing tuning: BoatConstants.Drive, with any per-model Attribute overrides applied. Read
-- once at registration rather than per tick -- retuning a live boat means re-registering it, which is
-- what CollectionService:RemoveTag/AddTag already does for free from the Tag Editor.
--
-- ONLY FOUR NUMBERS ARE OVERRIDABLE, and which four is the interesting part. HullSpeed and TurnRate are
-- the two a designer distinguishes a skiff from a trader with. WaterlineOffset has to be per-model
-- because it depends entirely on where the artist put the hull's largest part, and is the one override
-- most hulls will actually set. LeewayFraction is per-model because draught is a property of the boat
-- -- a shallow skiff really does slide downwind where a deep-keeled trader does not.
--
-- Everything else is NOT overridable, and deliberately: the acceleration ramps, the rudder-authority
-- curve, the heel coefficients and the whole wind polar are what make every boat in the game feel like
-- the same class of object. A per-model override on any of them is how two boats end up feeling like
-- two different games -- the identical argument BlimpTagging.ResolveTuning makes about its own ramps.
--
-- WaterlineOffset IS READ THROUGH THE POSITIVE-ONLY READER, which means a hull whose root genuinely
-- sits BELOW its waterline (a deep-keeled model whose largest part is the keel) cannot express that as
-- a negative number. That is a real limitation and not an oversight: it is one Attribute away from
-- being fixable if a hull ever needs it, and until one does, a signed reader here would mean a typo of
-- -20 silently sinks a boat with nothing in any log. Move the model's PrimaryPart to the hull instead,
-- which is what VesselAssembly.chooseRoot already honours.
function BoatTagging.ResolveTuning(model: Model): BoatTypes.DriveTuning
	local drive = BoatConstants.Drive
	local attributes = BoatConstants.ModelAttributes

	return {
		-- Filled in by ResolveForwardYaw, which needs geometry this function deliberately does not take.
		ForwardYawRadians = 0,
		HullSpeed = vessel.PositiveOverride(model, attributes.HullSpeed, drive.HullSpeed),
		SternwaySpeed = drive.SternwaySpeed,
		Acceleration = drive.Acceleration,
		Deceleration = drive.Deceleration,
		TurnRate = vessel.PositiveOverride(model, attributes.TurnRate, drive.TurnRate),
		TurnAcceleration = drive.TurnAcceleration,
		MinRudderAuthority = drive.MinRudderAuthority,
		RudderAuthorityFullAtSpeedFraction = drive.RudderAuthorityFullAtSpeedFraction,
		LeewayFraction = vessel.PositiveOverride(model, attributes.LeewayFraction, drive.LeewayFraction),
		WaterlineOffset = vessel.PositiveOverride(model, attributes.WaterlineOffset, drive.WaterlineOffset),
		HeaveSpeed = drive.HeaveSpeed,
		HeaveAcceleration = drive.HeaveAcceleration,
		HeelRadiansPerTurnRate = drive.HeelRadiansPerTurnRate,
		HeelRadiansPerWindPressure = drive.HeelRadiansPerWindPressure,
		MaxHeelRadians = drive.MaxHeelRadians,
		TrimRadiansPerAccel = drive.TrimRadiansPerAccel,
		MaxTrimRadians = drive.MaxTrimRadians,
	}
end

return BoatTagging
