--!strict
--[[
	HitStop.lua

	Owns: the purely-cosmetic freeze effects that share one throttled-freeze factory and one
	Constants.FX.HitStop tuning table --

	  * FreezeFlightLanding -- the dev-menu flight feature's landing-impact freeze.
	    Client/Flight/FlightController.lua is the only caller. Delegates to
	    Client/FX/FlightAnimator.FreezeActiveFlightTrack.

	  * FreezeExchange -- the combat hit-stop's ANIMATION half: every playing ACTION track on BOTH the attacker
	    and the defender stops dead for a beat, on every client that hears about the hit (both
	    participants get Combat_Feedback). That shared pose-freeze is what a hit-stop actually is -- the
	    impact landing, held for a few frames, on both bodies at once.

	  * FreezeVictimMovement -- the combat hit-stop's MOVEMENT half, on the DEFENDER's own client, off a
	    resolved Clean/Backstab/GuardBroken contact (the same three outcomes DamageResolver grants
	    DamageConstants.Hitstun to). Stops the local body where it stands for the beat.

	Both throttle rapid repeats on their own independent clock (see makeThrottledFreeze), so landings
	or hits close in time can't stack into unintended slow motion.

	WHY BOTH HALVES NOW, and what was wrong with movement alone (2026-09-28). This module used to freeze
	only the victim's velocity, on the reasoning that no swing animation played -- which stopped being
	true once weapons authored their own swing clips (Shared/Attack/AttackAnimations.lua). Two failures
	followed, both reported from play: nothing about the ATTACKER ever stopped, so the hit had no weight
	on the side that threw it; and the victim freeze did not hold a RUNNING player. It zeroed velocity on
	Heartbeat, which runs AFTER physics, and a running Humanoid's walk controller simply re-accelerated
	to full speed inside the very next step -- a runner felt, at most, a hitch. So:
	  * the animation freeze (FreezeExchange) is back, on both bodies, through
	    Client/FX/AnimationTrackUtil's generation-guarded FreezeGuard -- the same helper the flight freeze
	    already uses, so overlapping freezes extend rather than resume early;
	  * the movement freeze now takes the INPUT away rather than fighting its result: a RenderStep
	    binding just after Roblox's own control script (Enum.RenderPriority.Input + 1) calls
	    Humanoid:Move(Vector3.zero) for the beat, so the walk controller brakes instead of pushing. The
	    horizontal velocity is still zeroed on Heartbeat for anything already in flight; the vertical is
	    carried through, so a victim hit in the air is not hung in place.
	It never writes WalkSpeed (RunSystem is that property's sole writer) and never anchors anything.

	RUNS ON THE VICTIM'S OWN CLIENT, FOR THE SAME REASON Client/Combat/SwingLunge.lua's own forward
	step does. A character is network-owned by its own client: that client simulates it and replicates
	the result, so any freeze that has to be SEEN has to be written where the body is actually
	simulated. A server-side freeze attempt would land on the server's follower copy and be overwritten
	by the owner's very next replicated frame -- see SwingLunge.lua's header for the full argument,
	which this reuses rather than re-deriving. DamageConstants.Hitstun ATTACK-GATES the victim
	server-side (DamageSystem.CanAttack refuses "Hitstun" while stunned) and that gate is correct and
	sufficient on its own; this freeze adds nothing to fairness or correctness, only to how the
	already-real lockout READS in the moment it starts.

	NOT THE SAME DURATION AS THE HITSTUN IT RIDES ALONGSIDE, and that gap is the whole design. Hitstun
	(DamageConstants.Hitstun.Seconds, 0.65) is a real, felt lockout -- how long the victim cannot act.
	This freeze (Constants.FX.HitStop.VictimSeconds/PostureBreakSeconds, both under 0.15s) is a stinger
	at the START of that lockout -- the frame-perfect punctuation that says "that connected," not a
	second, shorter stun layered under the first. Holding it for anywhere near the full Hitstun window
	would just be hitstun with extra steps and would fight the player's own next input the moment
	control returns.

	Does not own: the actual track manipulation (FlightAnimator.FreezeActiveFlightTrack) or deciding
	WHICH landing happened for the flight half; the DEFENSE classification, the Hitstun timer itself,
	or WHETHER a hit landed for the combat half (DamageResolver/DamageSystem, server-side); or any
	camera/audio/highlight reaction that might accompany either (CameraShake.lua, CombatAudio.lua,
	HitFlash.lua -- all driven from the same Combat_Feedback event by CombatFeedbackClient.lua, but each
	its own independent FX primitive). Purely local, purely presentation.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local CharacterUtil = require(ReplicatedStorage.Shared.CharacterUtil)
local Constants = require(ReplicatedStorage.Shared.Constants)
local Logger = require(ReplicatedStorage.Shared.Logger)

local AnimationTrackUtil = require(script.Parent.AnimationTrackUtil)
local FlightAnimator = require(script.Parent.FlightAnimator)
local ParkourMotor = require(script.Parent.Parent.Parkour.ParkourMotor)

local logger = Logger.scope("HitStop")

local CONFIG = Constants.FX.HitStop

local HitStop = {}

-- Builds a throttled freeze function: at most one call through to `delegate` per
-- CONFIG.MinIntervalSeconds, everything in between silently dropped. Closes over its own `lastClock`
-- upvalue so each factory call's resulting function owns an independent throttle window -- kept as
-- its own factory (rather than a single inlined freezeFlight) since a second, unrelated freeze domain
-- landing on this same throttle clock would be a hidden coupling if one were ever added back.
local function makeThrottledFreeze(delegate: (number) -> (), logLabel: string): (number) -> ()
	local lastClock = 0
	return function(seconds: number): ()
		local now = os.clock()
		if now - lastClock < CONFIG.MinIntervalSeconds then
			return
		end
		lastClock = now
		delegate(seconds)
		logger:debug(logLabel, { seconds = seconds })
	end
end

local freezeFlight = makeThrottledFreeze(FlightAnimator.FreezeActiveFlightTrack, "Flight hit-stop")

-- The dev-menu flight feature's landing-impact freeze -- Hard is a real, heavier hitch; Soft barely
-- more than a single frame. Purely cosmetic, no combat implication.
function HitStop.FreezeFlightLanding(isHard: boolean): ()
	freezeFlight(if isHard then CONFIG.FlightLandingHardSeconds else CONFIG.FlightLandingSoftSeconds)
end

-- Exchange (animation) freeze ----------------------------------------------------------------------

-- One guard for every combat freeze, separate from the flight freeze's own -- see
-- AnimationTrackUtil.NewFreezeGuard's header on why families must not share one.
local exchangeGuard = AnimationTrackUtil.NewFreezeGuard()
local lastExchangeClock = 0

-- The priorities a hit-stop freezes: the swing, the guard, the parry -- the clips that ARE the
-- exchange. Idle/Movement/Core (walking, running, the armed idle) are deliberately absent.
--
-- CHANGED 2026-09-28: this used to freeze EVERY playing track, locomotion included. In an M1 trade that
-- is a full-body stop several times a second on both screens -- legs locking mid-stride on every hit --
-- which playtest read as stutter rather than as weight. The impact reads from the arms stopping; the
-- legs carrying on is what keeps a fight fluid.
local FROZEN_PRIORITIES: { [Enum.AnimationPriority]: boolean } = {
	[Enum.AnimationPriority.Action] = true,
	[Enum.AnimationPriority.Action2] = true,
	[Enum.AnimationPriority.Action3] = true,
	[Enum.AnimationPriority.Action4] = true,
}

local function appendPlayingTracks(model: Model, into: { AnimationTrack }): ()
	local humanoid = CharacterUtil.HumanoidOf(model)
	local animator = if humanoid then humanoid:FindFirstChildOfClass("Animator") else nil
	if animator == nil then
		return
	end
	for _, track in animator:GetPlayingAnimationTracks() do
		if FROZEN_PRIORITIES[track.Priority] then
			table.insert(into, track)
		end
	end
end

-- Freezes every playing Action-priority track on both combatants for `seconds`. Runs on every client that hears the
-- hit, and freezes the OTHER body locally too, so both participants see one shared stop rather than
-- each only their own half. Throttled like the other freezes, so a fast multi-hit string reads as a
-- series of stingers, not one long slow-motion hold.
function HitStop.FreezeExchange(attacker: Model?, defender: Model?, seconds: number): ()
	if seconds <= 0 then
		return
	end
	local now = os.clock()
	if now - lastExchangeClock < CONFIG.MinIntervalSeconds then
		return
	end
	lastExchangeClock = now

	local tracks: { AnimationTrack } = {}
	if attacker then
		appendPlayingTracks(attacker, tracks)
	end
	if defender and defender ~= attacker then
		appendPlayingTracks(defender, tracks)
	end
	exchangeGuard:FreezeTracks(tracks, seconds)
	logger:debug("Combat exchange hit-stop", { seconds = seconds, tracks = #tracks })
end

-- Victim movement freeze -----------------------------------------------------------------------------

-- Absolute os.clock() deadline the current freeze holds until, or nil when none is running. One
-- shared deadline rather than a table keyed by anything: this only ever freezes the LOCAL player's own
-- body, so there is exactly one character it could ever apply to at a time.
local victimFreezeUntil: number? = nil
local victimFreezeConnection: RBXScriptConnection? = nil
local inputHoldBound = false

-- After Roblox's own ControlModule, which calls Humanoid:Move on Enum.RenderPriority.Input -- so this
-- frame's move vector is the one written here, not the player's.
local INPUT_HOLD_BINDING = "CombatHitStopInputHold"
local INPUT_HOLD_PRIORITY = Enum.RenderPriority.Input.Value + 1

local function localRig(): (Humanoid?, BasePart?)
	local character = Players.LocalPlayer.Character
	if character == nil then
		return nil, nil
	end
	return CharacterUtil.LiveHumanoidOf(character), CharacterUtil.RootOf(character)
end

-- Tears down both per-frame writers. Safe to call when nothing is running.
local function stopVictimFreeze(): ()
	if victimFreezeConnection then
		victimFreezeConnection:Disconnect()
		victimFreezeConnection = nil
	end
	if inputHoldBound then
		RunService:UnbindFromRenderStep(INPUT_HOLD_BINDING)
		inputHoldBound = false
	end
	victimFreezeUntil = nil
end

local function freezeActive(): boolean
	local until_ = victimFreezeUntil
	if not until_ or os.clock() >= until_ then
		stopVictimFreeze()
		return false
	end
	return true
end

-- The half that makes it hold a RUNNING player: take this frame's input away before physics sees it.
local function onInputHold(): ()
	if not freezeActive() then
		return
	end
	local humanoid = localRig()
	if humanoid then
		humanoid:Move(Vector3.zero, false)
	end
end

-- The half for what is already moving: horizontal velocity to zero, vertical carried through.
-- ParkourMotor.ApplyExternalImpulse refuses only while the server holds the root, returning false rather
-- than throwing; losing a frame of a cosmetic freeze to that is the correct outcome. External rather than
-- the plain ApplyImpulse because a hit that lands mid-evade (outside its frames), mid-slide or mid-vault
-- must END that state (ParkourController's interrupt rule): a state that owns the body would otherwise
-- overwrite the freeze every physics step and carry the player straight through the hit that stopped it.
local function onVictimFreezeHeartbeat(): ()
	if not freezeActive() then
		return
	end
	local _, root = localRig()
	local vertical = if root then root.AssemblyLinearVelocity.Y else 0
	ParkourMotor.ApplyExternalImpulse(Vector3.new(0, vertical, 0))
end

-- Starts (or extends) the hold.
local function freezeVictimMovement(seconds: number): ()
	if seconds <= 0 then
		return
	end
	victimFreezeUntil = os.clock() + seconds
	if not victimFreezeConnection then
		victimFreezeConnection = RunService.Heartbeat:Connect(onVictimFreezeHeartbeat)
	end
	if not inputHoldBound then
		RunService:BindToRenderStep(INPUT_HOLD_BINDING, INPUT_HOLD_PRIORITY, onInputHold)
		inputHoldBound = true
	end
end

local freezeVictim = makeThrottledFreeze(freezeVictimMovement, "Combat victim hit-stop")

-- Stops the LOCAL player's own body where it stands for `seconds` -- see this file's header for both
-- halves and why the input half is what makes it work on a runner. Throttled the same as the flight
-- freeze. Caller supplies the duration: this module owns HOW to freeze, not which outcome deserves how
-- long.
function HitStop.FreezeVictimMovement(seconds: number): ()
	freezeVictim(seconds)
end

return HitStop
