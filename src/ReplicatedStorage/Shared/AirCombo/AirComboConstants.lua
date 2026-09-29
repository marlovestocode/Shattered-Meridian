--!strict
--[[
	AirComboConstants.lua

	Owns: the air combo's tunables -- when the launcher branch is earned, how high and how weightily the
	victim hovers, where the attacker follows, the one shared continuation deadline, how damage scales
	across a route, what each finisher does, and the air parry's lag rewind. The design, with the reasoning
	behind every number here, is docs/design/air-combat-and-evade.md (Part B); read it before retuning.

	Standalone rather than a section of CombatConstants for the reason every combat subsystem's constants
	are (GrabConstants' header): the air combo is a sibling module that can be pulled out without editing a
	central table. Requires nothing, so anything may require it.

	THERE IS NO PER-MOVE NUMBER IN THIS FILE. The launcher, the three air hits and the two finishers are
	ordinary Default moves (CombatConstants.Weapons.Baseline.Stages.Launcher/Air/AirFinisher, one copy per
	weapon via WeaponRoster), so their windups, damage and hitboxes are Move Editor tunable and persist
	through the existing Default-move override record. What is here is everything no single move could
	sensibly author: the scaling RULES, the hover, the follow, the deadlines and the finisher outcomes.

	Does not own: the combo's state or rules (Server/Combat/AirCombo/AirComboMachine.lua), applying any of it
	(AirComboSystem), or the parry's ordinary timing (DefenseConstants.Parry -- an air parry is the same
	parry, judged on the same substep clock, with only the rewind below added).
]]

local AirComboConstants = {}

-- The whole system's switch. Off, a launcher is an ordinary hit and nothing is ever held.
AirComboConstants.Enabled = true

