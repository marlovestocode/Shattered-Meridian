--!strict
--[[
	BoatPilotPose.lua

	Owns: ONE binding -- a helmsman's lean aboard a boat, which is Shared/Vessel/VesselPilotPose.lua
	reading BoatConstants.Lean.

	READ Shared/Vessel/VesselPilotPose.lua's HEADER, and Shared/Vessel/VesselArmPose.lua's before it.

	THE THIRD MOTION CHANNEL IS THIS HULL'S HEAVE RATE. VesselPilotPose calls that argument
	`verticalRate` precisely so it can be a blimp's commanded climb in one binding and a boat's rise off
	a swell in this one -- the body does not care which of the two lifted it, only that the deck came up
	under its feet. Client/Boat/BoatController.lua passes the camera sample's own heave.

	Does not own: any of the springs (Shared/Vessel/VesselPilotPose.lua), the coefficients
	(BoatConstants.Lean), measuring the hull (Client/Camera/BoatCamera.lua's sample), or who is mounted
	(Server/Systems/BoatSystem.lua).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local VesselPilotPose = require(ReplicatedStorage.Shared.Vessel.VesselPilotPose)
local BoatConstants = require(script.Parent.BoatConstants)

export type State = VesselPilotPose.State

return VesselPilotPose.New(BoatConstants.Lean)
