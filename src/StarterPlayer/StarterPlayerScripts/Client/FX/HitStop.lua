--!strict
--[[
	HitStop.lua

	Owns: two independent, purely-cosmetic freeze effects that happen to share one throttled-freeze
	factory and one Constants.FX.HitStop tuning table --

	  * FreezeFlightLanding -- the dev-menu flight feature's landing-impact freeze.
	    Client/Flight/FlightController.lua is the only caller. Delegates to
	    Client/FX/FlightAnimator.FreezeActiveFlightTrack.

	  * FreezeVictimMovement -- the combat hit-stop. Client/Combat/CombatFeedbackClient.lua is the only
	    caller, on the DEFENDER's own client, off a resolved Clean/Backstab/GuardBroken contact (the
	    same three outcomes DamageResolver grants DamageConstants.Hitstun to). Holds the local
	    character's AssemblyLinearVelocity at zero for a beat via ParkourMotor.ApplyImpulse.

	Both throttle rapid repeats on their own independent clock (see makeThrottledFreeze), so landings
	or hits close in time can't stack into unintended slow motion.

	WHY THE VICTIM FREEZE IS MOVEMENT, NOT ANIMATION, and this is a deliberate departure from what this
	module used to do. It used to also own an attacker/victim/parry/posture-break freeze family that
	delegated to a since-deleted CombatAnimator.FreezeActiveCombatTrack -- an ANIMATION-track freeze,
	removed alongside the rest of the pre-rewrite combat system (CombatAnimator.lua no longer even
	exposes that function). Rebuilding it as it was would freeze nothing visible for most swings today,
	because no swing body-animation plays at all right now -- every Default move's AnimationId is ""
	by design (see DamageTypes.AttackCatalogEntry's own comment on that). A freeze with nothing playing
	to freeze is a silent no-op, the same failure mode DamageConstants.AttackerLunge's own header warns
	about for a server-side movement write on a client-owned body -- except here the fix is the
	opposite one: movement, not animation, is the thing guaranteed to be visibly happening on a hit,
	so movement is what gets frozen.

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

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Constants = require(ReplicatedStorage.Shared.Constants)
local Logger = require(ReplicatedStorage.Shared.Logger)

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

-- Victim movement freeze -----------------------------------------------------------------------------

-- Absolute os.clock() deadline the current freeze holds until, or nil when none is running. One
-- shared deadline rather than a table keyed by anything: this module only ever freezes the LOCAL
-- player's own body (see this file's header on why it must run on the victim's own client), so there
-- is exactly one character it could ever apply to at a time.
local victimFreezeUntil: number? = nil
local victimFreezeConnection: RBXScriptConnection? = nil

-- Tears down the per-frame writer. Safe to call when nothing is running -- both call sites (expiry and
-- module Stop, if one is ever added) can reach this without checking first.
local function stopVictimFreeze(): ()
	if victimFreezeConnection then
		victimFreezeConnection:Disconnect()
		victimFreezeConnection = nil
	end
	victimFreezeUntil = nil
end

-- One frame of the hold. Re-checks the deadline every call rather than trusting a frame-count, the
-- same "measured against the clock, not the frame" discipline SwingLunge's own heartbeat keeps, so a
-- hitch or a low frame rate shortens how many WRITES happen rather than how long the freeze LASTS.
--
-- ApplyImpulse already refuses on its own (a kinematic traversal owns the body, or the server holds
-- RootControlLocked) and returns false rather than throwing -- the return value is not checked here
-- because there is nothing useful to do differently either way: the freeze is cosmetic, so losing a
-- frame of it to a traversal that outranks it is the correct outcome, not a fault to recover from.
local function onVictimFreezeHeartbeat(): ()
	local until_ = victimFreezeUntil
	if not until_ or os.clock() >= until_ then
		stopVictimFreeze()
		return
	end
	ParkourMotor.ApplyImpulse(Vector3.zero)
end

-- Starts (or extends) the hold. A connection is opened lazily on first use and left running between
-- freezes rather than reconnected per call -- the idle cost is one nil check per Heartbeat, cheaper
-- than tearing down and rebuilding a connection on every combat exchange in a busy fight.
local function freezeVictimMovement(seconds: number): ()
	if seconds <= 0 then
		return
	end
	victimFreezeUntil = os.clock() + seconds
	if not victimFreezeConnection then
		victimFreezeConnection = RunService.Heartbeat:Connect(onVictimFreezeHeartbeat)
	end
end

local freezeVictim = makeThrottledFreeze(freezeVictimMovement, "Combat victim hit-stop")

-- Freezes the LOCAL player's own body in place for `seconds` -- see this file's header for why this
-- is a movement freeze rather than an animation one, and why it has to be this specific client that
-- calls it. Throttled the same as the flight freeze, which is what stops a fast multi-hit combo from
-- chaining consecutive calls into one long freeze instead of a series of short stingers -- exactly
-- the failure mode Constants.FX.HitStop's own MinIntervalSeconds comment already names.
--
-- Caller supplies the duration rather than this function picking one from CONFIG itself, the same
-- "the tuning lives with the caller that knows which outcome this is" shape ShakePresets/HIT_FLASH_
-- COLORS already use in CombatFeedbackClient.lua -- this module owns HOW to freeze, not which outcome
-- deserves how long a freeze.
function HitStop.FreezeVictimMovement(seconds: number): ()
	freezeVictim(seconds)
end

return HitStop
