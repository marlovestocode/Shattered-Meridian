--!strict
--[[
	TrainingBotConstants.lua

	Owns: every tunable the training bot (Server/Combat/TrainingBot/) reads -- the STYLE presets
	(what it wants to do), the DIFFICULTY presets (how well it does it), and the handful of
	system-level numbers (health, respawn, leash, billboard cadence).

	STYLE x DIFFICULTY, NOT ONE TABLE PER BOT. docs/ai-design.md is explicit that difficulty is "different
	weight tables and reaction-time parameters on the same underlying decision model, not separate
	hand-authored AI per difficulty". So a style is WEIGHTS (how often it parries vs blocks vs rolls,
	how often it presses the attack, how much it likes heavies and feints) and a difficulty is
	PERCEPTION AND EXECUTION (how late it sees your swing, how precisely it times a press, how fast it
	learns your habits). Any style runs at any difficulty; a new style is one table below, with no code.

	Shared, not server-only, for exactly one reason: the Admin Menu's Spawn tab lists StyleOrder and
	DifficultyOrder to build its pickers, and a second copy of those names on the client would drift the
	first time one was added. Nothing in here is secret -- it is the bot's personality, not the player's.

	THE NUMBERS ARE HUMAN NUMBERS ON PURPOSE. Reaction times are simple visual reaction (~170-340ms)
	plus decision time; timing error is a standard deviation in seconds against a 0.2s parry window
	(DefenseConstants.RegisteredParryWindows). A Master bot is a very good player, not an input reader:
	it still has to SEE your windup, and it can still be baited by a feint until it has learned that you
	feint -- see TrainingBotBrain.lua's header on the habit model.

	Does not own: any combat rule (the bot plays by the combat stack's rules through the same public
	functions a player's remotes reach), the decision logic (TrainingBotBrain.lua), or the rig/presentation
	(TrainingBotSystem.lua).
]]

local TrainingBotConstants = {}

export type StyleName =
	"FullFight"
	| "Aggressor"
	| "Turtle"
	| "AttackOnly"
	| "BlockOnly"
	| "ParryOnly"
	| "DodgeOnly"
	| "ParryTrade"

export type DifficultyName = "Novice" | "Adept" | "Master"

