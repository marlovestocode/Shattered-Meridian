--!strict
--[[
	BoatSailLadder.lua

	Owns: ONE binding -- the sail rungs, which is Shared/Vessel/VesselSpeedLadder.lua reading
	BoatConstants.SailStates. Every rule about what a ladder is (saturate rather than wrap, find the
	neutral rung rather than write it down, nil rather than 0 for a malformed delta) lives in that
	module and its header; this file is the one line that says WHICH rungs a boat's rig has.

	WHY THE BINDING IS ITS OWN FILE rather than a VesselSpeedLadder.New(BoatConstants.SailStates) call
	at each call site: two of those call sites are on different machines -- the server's sailing loop
	and the client's sail gauge -- and a ladder is only useful if both are reading the SAME one. Two
	bindings would agree today and keep agreeing right up until somebody passed a bespoke per-hull rig
	in one of them, at which point the gauge would draw rungs the server did not believe in.

	THE RUNG IS CANVAS, NOT SPEED, which is the one thing that differs from the blimp binding next door
	and the only thing worth carrying in your head when reading a call site. VesselSpeedLadder calls the
	field Throttle because that is what it is on a telegraph; here it is a fraction of full sail, and
	the speed it produces still has to survive the wind's strength and the point of sail
	(Shared/Boat/BoatWind.lua) before it reaches the hull.

	Does not own: any of the behaviour (Shared/Vessel/VesselSpeedLadder.lua), the rungs themselves
	(BoatConstants.SailStates), which rung a given hull is on (Server/Systems/BoatSystem.lua), or how
	the ladder is drawn (Client/UI/Components/SpeedLadder.lua).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local VesselSpeedLadder = require(ReplicatedStorage.Shared.Vessel.VesselSpeedLadder)
local BoatConstants = require(script.Parent.BoatConstants)

export type Rung = VesselSpeedLadder.Rung

return VesselSpeedLadder.New(BoatConstants.SailStates :: { Rung })
