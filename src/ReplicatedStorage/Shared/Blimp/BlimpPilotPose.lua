--!strict
--[[
	BlimpPilotPose.lua

	Owns: ONE binding -- a blimp helmsman's lean, which is Shared/Vessel/VesselPilotPose.lua reading
	BlimpConstants.Lean.

	READ Shared/Vessel/VesselPilotPose.lua's HEADER, and Shared/Vessel/VesselArmPose.lua's before it.
	Everything about why the lean is physics-driven rather than authored, why the roll and pitch channels
	deliberately pull in opposite directions, and why the pose overwrites the idle clip's torso instead of
	composing onto it lives there. None of it is a fact about blimps.

	THE THIRD MOTION CHANNEL IS THIS HULL'S CLIMB RATE. VesselPilotPose calls that argument
	`verticalRate`, because a boat feeds its heave off a swell into the same coefficient -- the body does
	not care which of the two lifted it. Client/Blimp/BlimpController.lua passes the camera sample's
	ClimbRate.

	Does not own: any of the springs (Shared/Vessel/VesselPilotPose.lua), the coefficients
	(BlimpConstants.Lean), measuring the hull (Client/Camera/BlimpCamera.lua's sample, via
	Shared/Blimp/BlimpCameraMath.Observe), or who is mounted (Server/Systems/BlimpSystem.lua).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local VesselPilotPose = require(ReplicatedStorage.Shared.Vessel.VesselPilotPose)
local BlimpConstants = require(script.Parent.BlimpConstants)

export type State = VesselPilotPose.State

return VesselPilotPose.New(BlimpConstants.Lean)
