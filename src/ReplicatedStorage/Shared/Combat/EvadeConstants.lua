--!strict
--[[
	EvadeConstants.lua

	Owns: the tunables of the combat evade -- the ground glide on the Evade key (Z / gamepad Y). How fast
	and how far the body glides, how long it waits before the next one, and how long the server's evade
	frames last. Read by Client/Parkour/States/Evading.lua (the player's glide), Shared/Combat/
	EvadeMotion.lua (the one speed curve), Server/Combat/TrainingBot/TrainingBotSystem.lua (the bot's glide)
	and Shared/Defense/DefenseConstants.lua (the evade frames, which derive from Frames below).

	ONE MOVE, NO VARIANTS. This replaced ParkourConstants.Roll, which was two moves on one key: a traversal
	tumble (a 1.6-stud crouch, 30 studs/s for half a second, the roll clip) and a combat snap-step, picked
	between by whether the InCombat Attribute had already arrived. It usually had not on the first dodge
	of a fight, so players rolled into the floor while the training bot, which had no traversal branch,
	glided. There is no branch here to pick wrong: the glide never varies. It is also COMBAT ONLY -- refused
	outside an engagement by States/Evading.CanEnter and, for the frames, by Main.server.lua.

	Standalone rather than a section of ParkourConstants for the reason every combat subsystem's constants
	are (DefenseConstants' header): the evade is a combat move that happens to be driven by the parkour
	motor, and the server's defence layer and the bot both read it -- neither should need the whole parkour
	table to know how long a dodge lasts. Requires nothing, so anything may require it.

	Does not own: what a contact inside the evade frames resolves to (DefenseSystem/OutcomeResolver), the
	afterimage look (FXConstants.RollAfterimage), or the motor that drives the body (ParkourMotor).
]]

local EvadeConstants = {}

-- THE GLIDE. A flash-step curve -- fast out, eased in -- rather than a flat speed: speed(t) = PeakSpeed *
-- (1 - (t / DurationSeconds)^2), which covers PeakSpeed * DurationSeconds * 2/3 = 12.5 studs, most of it in
-- the first 0.15s. That front-loading is what reads as a teleport-glide instead of a run, and it is what
-- carries the body out of a swing's reach before the evade frames close. See Shared/Combat/EvadeMotion.lua
-- for the curve itself; nothing else may restate it.
--
-- 78 studs/s is well under ParkourConstants.Validation.MaxReportedSpeed (140) and MaxTravelSpeed (180), so
-- an honest evade can never trip the movement validator.
EvadeConstants.PeakSpeed = 78
EvadeConstants.DurationSeconds = 0.24

-- THE EVADE'S ONLY COST. The client's cooldown is the real gate for an honest client; the server refuses a
-- report sooner than CooldownSeconds - ServerCooldownToleranceSeconds (DefenseConstants.Evade), the
-- tolerance absorbing the jitter between two reports that left the client exactly one cooldown apart.
EvadeConstants.CooldownSeconds = 0.9
EvadeConstants.ServerCooldownToleranceSeconds = 0.15

-- How long an Evade press stays live while something refuses it (Client/Parkour/InputBuffer.PeekEvade).
-- The same 0.35 an attack press gets (AttackConstants.Input.BufferSeconds, 2026-09-29): an evade pressed
-- a little early in your own recovery or cooldown now fires the moment you are free instead of being
-- dropped. It used to share parkour's 0.18 ActionBufferSeconds, which is shorter than most recoveries.
EvadeConstants.BufferSeconds = 0.35

-- NO SurfaceStickSpeed, deliberately: a downward stick at the parkour drive's force sinks a standing R6
-- body into the floor. See States/Evading.lua's drive() before adding one back.

-- Grounded states an evade may start from. Airborne states are absent on purpose: the evade is a ground
-- move, and the Dash owns the air. No landing window either -- an evade pressed in the air is refused, not
-- buffered into a landing.
EvadeConstants.AllowedFromStates = {
	Idle = true,
	Walking = true,
	Sprinting = true,
	Sliding = true,
	Landing = true,
} :: { [string]: boolean }

-- THE SERVER'S EVADE FRAMES, counted from the moment the server accepts the Evade report. Startup 0: a
-- press anywhere in an opponent's windup covers the hit. Active outlasts the glide (0.30 against 0.24) so
-- the whole move is covered, and by the time the window closes the glide has carried the body out of reach.
-- The ping refund extends the END only, under the same cap the parry uses (DefenseConstants.Parry.
-- PingCompensationMaxSeconds), because a client-influenced number is exactly as untrustworthy here.
EvadeConstants.Frames = {
	StartupSeconds = 0,
	ActiveSeconds = 0.30,
	PingCompensationMaxSeconds = 0.12,
}

-- How long the server treats a reported evade as owning the body (ParkourController's ACTION_DURATIONS).
-- The glide plus a margin for the End report arriving late.
EvadeConstants.ReportOwnershipSeconds = EvadeConstants.DurationSeconds + 0.5

-- Optional directional clips, published by States/Evading.lua as its AnimationVariant from the angle
-- between travel and facing. BLANK MEANS NO CLIP, not a fallback: an evade with no clip keeps the body
-- upright in its current pose, which with the afterimage ghosts reads as a flash-step. Paste a step/dash
-- clip in to replace one; each is a one-line id edit and no code change.
EvadeConstants.AnimationIds = {
	Forward = "",
	Back = "",
	Left = "",
	Right = "",
} :: { [string]: string }

-- The evade's one-shot, played by Client/FX/ParkourAudio.lua on entering Evading. A short air whoosh.
-- BLANK UNTIL AN ASSET IS UPLOADED -- this codebase does not guess asset ids; SoundManager.Register warns
-- once on a blank id and Play no-ops on it.
EvadeConstants.Sound = {
	SoundId = "",
	Volume = 0.55,
	PoolSize = 2,
}

return EvadeConstants
