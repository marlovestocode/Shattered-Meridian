--!strict
--[[
	BlimpArmPose.lua

	Owns: ONE binding -- a blimp's hands-on-the-wheel solver, which is Shared/Vessel/VesselArmPose.lua
	reading BlimpConstants.Attachments (the two grip Attachment names a builder may author) and
	BlimpConstants.Pose (the fallback grip width and the elbow pole).

	READ Shared/Vessel/VesselArmPose.lua's HEADER for everything that matters here: why this is
	client-side presentation rather than a server write, why Motor6D.Transform is the only channel that
	can beat a playing idle clip, why the mount broadcast is therefore FireAllClients, and why the caller
	must drive Apply above Enum.RenderPriority.Character. None of that is repeated in this file, because
	none of it is a fact about blimps.

	Does not own: any of the solve (Shared/Vessel/VesselArmPose.lua), the Attachment names or the tuning
	(BlimpConstants), who is mounted (Server/Systems/BlimpSystem.lua), or the body weld
	(Server/Vessel/VesselMount.lua).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local VesselArmPose = require(ReplicatedStorage.Shared.Vessel.VesselArmPose)
local BlimpConstants = require(script.Parent.BlimpConstants)

return VesselArmPose.New({
	LeftGrip = BlimpConstants.Attachments.LeftGrip,
	RightGrip = BlimpConstants.Attachments.RightGrip,
	FallbackGripHalfWidth = BlimpConstants.Pose.FallbackGripHalfWidth,
	FallbackGripMaxHalfWidth = BlimpConstants.Pose.FallbackGripMaxHalfWidth,
	ElbowPoleSign = BlimpConstants.Pose.ElbowPoleSign,
	MaxReachFraction = BlimpConstants.Pose.MaxReachFraction,
})
