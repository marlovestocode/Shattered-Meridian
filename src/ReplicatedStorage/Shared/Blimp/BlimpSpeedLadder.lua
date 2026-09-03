--!strict
--[[
	BlimpSpeedLadder.lua

	Owns: ONE binding -- the airship engine telegraph, which is Shared/Vessel/VesselSpeedLadder.lua
	reading BlimpConstants.SpeedStates. Every rule about what a ladder is (saturate rather than wrap,
	find the neutral rung rather than write it down, nil rather than 0 for a malformed delta) lives in
	that module and its header; this file is the one line that says WHICH rungs the blimp's telegraph
	has.

	WHY THE BINDING IS ITS OWN FILE rather than a `VesselSpeedLadder.New(BlimpConstants.SpeedStates)`
	call at each of its three call sites. Two of those call sites are on different machines -- the
	server's flight loop and the client's gauge -- and a ladder is only useful if both are reading the
	SAME one. Two bindings of the same table would agree today and would keep agreeing right up until
	somebody passed a bespoke per-hull ladder in one of them, at which point the gauge would draw rungs
	the server did not believe in. One binding, one module, one answer.

	Does not own: any of the behaviour (Shared/Vessel/VesselSpeedLadder.lua), the rungs themselves
	(BlimpConstants.SpeedStates), which rung a given hull is on (Server/Systems/BlimpSystem.lua), or how
	the ladder is drawn (Client/UI/Components/SpeedLadder.lua).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local VesselSpeedLadder = require(ReplicatedStorage.Shared.Vessel.VesselSpeedLadder)
local BlimpConstants = require(script.Parent.BlimpConstants)

export type Rung = VesselSpeedLadder.Rung

return VesselSpeedLadder.New(BlimpConstants.SpeedStates :: { Rung })
