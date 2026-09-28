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

export type StyleName = "FullFight" | "Aggressor" | "Turtle" | "AttackOnly" | "BlockOnly" | "ParryOnly" | "DodgeOnly"

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
	-- 0..1: chance, per neutral-game decision with you in reach, that it raises its guard for a beat
	-- before you have swung at all -- the "respect" a player shows someone in their face. Doubles as
	-- it gets rattled. Blocks, never parries (a held guard cannot arm one).
	GuardInRange: number,
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
}) :: { StyleName }

TrainingBotConstants.DifficultyOrder = table.freeze({ "Novice", "Adept", "Master" }) :: { DifficultyName }

TrainingBotConstants.DefaultStyle = "FullFight" :: StyleName
TrainingBotConstants.DefaultDifficulty = "Adept" :: DifficultyName

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
	-- Sprint when further than this outside its preferred range.
	SprintBeyondStuds = 10,
	-- Estimated weapon reach when the roster's hitbox config cannot answer (studs, root to target root).
	FallbackReach = 6,
	-- Extra studs on the target's reach when judging whether an incoming swing can reach the bot --
	-- a real player also respects a swing a little outside its nominal range.
	ThreatMarginStuds = 2.5,
	-- Repaint cadence for the billboard. Text writes replicate, so this is deliberately not per-frame.
	BillboardRefreshSeconds = 0.2,
	BillboardColor = Color3.fromRGB(214, 120, 70),
	-- Give up on a planned press the combat stack keeps refusing (chain delay, cooldown) after this long.
	AttackIntentSeconds = 0.6,
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

function TrainingBotConstants.IsStyle(value: unknown): boolean
	return typeof(value) == "string" and TrainingBotConstants.Styles[value :: any] ~= nil
end

function TrainingBotConstants.IsDifficulty(value: unknown): boolean
	return typeof(value) == "string" and TrainingBotConstants.Difficulties[value :: any] ~= nil
end

return TrainingBotConstants
