--!strict
--[[
	HitboxDebugState.lua

	Owns: the single, server-wide, runtime-toggleable flag that gates HitboxResolver.lua's
	renderDebugHitbox visualization. Split out of a bare Constants.Combat.DebugHitboxes read (which
	required editing Constants.lua and republishing to flip, and was additionally hard-gated on
	RunService:IsStudio() so it could never be seen in a live server) so an authorized admin can flip
	it live -- in Studio OR a published server -- via DevMenuSystem.lua's GetHitboxDebug/
	SetHitboxDebug remotes.

	A plain module-local boolean, not a per-player AdminOverrideState entry (AdminActionSystem.lua) --
	a debug hitbox Part is a real Workspace object every nearby player already sees when it renders,
	there is no per-player visibility to key this by, so one server-wide flag is the honest shape.

	Does not own: authorization/rate-limiting (DevMenuSystem.lua's handleGetHitboxDebug/
	handleSetHitboxDebug, same as every other admin action) or rendering the debug Part itself
	(HitboxResolver.lua's renderDebugHitbox, which only ever calls IsEnabled -- never mutates this
	module directly).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Constants = require(ReplicatedStorage.Shared.Constants)

local HitboxDebugState = {}

-- Boot default mirrors Constants.Combat.DebugHitboxes's own file value, so a fresh server starts
-- exactly as it always has; every change after that point lives only in this module's memory,
-- same "no persistence, resets on server restart" contract as HitboxTuning.lua/DefaultMoveRegistry.
-- lua's own live-tuned values.
local enabled: boolean = Constants.Combat.DebugHitboxes

function HitboxDebugState.IsEnabled(): boolean
	return enabled
end

function HitboxDebugState.SetEnabled(value: boolean): ()
	enabled = value
end

return HitboxDebugState
