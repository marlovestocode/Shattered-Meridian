--!strict
--[[
	BoatArmPose.lua

	Owns: ONE binding -- a boat's hands-on-the-wheel solver, which is Shared/Vessel/VesselArmPose.lua
	reading BoatConstants.Attachments (the two grip Attachment names a builder may author) and
	BoatConstants.Pose (the fallback grip width and the elbow pole).

	READ Shared/Vessel/VesselArmPose.lua's HEADER for everything that matters here: why this is
	client-side presentation rather than a server write, why Motor6D.Transform is the only channel that
	can beat a playing idle clip, why the mount broadcast is therefore FireAllClients, and why the caller
	must drive Apply above Enum.RenderPriority.Character.

	Does not own: any of the solve (Shared/Vessel/VesselArmPose.lua), the Attachment names or the tuning
	(BoatConstants), who is mounted (Server/Systems/BoatSystem.lua), or the body weld
	(Server/Vessel/VesselMount.lua).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local VesselArmPose = require(ReplicatedStorage.Shared.Vessel.VesselArmPose)
local BoatConstants = require(script.Parent.BoatConstants)

return VesselArmPose.New({
	LeftGrip = BoatConstants.Attachments.LeftGrip,
	RightGrip = BoatConstants.Attachments.RightGrip,
	FallbackGripHalfWidth = BoatConstants.Pose.FallbackGripHalfWidth,
	FallbackGripMaxHalfWidth = BoatConstants.Pose.FallbackGripMaxHalfWidth,
	ElbowPoleSign = BoatConstants.Pose.ElbowPoleSign,
	MaxReachFraction = BoatConstants.Pose.MaxReachFraction,
})
