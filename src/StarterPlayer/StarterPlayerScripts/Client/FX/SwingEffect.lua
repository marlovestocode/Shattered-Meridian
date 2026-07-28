--!strict
--[[
	SwingEffect.lua

	Owns: a tiny, asset-free camera "punch" that plays the instant the LOCAL player's own attack is
	confirmed accepted by the server (Combat_AttackStarted) -- immediate confirmation that a swing is
	happening, well before any hit-resolution feedback (damage number/sound, or nothing at all on a
	whiff) could possibly arrive. Before this module existed, Combat_AttackStarted was wired but
	unused (see CombatClient.lua's own prior comment on it) -- with no animation/VFX asset pipeline
	in this repo yet (StunEffect.lua's header explains why), a swing had literally zero player-facing
	feedback between the press and a hit landing, which reads as unresponsive input rather than a
	deliberate windup.

	The actual FieldOfView write is delegated to FOVOffset.lua (a named "SwingPunch" slot) rather
	than tweening camera.FieldOfView directly -- see that module's header for why: this used to
	read-current-FieldOfView-as-base and tween independently of FlightCamera's own direct write,
	which meant the two could fight (and stomp Sprint/Slide's zoom, once those existed) whenever
	they landed in the same window.

	Does not own: deciding when an attack was accepted -- CombatClient.lua's Combat_AttackStarted
	listener is the only caller, translating a server-confirmed accept into a call here. This module
	only knows how to punch the camera once told to; it has no idea what a combo, a weapon, or a hit
	even is.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Constants = require(ReplicatedStorage.Shared.Constants)
local Logger = require(ReplicatedStorage.Shared.Logger)
local FOVOffset = require(script.Parent.FOVOffset)

local logger = Logger.scope("SwingEffect")

local SwingEffect = {}

-- A gentle FOV dip-and-recover -- reads as "effort/impact" without a swing animation, tuned soft
-- enough not to be disorienting on its own. Heavy gets a slightly larger punch than Basic so a
-- Heavy throw reads as weightier through this one asset-free cue. Restrained per
-- docs/ui-ux-philosophy.md's Critical States rule ("controlled... not excessive"). Both legs use
-- InOut easing (ramps up AND down smoothly, no instant-velocity snap at the start of either tween)
-- rather than Out/In, which is what made the original punch read as a jolt rather than a dip.
-- Now Constants.Camera.SwingPunch, a sibling to that table's own Sprint/Slide FOV presets -- see
-- that field's own header in Constants.lua.
local BASIC_FOV_DELTA = Constants.Camera.SwingPunch.BasicFOVDelta
local HEAVY_FOV_DELTA = Constants.Camera.SwingPunch.HeavyFOVDelta
local PUNCH_OUT_SECONDS = Constants.Camera.SwingPunch.PunchOutSeconds
local PUNCH_BACK_SECONDS = Constants.Camera.SwingPunch.PunchBackSeconds

-- Plays the punch. Safe to call again mid-effect -- FOVOffset.Punch restarts the same named slot,
-- the same "a second call interrupts/restarts the first" contract this always had.
function SwingEffect.Play(isHeavy: boolean): ()
	local delta = if isHeavy then HEAVY_FOV_DELTA else BASIC_FOV_DELTA
	FOVOffset.Punch("SwingPunch", delta, PUNCH_OUT_SECONDS, PUNCH_BACK_SECONDS)
	logger:debug("Swing effect played", { isHeavy = isHeavy })
end

return SwingEffect
