--!strict
--[[
	BoatAssembly.lua

	Owns: ONE binding -- a boat hull's physics rig, which is Server/Vessel/VesselAssembly.lua reading
	BoatConstants.Physics.

	READ Server/Vessel/VesselAssembly.lua's HEADER for what Build actually does and why: what a builder
	hands us and why none of it can be assumed, why the root is the largest part, why massless non-root
	parts are what make one set of force constants correct for every hull, and why the whole thing is
	recoverable rather than destructive. None of that is a fact about boats.

	Does not own: the sailing arithmetic (Server/Boat/BoatDrive.lua -- this rig only owns the constraints
	it is fed into), the mount (Server/Vessel/VesselMount.lua), or which parts are stations
	(Shared/Boat/BoatTagging.lua).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local BoatConstants = require(ReplicatedStorage.Shared.Boat.BoatConstants)
local VesselAssembly = require(ServerScriptService.Server.Vessel.VesselAssembly)

export type Assembly = VesselAssembly.Assembly

return VesselAssembly.New({
	Scope = "Boat",
	Physics = BoatConstants.Physics,
})
