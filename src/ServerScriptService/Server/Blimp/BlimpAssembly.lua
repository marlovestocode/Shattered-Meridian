--!strict
--[[
	BlimpAssembly.lua

	Owns: ONE binding -- an airship hull's physics rig, which is Server/Vessel/VesselAssembly.lua reading
	BlimpConstants.Physics.

	READ Server/Vessel/VesselAssembly.lua's HEADER for what Build actually does and why: what a builder
	hands us and why none of it can be assumed, why the root is the largest part, why massless non-root
	parts are what make one set of force constants correct for every hull, and why the whole thing is
	recoverable rather than destructive. None of that is a fact about blimps.

	Does not own: the flight arithmetic (Server/Blimp/BlimpDrive.lua -- this rig only owns the constraints
	it is fed into), the mount (Server/Vessel/VesselMount.lua), or which parts are stations
	(Shared/Blimp/BlimpTagging.lua).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local BlimpConstants = require(ReplicatedStorage.Shared.Blimp.BlimpConstants)
local VesselAssembly = require(ServerScriptService.Server.Vessel.VesselAssembly)

export type Assembly = VesselAssembly.Assembly

return VesselAssembly.New({
	Scope = "Blimp",
	Physics = BlimpConstants.Physics,
})
