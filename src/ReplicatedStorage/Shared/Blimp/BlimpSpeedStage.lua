--!strict
--[[
	BlimpSpeedStage.lua

	Owns: ONE binding -- the airship's three flight stages, which is Shared/Vessel/VesselSpeedStage.lua
	reading BlimpConstants.Audio.Stages and BlimpConstants.Audio.StageHysteresis. The hysteresis argument
	(and it is the whole module) lives in that file's header; this one only says which bands a blimp has
	and how wide its dead band is.

	Its own file for the same reason Shared/Blimp/BlimpSpeedLadder.lua is: a stage index is compared
	across frames by Client/FX/BlimpAudio.lua, and two independent bindings of the same table would be
	two ladders that happen to agree until one of them stops.

	Does not own: any of the behaviour (Shared/Vessel/VesselSpeedStage.lua), the stage definitions or the
	dead band (BlimpConstants.Audio), or the sounds (Client/FX/BlimpAudio.lua).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local VesselSpeedStage = require(ReplicatedStorage.Shared.Vessel.VesselSpeedStage)
local BlimpConstants = require(script.Parent.BlimpConstants)

export type Stage = VesselSpeedStage.Stage

return VesselSpeedStage.New(BlimpConstants.Audio.Stages :: { Stage }, BlimpConstants.Audio.StageHysteresis)
