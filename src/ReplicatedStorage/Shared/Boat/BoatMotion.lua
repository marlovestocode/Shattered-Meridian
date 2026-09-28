--!strict
--[[
	BoatMotion.lua

	Owns: ONE binding -- how hard a boat hull's replicated physics is filtered before anything reads it,
	which is Shared/Vessel/VesselMotion.lua reading BoatConstants.Camera.Smoothing.

	READ Shared/Vessel/VesselMotion.lua's HEADER for what a sample actually is and why: why every signal
	is in the hull's own frame, why the forward axis is flattened, why the first frame reports no
	acceleration, and why nothing here is ever a number the server sent.

	IT READS THE CAMERA'S SMOOTHING TABLE, and that is worth one line rather than a shrug. The numbers
	live under BoatConstants.Camera because a camera is where filtering a noisy velocity was first
	needed and where a designer goes to retune how twitchy a vehicle feels. A boat has no bespoke camera
	yet (see Client/Boat/BoatController.lua's header on why that is a deliberate omission rather than a
	gap), so today this binding's only consumers are the mounted body's lean and the wake gate -- both of
	which want exactly the same filter for exactly the same reason, and neither of which would be better
	served by a second set of numbers to keep in step.

	Does not own: the sampling arithmetic (Shared/Vessel/VesselMotion.lua), the numbers
	(BoatConstants.Camera.Smoothing), or reading a hull's AssemblyRootPart -- callers pass values in.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local VesselMotion = require(ReplicatedStorage.Shared.Vessel.VesselMotion)
local BoatConstants = require(script.Parent.BoatConstants)

export type State = VesselMotion.State
export type Motion = VesselMotion.Motion

return VesselMotion.New(BoatConstants.Camera.Smoothing)
