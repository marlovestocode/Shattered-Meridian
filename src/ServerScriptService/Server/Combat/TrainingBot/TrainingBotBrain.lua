--!strict
--[[
	TrainingBotBrain.lua

	Owns: every DECISION a training bot makes -- when it notices your swing, which way it answers it,
	exactly when it presses, when it presses the attack and with what, where it stands, and what it has
	learned about you. Pure: it is handed a Perception (primitives only, no Instances, no clock of its own,
	no services) and a Random, and it returns an Intent. TrainingBotSystem.lua does every Instance read,
	and every action goes through the combat stack's own public functions -- this module could not cheat
	if it tried, because it cannot reach anything.

	    TrainingBotSystem  reads the world, applies the intent through the player's own entry points
	    TrainingBotBrain   what a player in its position would decide                  <- this module

	WHAT "FIGHTS LIKE A PLAYER" MEANS HERE, and the three rules that keep it honest:

	  1. IT SEES YOUR SWING LATE. A swing is noticed ReactionSeconds (sampled per swing, with jitter)
	     after the server started it -- the gap between the windup starting on screen and a human's hand
	     moving. Everything it does in answer is scheduled from that moment, never from the swing's
	     start. A swing whose impact arrives before the bot has noticed it simply lands.

	  2. IT PRESSES WITH HUMAN ERROR. A parry press aims at the middle of the real window
	     (Perception.ParryOpen/Close, read from the same ParryWindows the defence layer times against) and
	     misses by a Gaussian TimingErrorSeconds; MisreadChance occasionally throws it a whole beat off.
	     An early press held degrades into a block, a tapped one into a whiff -- exactly as yours does.

	  3. IT KNOWS THE MOVE LIST, NOT YOUR INPUTS. It is told which move you started and that move's
	     authored windup (what a practised player knows by sight) and nothing else -- not your buffered
	     press, not whether you are about to feint. A feint therefore baits it exactly as it baits a
	     person: it commits to answering a Heavy that never arrives. What it CAN do, from Adept up, is
	     LEARN that you feint and start waiting out AttackConstants.Feint's window before it commits,
	     which is precisely the read a good player makes (combat-philosophy.md: "reads beat reflexes at
	     the top").

	THE HABIT MODEL. Every contact its own swings make updates an EMA of how YOU answer them (block,
	parry, roll, or eat it), and every feintable swing you throw updates an EMA of how often you feint.
	Those estimates reshape the style's weights by the difficulty's ReadInfluence: a bot that sees you
	block leans into Heavies (guard drain -- GuardMeter), one that sees you parry leans into feint
	baits, one that sees you roll shortens its strings to catch the roll's recovery. The billboard
	narrates the read so a tester can see why it just did what it did.

	PLAYING ITS TURN (2026-09-28, "they are actually lobotomized"). What a player does that the first build
did not, all tuned in TrainingBotConstants.Offence: you stepping into its reach while idle is its turn to
swing, not a cue to back away; a held guard gets a Heavy rather than a feint; a block on the swing that
ENDS your string is dropped into your recovery and punished rather than held until you are safe again;
its own strings are not a metronome -- it holds a beat back, more so the more you parry; and a string
that lands is followed up rather than walked away from.

COMPOSURE. A 0..1 mood that drops when it is hit or guard-broken and recovers over time and on its
	own successes. Low composure makes it parry less, roll and block more, and back off -- a rattled
	bot looks rattled, which is most of what makes a sparring partner feel alive rather than scripted.

	Does not own: whether anything it decides is LEGAL (every Intent is attempted through
	AttackRequestSystem/DefenseSystem, which refuse exactly what they refuse a player), the rig, movement
	physics, animation, or targeting (all TrainingBotSystem.lua).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TrainingBotConstants = require(ReplicatedStorage.Shared.TrainingBot.TrainingBotConstants)

type Style = TrainingBotConstants.Style
type Difficulty = TrainingBotConstants.Difficulty

local TrainingBotBrain = {}

-- A swing, as a player sees it: which kind of move started, when, and how long its windup is.
export type SwingView = {
	StartedAt: number,
	WindupSeconds: number,
	Feintable: boolean,
	Heavy: boolean,
}

export type Perception = {
	Now: number,
	HasTarget: boolean,
	-- Horizontal studs, root to root.
	Distance: number,
	Reach: number,
	TargetReach: number,
	-- Degrees between the bot's facing and the direction to the target (0 = squarely facing them).
	FacingError: number,
	-- Degrees between the TARGET's facing and the direction to the bot (180 = the bot is behind them).
	BearingFromTarget: number,

	TargetSwing: SwingView?,
	TargetAttackState: string,
	TargetDefenseState: string,
	TargetGuardFraction: number,
	-- In hitstun (HitstunUntil) -- a swing of theirs that vanishes now was interrupted, not feinted.
	TargetStunned: boolean,

	SelfSwing: SwingView?,
	SelfAttackState: string,
	-- CombatBusyUntil: when the bot's own body is next free to guard or roll on time.
	SelfBusyUntil: number,
	SelfDefenseState: string,
	SelfGuardFraction: number,
	SelfHealthFraction: number,
	-- Hitstunned, grabbed, staggered or guard-broken: nothing it decides can happen this frame.
	SelfDisabled: boolean,
	-- Grabbed, staggered or guard-broken: a guard pressed now would not come up in time to matter.
	-- Hitstun is deliberately NOT in here -- its end is already in SelfBusyUntil, and DefenseSystem holds
	-- a guard pressed during it and raises it the instant it ends, which the bot uses.
	SelfLocked: boolean,
	-- Earliest time a guard PRESS can arm a parry: DefenseConstants.Parry.MinUnguardedSeconds after the
	-- guard last came down, or math.huge while it is still up (a held guard is not a fresh press). A
	-- press before this only blocks.
	ParryArmableAt: number,
	SelfEvading: boolean,
	EvadeReady: boolean,
	HomeDistance: number,

	-- THE AIR COMBO (docs/design/air-combat-and-evade.md). All optional, so a perception built before air
	-- combat existed (every spec's) reads as "on the ground, in nobody's combo".
	-- Held in the air by your combo: the ONLY answer left is a timed parry -- a guard does nothing, an evade
	-- is refused, and it cannot swing. Its rhythm read applies to your air beats like any other swing.
	SelfAirHeld: boolean?,
	-- Stunned on the ground by a hit, not swinging: the ground half of the same rule (DefenseConstants.StunParry)
	-- -- a guard does nothing, an evade is refused, and a timed parry on the next impact breaks the string.
	SelfStunHeld: boolean?,
	-- The attacker of a live combo -- its launcher landed on you.
	SelfAirAttacker: boolean?,
	-- How many of its air beats have landed, and when its first air press may be thrown.
	SelfAirHitsLanded: number?,
	AirPressReadyAt: number?,
	-- A wall close behind you, along the line it would Spike you: the finisher it picks.
	WallBehindTarget: boolean?,

	-- The combat stack's own numbers, handed in rather than required so this module stays pure.
	FeintWindowFraction: number,
	ParryOpen: number,
	ParryClose: number,
	EvadeStartup: number,
	EvadeActive: number,
}

export type MoveKind = "Hold" | "Approach" | "Retreat" | "Strafe" | "Home"
export type EvadeDirection = "Back" | "Left" | "Right"
export type AttackKind = "Basic" | "Heavy"
-- One press a plan makes. "Launcher" is a Basic thrown with the Up modifier (Space + M1) -- the air combo's
-- branch off the string, earned by the Basics before it.
export type PlanPress = AttackKind | "Launcher"

export type Intent = {
	Move: MoveKind,
	StrafeSign: number,
	Sprint: boolean,
	Guard: boolean,
	Attack: AttackKind?,
	-- "Up" presses the attack with the jump key held: the launcher on a Basic, the Spike on an air Heavy.
	Modifier: "Up"?,
	Feint: boolean,
	Evade: EvadeDirection?,
}

export type Response = "Parry" | "Block" | "Evade" | "Trade" | "None"

export type Stats = {
	Seen: number,
	Parry: number,
	Block: number,
	Evade: number,
	Trade: number,
	-- Noticed after the swing had already landed.
	Late: number,
	-- Its own swing, a stagger or a grab would still hold the body when the hit landed.
	Busy: number,
	-- Too far away to be hit; let it whiff.
	Range: number,
	-- Chose not to answer (no weight on any option this style could use).
	None: number,
}

-- How the TARGET has been answering the bot's swings, and how often they feint. EMAs, 0..1.
export type Habits = {
	Block: number,
	Parry: number,
	Evade: number,
	Clean: number,
	Feint: number,
}

type Threat = {
	StartedAt: number,
	NoticeAt: number,
	ImpactAt: number,
	Swing: SwingView,
	Decided: boolean,
	Response: Response,
	ActAt: number,
	ReleaseAt: number,
	EvadeDirection: EvadeDirection,
	EvadeSent: boolean,
	-- Set once the swing ends (landed, whiffed, feinted or was interrupted). A Block keeps its guard up
	-- until ReleaseAt after this; everything else is simply done.
	Over: boolean,
	SawActive: boolean,
}

type Plan = {
	Label: string,
	-- Presses still to make, in order.
	Queue: { PlanPress },
	-- Throw the head of Queue as a Heavy and feint it at this fraction of its feint window.
	FeintFraction: number?,
	-- Set once the planned feint's swing is accepted: feint when Now passes this.
	FeintAt: number?,
	-- When the current head press was first wanted -- a press refused for this long is abandoned.
	WantedSince: number?,
	-- A deliberate hold before the next press (TrainingBotConstants.Offence's anti-metronome): rolled
	-- when a press is accepted, started once the body is free, and pressed at PressAt.
	PendingDelay: number?,
	PressAt: number?,
	ExpiresAt: number,
	Punish: boolean,
}

-- Its air string, once its launcher has you up: how many beats it means to land before cashing out, and
-- when it will press the next one (on-beat, or held back to bait your parry).
type AirPlan = {
	Length: number,
	NextAt: number,
	SeenHits: number,
}

export type Brain = {
	Air: AirPlan?,
	Style: Style,
	Difficulty: Difficulty,
	StyleName: string,
	DifficultyName: string,
	Rng: Random,

	Habits: Habits,
	Composure: number,
	Narration: string,
	-- What happened to every swing of yours it noticed -- the billboard's answer to "why didn't it block".
	Stats: Stats,
	-- Your string's rhythm: seconds between consecutive swing starts inside a string (EMA), and the
	-- start/windup of the last one, so a follow-up that arrives on the beat is read early.
	Cadence: number?,
	LastSwingStart: number?,
	-- Which swing of your current string the last one was (1..Offence.StringLength) -- what tells it
	-- that a blocked swing ended your string and its recovery is there to punish.
	StringCount: number,
	-- When a contact of its own last landed clean (or broke your guard), and until when a string that
	-- ended on it may be followed straight up (Offence.PressureWindowSeconds).
	LastLandedAt: number,
	PressureUntil: number,
	-- Clean contacts its CURRENT plan has landed -- what decides whether a planned Launcher was earned.
	PlanLanded: number,
	-- Guard held up in neutral, as a player holds block when you are in their face, until this time.
	StanceUntil: number,
	NextStanceThinkAt: number,

	-- Internal state; exposed on the record (not hidden behind closures) so a spec can read it.
	Threat: Threat?,
	Plan: Plan?,
	NextThinkAt: number,
	StrafeSign: number,
	StrafeFlipAt: number,
	RetreatUntil: number,
	-- Footsies: planted (letting you commit) or circling, re-rolled with the strafe direction.
	Planted: boolean,
	ConsecutiveBlocked: number,
	-- One punish roll per opening: the DefenseState it was taken (or declined) against, cleared once the
	-- target leaves a punishable state; and the swing whose whiff it has already judged.
	PunishJudgedState: string?,
	WhiffJudgedFor: number?,
	LastNow: number,
	-- Recent server frame length (EMA). A press is only ever applied on a frame, so a PerfectParry style
	-- aims one frame ahead of its ideal moment to land on the last frame that still makes it.
	FrameSeconds: number,
	-- Style.CounterAfterParry: the one counter swing its last parry earned, owed until this time. Set by
	-- OnOutcome when it parries you, spent when the swing is planned -- so a missed parry-back (which
	-- drops you straight back into the same stagger) does not earn it a second free swing.
	CounterOwedUntil: number,
}

-- Maths -------------------------------------------------------------------------------------------

-- One sample of N(mean, sd) -- Box-Muller. 1 - NextNumber keeps the log argument off exactly 0.
local function gaussian(rng: Random, mean: number, sd: number): number
	if sd <= 0 then
		return mean
	end
	local u1 = 1 - rng:NextNumber()
	local u2 = rng:NextNumber()
	return mean + sd * math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2)
end

local function ema(current: number, observed: number, alpha: number): number
	return current + (observed - current) * alpha
end

local function pickWeighted(rng: Random, weights: { [string]: number }, order: { string }): string?
	local total = 0
	for _, key in order do
		total += math.max(weights[key] or 0, 0)
	end
	if total <= 0 then
		return nil
	end
	local roll = rng:NextNumber() * total
	for _, key in order do
		local weight = math.max(weights[key] or 0, 0)
		if roll < weight then
			return key
		end
		roll -= weight
	end
	return order[#order]
end

local RESPONSE_ORDER = { "Parry", "Block", "Evade", "Trade" }

local function percent(value: number): string
	return `{math.floor(value * 100 + 0.5)}%`
end

-- Construction ------------------------------------------------------------------------------------

function TrainingBotBrain.new(styleName: string, difficultyName: string, rng: Random): Brain
	local style = TrainingBotConstants.Styles[styleName :: any]
		or TrainingBotConstants.Styles[TrainingBotConstants.DefaultStyle]
	local difficulty = TrainingBotConstants.Difficulties[difficultyName :: any]
		or TrainingBotConstants.Difficulties[TrainingBotConstants.DefaultDifficulty]
	return {
		Air = nil,
		Style = style,
		Difficulty = difficulty,
		StyleName = styleName,
		DifficultyName = difficultyName,
		Rng = rng,
		-- Neutral priors: most people eat a fair few hits and block more than they parry, and nobody is
		-- assumed to feint until they have been seen to.
		Habits = { Block = 0.3, Parry = 0.2, Evade = 0.1, Clean = 0.4, Feint = 0 },
		Composure = 1,
		Narration = "Sizing you up",
		Stats = { Seen = 0, Parry = 0, Block = 0, Evade = 0, Trade = 0, Late = 0, Busy = 0, Range = 0, None = 0 },
		Cadence = nil,
		LastSwingStart = nil,
		StringCount = 0,
		LastLandedAt = -math.huge,
		PressureUntil = -math.huge,
		PlanLanded = 0,
		StanceUntil = 0,
		NextStanceThinkAt = 0,
		Threat = nil,
		Plan = nil,
		NextThinkAt = 0,
		StrafeSign = if rng:NextNumber() < 0.5 then -1 else 1,
		StrafeFlipAt = 0,
		RetreatUntil = 0,
		Planted = false,
		ConsecutiveBlocked = 0,
		PunishJudgedState = nil,
		WhiffJudgedFor = nil,
		LastNow = 0,
		FrameSeconds = 1 / 60,
		CounterOwedUntil = -math.huge,
	}
end

-- Reads -------------------------------------------------------------------------------------------

-- "blk 45% | pry 20% | evade 10% | feint 30%" -- what the bot currently believes about you.
function TrainingBotBrain.DescribeRead(brain: Brain): string
	local habits = brain.Habits
	return `blk {percent(habits.Block)} | pry {percent(habits.Parry)} | evade {percent(habits.Evade)} | feint {percent(
		habits.Feint
	)}`
end

-- "Seen 14: P5 B4 R1 T0 | late 1 busy 2 far 1" -- what it did with every swing of yours it noticed.
function TrainingBotBrain.DescribeAnswers(brain: Brain): string
	local stats = brain.Stats
	return `Seen {stats.Seen}: P{stats.Parry} B{stats.Block} R{stats.Evade} T{stats.Trade} | late {stats.Late} busy {stats.Busy} far {stats.Range}`
end

-- Threats (your swings) ---------------------------------------------------------------------------

local function narrate(brain: Brain, line: string): ()
	brain.Narration = line
end

-- Beyond this gap between two swing starts, the second one is a new exchange, not the next beat of a
-- string, and teaches the cadence nothing.
-- Sized off the M1 string's own start-to-start beat (~1.03-1.06s since AttackConstants' 2026-09-28
-- slowdown) with room for a late press; the end-of-string lockout pushes a fresh string past it.
local STRING_GAP_SECONDS = 1.35
-- How close to the expected beat a swing has to start to count as "on rhythm".
local RHYTHM_TOLERANCE_SECONDS = 0.15
-- A swing that arrives exactly when it was expected is not reacted to -- it was already being watched
-- for. What is left is the time to commit, not to notice.
local RHYTHM_REACTION_SECONDS = 0.07

local function beginThreat(brain: Brain, swing: SwingView): ()
	local difficulty = brain.Difficulty
	local rng = brain.Rng
	local reaction = math.max(
		gaussian(rng, difficulty.ReactionSeconds, difficulty.ReactionJitterSeconds),
		difficulty.ReactionMinSeconds
	)
	-- The parry-trade drill (Style.PerfectParry) is not a person: it sees the swing the moment it starts.
	if brain.Style.PerfectParry then
		reaction = 0
	end

	-- READING THE STRING. A player does not react to the second and third swings of a string -- they
	-- have the rhythm from the first. Every swing that starts inside a string updates the cadence; one
	-- that lands on the expected beat is seen almost at once, as often as this difficulty reads rhythm.
	local last = brain.LastSwingStart
	local continuesString = false
	if last then
		local gap = swing.StartedAt - last
		continuesString = gap > 0 and gap <= STRING_GAP_SECONDS
		if continuesString then
			local cadence = brain.Cadence
			if
				cadence
				and math.abs(gap - cadence) <= RHYTHM_TOLERANCE_SECONDS
				and rng:NextNumber() < difficulty.RhythmRead
			then
				reaction = math.min(reaction, RHYTHM_REACTION_SECONDS + math.abs(gaussian(rng, 0, 0.03)))
			end
			brain.Cadence = if cadence then ema(cadence, gap, 0.35) else gap
		end
	end
	brain.LastSwingStart = swing.StartedAt
	-- A string past its last Basic is a fresh one (the end-of-string lockout sits between them).
	brain.StringCount = if continuesString and brain.StringCount < TrainingBotConstants.Offence.StringLength
		then brain.StringCount + 1
		else 1

	brain.Threat = {
		StartedAt = swing.StartedAt,
		NoticeAt = swing.StartedAt + reaction,
		ImpactAt = swing.StartedAt + swing.WindupSeconds,
		Swing = swing,
		Decided = false,
		Response = "None",
		ActAt = math.huge,
		ReleaseAt = -math.huge,
		EvadeDirection = "Back",
		EvadeSent = false,
		Over = false,
		SawActive = false,
	}
end

-- The swing this threat was tracking is over. Whether it was FEINTED is what feeds the feint habit:
-- it vanished before its impact without the bot having hit or parried it.
local function endThreat(brain: Brain, threat: Threat, p: Perception): ()
	threat.Over = true
	if threat.Swing.Feintable then
		local interruptedByUs = p.TargetStunned
			or p.TargetDefenseState == "Staggered"
			or p.TargetDefenseState == "GuardBroken"
			or p.TargetAttackState == "Interrupted"
		local feinted = not threat.SawActive and p.Now < threat.ImpactAt - 0.02 and not interruptedByUs
		if not interruptedByUs then
			brain.Habits.Feint = ema(brain.Habits.Feint, if feinted then 1 else 0, brain.Difficulty.LearnRate)
		end
		if feinted then
			narrate(
				brain,
				if threat.Decided and threat.Response ~= "None" then "Baited by your feint" else "Saw the feint"
			)
		end
	end
	if threat.Response == "Block" then
		-- A player lets go a beat after the danger passes, not on the frame.
		threat.ReleaseAt = p.Now + 0.08 + brain.Rng:NextNumber() * 0.15
	elseif threat.Response == "Parry" and p.Now < threat.ReleaseAt then
		-- A feint (or an interrupted swing) leaves a pending parry with nothing to catch. If it has not
		-- been pressed yet, it is simply not pressed; if it has, the hand comes off now -- which is the
		-- whiff lockout a baited player pays.
		if p.Now < threat.ActAt then
			threat.ActAt = math.huge
		end
		threat.ReleaseAt = p.Now
	end
end

local function decideResponse(brain: Brain, threat: Threat, p: Perception): ()
	local style = brain.Style
	local difficulty = brain.Difficulty
	local rng = brain.Rng
	local swing = threat.Swing
	local now = p.Now
	local stats = brain.Stats

	threat.Decided = true
	stats.Seen += 1

	if now >= threat.ImpactAt then
		threat.Response = "None"
		stats.Late += 1
		narrate(brain, "Too slow for that one")
		return
	end
	if p.Distance > p.TargetReach + TrainingBotConstants.Config.ThreatMarginStuds then
		threat.Response = "None"
		stats.Range += 1
		narrate(brain, "Out of your range -- let it whiff")
		return
	end

	-- WHEN THE BODY IS NEXT FREE. Mid-swing or in hitstun, a guard press is not refused -- DefenseSystem
	-- holds it and raises the guard the instant the body is free (SetBlocking's deferral), exactly what a
	-- player mashing block out of a stun gets. So being busy DELAYS the guard rather than forbidding it;
	-- it only forbids it when the body is still committed as the hit lands. A roll is refused outright
	-- while committed, so it needs the body free before its own startup.
	-- AIR-HELD, the press is never deferred: DefenseSystem.SetBlocking lets an air-held victim's press through
	-- the stun, because the parry is their one way out. So the body is "free" to press right now.
	-- STUN-HELD on the ground, likewise (DefenseConstants.StunParry): the press goes through the stun and arms.
	local airHeld = p.SelfAirHeld == true
	local heldInStun = airHeld or p.SelfStunHeld == true
	local freeAt = if heldInStun then now else math.max(now, p.SelfBusyUntil)
	local canGuard = not p.SelfLocked and freeAt <= threat.ImpactAt - 0.02
	local canRoll = canGuard and p.EvadeReady and freeAt <= threat.ImpactAt - p.EvadeStartup - 0.02

	local weights: { [string]: number } = {
		Parry = if canGuard then style.Parry else 0,
		Block = if canGuard then style.Block else 0,
		Evade = if canRoll then style.Evade else 0,
		Trade = 0,
	}

	-- Its own swing already in the air: trading is only on the table if its hit lands first.
	local ownSwing = p.SelfSwing
	if ownSwing and (p.SelfAttackState == "Windup" or p.SelfAttackState == "Active") then
		local ownImpact = ownSwing.StartedAt + ownSwing.WindupSeconds
		if ownImpact < threat.ImpactAt - 0.05 and p.Distance <= p.Reach + 0.5 then
			weights.Trade = style.Trade
		end
	end

	-- Struck from behind, a raised guard is a Backstab -- only a roll helps.
	if p.FacingError > 100 then
		weights.Parry = 0
		weights.Block = 0
	end

	-- A Heavy costs twice the guard to block (GuardMeter.DrainFor) and is slow enough to parry on sight.
	if swing.Heavy then
		weights.Block *= 0.6
		weights.Parry *= 1.25
		weights.Evade *= 1.2
	end
	-- Blocking on an almost-empty guard is volunteering for a GuardBroken.
	if p.SelfGuardFraction < 0.35 then
		weights.Block *= 0.15
		weights.Evade *= 1.5
	end
	-- A rattled bot stops trusting its timing.
	if brain.Composure < 0.45 then
		weights.Parry *= 0.6
		weights.Block *= 1.2
		weights.Evade *= 1.4
	end
	-- Guard already up (a neutral stance, a turtle, a block still held from the last swing): raising it
	-- again is not a fresh press, so there is no parry without letting go first -- and letting go now
	-- would be too late to arm one (MinUnguardedSeconds). It keeps blocking.
	if p.ParryArmableAt == math.huge then
		weights.Block += weights.Parry
		weights.Parry = 0
	end
	-- Held in your air combo: a guard does nothing, an evade is refused and it cannot swing -- the timed
	-- parry is the one way out, read off your air beats exactly like any other swing (baited by your delays
	-- at the difficulty's own rate). A guard still up from the last beat simply comes down, so the next
	-- press can arm.
	-- Stunned in a linked M1 string on the ground is the same answer (DefenseConstants.StunParry).
	if heldInStun then
		weights.Block = 0
		weights.Evade = 0
		weights.Trade = 0
	end

	local picked = pickWeighted(rng, weights, RESPONSE_ORDER)
	if picked == nil then
		threat.Response = "None"
		if canGuard then
			stats.None += 1
			narrate(brain, "Letting it come")
		else
			stats.Busy += 1
			narrate(brain, "Committed -- can't answer that")
		end
		return
	end
	local choice = picked :: Response

	-- Aim error, and the occasional outright misread.
	local timingError = gaussian(rng, 0, difficulty.TimingErrorSeconds)
	if rng:NextNumber() < difficulty.MisreadChance then
		local beat = 0.1 + rng:NextNumber() * 0.15
		timingError += if rng:NextNumber() < 0.5 then -beat else beat
	end

	if choice == "Parry" then
		local actAt
		if style.PerfectParry then
			-- A PERFECT parry is a contact within DefenseConstants.PerfectParry of the window OPENING, so aim
			-- at the opening, not the middle, and with no human error. A press only happens on a frame: aimed
			-- one frame ahead, it lands on the last frame whose window still opens before the hit, and the hit
			-- then arrives less than a frame after the window went live.
			actAt = math.max(threat.ImpactAt - p.ParryOpen - brain.FrameSeconds, freeAt)
		else
			local ideal = threat.ImpactAt - (p.ParryOpen + p.ParryClose) * 0.5
			actAt = math.max(ideal + timingError, freeAt)
		end
		-- Too soon after its guard came down, a press only blocks. Wait for it to arm if the window
		-- would still catch the hit from there.
		if actAt < p.ParryArmableAt then
			actAt = p.ParryArmableAt
		end
		if actAt + p.ParryOpen > threat.ImpactAt then
			-- No window can open before the hit: a held guard is all that is left, for a style that blocks
			-- at all. (A press that is merely EARLY is kept -- that is an honest mistake, and holding it
			-- turns it into a block exactly as it does for a player.)
			choice = if weights.Block > 0 or style.Block > 0 then "Block" else "None"
		else
			threat.ActAt = actAt
			if style.PerfectParry then
				-- Always a tap: a held guard could not arm the NEXT parry of the trade (a fresh press has to
				-- follow DefenseConstants.Parry.MinUnguardedSeconds of guard down), and the window runs to its
				-- close whether the key is held or not.
				threat.ReleaseAt = actAt + 0.05
			else
				local holds = rng:NextNumber() < difficulty.HoldAfterParryChance
				threat.ReleaseAt = if holds then math.huge else actAt + p.ParryClose + 0.02
			end
		end
	end
	if choice == "Evade" then
		local ideal = threat.ImpactAt - p.EvadeStartup - p.EvadeActive * 0.4
		threat.ActAt = math.max(ideal + timingError, freeAt)
		if threat.ImpactAt - threat.ActAt < p.EvadeStartup then
			choice = if canGuard and (style.Block > 0 or style.Parry > 0) then "Block" else "None"
		else
			local sidestep = rng:NextNumber() < 0.55 and not swing.Heavy and p.SelfHealthFraction > 0.3
			threat.EvadeDirection = if sidestep then (if rng:NextNumber() < 0.5 then "Left" else "Right") else "Back"
		end
	end
	if choice == "Block" then
		-- Pressed now; held by DefenseSystem until the body is free if it is not already.
		threat.ActAt = now
		threat.ReleaseAt = math.huge
	end

	threat.Response = choice
	local what = if swing.Heavy then "your Heavy" else "your swing"
	if choice == "Parry" then
		stats.Parry += 1
		narrate(brain, `Parry {what}`)
	elseif choice == "Block" then
		stats.Block += 1
		narrate(brain, if freeAt > now then `Block {what} (out of the stun)` else `Block {what}`)
	elseif choice == "Evade" then
		stats.Evade += 1
		narrate(brain, `Evade {string.lower(threat.EvadeDirection)} from {what}`)
	elseif choice == "Trade" then
		stats.Trade += 1
		narrate(brain, "Swing through it -- mine lands first")
	else
		stats.None += 1
		narrate(brain, `No answer to {what}`)
	end
end

local function updateThreat(brain: Brain, p: Perception): ()
	local swing = p.TargetSwing
	local threat = brain.Threat

	-- LastSwingStart, not just the live threat: a threat retired while its swing is still recovering
	-- (below) must not be re-noticed as a brand-new swing on the next frame.
	if swing and swing.StartedAt ~= brain.LastSwingStart and (threat == nil or threat.StartedAt ~= swing.StartedAt) then
		if threat and not threat.Over then
			endThreat(brain, threat, p)
		end
		-- A block still held from the last swing carries into this one: a player blocking a string holds
		-- the button through it rather than letting go and re-reacting to every hit. A Heavy is the
		-- exception -- it costs double to block, so it is worth a fresh decision.
		local holdingBlock = threat ~= nil and threat.Response == "Block" and p.Now < threat.ReleaseAt
		-- ...as often as the style would rather block than parry. A parrier lets go after a blocked hit so
		-- the next beat can be parried (it has to be down MinUnguardedSeconds to arm one).
		local style = brain.Style
		local blockShare = if style.Block + style.Parry > 0 then style.Block / (style.Block + style.Parry) else 1
		beginThreat(brain, swing)
		threat = brain.Threat
		if holdingBlock and threat and not swing.Heavy and brain.Rng:NextNumber() < math.max(blockShare, 0.35) then
			threat.Decided = true
			threat.Response = "Block"
			threat.ActAt = p.Now
			threat.ReleaseAt = math.huge
			narrate(brain, "Holding guard through your string")
		end
	end
	if threat == nil then
		return
	end

	if not threat.Over then
		if p.TargetAttackState == "Active" or p.TargetAttackState == "Recovery" then
			threat.SawActive = true
		end
		if swing == nil or swing.StartedAt ~= threat.StartedAt then
			endThreat(brain, threat, p)
		elseif p.TargetAttackState == "Recovery" then
			-- The danger is past once the swing is recovering. A guard held on it comes down now -- so the
			-- recovery can be punished -- if that swing ended your string (or was a Heavy); mid-string it
			-- stays up for the next beat, as a player's does. Anything else is simply over.
			local guardHeld = (threat.Response == "Block" or threat.Response == "Parry")
				and threat.ReleaseAt == math.huge
			local stringOver = threat.Swing.Heavy or brain.StringCount >= TrainingBotConstants.Offence.StringLength
			if stringOver or not guardHeld then
				endThreat(brain, threat, p)
			end
		end
	end

	if not threat.Decided and not threat.Over and p.Now >= threat.NoticeAt then
		-- Waiting out the feint window: once it has learned you feint, it will not commit to a
		-- feintable swing until the window has closed -- if that still leaves time to answer it.
		local difficulty = brain.Difficulty
		if threat.Swing.Feintable and difficulty.FeintPatience and brain.Habits.Feint >= difficulty.FeintAwareAt then
			local feintSafeAt = threat.StartedAt + threat.Swing.WindupSeconds * p.FeintWindowFraction + 0.03
			local latestUseful = threat.ImpactAt - 0.12
			if p.Now < math.min(feintSafeAt, latestUseful) then
				narrate(brain, "Waiting out your feint window")
				return
			end
		end
		decideResponse(brain, threat, p)
	end

	-- Fully retired once nothing about it can still hold the guard.
	if threat.Over and p.Now >= threat.ReleaseAt then
		brain.Threat = nil
	end
end

-- Offence -----------------------------------------------------------------------------------------

local function randomInt(rng: Random, low: number, high: number): number
	if high <= low then
		return low
	end
	return rng:NextInteger(low, high)
end

local function basicString(count: number): { PlanPress }
	local queue: { PlanPress } = {}
	for _ = 1, count do
		table.insert(queue, "Basic")
	end
	return queue
end

local function startPlan(brain: Brain, plan: Plan): ()
	brain.Plan = plan
	brain.PlanLanded = 0
	narrate(brain, plan.Label)
end

-- THE LAUNCHER, planned the way a player plans it: a string of 3+ Basics may end in Space + M1 as its
-- 4th hit, at the style's LaunchChance -- and whether it is PRESSED is decided at the moment it is due,
-- off whether all three Basics landed (PlanLanded), exactly the condition the combat stack checks. A
-- string that was blocked just ends there instead of wasting the press on a fresh B1.
local LAUNCH_STRING = 3
local function maybeLaunch(brain: Brain, queue: { PlanPress }): { PlanPress }
	local chance = brain.Style.LaunchChance or 0
	if chance <= 0 or #queue < LAUNCH_STRING or brain.Rng:NextNumber() >= chance then
		return queue
	end
	for _, press in queue do
		if press ~= "Basic" then
			return queue
		end
	end
	return { "Basic", "Basic", "Basic", "Launcher" }
end

-- The DefenseStates in which your guard is up (raised, parrying or held).
local GUARDING: { [string]: boolean } = { Raising = true, ParryWindow = true, Blocking = true }

-- The punishable DefenseStates, and what the bot calls each.
local PUNISHABLE: { [string]: string } = {
	Staggered = "Punish your stagger",
	GuardBroken = "Guard broken -- go in",
	ParryRecovery = "Punish the whiffed parry",
}

-- A punish on offer that has not been judged yet: you are staggered, guard-broken or locked out of a
-- whiffed parry, or you just swung into recovery without touching the bot. LEVEL-triggered and judged
-- once per opening (PunishJudgedState / WhiffJudgedFor), not edge-triggered -- an opening that begins
-- on a frame the bot is busy holding its own guard is still there to take a frame later.
local function punishOnOffer(brain: Brain, p: Perception): string?
	local label = PUNISHABLE[p.TargetDefenseState]
	if label == nil then
		brain.PunishJudgedState = nil
	elseif brain.PunishJudgedState ~= p.TargetDefenseState then
		brain.PunishJudgedState = p.TargetDefenseState
		return label
	end
	local swing = p.TargetSwing
	if
		swing
		and p.TargetAttackState == "Recovery"
		and brain.WhiffJudgedFor ~= swing.StartedAt
		and p.SelfDefenseState ~= "Blocking"
	then
		-- Recovery after a swing that whiffed or was blocked (a landed one leaves the bot stunned, and a
		-- disabled bot never gets this far). A blocked one reaches here once updateThreat drops the guard
		-- at the end of your string.
		brain.WhiffJudgedFor = swing.StartedAt
		return "Punish your recovery"
	end
	return nil
end

local function considerOffence(brain: Brain, p: Perception): ()
	local style = brain.Style
	local difficulty = brain.Difficulty
	local rng = brain.Rng
	if not style.CanAttack or brain.Plan ~= nil then
		return
	end

	-- The parry-trade drill's only offence: the one swing each of its parries earns (CounterOwedUntil),
	-- thrown at you while that parry still has you staggered, so you can parry it back. Always taken.
	if style.CounterAfterParry then
		if p.Now < brain.CounterOwedUntil and p.TargetDefenseState == "Staggered" then
			brain.CounterOwedUntil = -math.huge
			startPlan(brain, {
				Label = "Your turn -- parry it back",
				Queue = { "Basic" },
				FeintFraction = nil,
				FeintAt = nil,
				WantedSince = nil,
				ExpiresAt = p.Now + 1.5,
				Punish = true,
			})
		end
		return
	end

	local punish = punishOnOffer(brain, p)
	if punish and p.Distance <= p.Reach + 6 and rng:NextNumber() < difficulty.PunishChance then
		startPlan(brain, {
			Label = punish,
			Queue = maybeLaunch(
				brain,
				basicString(randomInt(rng, math.max(style.StringMin, 2), math.max(style.StringMax, 3)))
			),
			FeintFraction = nil,
			FeintAt = nil,
			WantedSince = nil,
			ExpiresAt = p.Now + 1.5,
			Punish = true,
		})
		return
	end

	local offence = TrainingBotConstants.Offence

	-- PRESSURE. Its last string landed: a player keeps the initiative rather than stepping out, so it goes
	-- again the moment its end-of-string lockout lets it (the plan waits that out). One roll per string.
	if p.Now < brain.PressureUntil and p.Distance <= p.Reach + 2 then
		brain.PressureUntil = -math.huge
		if rng:NextNumber() < style.Aggression * difficulty.PunishChance then
			local count = randomInt(rng, style.StringMin, style.StringMax)
			local heavy = style.HeavyBias > 0 and p.TargetGuardFraction < 0.4
			startPlan(brain, {
				Label = if heavy then "Keep the pressure -- Heavy" else "Keep the pressure",
				Queue = if heavy then { "Heavy" } else maybeLaunch(brain, basicString(count)),
				FeintFraction = nil,
				FeintAt = nil,
				WantedSince = nil,
				ExpiresAt = p.Now + 1.5 + (count + 1) * 1.1,
				Punish = false,
			})
			return
		end
	end

	if p.Now < brain.NextThinkAt then
		return
	end
	-- Only from inside (or right at the edge of) its own reach.
	if p.Distance > p.Reach + 1 then
		return
	end

	-- Caught from behind: take it.
	if p.BearingFromTarget > 115 then
		startPlan(brain, {
			Label = "Your back is open",
			Queue = { "Basic", "Basic" },
			FeintFraction = nil,
			FeintAt = nil,
			WantedSince = nil,
			ExpiresAt = p.Now + 1,
			Punish = false,
		})
		return
	end

	local habits = brain.Habits
	local influence = difficulty.ReadInfluence
	local aggression = style.Aggression * (0.5 + 0.5 * brain.Composure)
	if p.SelfHealthFraction < 0.3 and style.Aggression >= 0.8 then
		aggression = math.min(aggression + 0.2, 1)
	end
	-- You, standing in its reach doing nothing: its turn. A player does not wait a second and a half to
	-- swing at someone who just walked into range.
	local targetGuarding = GUARDING[p.TargetDefenseState] == true
	if p.Distance <= p.Reach and p.TargetAttackState == "Idle" and not targetGuarding then
		aggression = math.min(aggression * offence.InReachAggressionScale, 0.95)
	end
	-- Aggression is a chance per SECOND in reach, converted to this think's slice -- as a per-think chance
	-- it made the bot swing every few hundred milliseconds and spend most of the fight mid-swing, which
	-- is exactly when it cannot defend.
	local perThink = 1 - (1 - math.clamp(aggression, 0, 0.999)) ^ difficulty.ThinkSeconds
	if rng:NextNumber() >= perThink then
		return
	end

	-- What to open with, shaped by what it has learned about you.
	local heavyChance = style.HeavyBias + influence * 0.5 * habits.Block - influence * 0.25 * habits.Parry
	if p.TargetGuardFraction < 0.4 then
		heavyChance += 0.3
	end
	-- A HELD guard cannot parry and pays double for a Heavy; a feint (which baits a parry) is wasted on it.
	local feintScale = 1
	if p.TargetDefenseState == "Blocking" and style.HeavyBias > 0 then
		heavyChance += offence.HeldGuardHeavyBonus * (0.5 + 0.5 * influence)
		feintScale = offence.HeldGuardFeintScale
	end
	heavyChance = math.clamp(heavyChance, 0, 0.85)
	local feintChance = math.clamp((style.FeintChance + influence * 0.6 * habits.Parry) * feintScale, 0, 0.8)
	-- A roller gets short strings: one swing to draw the roll, then wait out its recovery.
	local stringMax = style.StringMax
	if influence * habits.Evade > 0.35 then
		stringMax = style.StringMin
	end

	if rng:NextNumber() < heavyChance then
		if rng:NextNumber() < feintChance then
			local reason = if habits.Parry > 0.3 then "you like to parry" else "mix-up"
			startPlan(brain, {
				Label = `Feint the Heavy ({reason})`,
				Queue = { "Heavy", "Basic", "Basic" },
				FeintFraction = 0.35 + rng:NextNumber() * 0.5,
				FeintAt = nil,
				WantedSince = nil,
				ExpiresAt = p.Now + 2.5,
				Punish = false,
			})
		else
			local reason = if p.TargetGuardFraction < 0.4
				then "your guard is low"
				elseif targetGuarding then "you're holding guard"
				elseif habits.Block > 0.4 then "you keep blocking"
				else "change of pace"
			startPlan(brain, {
				Label = `Heavy ({reason})`,
				Queue = if rng:NextNumber() < 0.5 then { "Heavy", "Basic" } else { "Heavy" },
				FeintFraction = nil,
				FeintAt = nil,
				WantedSince = nil,
				ExpiresAt = p.Now + 2,
				Punish = false,
			})
		end
		return
	end

	local count = randomInt(rng, style.StringMin, stringMax)
	-- AN M1 FEINT: the string's first Basic cancelled inside its feint window, then the real string --
	-- the cheap bait on someone who parries on sight.
	if rng:NextNumber() < feintChance * offence.BasicFeintShare then
		startPlan(brain, {
			Label = if habits.Parry > 0.3 then "Feint the M1 (you like to parry)" else "Feint the M1",
			Queue = { "Basic", "Basic", "Basic" },
			FeintFraction = 0.3 + rng:NextNumber() * 0.5,
			FeintAt = nil,
			WantedSince = nil,
			ExpiresAt = p.Now + 1 + 3 * 1.1,
			Punish = false,
		})
		return
	end
	local queue = maybeLaunch(brain, basicString(count))
	local launching = queue[#queue] == "Launcher"
	startPlan(brain, {
		Label = if launching then "Full string -- launcher" elseif count == 1 then "Poke" else `{count}-hit string`,
		Queue = queue,
		FeintFraction = nil,
		FeintAt = nil,
		WantedSince = nil,
		ExpiresAt = p.Now + 1 + #queue * 1.1,
		Punish = false,
	})
end

-- Movement ----------------------------------------------------------------------------------------

local function neutralMovement(brain: Brain, p: Perception, intent: Intent): ()
	local style = brain.Style
	local config = TrainingBotConstants.Config
	local rng = brain.Rng
	-- A rattled bot backs off -- except the parry-trade drill, which has to stay in the exchange.
	local rattled = if style.CounterAfterParry then 0 else (1 - brain.Composure) * 3
	local desired = p.Reach + style.SpacingStuds + rattled

	if p.Now < brain.RetreatUntil then
		intent.Move = "Retreat"
		return
	end

	if p.Now >= brain.StrafeFlipAt then
		brain.StrafeSign = if rng:NextNumber() < 0.5 then -1 else 1
		brain.Planted = rng:NextNumber() < 0.25
		brain.StrafeFlipAt = p.Now + 0.8 + rng:NextNumber() * 1.6
	end
	intent.StrafeSign = brain.StrafeSign

	if p.Distance > desired + 1.5 then
		intent.Move = "Approach"
		intent.Sprint = p.Distance > desired + config.SprintBeyondStuds
	elseif p.Distance < desired - 1.5 and (brain.Composure < 0.6 or p.SelfGuardFraction < 0.35) then
		-- Only a rattled bot, or one on a failing guard, gives ground. A calm one that is walked into holds
		-- it -- that is its turn to swing (considerOffence) -- rather than backpedalling at the speed you
		-- advance, which read as running away from the fight.
		intent.Move = "Retreat"
	else
		-- Footsies (and a calm bot walked into): mostly circling, sometimes planting to let you commit.
		intent.Move = if brain.Planted then "Hold" else "Strafe"
	end
end

-- The frame -----------------------------------------------------------------------------------------

local function idleIntent(): Intent
	return {
		Move = "Hold",
		StrafeSign = 1,
		Sprint = false,
		Guard = false,
		Attack = nil,
		Modifier = nil,
		Feint = false,
		Evade = nil,
	}
end

function TrainingBotBrain.Think(brain: Brain, p: Perception): Intent
	local intent = idleIntent()
	local now = p.Now
	local dt = math.clamp(now - brain.LastNow, 0, 0.5)
	brain.LastNow = now
	-- Frames longer than a tenth of a second are hitches (or the first call), not the server's pace.
	if dt > 0 and dt < 0.1 then
		brain.FrameSeconds = ema(brain.FrameSeconds, dt, 0.2)
	end

	-- Composure drifts back toward calm.
	brain.Composure = math.min(brain.Composure + dt * 0.08, 1)

	if not p.HasTarget then
		brain.Threat = nil
		brain.Plan = nil
		intent.Move = if p.HomeDistance > TrainingBotConstants.Config.HomeRadius then "Home" else "Hold"
		brain.PunishJudgedState = nil
		return intent
	end

	-- ITS AIR STRING. Its launcher landed: nothing else it could decide matters until the combo is over, and
	-- the victim cannot swing at it. Each beat is pressed the moment its body is free -- on-beat -- or held
	-- back to bait your parry, at a rate its difficulty's read sets; after the beats it meant to land, it
	-- cashes out: the Spike with a wall behind you, the Slam otherwise.
	if p.SelfAirAttacker then
		brain.Plan = nil
		brain.Threat = nil
		local rng = brain.Rng
		local air = brain.Air
		if air == nil then
			air = {
				Length = randomInt(rng, 0, 3),
				NextAt = p.AirPressReadyAt or now,
				SeenHits = 0,
			}
			brain.Air = air
			narrate(brain, "Launched -- read me")
		end
		local plan = air :: AirPlan
		local hits = p.SelfAirHitsLanded or 0
		if hits > plan.SeenHits then
			plan.SeenHits = hits
			local AIR = TrainingBotConstants.Air
			local delayChance = AIR.DelayChance * (0.5 + brain.Difficulty.ReadInfluence)
			local delay = if rng:NextNumber() < delayChance then rng:NextNumber() * AIR.MaxBeatDelaySeconds else 0
			plan.NextAt = now + delay
			if delay > 0.1 then
				narrate(brain, "Delayed beat")
			end
		end
		local free = p.SelfAttackState == "Idle" and p.SelfBusyUntil <= now
		if free and now >= plan.NextAt then
			if hits >= plan.Length then
				intent.Attack = "Heavy"
				intent.Modifier = if p.WallBehindTarget then "Up" else nil
			else
				intent.Attack = "Basic"
			end
		end
		return intent
	end
	brain.Air = nil

	updateThreat(brain, p)

	if p.SelfDisabled or p.SelfEvading then
		-- Nothing it decides can happen; a plan that was mid-string is over (it got hit, it is rolling).
		if p.SelfDisabled then
			brain.Plan = nil
		end
		-- Still report the guard it WANTS, so a guard press answered during a stun is held and raised
		-- the instant it is free -- DefenseSystem.SetBlocking's own deferral, which a player gets too.
		local threat = brain.Threat
		intent.Guard = threat ~= nil
			and (threat.Response == "Block" or threat.Response == "Parry")
			and now >= threat.ActAt
			and now < threat.ReleaseAt
		return intent
	end

	-- Defence first.
	local threat = brain.Threat
	local defending = false
	if threat and threat.Decided then
		if
			(threat.Response == "Parry" or threat.Response == "Block")
			and now >= threat.ActAt
			and now < threat.ReleaseAt
		then
			intent.Guard = true
			defending = true
		elseif threat.Response == "Evade" and not threat.EvadeSent and now >= threat.ActAt then
			threat.EvadeSent = true
			intent.Evade = threat.EvadeDirection
			defending = true
		elseif not threat.Over and (threat.Response == "Parry" or threat.Response == "Evade") then
			-- Answer scheduled but not yet due: stand your ground rather than walk into the swing.
			defending = true
		end
	end

	-- A pending feint on its own swing, due now.
	local plan = brain.Plan
	if plan and plan.FeintAt and now >= plan.FeintAt then
		plan.FeintAt = nil
		if p.SelfAttackState == "Windup" then
			intent.Feint = true
		end
	end

	if not defending then
		considerOffence(brain, p)
		plan = brain.Plan
	end
	if now >= brain.NextThinkAt then
		brain.NextThinkAt = now + brain.Difficulty.ThinkSeconds * (0.75 + brain.Rng:NextNumber() * 0.5)
	end

	if plan and (now > plan.ExpiresAt or #plan.Queue == 0) then
		if #plan.Queue == 0 and now - brain.LastLandedAt < 1 then
			-- It landed: keep the initiative (considerOffence's pressure roll) instead of stepping out.
			brain.PressureUntil = now + TrainingBotConstants.Offence.PressureWindowSeconds
			brain.NextThinkAt = now
		elseif #plan.Queue == 0 and not plan.Punish then
			-- Blocked or dodged: step out rather than standing in front of the answer.
			brain.RetreatUntil = now + 0.3 + brain.Rng:NextNumber() * 0.4
		end
		brain.Plan = nil
		plan = nil
	end

	if plan and not defending then
		if p.Distance > p.Reach + 0.3 then
			intent.Move = "Approach"
			intent.Sprint = p.Distance > p.Reach + 6
		else
			intent.Move = "Hold"
			local free = p.SelfAttackState == "Idle" and p.SelfBusyUntil <= now
			-- The anti-metronome hold starts once the body is free, so it is a real gap in the string -- and
			-- never after a hit that landed: that gap would drop the combo (see Offence.StringDelayChance).
			if free and plan.PendingDelay then
				if now - brain.LastLandedAt < 0.8 then
					plan.PendingDelay = nil
				else
					plan.PressAt = now + plan.PendingDelay
					plan.PendingDelay = nil
				end
			end
			local holding = plan.PendingDelay ~= nil or (plan.PressAt ~= nil and now < plan.PressAt)
			local press = plan.Queue[1]
			if press == "Launcher" and free and brain.PlanLanded < LAUNCH_STRING then
				-- Not earned: the string was blocked, dodged or broken up. Stop rather than throw a fresh B1.
				brain.Plan = nil
				narrate(brain, "String didn't land -- no launch")
				return intent
			end
			if holding then
				intent.Attack = nil
			elseif press == "Launcher" then
				intent.Attack = "Basic"
				intent.Modifier = "Up"
			else
				intent.Attack = press :: AttackKind
			end
			-- The give-up clock only runs while the body is FREE and not deliberately holding: waiting out
			-- its own previous swing is the string working, not the press being refused. What it catches
			-- is a press refused with nothing in the way -- a cooldown, a gate that did not open.
			if not free or holding then
				plan.WantedSince = nil
			elseif plan.WantedSince == nil then
				plan.WantedSince = now
			elseif now - plan.WantedSince > TrainingBotConstants.Config.AttackIntentSeconds then
				brain.Plan = nil
				intent.Attack = nil
			end
		end
	elseif not defending then
		neutralMovement(brain, p, intent)
		local inYourReach = p.Distance <= p.TargetReach + 2
		-- RESPECT. A player with you in their face does not wait to see your swing -- they hold block
		-- for a beat and let you commit. Rolled on its own think clock, more often when rattled.
		if now >= brain.NextStanceThinkAt then
			brain.NextStanceThinkAt = now + brain.Difficulty.ThinkSeconds
			-- GuardInRange is per SECOND (as Aggression is), converted to this think's slice.
			local perSecond = math.clamp(brain.Style.GuardInRange * (1 + (1 - brain.Composure)), 0, 0.999)
			local chance = 1 - (1 - perSecond) ^ brain.Difficulty.ThinkSeconds
			if inYourReach and brain.Rng:NextNumber() < chance then
				brain.StanceUntil = now + 0.4 + brain.Rng:NextNumber() * 0.7
			end
		end
		if (brain.Style.HoldGuardInNeutral or now < brain.StanceUntil) and inYourReach then
			intent.Guard = true
		end
	end

	return intent
end

-- Feedback from the combat stack --------------------------------------------------------------------

-- The bot's own press was accepted: pop it off the plan, and arm a planned feint against the real
-- windup that is now running.
function TrainingBotBrain.OnOwnSwingAccepted(
	brain: Brain,
	kind: AttackKind,
	swing: SwingView,
	feintWindowFraction: number
): ()
	local plan = brain.Plan
	local press = plan and plan.Queue[1]
	local pressKind = if press == "Launcher" then "Basic" else press
	if not plan or pressKind ~= kind then
		return
	end
	table.remove(plan.Queue, 1)
	plan.WantedSince = nil
	plan.PressAt = nil
	-- ANTI-METRONOME: maybe hold the next press back a beat -- more often the more you parry. Never on a
	-- punish (that is a race) or ahead of a planned feint's follow-up (the feint is the mix-up).
	if #plan.Queue > 0 and plan.Queue[1] ~= "Launcher" and not plan.Punish and plan.FeintFraction == nil then
		local offence = TrainingBotConstants.Offence
		local influence = brain.Difficulty.ReadInfluence
		local chance = offence.StringDelayChance * (0.5 + influence) + 0.5 * influence * brain.Habits.Parry
		if brain.Rng:NextNumber() < math.clamp(chance, 0, 0.8) then
			plan.PendingDelay = 0.08 + brain.Rng:NextNumber() * (offence.StringDelayMaxSeconds - 0.08)
		end
	end
	if plan.FeintFraction and swing.Feintable then
		plan.FeintAt = swing.StartedAt + swing.WindupSeconds * feintWindowFraction * plan.FeintFraction
		plan.FeintFraction = nil
	end
end

-- A contact resolved with the bot on one end of it. `role` is the bot's side.
function TrainingBotBrain.OnOutcome(brain: Brain, role: "Attacker" | "Defender", kind: string, now: number): ()
	local alpha = brain.Difficulty.LearnRate
	local habits = brain.Habits
	if role == "Attacker" then
		-- How the TARGET answered the bot's swing.
		local block = if kind == "Blocked" or kind == "GuardBroken" then 1 else 0
		local parry = if kind == "Parried" or kind == "Trade" then 1 else 0
		local evade = if kind == "Evaded" then 1 else 0
		local clean = if kind == "Clean" or kind == "Backstab" then 1 else 0
		habits.Block = ema(habits.Block, block, alpha)
		habits.Parry = ema(habits.Parry, parry, alpha)
		habits.Evade = ema(habits.Evade, evade, alpha)
		habits.Clean = ema(habits.Clean, clean, alpha)

		if kind == "Clean" or kind == "Backstab" or kind == "GuardBroken" then
			brain.Composure = math.min(brain.Composure + 0.08, 1)
			brain.ConsecutiveBlocked = 0
			brain.LastLandedAt = now
			if kind ~= "GuardBroken" then
				brain.PlanLanded += 1
			end
		elseif kind == "Blocked" then
			brain.ConsecutiveBlocked += 1
			brain.LastLandedAt = -math.huge
			brain.PressureUntil = -math.huge
			-- Two blocked in a row: stop feeding the guard Basics. Leave the string, or swap its tail for a
			-- Heavy if the guard is worth breaking.
			local plan = brain.Plan
			if plan and brain.ConsecutiveBlocked >= 2 and not plan.Punish then
				if
					brain.Style.HeavyBias > 0
					and brain.Rng:NextNumber() < 0.5 + brain.Difficulty.ReadInfluence * 0.3
				then
					plan.Queue = { "Heavy" }
					plan.WantedSince = nil
					narrate(brain, "You're turtling -- Heavy")
				else
					brain.Plan = nil
					brain.RetreatUntil = now + 0.4
					narrate(brain, "Blocked -- reset")
				end
			end
		elseif kind == "Parried" or kind == "Trade" then
			brain.Plan = nil
			brain.ConsecutiveBlocked = 0
			brain.LastLandedAt = -math.huge
			brain.PressureUntil = -math.huge
			brain.Composure = math.max(brain.Composure - 0.15, 0)
			narrate(brain, if kind == "Parried" then "Parried -- ouch" else "Traded")
		elseif kind == "Evaded" then
			brain.ConsecutiveBlocked = 0
			brain.LastLandedAt = -math.huge
			brain.PressureUntil = -math.huge
			narrate(brain, "You rolled it")
		end
	else
		if kind == "Clean" or kind == "Backstab" then
			brain.Composure = math.max(brain.Composure - 0.15, 0)
			-- Hit back first: whatever initiative its last string earned is gone.
			brain.PressureUntil = -math.huge
		elseif kind == "GuardBroken" then
			brain.Composure = math.max(brain.Composure - 0.3, 0)
			narrate(brain, "Guard broken!")
		elseif kind == "Parried" then
			brain.Composure = math.min(brain.Composure + 0.12, 1)
			narrate(brain, "Parried you")
			if brain.Style.CounterAfterParry then
				-- Good for as long as the stagger it caused could last; past that there is nothing to trade.
				brain.CounterOwedUntil = now + 2
			end
		elseif kind == "Blocked" or kind == "Evaded" then
			brain.Composure = math.min(brain.Composure + 0.04, 1)
		end
	end
end

return TrainingBotBrain