-- WHAT THE BOT WANTS. Weights are RELATIVE (they need not sum to anything); a zero removes the option.
export type Style = {
	-- Response to an incoming swing it has noticed and judged in range.
	Parry: number,
	Block: number,
	Evade: number,
	-- Swing through it -- only ever chosen when the bot's own swing is already live and would land first.
	Trade: number,
	-- 0..1: chance PER SECOND in reach that it starts an exchange from neutral. 0 means it never starts
	-- one -- with CanAttack true it still takes the punishes you hand it.
	Aggression: number,
	-- False disables every offensive action outright (BlockOnly/ParryOnly/DodgeOnly are pure drills).
	CanAttack: boolean,
	-- Base probability a from-neutral attack opens with a Heavy rather than a Basic string.
	HeavyBias: number,
	-- Base probability a Heavy is thrown as a feint (cancelled inside AttackConstants.Feint's window)
	-- followed by a quick Basic -- the bait.
	FeintChance: number,
	-- Basic presses the bot plans per string, inclusive range. The string itself (stages, finisher,
	-- chain delay) is SwingSequencer's; this is only how many presses the bot intends to make.
	StringMin: number,
	StringMax: number,
	-- Where it likes to stand in neutral, as studs OUTSIDE its own reach (negative = inside it).
	SpacingStuds: number,
	-- Holds guard in neutral whenever the target is close, rather than only in response to a swing.
	HoldGuardInNeutral: boolean,
	-- 0..1: chance PER SECOND with you in reach that it raises its guard for a beat before you have
	-- swung at all -- the "respect" a player shows someone in their face. Doubles as it gets rattled.
	-- Blocks, never parries (a held guard cannot arm one), which is why this is kept low on anything
	-- meant to parry: at the old per-think rate a FullFight bot spent most of close range turtled.
	GuardInRange: number,
	-- PARRY-TRADE DRILL SWITCHES (DefenseConstants.Rally). Both optional; absent means off, which is
	-- every style but ParryTrade.
	--
	-- Every swing it answers is a PERFECT parry: seen the instant it starts, pressed on the last server
	-- frame before the window would open too late, never misread, never held. This deliberately steps
	-- outside the difficulty's human numbers -- the drill is you against a wall that always answers.
	PerfectParry: boolean?,
	-- Its only offence is one Basic thrown at you while you are Staggered -- i.e. right after it parried
	-- you -- so you get to parry it back. Never opens from neutral, never punishes a whiff, never strings.
	CounterAfterParry: boolean?,
	-- Chance a planned string of 3+ Basics (from neutral, a punish or a pressure follow-up) ends in the
	-- LAUNCHER as its 4th hit (Space + M1 after B3 -- docs/design/air-combat-and-evade.md B2). It is only
	-- ever PRESSED if all three Basics actually landed (the same thing the combat stack requires), so this
	-- is "how often it goes for the air combo when it has earned one". nil/0 = never launches.
	LaunchChance: number?,
}

-- HOW WELL IT DOES IT.
export type Difficulty = {
	-- Seconds between your swing starting on the server and the bot noticing it: mean and one standard
	-- deviation, clamped to ReactionMinSeconds. This is the single biggest "feels human" number.
	ReactionSeconds: number,
	ReactionJitterSeconds: number,
	ReactionMinSeconds: number,
	-- Standard deviation, in seconds, of every timed press (parry, evade) around its ideal moment.
	TimingErrorSeconds: number,
	-- Chance a noticed swing is simply misjudged -- responded to as if it were a different move, i.e.
	-- the press lands a random 0.1-0.25s early or late. The "I panicked" button.
	MisreadChance: number,
	-- How strongly one observation moves a habit estimate (an EMA alpha) and how much those estimates
	-- are allowed to reshape the style's weights. 0 influence = never adapts.
	LearnRate: number,
	ReadInfluence: number,
	-- Chance it takes a punish that is on offer (you whiffed, you got parried, you are guard-broken).
	PunishChance: number,
	-- Whether it will deliberately wait out the feint window on a feintable swing once it has seen you
	-- feint. Needs FeintAwareAt of your observed feint rate before it bothers.
	FeintPatience: boolean,
	FeintAwareAt: number,
	-- Seconds between neutral-game decisions (movement, whether to press the attack). Threat responses
	-- are NOT on this clock -- they are scheduled per swing.
	ThinkSeconds: number,
	-- Degrees per second it can turn to face you. A finite turn rate is what makes circling it for a
	-- backstab a real skill rather than impossible.
	TurnRateDegrees: number,
	-- Chance, after tapping a parry, that it keeps holding (so an early press degrades to a block
	-- rather than to a whiff). Good players hold; new players tap.
	HoldAfterParryChance: number,
	-- Chance that a follow-up swing landing on your string's established beat is read off the rhythm
	-- rather than reacted to (seen in ~0.07s instead of ReactionSeconds). This is how a person handles
	-- M1s faster than their reaction time.
	RhythmRead: number,
}

TrainingBotConstants.StyleOrder = table.freeze({
	"FullFight",
	"Aggressor",
	"Turtle",
	"AttackOnly",
	"BlockOnly",
	"ParryOnly",
	"DodgeOnly",
	"ParryTrade",
}) :: { StyleName }

TrainingBotConstants.DifficultyOrder = table.freeze({ "Novice", "Adept", "Master" }) :: { DifficultyName }

TrainingBotConstants.DefaultStyle = "FullFight" :: StyleName
TrainingBotConstants.DefaultDifficulty = "Adept" :: DifficultyName
-- The Admin Menu weapon picker's first entry: "whatever the roster hands a combatant by default"
-- (WeaponRoster.Default()). Every other entry is a WeaponRoster id, which the server re-checks.
TrainingBotConstants.DefaultWeaponChoice = "Default"

TrainingBotConstants.Styles = table.freeze({
	-- A well-rounded duelist: the default sparring partner.
	FullFight = table.freeze({
		Parry = 4,
		Block = 3,
		Evade = 2,
		Trade = 1,
		Aggression = 0.6,
		CanAttack = true,
		HeavyBias = 0.2,
		FeintChance = 0.2,
		StringMin = 2,
		StringMax = 4,
		SpacingStuds = 1.5,
		HoldGuardInNeutral = false,
		GuardInRange = 0.3,
		LaunchChance = 0.85,
	}),
	-- Walks you down. Trades freely, strings long, parries less.
	Aggressor = table.freeze({
		Parry = 2,
		Block = 1,
		Evade = 1,
		Trade = 3,
		Aggression = 0.9,
		CanAttack = true,
		HeavyBias = 0.3,
		FeintChance = 0.25,
		StringMin = 3,
		StringMax = 5,
		SpacingStuds = 0,
		HoldGuardInNeutral = false,
		GuardInRange = 0.08,
		LaunchChance = 0.95,
	}),
	-- Sits behind its guard and punishes. The thing you practise guard-breaking and feint-baiting on.
	Turtle = table.freeze({
		Parry = 2,
		Block = 6,
		Evade = 1,
		Trade = 0,
		Aggression = 0.15,
		CanAttack = true,
		HeavyBias = 0.1,
		FeintChance = 0.05,
		StringMin = 1,
		StringMax = 2,
		SpacingStuds = 0.5,
		HoldGuardInNeutral = true,
		GuardInRange = 0,
		LaunchChance = 0.6,
	}),
	-- Never defends. Practise your own parry/roll timing against a steady stream of real swings.
	AttackOnly = table.freeze({
		Parry = 0,
		Block = 0,
		Evade = 0,
		Trade = 1,
		Aggression = 0.85,
		CanAttack = true,
		HeavyBias = 0.3,
		FeintChance = 0.15,
		StringMin = 2,
		StringMax = 4,
		SpacingStuds = 0,
		HoldGuardInNeutral = false,
		GuardInRange = 0,
		LaunchChance = 0.9,
	}),
	-- Pure defensive drills: each one only ever answers your swings one way.
	BlockOnly = table.freeze({
		Parry = 0,
		Block = 1,
		Evade = 0,
		Trade = 0,
		Aggression = 0,
		CanAttack = false,
		HeavyBias = 0,
		FeintChance = 0,
		StringMin = 1,
		StringMax = 1,
		SpacingStuds = 0.5,
		HoldGuardInNeutral = true,
		GuardInRange = 0,
	}),
	ParryOnly = table.freeze({
		Parry = 1,
		Block = 0,
		Evade = 0,
		Trade = 0,
		Aggression = 0,
		CanAttack = false,
		HeavyBias = 0,
		FeintChance = 0,
		StringMin = 1,
		StringMax = 1,
		SpacingStuds = 0.5,
		HoldGuardInNeutral = false,
		GuardInRange = 0,
	}),
	DodgeOnly = table.freeze({
		Parry = 0,
		Block = 0,
		Evade = 1,
		Trade = 0,
		Aggression = 0,
		CanAttack = false,
		HeavyBias = 0,
		FeintChance = 0,
		StringMin = 1,
		StringMax = 1,
		SpacingStuds = 1,
		HoldGuardInNeutral = false,
		GuardInRange = 0,
	}),
	-- Parry-trade drill: you swing, it perfect-parries, it counters with one swing for you to parry back,
	-- and round it goes, the window shrinking every exchange (DefenseConstants.Rally). It never starts
	-- anything, so the rally always begins when you swing.
	ParryTrade = table.freeze({
		Parry = 1,
		Block = 0,
		Evade = 0,
		Trade = 0,
		Aggression = 0,
		CanAttack = true,
		HeavyBias = 0,
		FeintChance = 0,
		StringMin = 1,
		StringMax = 1,
		-- Inside its own reach, so the counter needs no walk-in and your answer is always in range.
		SpacingStuds = -1,
		HoldGuardInNeutral = false,
		GuardInRange = 0,
		PerfectParry = true,
		CounterAfterParry = true,
	}),
}) :: { [StyleName]: Style }

TrainingBotConstants.Difficulties = table.freeze({
	Novice = table.freeze({
		ReactionSeconds = 0.3,
		ReactionJitterSeconds = 0.07,
		ReactionMinSeconds = 0.2,
		TimingErrorSeconds = 0.09,
		MisreadChance = 0.15,
		LearnRate = 0.1,
		ReadInfluence = 0.3,
		PunishChance = 0.35,
		FeintPatience = false,
		FeintAwareAt = 1,
		ThinkSeconds = 0.35,
		TurnRateDegrees = 300,
		HoldAfterParryChance = 0.3,
		RhythmRead = 0.25,
	}),
	Adept = table.freeze({
		ReactionSeconds = 0.22,
		ReactionJitterSeconds = 0.04,
		ReactionMinSeconds = 0.16,
		TimingErrorSeconds = 0.05,
		MisreadChance = 0.06,
		LearnRate = 0.2,
		ReadInfluence = 0.7,
		PunishChance = 0.7,
		FeintPatience = true,
		FeintAwareAt = 0.45,
		ThinkSeconds = 0.25,
		TurnRateDegrees = 480,
		HoldAfterParryChance = 0.7,
		RhythmRead = 0.6,
	}),
	Master = table.freeze({
		ReactionSeconds = 0.17,
		ReactionJitterSeconds = 0.025,
		ReactionMinSeconds = 0.13,
		TimingErrorSeconds = 0.025,
		MisreadChance = 0.02,
		LearnRate = 0.35,
		ReadInfluence = 1,
		PunishChance = 0.95,
		FeintPatience = true,
		FeintAwareAt = 0.25,
		ThinkSeconds = 0.15,
		TurnRateDegrees = 720,
		HoldAfterParryChance = 0.9,
		RhythmRead = 0.9,
	}),
}) :: { [DifficultyName]: Difficulty }

-- System-level numbers (TrainingBotSystem.lua).
TrainingBotConstants.Config = table.freeze({
	MaxHealth = 500,
	-- Seconds a defeated bot lies there before it is rebuilt at its spawn point.
	RespawnDelay = 3,
	-- Studs in front of the spawning admin.
	SpawnDistance = 12,
	-- Oldest is evicted past this. Each bot is a real combatant with its own Heartbeat work.
	MaxActive = 4,
	-- It fights whoever spawned it while they are within this range and alive; otherwise the nearest
	-- live player within it; otherwise it walks home and idles.
	LeashRange = 90,
	-- Beyond this from its spawn point with no target, it walks back.
	HomeRadius = 6,
	-- Walk and sprint speeds -- the same numbers a player moves at (CombatConstants.BaseWalkSpeed and
	-- RunConstants' sprint multiplier), restated rather than required because the bot is not a player
	-- and RunSystem does not drive it. Guarding walks slower, as a player's guard does.
	WalkSpeed = 10,
	SprintSpeed = 18,
	GuardWalkSpeed = 7,
	-- Sprint when further than this outside its preferred range. A player closing on someone sprints;
	-- at 10 the bot walked most gaps at WalkSpeed and could be kited indefinitely.
	SprintBeyondStuds = 5,
	-- Estimated weapon reach when the roster's hitbox config cannot answer (studs, root to target root).
	FallbackReach = 6,
	-- Extra studs on the target's reach when judging whether an incoming swing can reach the bot --
	-- a real player also respects a swing a little outside its nominal range.
	ThreatMarginStuds = 2.5,
	-- Repaint cadence for the billboard. Text writes replicate, so this is deliberately not per-frame.
	BillboardRefreshSeconds = 0.2,
	BillboardColor = Color3.fromRGB(214, 120, 70),
	-- Give up on a planned press the combat stack keeps refusing (chain delay, cooldown) after this long.
	-- Must exceed AttackConstants.Sequence.EndOfStringCooldownSeconds (0.5): a pressure string planned the
	-- moment the last one ends is refused for exactly that long with the body otherwise free.
	AttackIntentSeconds = 0.8,
}) :: {
	MaxHealth: number,
	RespawnDelay: number,
	SpawnDistance: number,
	MaxActive: number,
	LeashRange: number,
	HomeRadius: number,
	WalkSpeed: number,
	SprintSpeed: number,
	GuardWalkSpeed: number,
	SprintBeyondStuds: number,
	FallbackReach: number,
	ThreatMarginStuds: number,
	BillboardRefreshSeconds: number,
	BillboardColor: Color3,
	AttackIntentSeconds: number,
}

-- HOW IT PLAYS OFFENCE AND READS YOUR STRINGS (TrainingBotBrain). Style-independent: these are how a
-- competent player uses whatever aggression their style gives them, not how much of it they have.
TrainingBotConstants.Offence = table.freeze({
	-- You standing inside its reach, not swinging and not guarding, is its turn: its per-second
	-- Aggression is multiplied by this there (capped at 0.95). Without it the bot spaced itself just
	-- outside its own reach and let you walk in unanswered.
	InReachAggressionScale = 2.5,
	-- Extra Heavy chance against a guard that is being HELD (Blocking) -- a held guard cannot parry, and
	-- a Heavy drains it double -- scaled by 0.5 + 0.5 * ReadInfluence. A feint is wasted on a held guard,
	-- so the feint chance is multiplied by HeldGuardFeintScale at the same time.
	HeldGuardHeavyBonus = 0.35,
	HeldGuardFeintScale = 0.3,
	-- An M1 feint (every Basic is feintable -- MoveTypes.FeintableByStage): a from-neutral string opens
	-- with a feinted M1 at this fraction of the Heavy feint chance, then swings for real.
	BasicFeintShare = 0.4,
	-- ANTI-METRONOME. After each accepted press of a string with presses left, the next one is held back
	-- by up to StringDelayMaxSeconds, at StringDelayChance * (0.5 + ReadInfluence) plus half the
	-- read-weighted parry habit -- so a parrier gets its timing broken. ONLY WHEN ITS LAST HIT DID NOT LAND:
	-- the M1 impact gap sits 0.06s inside DamageConstants.Combo.WindowSeconds (see AttackConstants.
	-- Sequence.ChainDelaySeconds), so any hold on a landing string drops the combo and the launcher -- and a
	-- stunned target has no parry timing to break anyway.
	StringDelayChance = 0.2,
	StringDelayMaxSeconds = 0.25,
	-- After a string of its own whose last contact LANDED, it keeps the pressure on (a new exchange the
	-- moment its lockout ends) at Aggression * PunishChance, rather than stepping out as it does after a
	-- blocked or parried one.
	PressureWindowSeconds = 0.9,
	-- How many Basics a player's string has before it ends in AttackConstants' end-of-string lockout (the
	-- launcher is the only 4th hit, and it is never earned on a guard). A block on the swing that ends a
	-- string -- or on any Heavy -- is dropped the moment that swing goes into recovery so the recovery can
	-- be punished; mid-string it is held, as a player holds block through a string.
	StringLength = 3,
})

-- THE BOT'S AIR GAME, once its launcher has you up (TrainingBotBrain's air beats). It runs the same air
-- string a player does, through the same presses, and the one thing that makes it a sparring partner rather
-- than a metronome is the DELAY: each beat is pressed on-beat or held back by up to MaxBeatDelaySeconds, at
-- DelayChance, scaled by the difficulty's ReadInfluence -- so a Master baits your parry the way a person
-- would. MaxBeatDelaySeconds stays inside AirComboConstants' legal delay space (ContinueSeconds minus an air
-- hit's windup and recovery), or the bot would drop its own combos.
TrainingBotConstants.Air = table.freeze({
	MaxBeatDelaySeconds = 0.35,
	DelayChance = 0.5,
	-- It cashes out with the Spike when a wall is within this many studs behind you (the splat is the
	-- Spike's whole point), with the Slam otherwise.
	SpikeWallStuds = 14,
})

function TrainingBotConstants.IsStyle(value: unknown): boolean
	return typeof(value) == "string" and TrainingBotConstants.Styles[value :: any] ~= nil
end

function TrainingBotConstants.IsDifficulty(value: unknown): boolean
	return typeof(value) == "string" and TrainingBotConstants.Difficulties[value :: any] ~= nil
end

return TrainingBotConstants
