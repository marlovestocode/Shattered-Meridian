--!strict
--[[
	DefenseStateMachine.lua

	Owns: the lifecycle of ONE combatant's guard -- Neutral -> Raising -> ParryWindow -> Blocking, the
	ParryRecovery branch a whiff takes, and the Staggered/GuardBroken conditions imposed from outside.
	One instance per registered combatant, created and driven by DefenseSystem.lua.

	Structurally this follows Server/Combat/HitboxEngine/AttackStateMachine.lua, which in turn follows
	Client/Parkour/StateMachine.lua -- so anyone who has read either already knows how to read this.
	Same three rules, for the same reasons:
	  * TIME COMES FROM THE CALLER on every entry point, never os.clock() here.
	  * PHASE BOUNDARIES USE THE TIME THEY WERE DUE, not the time they were noticed, so a window's
	    length never depends on server frame timing.
	  * TRANSITIONS CHAIN within one Update, so a window authored to open at 0 seconds is live within
	    the call that armed it rather than a frame later.

	WHAT THIS MACHINE HAS THAT NEITHER OF THOSE DOES: history. DefenseSystem classifies each contact
	against the defender's posture at that contact's SampleTime, which on a subdivided frame is
	EARLIER than now -- the hitbox engine subdivides one Heartbeat into up to eight substeps, so a
	single frame can deliver contacts tens of milliseconds apart, comfortably wider than a parry
	window. Answering only "what state are you in" would misclassify every contact that straddles a
	boundary inside one frame: a hit landing before ParryStart would be parried, and one landing
	after it closed would be too. So this machine records a bounded trail of posture segments and can
	answer "what were you at time t" -- see StateAt/BlockHeldAt/IsParryLiveAt.

	TWO THINGS ARE DELIBERATELY NOT STATES, because they are conditions that outlive and cut across
	states:
	  * The parry LOCKOUT (_parryLockedUntil). A whiffed tap and a stagger both forbid arming a new
	    parry for a while, but neither forbids blocking -- so a player can leave the ParryRecovery
	    state by pressing, and must still not get a parry out of it. A timestamp survives that; a
	    state would not.
	  * PARRY LIVENESS (_parryOpensAt/_parryEndsAt). The window's END for hit classification is later
	    than the transition to Blocking, because ping compensation refunds latency without delaying
	    the guard coming up -- see ParryWindows.ParryEndFor. One marker, two derived times, so the
	    membership test cannot be "is the state ParryWindow".
	  * EVADE LIVENESS (_evadeOpensAt/_evadeEndsAt). The evade's frames, same shape as the parry's
	    for the same reason: a ping-refunded window that a contact is tested against at its own
	    SampleTime. Not a state because an evade changes nothing else about the defender's posture --
	    evading out of a guard releases it through the ordinary Release path, and an evade in any other
	    posture leaves that posture exactly as it was.

	Does not own: the guard pool (GuardMeter.lua), what a contact resolves to (OutcomeResolver.lua),
	any Instance, any remote, or the window's timing (ParryWindows.lua).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DefenseConstants = require(ReplicatedStorage.Shared.Defense.DefenseConstants)
local DefenseTypes = require(ReplicatedStorage.Shared.Defense.DefenseTypes)
local ParryWindows = require(ReplicatedStorage.Shared.Defense.ParryWindows)

type DefenseState = DefenseTypes.DefenseState
type ParryWindow = DefenseTypes.ParryWindow

local DefenseStateMachine = {}
DefenseStateMachine.__index = DefenseStateMachine

-- One stretch of unchanging defensive posture. Pushed on every state change AND on every block-held
-- change, so the trail describes the defender's full posture over time rather than just their state
-- -- a staggered defender toggling their guard changes nothing about their state and everything
-- about how a contact resolves.
export type Segment = {
	State: DefenseState,
	BlockHeld: boolean,
	From: number,
	-- math.huge for the live segment.
	To: number,
}

export type Hooks = {
	-- Fires on every state change, with the time the transition was DUE. DefenseSystem uses it to
	-- publish the DefenseState Attribute and to notify the owning client.
	OnTransition: ((from: DefenseState, to: DefenseState, at: number) -> ())?,
}

export type Machine = typeof(setmetatable(
	{} :: {
		_state: DefenseState,
		_previousState: DefenseState,
		_enteredAt: number,
		_blockHeld: boolean,
		-- The window the CURRENT press armed, held for the press's whole life so a contact resolved
		-- late in the frame can still see what was armed at the start of it.
		_window: ParryWindow?,
		-- Absolute times, not offsets. _parryEndsAt carries the ping refund; the Blocking transition
		-- does not -- see this file's header.
		_parryOpensAt: number,
		_parryEndsAt: number,
		_parryConsumed: boolean,
		-- The rally multiplier the CURRENT press armed with (DefenseConstants.Rally), 1 outside a rally.
		-- Kept so the perfect-parry band shrinks with the window it belongs to.
		_windowScale: number,
		-- Wall-clock until which no new parry may be armed. Survives leaving ParryRecovery.
		_parryLockedUntil: number,
		-- When the defender last stopped holding guard, for the anti-turtle arming rule.
		_guardDownSince: number,
		_staggerUntil: number,
		_guardBrokenUntil: number,
		-- The evade window, absolute. _evadeEndsAt carries the ping refund. Zero when no evade has
		-- ever been opened, which no real contact time can fall inside.
		_evadeOpensAt: number,
		_evadeEndsAt: number,
		-- When the last evade was ACCEPTED, for DefenseConstants.Evade.CooldownSeconds. -math.huge rather
		-- than 0 so the very first evade is never refused against a synthetic clock that starts at 0.
		_lastEvadeAt: number,
		_segments: { Segment },
		_hooks: Hooks,
	},
	DefenseStateMachine
))

-- Bounded like AttackStateMachine's. The real maximum from a standing start is three
-- (Raising -> ParryWindow -> Blocking); eight leaves room for a phase without becoming a silent cap,
-- and guarantees Update terminates if a cycle is ever introduced.
local MAX_CHAINED_TRANSITIONS = 8

-- How many posture segments are kept. Pass 1 only ever queries times inside the current frame, and a
-- frame that produced sixteen posture changes is not one whose seventeenth-oldest matters. Bounded
-- because this trail is per-combatant and would otherwise grow for the whole session.
local MAX_SEGMENTS = 16

local function pushSegment(self: Machine, state: DefenseState, blockHeld: boolean, at: number): ()
	local segments = self._segments
	local live = segments[#segments]
	if live then
		if live.From == at then
			-- Two posture changes at the same instant (a zero-length Raising chaining straight into
			-- ParryWindow). Rewriting the live segment rather than pushing a zero-width one keeps the
			-- trail free of segments no query could ever select.
			live.State = state
			live.BlockHeld = blockHeld
			return
		end
		live.To = at
	end
	table.insert(segments, { State = state, BlockHeld = blockHeld, From = at, To = math.huge })
	while #segments > MAX_SEGMENTS do
		table.remove(segments, 1)
	end
end

function DefenseStateMachine.New(hooks: Hooks?): Machine
	local machine = setmetatable({
		_state = "Neutral" :: DefenseState,
		_previousState = "Neutral" :: DefenseState,
		_enteredAt = 0,
		_blockHeld = false,
		_window = nil,
		_parryOpensAt = 0,
		_parryEndsAt = 0,
		_parryConsumed = false,
		_windowScale = 1,
		_parryLockedUntil = 0,
		_guardDownSince = 0,
		_staggerUntil = 0,
		_guardBrokenUntil = 0,
		_evadeOpensAt = 0,
		_evadeEndsAt = 0,
		_lastEvadeAt = -math.huge,
		_segments = {},
		_hooks = hooks or {},
	}, DefenseStateMachine) :: any
	pushSegment(machine, "Neutral", false, 0)
	return machine
end

-- Transitions ----------------------------------------------------------------------------------------

local function applyTransition(self: Machine, target: DefenseState, at: number): ()
	local from = self._state
	if from == target then
		return
	end

	-- The moment the guard comes down is what the anti-turtle arming rule measures from. Recorded on
	-- the way OUT of a guarding posture rather than on the way in, because the rule is about how long
	-- you have been exposed, not how long you were covered.
	if from == "Blocking" then
		self._guardDownSince = at
	end

	self._previousState = from
	self._state = target
	self._enteredAt = at
	pushSegment(self, target, self._blockHeld, at)

	local onTransition = self._hooks.OnTransition
	if onTransition then
		onTransition(from, target, at)
	end
end

-- How long the CURRENT state lasts, or nil for the states that only end on an input or an external
-- call. Expressed against absolute times where the window supplies them, so the ping refund and the
-- authored offsets cannot be confused for one another.
local function phaseEnd(self: Machine): number?
	local state = self._state
	local window = self._window
	if state == "Raising" then
		-- Raising ends exactly when the window opens. Read off the absolute stamped at Press rather
		-- than re-derived from the offset, so there is one place that converts clip-relative to
		-- wall-clock and nowhere for the two to disagree.
		return if window then self._parryOpensAt else nil
	elseif state == "ParryWindow" then
		-- A parry that LANDED ends the window on the spot. ConsumeParry already pulled _parryEndsAt back
		-- to the contact, so the parrier drops straight to Blocking (key held) or Neutral instead of
		-- sitting in ParryWindow until its authored Close -- where CanAttack refuses "Guarding", a
		-- refusal the input buffer drops, eating the very counter-hit the parry just earned.
		if self._parryConsumed then
			return self._parryEndsAt
		end
		-- Closes at the authored Close, NOT at the ping-compensated _parryEndsAt. The refund extends
		-- how long a contact still counts as a parry; it must not delay the guard coming up, or a
		-- high-ping player is charged for the latency this is meant to refund.
		return if window then self._parryOpensAt + (window.Close - window.Open) else nil
	elseif state == "ParryRecovery" then
		-- Never earlier than the state was entered: a consumed window has stamped no lockout, and a stale
		-- one would otherwise date the transition out of here to some moment in the past.
		return math.max(self._parryLockedUntil, self._enteredAt)
	elseif state == "Staggered" then
		return self._staggerUntil
	elseif state == "GuardBroken" then
		return self._guardBrokenUntil
	end
	return nil
end

local function nextAfter(self: Machine, state: DefenseState, at: number): DefenseState?
	if state == "Raising" then
		return "ParryWindow"
	elseif state == "ParryWindow" then
		-- A parry armed OUT OF A STAGGER (DefenseConstants.Rally) that caught nothing drops straight back
		-- into the stagger it interrupted: the punish is still running, and a whiff must not end it.
		-- Held or released makes no difference here -- a staggered guard is represented as Staggered with
		-- the block held, exactly as a plain press during a stagger already is.
		if at < self._staggerUntil then
			return "Staggered"
		end
		-- The whole branch. Held guard becomes a block; a released tap that caught nothing becomes a
		-- whiff and pays the recovery.
		return if self._blockHeld then "Blocking" else "ParryRecovery"
	elseif state == "ParryRecovery" then
		if at < self._staggerUntil then
			return "Staggered"
		end
		return if self._blockHeld then "Blocking" else "Neutral"
	elseif state == "Staggered" then
		return if self._blockHeld then "Blocking" else "Neutral"
	elseif state == "GuardBroken" then
		return if self._blockHeld then "Blocking" else "Neutral"
	end
	return nil
end

-- Advances to `now`, chaining. Returns the state active when it finishes.
function DefenseStateMachine.Update(self: Machine, now: number): DefenseState
	for _ = 1, MAX_CHAINED_TRANSITIONS do
		local dueAt = phaseEnd(self)
		if dueAt == nil or now < dueAt then
			break
		end

		local state = self._state
		-- A window that closes without having been consumed is a whiff, and the lockout is stamped
		-- HERE rather than on entry to ParryRecovery -- so it is charged even when the player presses
		-- straight back into a block and never visits that state at all.
		if state == "ParryWindow" and not self._parryConsumed and not self._blockHeld then
			local window = self._window
			local recovery = if window
				then window.RecoveryEnd - window.Close
				else DefenseConstants.Parry.RecoverySeconds
			self._parryLockedUntil = math.max(self._parryLockedUntil, dueAt + recovery)
		end

		local target = nextAfter(self, state, dueAt)
		if target == nil then
			break
		end
		applyTransition(self, target, dueAt)
	end

	return self._state
end

-- Input ----------------------------------------------------------------------------------------------

-- The block/parry press. `window` is the parry window for whatever defensive animation this combatant
-- uses, or nil when none is armed for it -- in which case this is a plain block, exactly as the
-- fail-closed rule requires.
--
-- Returns whether a parry was actually armed, so the caller can tell the client which animation to
-- play without re-deriving the arming rules.
--
-- FAIL-SOFT ON EVERY REFUSAL. A press that cannot arm a parry -- no window, still inside a lockout,
-- guard dropped too recently, mid-stagger -- still raises the guard. The player never loses their
-- block for pressing at a bad moment; they only lose the parry, which is the thing being priced.
--
-- `windowScale` is the rally multiplier (DefenseConstants.Rally) -- the caller owns who is rallying with
-- whom; this only shortens the window it was handed. Omitted, or anything outside (0, 1), means 1.
function DefenseStateMachine.Press(
	self: Machine,
	now: number,
	window: ParryWindow?,
	pingSeconds: number,
	windowScale: number?
): boolean
	self._blockHeld = true

	-- A guard break is an opening, and the whole point of an opening is that the guard is not
	-- available. The press is remembered (so the guard comes up the instant the break ends) but
	-- changes nothing now.
	if self._state == "GuardBroken" then
		pushSegment(self, self._state, true, now)
		return false
	end

	-- Already guarding. Nothing to re-arm -- re-pressing without releasing must not mint a second
	-- window, which is the shape of the hold-and-retap exploit.
	if self._state == "Raising" or self._state == "ParryWindow" or self._state == "Blocking" then
		pushSegment(self, self._state, true, now)
		return false
	end

	local canArm = window ~= nil
		and now >= self._parryLockedUntil
		and (now - self._guardDownSince) >= DefenseConstants.Parry.MinUnguardedSeconds
		-- A staggered attacker may parry back only while parry trading is on (DefenseConstants.Rally).
		-- Otherwise they can block but not parry -- the original brief's two halves.
		and (self._state ~= "Staggered" or DefenseConstants.Rally.ParryFromStagger)

	if not canArm then
		if self._state == "Staggered" then
			-- Guard up, but the stagger still owns the state for reporting and for the degraded
			-- mitigation the counterweight applies. Only the posture changes.
			pushSegment(self, self._state, true, now)
		else
			applyTransition(self, "Blocking", now)
		end
		return false
	end

	local scale = if windowScale and windowScale > 0 and windowScale < 1 then windowScale else 1
	local armed = window :: ParryWindow
	if scale < 1 then
		-- Same opening moment, shorter duration. The whiff recovery after the close keeps its own length:
		-- a rally makes the read harder, not the miss cheaper.
		local close = armed.Open + (armed.Close - armed.Open) * scale
		armed = {
			Open = armed.Open,
			Close = close,
			RecoveryEnd = close + (armed.RecoveryEnd - armed.Close),
			Source = armed.Source,
		}
	end
	self._windowScale = scale
	self._window = armed
	-- ParryWindows deals in clip-relative offsets; everything on this machine past this point is
	-- wall-clock. This pair is the single conversion between the two.
	self._parryOpensAt = now + armed.Open
	self._parryEndsAt = now + ParryWindows.ParryEndFor(armed, pingSeconds)
	self._parryConsumed = false

	applyTransition(self, "Raising", now)
	-- Driven immediately so a window authored to open at 0 is live within this call rather than on
	-- the next tick -- the same reasoning as AttackStateMachine.Begin's own immediate Update.
	DefenseStateMachine.Update(self, now)
	return true
end

-- The release. Drops the guard; where that leads depends on what was holding it up.
function DefenseStateMachine.Release(self: Machine, now: number): ()
	if not self._blockHeld then
		return
	end
	self._blockHeld = false

	local state = self._state
	if state == "Blocking" then
		applyTransition(self, "Neutral", now)
		return
	end
	-- A staggered guard coming down is a guard coming down, for the anti-turtle rule. applyTransition
	-- only stamps this on the way out of Blocking, and a staggered block never is Blocking -- so without
	-- this, holding guard through a stagger and re-tapping would re-arm a parry trade for free.
	if state == "Staggered" then
		self._guardDownSince = now
	end
	-- Released mid-window. The window is NOT cancelled -- it runs to its close regardless, and the
	-- release only decides where that close leads (ParryRecovery rather than Blocking). A parry is a
	-- committed read; the alternative is a free arm-and-disarm, where a tap buys a live window while
	-- leaving the player free to act inside it.
	pushSegment(self, state, false, now)
end

-- External conditions ---------------------------------------------------------------------------------

-- The parry punish, imposed by DefenseSystem when THIS combatant's attack is parried. Pre-empts
-- whatever the defender was doing -- a stagger is not something the staggered player's own state
-- machine gets an opinion about.
--
-- `seconds` overrides the ordinary length -- a PERFECT parry passes DefenseConstants.PerfectParry.
-- StaggerSeconds. Omitted means Stagger.DurationSeconds, which is every other caller.
function DefenseStateMachine.Stagger(self: Machine, now: number, seconds: number?): ()
	self._staggerUntil = now + (seconds or DefenseConstants.Stagger.DurationSeconds)
	-- Without parry trading, cannot parry for the duration -- and the lockout is a timestamp rather
	-- than the state itself so it survives the player pressing straight back into a block. With it
	-- (DefenseConstants.Rally), parrying back is the whole point, so no lockout is stamped here.
	if not DefenseConstants.Rally.ParryFromStagger then
		self._parryLockedUntil = math.max(self._parryLockedUntil, self._staggerUntil)
	end
	self._window = nil
	self._parryOpensAt = 0
	self._parryEndsAt = 0
	applyTransition(self, "Staggered", now)
end

-- The guard emptying. Same pre-emption, and it additionally forbids blocking for its duration, which
-- is what makes a break a real opening rather than a scratch.
--
-- A BREAK CAN NEVER SHORTEN A STAGGER, and the max below is what guarantees it. GuardBroken and
-- Staggered both end at their own timestamp (see phaseEnd), so transitioning from one to the other
-- abandons the timer that was running -- and a break landing late in a stagger (or a perfect parry's
-- longer one, PerfectParry.StaggerSeconds 1.1 against GuardBrokenSeconds 1.0) would otherwise let them
-- act SOONER than if their guard had held. That inverts both mechanics at once: the counterweight that makes
-- "a parried attacker may still block" cost something (DefenseConstants.Stagger.GuardDrainMultiplier
-- exists precisely so a turtling stagger ends one hit from a break) would instead be an escape hatch
-- out of the punish it is supposed to sharpen.
--
-- Taking the later of the two is the honest reading rather than a patch: both states mean "cannot
-- attack, cannot parry," and GuardBroken only ADDS "cannot block," so a break landing mid-stagger is
-- strictly the harsher punish and should last at least as long as what it replaced.
function DefenseStateMachine.BreakGuard(self: Machine, now: number): ()
	self._guardBrokenUntil = now + DefenseConstants.GuardBrokenSeconds
	if self._state == "Staggered" then
		self._guardBrokenUntil = math.max(self._guardBrokenUntil, self._staggerUntil)
	end
	self._window = nil
	self._parryOpensAt = 0
	self._parryEndsAt = 0
	applyTransition(self, "GuardBroken", now)
end

-- Spends the parry. Called once, by DefenseSystem, for the contact that actually landed inside the
-- window -- which is why being surrounded is dangerous: one window stops one attack.
-- `at` is the contact's SampleTime, taken for symmetry with every other entry point on this machine
-- and so a future consumer can order consumptions; the flag itself is what closes the window.
--
-- A consumed parry is a SUCCESS, so it must not also charge the whiff lockout -- Update's whiff
-- branch is gated on this flag for exactly that reason.
function DefenseStateMachine.ConsumeParry(self: Machine, at: number): ()
	self._parryConsumed = true
	self._parryEndsAt = math.min(self._parryEndsAt, at)
	-- A parry landed OUT OF A STAGGER wins the exchange (DefenseConstants.Rally): the punish ends here,
	-- and the window's own early close (phaseEnd) then hands the body straight back.
	if self._staggerUntil > at then
		self._staggerUntil = at
	end
end

-- Opens the evade window, or refuses and says why. The POSTURE gates live here; the BODY gates
-- (mid-swing, hitstun, grabbed, mounted) are DefenseSystem.BeginEvade's, because they read things this
-- machine has no view of -- the same split SetBlocking/Press already make.
--
-- Staggered and GuardBroken refuse because both are punishes, and an evade out of either would be the
-- cheapest possible way to make a punish end early. The parkour client never gets this far in either
-- (both take RootControlLocked, which parks the framework) -- this is the server not trusting that.
--
-- A RAISED GUARD IS DROPPED, not refused. Evade-from-guard is a legitimate read, and it goes through the
-- ordinary Release so the anti-turtle clock and the segment trail record it exactly as a key release
-- would. A parry window already armed is NOT cancelled -- it runs to its close, per Release's own rule --
-- but a contact inside both resolves Evaded first (OutcomeResolver rule 0) and never spends it.
function DefenseStateMachine.BeginEvade(self: Machine, now: number, pingSeconds: number): (boolean, string?)
	local state = self._state
	if state == "Staggered" or DefenseStateMachine.IsStaggerHeld(self) then
		return false, "Staggered"
	end
	if state == "GuardBroken" then
		return false, "GuardBroken"
	end
	local EVADE = DefenseConstants.Evade
	if (now - self._lastEvadeAt) < EVADE.CooldownSeconds then
		return false, "EvadeCooldown"
	end

	DefenseStateMachine.Release(self, now)

	local refund = 0
	if pingSeconds == pingSeconds and pingSeconds > 0 then
		refund = math.min(pingSeconds, EVADE.PingCompensationMaxSeconds)
	end
	self._lastEvadeAt = now
	self._evadeOpensAt = now + EVADE.StartupSeconds
	self._evadeEndsAt = self._evadeOpensAt + EVADE.ActiveSeconds + refund
	return true, nil
end

-- Queries -----------------------------------------------------------------------------------------

function DefenseStateMachine.GetState(self: Machine): DefenseState
	return self._state
end

function DefenseStateMachine.GetPreviousState(self: Machine): DefenseState
	return self._previousState
end

function DefenseStateMachine.IsBlockHeld(self: Machine): boolean
	return self._blockHeld
end

function DefenseStateMachine.GetStateElapsed(self: Machine, now: number): number
	return math.max(now - self._enteredAt, 0)
end

local function segmentAt(self: Machine, at: number): Segment?
	local segments = self._segments
	for index = #segments, 1, -1 do
		local segment = segments[index]
		if at >= segment.From and at < segment.To then
			return segment
		end
	end
	-- Older than anything retained. The oldest segment is the best available answer and is returned
	-- rather than nil, so a caller never has to special-case a trail that has rolled over -- it can
	-- only happen for a time well outside the current frame, which nothing in this system queries.
	return segments[1]
end

-- The defender's state at `at`. See this file's header for why this exists.
function DefenseStateMachine.StateAt(self: Machine, at: number): DefenseState
	local segment = segmentAt(self, at)
	return if segment then segment.State else self._state
end

-- Whether the guard was up at `at`. Needed alongside StateAt because a staggered defender's block is
-- allowed, so "Staggered" alone does not say whether a contact was blocked.
function DefenseStateMachine.BlockHeldAt(self: Machine, at: number): boolean
	local segment = segmentAt(self, at)
	return if segment then segment.BlockHeld else self._blockHeld
end

-- Whether a contact at `at` lands inside the live, unspent parry window. The precise membership test,
-- deliberately NOT "is the state ParryWindow" -- ping compensation extends this end past the state's
-- own transition, and a consumed window is closed even though the state has not moved.
function DefenseStateMachine.IsParryLiveAt(self: Machine, at: number): boolean
	if self._parryConsumed then
		return false
	end
	if self._parryEndsAt <= 0 then
		return false
	end
	return at >= self._parryOpensAt and at <= self._parryEndsAt
end

-- Whether a contact at `at`, already known to land inside the live window, is a PERFECT parry: within
-- DefenseConstants.PerfectParry.WindowSeconds of the window going live. Measured from _parryOpensAt,
-- the same absolute the liveness test above uses, so the two can never disagree about when the window
-- began -- see PerfectParry's own header on why no ping refund is applied here. Pure query: asks
-- nothing about whether the window is live or spent, which the caller has already established.
function DefenseStateMachine.IsPerfectParryAt(self: Machine, at: number): boolean
	if self._parryEndsAt <= 0 then
		return false
	end
	local elapsed = at - self._parryOpensAt
	return elapsed >= 0 and elapsed <= DefenseConstants.PerfectParry.WindowSeconds * self._windowScale
end

-- Whether a contact at `at` lands inside the evade window. Unlike the parry it is never
-- consumed: an evade through two swings evades both, because the dodge is about where the body IS, not
-- about spending a read on one attack.
function DefenseStateMachine.IsEvadingAt(self: Machine, at: number): boolean
	if self._evadeEndsAt <= 0 then
		return false
	end
	return at >= self._evadeOpensAt and at <= self._evadeEndsAt
end

-- Whether a new parry could be armed right now. Exposed for the client's own prediction and for the
-- debug readout; the authoritative check is inside Press.
-- The STATE checks come before the lockout deliberately. A stagger sets both -- it forbids arming and
-- stamps _parryLockedUntil to its own end -- so a caller asking mid-punish would otherwise be told
-- "Locked", which is true but useless. "Staggered" is the reason a player could act on.
function DefenseStateMachine.CanArmParryAt(self: Machine, at: number): (boolean, string?)
	if self._state == "Staggered" and not DefenseConstants.Rally.ParryFromStagger then
		return false, "Staggered"
	end
	if self._state == "GuardBroken" then
		return false, "GuardBroken"
	end
	if at < self._parryLockedUntil then
		return false, "Locked"
	end
	if (at - self._guardDownSince) < DefenseConstants.Parry.MinUnguardedSeconds then
		return false, "GuardTooRecent"
	end
	return true, nil
end

-- THE AIR PARRY'S REWIND (docs/design/air-combat-and-evade.md B5): would a press made at `pressAt` -- in the
-- past, the arrival of a press minus the defender's round trip -- have caught a contact at `contactAt`?
-- Judged exactly as Press judges a live press, but at `pressAt`: the whiff lockout and MinUnguardedSeconds
-- evaluated then, the guard not already held then (a held guard mints no window), and the window's own
-- opening and (rally-scaled) length from then. NO END REFUND: the rewind replaces the ping refund, it does
-- not stack with it. Returns whether it covers, and whether it would have been PERFECT.
--
-- A pure query. DefenseSystem only ever asks it for an AIR-HELD defender's held Clean contact, and applies
-- the answer itself (the window the arriving press armed is spent through the ordinary ConsumeParry).
function DefenseStateMachine.RewoundParryCovers(
	self: Machine,
	pressAt: number,
	contactAt: number,
	window: ParryWindow?,
	windowScale: number?
): (boolean, boolean)
	if window == nil then
		return false, false
	end
	if pressAt < self._parryLockedUntil then
		return false, false
	end
	if (pressAt - self._guardDownSince) < DefenseConstants.Parry.MinUnguardedSeconds then
		return false, false
	end
	local stateThen = DefenseStateMachine.StateAt(self, pressAt)
	if stateThen == "GuardBroken" or (stateThen == "Staggered" and not DefenseConstants.Rally.ParryFromStagger) then
		return false, false
	end
	if DefenseStateMachine.BlockHeldAt(self, pressAt) then
		return false, false
	end
	local scale = if windowScale and windowScale > 0 and windowScale < 1 then windowScale else 1
	local opensAt = pressAt + window.Open
	local closesAt = opensAt + (window.Close - window.Open) * scale
	if contactAt < opensAt or contactAt > closesAt then
		return false, false
	end
	return true, (contactAt - opensAt) <= DefenseConstants.PerfectParry.WindowSeconds * scale
end

-- Whether a stagger is still running underneath the current state -- true in Staggered itself, and in a
-- parry window armed out of one (DefenseConstants.Rally) that has not landed yet. DefenseSystem keeps
-- the movement lock on through it, and the evade and attack gates treat it as the stagger it is:
-- arming a parry mid-punish must not become a way to evade or swing out of that punish.
--
-- Read off the time the current state was ENTERED rather than a clock, so it needs none: a state
-- entered before the stagger's end began inside the punish. A landed parry pulls _staggerUntil back
-- to the contact, and the window closes on that same instant, so the next state starts clear.
function DefenseStateMachine.IsStaggerHeld(self: Machine): boolean
	local state = self._state
	if state == "Staggered" then
		return true
	end
	if state == "Raising" or state == "ParryWindow" or state == "ParryRecovery" then
		return self._enteredAt < self._staggerUntil
	end
	return false
end

-- Whether this combatant may start an attack. The defence layer's job, not the engine's -- see
-- DefenseSystem's own header.
function DefenseStateMachine.CanAttack(self: Machine): (boolean, string?)
	local state = self._state
	if state == "Staggered" or DefenseStateMachine.IsStaggerHeld(self) then
		return false, "Staggered"
	end
	if state == "GuardBroken" then
		return false, "GuardBroken"
	end
	if state == "Raising" or state == "ParryWindow" or state == "Blocking" then
		return false, "Guarding"
	end
	return true, nil
end

-- Drops everything to Neutral, running the ordinary transition path so nothing is left published on a
-- body. For teardown -- unregistration, a respawn, a spec resetting between cases.
function DefenseStateMachine.Reset(self: Machine, now: number): ()
	self._blockHeld = false
	self._window = nil
	self._parryOpensAt = 0
	self._parryEndsAt = 0
	self._parryConsumed = false
	self._windowScale = 1
	self._parryLockedUntil = 0
	self._guardDownSince = 0
	self._staggerUntil = 0
	self._guardBrokenUntil = 0
	self._evadeOpensAt = 0
	self._evadeEndsAt = 0
	self._lastEvadeAt = -math.huge
	if self._state ~= "Neutral" then
		applyTransition(self, "Neutral", now)
	end
	self._previousState = "Neutral"
	self._enteredAt = now
	table.clear(self._segments)
	pushSegment(self, "Neutral", false, now)
end

return DefenseStateMachine
