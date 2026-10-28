--!strict
--[[
	HitStop.lua

	Owns: the purely-cosmetic freeze effects that share one throttled-freeze factory and one
	FXConstants.HitStop tuning table --

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

	  * SlowVictimMovement -- the rest of the stun (2026-09-30). After the freeze, a stunned body walks at a
	    fraction of its speed (CombatConstants.HitSlowMultiplier) until the stun ends. Before this nothing
	    slowed a stunned player at all: they walked out of an 8-stud swing box at full walking speed inside
	    one stun, so an M1 string that landed its first hit whiffed its second -- the "chains stop in the
	    middle" report. Same input-hold binding as the freeze; the freeze wins while both are live.

	The flight freeze throttles rapid repeats on its own clock (makeThrottledFreeze). The two combat freezes
	are CHAINED instead (2026-10-27, FXConstants.HitStop's chain rules): overlapping freezes merge into one
	hold capped at MaxChainSeconds, a freeze that would not extend the hold is dropped, and a finished chain
	leaves ChainGapSeconds of free motion before the next. A server verdict's freeze is also AGED by its
	trip (AgedSeconds), so latency is not stacked on top of the beat. Before this, hits arriving faster than
	the freezes ran out kept both bodies stopped for as long as they kept coming -- the "I am stuck though
	the hit-stop should be over" report -- and a knockback waited out a table's freeze length even when no
	freeze had started; a launch now waits out VictimFreezeRemaining, the freeze that actually runs.

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
	This freeze (FXConstants.HitStop.VictimSeconds/PostureBreakSeconds, both under 0.15s) is a stinger
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
local AnimationManager = require(ReplicatedStorage.Shared.Animation.AnimationManager)
local CharacterUtil = require(ReplicatedStorage.Shared.CharacterUtil)
local FXConstants = require(ReplicatedStorage.Shared.FXConstants)
local Logger = require(ReplicatedStorage.Shared.Logger)

local AnimationTrackUtil = require(script.Parent.AnimationTrackUtil)
local FlightAnimator = require(script.Parent.FlightAnimator)
local ParkourMotor = require(script.Parent.Parent.Parkour.ParkourMotor)
local FrameOrder = require(script.Parent.Parent.Config.FrameOrder)

local logger = Logger.scope("HitStop")

local CONFIG = FXConstants.HitStop

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

-- Smoothness rules (2026-10-27) ----------------------------------------------------------------------
--
-- FXConstants.HitStop's CHAIN RULES and LATENCY AGING headers say why. Both are pure here so a spec pins the
-- arithmetic with no rig; the two freeze families below each keep their own chain state and ask these.

-- How long a freeze of `seconds` arriving `ageSeconds` after its contact should still hold. A verdict that
-- arrived late keeps a stinger (MinStingerSeconds, or the beat itself if shorter) rather than vanishing.
function HitStop.AgedSeconds(seconds: number, ageSeconds: number?): number
	local age = if CONFIG.AgeByLatency and typeof(ageSeconds) == "number" and ageSeconds > 0 then ageSeconds else 0
	if age <= 0 then
		return seconds
	end
	return math.max(seconds - age, math.min(seconds, CONFIG.MinStingerSeconds))
end

-- How long a freeze wanting `seconds` from `now` may hold, given the chain it lands in: the chain began at
-- `chainStartedAt` and is held until `heldUntil` (a past `heldUntil` is an idle chain). 0 means "start
-- nothing": the chain's budget is spent, the freeze would not extend the hold, it falls inside the gap after a
-- chain, or it is too short to read.
function HitStop.ChainedSeconds(seconds: number, now: number, chainStartedAt: number, heldUntil: number): number
	if seconds <= 0 then
		return 0
	end
	if now >= heldUntil then
		if now < heldUntil + CONFIG.ChainGapSeconds then
			return 0
		end
		local fresh = math.min(seconds, CONFIG.MaxChainSeconds)
		return if fresh >= CONFIG.MinFreezeSeconds then fresh else 0
	end
	local wantedEnd = math.min(now + seconds, chainStartedAt + CONFIG.MaxChainSeconds)
	if wantedEnd <= heldUntil then
		return 0
	end
	return wantedEnd - now
end

-- One freeze family's chain: when it began and until when it holds.
type Chain = { StartedAt: number, HeldUntil: number }

local function newChain(): Chain
	-- Far enough in the past that the first freeze is never inside a gap.
	return { StartedAt = -math.huge, HeldUntil = -math.huge }
end

-- Admits a freeze into `chain` and records it. Returns the seconds to hold (0: start nothing).
local function admit(chain: Chain, seconds: number, now: number): number
	local granted = HitStop.ChainedSeconds(seconds, now, chain.StartedAt, chain.HeldUntil)
	if granted <= 0 then
		return 0
	end
	if now >= chain.HeldUntil then
		chain.StartedAt = now
	end
	chain.HeldUntil = now + granted
	return granted
end

-- Exchange (animation) freeze ----------------------------------------------------------------------

-- One guard for every combat freeze, separate from the flight freeze's own -- see
-- AnimationTrackUtil.NewFreezeGuard's header on why families must not share one.
local exchangeGuard = AnimationTrackUtil.NewFreezeGuard()
local exchangeChain = newChain()

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

-- Tracks no manager owns, appended for the guard to freeze. `skip` is what the managers already hold.
local function appendPlayingTracks(model: Model, into: { AnimationTrack }, skip: { [AnimationTrack]: boolean }): ()
	local humanoid = CharacterUtil.HumanoidOf(model)
	local animator = if humanoid then humanoid:FindFirstChildOfClass("Animator") else nil
	if animator == nil then
		return
	end
	for _, track in animator:GetPlayingAnimationTracks() do
		if FROZEN_PRIORITIES[track.Priority] and not skip[track] then
			table.insert(into, track)
		end
	end
end

-- Freezes every playing Action-priority track on both combatants for `seconds`. Runs on every client that hears the
-- hit, and freezes the OTHER body locally too, so both participants see one shared stop rather than
-- each only their own half. Chained (FXConstants.HitStop's CHAIN RULES), so a fast multi-hit string reads as
-- a series of stingers with free motion between them, never one long slow-motion hold. `ageSeconds` is how
-- long ago the contact happened (a server verdict's trip); nil for a predicted impact.
--
-- TWO ROUTES, because two kinds of track exist. A track an AnimationManager owns (the local player's swing and
-- guard) is frozen THROUGH its manager (AnimationManager.FreezeFor): a raw AdjustSpeed(0) on one is undone by the
-- manager's stranded-speed repair on the next frame, which made the attacker's hit-stop one frame long. Every
-- other track (a remote rig's replicated clips) is frozen directly by the generation-guarded guard below.
-- Returns whether a freeze was started (false when throttled or empty).
function HitStop.FreezeExchange(attacker: Model?, defender: Model?, seconds: number, ageSeconds: number?): boolean
	seconds = admit(exchangeChain, HitStop.AgedSeconds(seconds, ageSeconds), os.clock())
	if seconds <= 0 then
		return false
	end

	local catchUp = CONFIG.CatchUpSpeedMultiplier
	local owned: { [AnimationTrack]: boolean } = {}
	for _, model in { attacker, defender } do
		if model then
			for track in AnimationManager.FreezeFor(model, seconds, FROZEN_PRIORITIES, catchUp) do
				owned[track] = true
			end
		end
	end

	local tracks: { AnimationTrack } = {}
	if attacker then
		appendPlayingTracks(attacker, tracks, owned)
	end
	if defender and defender ~= attacker then
		appendPlayingTracks(defender, tracks, owned)
	end
	-- Caught up afterwards: the server's swing kept running through the freeze (CatchUpSpeedMultiplier).
	exchangeGuard:FreezeTracks(tracks, seconds, catchUp)
	logger:debug("Combat exchange hit-stop", { seconds = seconds, tracks = #tracks })
	return true
end

-- Ends the exchange freeze now on both bodies -- a predicted impact the server then reversed (a block, a
-- parry, an evade), whose hold would otherwise run on over a hit that did not happen. The chain is reset so
-- the verdict's own beat (a parry's clash) is neither refused as a repeat nor held off by the gap.
function HitStop.EndExchange(attacker: Model?, defender: Model?): ()
	exchangeChain = newChain()
	for _, model in { attacker, defender } do
		if model then
			AnimationManager.ThawFor(model)
		end
	end
	exchangeGuard:Release()
end

-- How much of the exchange freeze is still to hold, 0 when none is. What a push waiting out the freeze reads,
-- so it starts when the freeze that ACTUALLY ran ends -- not after a table's length for one that was dropped,
-- shortened or aged.
function HitStop.ExchangeRemaining(): number
	return math.max(exchangeChain.HeldUntil - os.clock(), 0)
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
local INPUT_HOLD_PRIORITY = FrameOrder.Priority("HitStopInputHold")

local function localRig(): (Humanoid?, BasePart?)
	local character = Players.LocalPlayer.Character
	if character == nil then
		return nil, nil
	end
	return CharacterUtil.LiveHumanoidOf(character), CharacterUtil.RootOf(character)
end

-- Tears down the freeze's velocity writer. The input hold unbinds itself once neither the freeze nor the
-- stun slow is live (onInputHold). Safe to call when nothing is running.
local function stopVictimFreeze(): ()
	if victimFreezeConnection then
		victimFreezeConnection:Disconnect()
		victimFreezeConnection = nil
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

-- The stun slow (SlowVictimMovement): until when, and to what fraction of the player's own input.
local victimSlowUntil: number? = nil
local victimSlowMultiplier = 1

-- The fraction of input a slow of `multiplier` lets through at `now`: the multiplier itself, easing linearly
-- back to 1 across the last SlowReleaseSeconds before `untilAt` (FXConstants.HitStop.SlowReleaseSeconds).
function HitStop.SlowMultiplierAt(multiplier: number, untilAt: number?, now: number): number
	local release = CONFIG.SlowReleaseSeconds
	if untilAt == nil or release <= 0 then
		return multiplier
	end
	local remaining = untilAt - now
	if remaining >= release then
		return multiplier
	end
	return multiplier + (1 - multiplier) * math.clamp(1 - remaining / release, 0, 1)
end

local function slowActive(now: number): boolean
	local until_ = victimSlowUntil
	if not until_ or now >= until_ then
		victimSlowUntil = nil
		return false
	end
	return true
end

local function unbindInputHold(): ()
	if inputHoldBound then
		RunService:UnbindFromRenderStep(INPUT_HOLD_BINDING)
		inputHoldBound = false
	end
end

-- The half that makes it hold a RUNNING player: take this frame's input away before physics sees it. And,
-- once the freeze is over, the stun slow: this frame's input scaled down rather than removed.
--
-- The slow NORMALISES before scaling. MoveDirection is read after the control script's own Move this frame,
-- so it is the player's input; normalising means that even if it were ever last frame's scaled write
-- instead, the slow could not compound toward a standstill.
local function onInputHold(): ()
	local frozen = freezeActive()
	local slowed = not frozen and slowActive(os.clock())
	if not frozen and not slowed then
		unbindInputHold()
		return
	end
	local humanoid = localRig()
	if not humanoid then
		return
	end
	if frozen then
		humanoid:Move(Vector3.zero, false)
		return
	end
	local direction = humanoid.MoveDirection
	if direction.Magnitude > 1e-3 then
		humanoid:Move(
			direction.Unit * HitStop.SlowMultiplierAt(victimSlowMultiplier, victimSlowUntil, os.clock()),
			false
		)
	end
	-- No jumping out of a stun either: a hop carries the body out of the next swing just as a walk did.
	humanoid.Jump = false
end

local function bindInputHold(): ()
	if not inputHoldBound then
		RunService:BindToRenderStep(INPUT_HOLD_BINDING, INPUT_HOLD_PRIORITY, onInputHold)
		inputHoldBound = true
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

-- The victim freeze's own chain -- separate from the exchange's, since the two start on different events (a
-- predicted impact freezes the exchange, never this body's movement).
local victimChain = newChain()

-- Stops the LOCAL player's own body where it stands for `seconds` -- see this file's header for both
-- halves and why the input half is what makes it work on a runner. Chained and aged like the exchange
-- freeze (FXConstants.HitStop), so a burst of hits holds the body once, briefly, rather than pinning it for
-- as long as they keep arriving. Caller supplies the duration: this module owns HOW to freeze, not which
-- outcome deserves how long. Returns how long the freeze will still hold (0 when none started and none is
-- running) -- the delay a launch must wait out.
function HitStop.FreezeVictimMovement(seconds: number, ageSeconds: number?): number
	local now = os.clock()
	local granted = admit(victimChain, HitStop.AgedSeconds(seconds, ageSeconds), now)
	if granted > 0 then
		victimFreezeUntil = victimChain.HeldUntil
		if not victimFreezeConnection then
			victimFreezeConnection = RunService.Heartbeat:Connect(onVictimFreezeHeartbeat)
		end
		bindInputHold()
		logger:debug("Combat victim hit-stop", { seconds = granted })
	end
	return HitStop.VictimFreezeRemaining()
end

-- How much of the victim freeze is still to hold, 0 when none is.
function HitStop.VictimFreezeRemaining(): number
	local until_ = victimFreezeUntil
	return if until_ then math.max(until_ - os.clock(), 0) else 0
end

-- Slows the LOCAL player's own walking to `multiplier` of their input until `seconds` from now -- the stun
-- after the hit-stop's freeze. NOT throttled: every stunning hit extends it (never shortens it), because
-- the stun it mirrors is extended by every hit too. Caller supplies both numbers.
function HitStop.SlowVictimMovement(seconds: number, multiplier: number): ()
	if seconds <= 0 then
		return
	end
	local until_ = os.clock() + seconds
	if victimSlowUntil == nil or until_ > victimSlowUntil then
		victimSlowUntil = until_
	end
	victimSlowMultiplier = math.clamp(multiplier, 0, 1)
	bindInputHold()
end

-- Ends the stun slow early -- a parry out of the stun (DefenseConstants.StunParry) frees the body on the spot,
-- and the walk should come back with it rather than at the deadline the last hit set.
function HitStop.EndVictimSlow(): ()
	if victimSlowUntil ~= nil then
		victimSlowUntil = os.clock()
	end
end

return HitStop