-- THE LAUNCHER IS THE 4TH M1 (docs B2). B1, B2, B3, then Space + M1 throws the weapon's Launcher -- and it
-- is the ONLY 4th hit an M1 string has (SwingSequencer's header: a plain M1 after B3 starts a fresh string).
-- It needs BOTH: the Basic string has THROWN MinStringStage stages, and the LANDED combo (ComboEscalation)
-- is at least MinComboStage -- all three hits connected. Throw-based and landing-based, so a launcher cannot
-- be earned by flailing at air. Short of either, Space + M1 is simply the next Basic -- never a dead input.
-- Space stops jumping from the moment B3 is thrown (Client/Combat/AttackInputClient's jump suppression reads
-- MinStringStage), so the modifier never hops the body off the ground.
AirComboConstants.Launcher = {
	MinStringStage = 3,
	MinComboStage = 3,
	-- How long, from the click that will be B3, the client assumes the swing takes when it starts the jump
	-- suppression -- before the server's confirmation of B3 replaces it with the string's real lapse. Only
	-- ever lengthens a window the confirmation then corrects; see AttackInputClient.notePressForJump.
	-- 1.2: a B3 at the slowed M1 tempo (AttackConstants.Tempo.ByStage.Basic 0.65) runs ~1.03s.
	JumpSuppressSwingAllowanceSeconds = 1.2,
}

-- The air string's fixed length. After the last air hit lands, the next Basic throws the Slam finisher
-- automatically: the string cannot continue past it.
AirComboConstants.StringLength = 3

-- ONE SHARED DEADLINE (docs B1). The victim's hold, the attacker's commitment and the drop all derive from
-- a single ContinueBy, which each landed air hit resets to contact + ContinueSeconds. The deleted
-- AirCombo.lua ran hold and continuation on two constants, and hits that visibly connected were rejected
-- as "late" -- one number cannot disagree with itself.
AirComboConstants.Timing = {
	-- The first beat's budget, from launch contact. Longer than the rest to absorb the follow's one-RTT
	-- late start (the attacker's client only begins following when the launch reaches it).
	FirstContinueSeconds = 1.1,
	-- Every later beat's budget, from the previous landed air hit's contact.
	ContinueSeconds = 0.9,
	-- The first air press may be thrown from launch + this. Before it, the victim is still rising.
	FirstPressSeconds = 0.18,
	-- The hard cap on a whole combo, whatever else happens.
	MaxComboSeconds = 4.0,
	-- Cannot be launched again for this long after ANY combo ends -- victim AND attacker (a parried
	-- attacker must never become the target of a reversed air combo).
	LaunchImmunitySeconds = 2.5,
	-- "In-time swings are honoured" (docs B5): a swing's start is rewound by min(attacker ping, this)
	-- before it is judged against ContinueBy, so an attacker is only ever dropped for a press that was
	-- late on their own screen. The same cap the parry's ping refund uses.
	SwingRewindMaxSeconds = 0.12,
	-- How long the end-state phase (Parried/Dropped/Slammed/Spiked/Recovering) stays published after the
	-- combo ends, so a spectator can read it, before the Attribute clears.
	PhaseLingerSeconds = 0.8,
}

-- THE HOVER (docs B3). The victim is server-owned while held and springs to anchor = launch-contact root
-- position + HeightStuds. An UNDERDAMPED spring (FlightMath.SpringStep, unconditionally stable), so it
-- overshoots about half a stud and settles -- the overshoot is what sells the launch. Each landed air hit
-- kicks the spring upward by HitKickSpeed for a small, weighty bob.
AirComboConstants.Hover = {
	HeightStuds = 8,
	-- How long the combo stays in the Rising phase before Held.
	RiseSeconds = 0.30,
	Frequency = 9,
	Damping = 0.55,
	-- The rise's initial upward velocity. The launcher's own authored Knockback UpVelocity is used instead
	-- when it has one (a custom StartsAirCombo move); a Default launcher authors none.
	InitialRiseSpeed = 30,
	HitKickSpeed = 6,
	-- The constraint the server drives the victim's root with. Stiff and fast: the SPRING is the feel, the
	-- constraint only has to put the body where the spring says.
	MaxForce = 200000,
	Responsiveness = 200,
	MaxTorque = 200000,
	OrientationResponsiveness = 60,
}

-- THE FOLLOW (docs B2/B5). The attacker's slot is anchor - StandoffStuds along the attacker->victim flat
-- direction - BelowStuds down: the old AirCombo table's standoff and below-offset, which were right. The
-- attacker's own client springs to it (their body is theirs); a server-owned attacker (the bot) is driven
-- by the server instead, to the same slot.
AirComboConstants.Follow = {
	StandoffStuds = 3.5,
	BelowStuds = 1.5,
	-- WASD moves the attacker within this disc around the slot. Spacing error lives here, not in ping.
	DriftRadiusStuds = 4,
	DriftSpeed = 10,
	-- Facing is ASSISTED, not locked: the body turns toward the victim at this capped rate, so looking
	-- away mid-string can whiff.
	TurnDegreesPerSecond = 540,
	-- The follow spring. Critically damped-ish: the attacker arrives without bouncing past the slot.
	Frequency = 8,
	Damping = 1,
	-- Proportional correction from the spring's position to the body's, on top of the spring's velocity.
	CorrectionGain = 12,
	MaxForce = 200000,
	-- Server audit: after Rising + GraceSeconds, an attacker root further than ToleranceStuds from its
	-- slot for longer than GraceSeconds ends the combo SpacingFail. A client that refuses to follow only
	-- drops its own combo.
	ToleranceStuds = 7,
	GraceSeconds = 0.35,
	-- A parried attacker is pushed up and back at this speed on the clash, so the victim lands first.
	ClashPushSpeed = 4,
}

-- DAMAGE SCALING (docs B3). The moves' authored damage is the BASE; these are the rules on top of it.
--   * Air hit k (0-based: how many air hits have already landed) deals base * max(Floor, 1 - FalloffPerHit*k).
--   * A finisher deals base + PerHitBonus * air hits landed -- running the read is worth more than cashing
--     out at once.
-- ComboEscalation does NOT scale any air move: DamageSystem prices the launcher's follow-ups flat, the same
-- way it already prices M1s, so the two scalings never stack.
AirComboConstants.Damage = {
	AirHitFalloffPerHit = 0.1,
	AirHitFloor = 0.6,
	Finishers = {
		Slam = { PerHitBonus = 2.5 },
		Spike = { PerHitBonus = 1.5 },
	},
}

-- SLAM: damage now. Drives the victim straight down; a HARD KNOCKDOWN on landing, during which the victim is
-- intangible (every contact resolves Evaded) and then wakes where they fell.
AirComboConstants.Slam = {
	DownSpeed = 90,
	KnockdownSeconds = 0.9,
	-- The drop gives up and lands wherever the body is after this long -- a slam over a void still ends.
	MaxDropSeconds = 1.2,
	-- Ground contact: a cast this far below the root each frame.
	GroundProbeStuds = 3.5,
}

-- SPIKE: position and guard pressure. Sends the victim along the attacker's facing, drains a fraction of
-- their MAX guard through DefenseSystem.DrainGuard (the existing seam), and a wall in the path within
-- SplatWindowSeconds is a WALL SPLAT: SplatHitstunSeconds of hitstun through DamageSystem.ExtendHitstun, the
-- path the environment system already uses. Launch immunity still stands, so the follow-up is a ground
-- string, never a relaunch.
AirComboConstants.Spike = {
	HorizontalSpeed = 70,
	VerticalSpeed = -25,
	GuardDrainFraction = 0.35,
	SplatWindowSeconds = 1.2,
	SplatHitstunSeconds = 0.8,
	-- A wall: a surface this far ahead along the flight whose normal is within this of horizontal.
	WallProbeStuds = 3,
	WallMaxNormalY = 0.5,
}

-- THE AIR PARRY'S LAG REWIND (docs B4/B5). For AIR-HELD defenders only, DefenseSystem holds a Clean contact
-- for up to D = min(defender round trip, RewindMaxSeconds) instead of applying it. A block press arriving in
-- that hold is judged at its REWOUND press time (arrival - D): would a window armed then -- same MinUnguarded
-- and lockout checks, evaluated then, and NO additional end refund (the rewind replaces it) -- contain the
-- contact? Yes means Parried. The cost is stated honestly: against a laggy victim, the attacker's hit
-- confirmation arrives up to this much later. Their own swing animation is unaffected.
AirComboConstants.Parry = {
	RewindMaxSeconds = 0.20,
}

-- A dropped or parried victim is released to their own client and falls; once they touch down (or this
-- long passes) the Recovering phase publishes.
AirComboConstants.Recovery = {
	MaxFallSeconds = 3,
	GroundProbeStuds = 3.5,
}

-- PRESENTATION (docs B4: weight and readability), read by Client/FX/AirComboFX.lua. Built from primitives --
-- parts, highlights, trails -- so nothing here waits on an uploaded asset. Every camera effect is gated by
-- the player's own comfort settings through CameraShake/FOVOffset, like every other one in the game.
AirComboConstants.Presentation = {
	-- A spectator's read of each phase, on the VICTIM (the attacker gets the wind trail while following).
	Colors = {
		Held = Color3.fromRGB(235, 70, 60),
		Parried = Color3.fromRGB(90, 170, 255),
		Dropped = Color3.fromRGB(150, 150, 150),
		Recovering = Color3.fromRGB(255, 255, 255),
		Slammed = Color3.fromRGB(150, 120, 90),
		Spiked = Color3.fromRGB(255, 160, 60),
		Clash = Color3.fromRGB(255, 255, 255),
	},
	-- The faint light column under a held victim.
	ColumnHeightStuds = 9,
	ColumnWidthStuds = 0.35,
	ColumnTransparency = 0.72,
	-- An end-state flash on the victim's whole body.
	FlashSeconds = 0.28,
	-- A ring shockwave (the clash, the parried-out flash, the slam's crater).
	RingSeconds = 0.35,
	RingStartStuds = 2,
	RingEndStuds = 14,
	-- A puff (dropped).
	PuffSeconds = 0.4,
	PuffEndStuds = 6,
	-- Only effects within this distance of the camera are drawn.
	MaxDrawDistanceStuds = 250,
	-- Camera weight per contact (the attacker's and the victim's own clients), as FOVOffset punches and
	-- CameraShake presets. The finisher hits hardest; the clash is its own, and a perfect parry heavier still.
	Punch = {
		Hit = { Delta = 2.5, OutSeconds = 0.04, BackSeconds = 0.14 },
		Launch = { Delta = 4, OutSeconds = 0.05, BackSeconds = 0.2 },
		Finisher = { Delta = 7, OutSeconds = 0.05, BackSeconds = 0.3 },
		Clash = { Delta = 9, OutSeconds = 0.04, BackSeconds = 0.3 },
	},
	Shake = {
		Hit = { Amplitude = 0.02, Frequency = 22, DurationSeconds = 0.14 },
		Launch = { Amplitude = 0.03, Frequency = 20, DurationSeconds = 0.22 },
		Finisher = { Amplitude = 0.06, Frequency = 18, DurationSeconds = 0.45 },
		Clash = { Amplitude = 0.05, Frequency = 24, DurationSeconds = 0.3 },
	},
}

AirComboConstants.Debug = {
	Enabled = false,
}

return AirComboConstants
