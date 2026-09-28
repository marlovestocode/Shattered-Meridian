--!strict
--[[
	FXConstants.lua

	Owns: the presentation-layer tuning every client-side effect module reads -- hit feedback, screen
	shake, damage numbers, the pooled-effect budgets and the sound entries that go with them.

	Lifted out of Constants.lua. Constants.FX re-exports this module, so every existing
	Constants.FX.X call site keeps working unchanged; new code should require this module directly.

	PRESENTATION ONLY, AND THAT LINE IS LOAD-BEARING. Nothing here may decide an outcome. These
	numbers run on the client, where a player can change them; a value that reached a gameplay
	decision would be a value a client could edit in its own favour. The server decides what happened
	and tells the client; this file only says how loudly to say it.

	Does not own: the SoundDefinition/LoopSoundDefinition shapes those sound entries conform to
	(those stay exported from Constants.lua, which is where SoundManager's other callers read them
	from), nor any domain's own FX tuning -- Blimp, Parkour, Flight and Combat each keep theirs in
	their own constants module.
]]

-- Client-only impact-feel tunables (Client/FX/CameraShake.lua, HitStop.lua, HitFlash.lua). These
-- never affect a gameplay OUTCOME -- they're driven exclusively off server-validated
-- Combat_FeedbackEvent resolutions (CombatClient.lua) and only shape how a confirmed hit LOOKS on
-- the acting/receiving client, so they live here as presentation tunables (like Constants.Camera),
-- not under Constants.Combat, and are deliberately absent from validateCombatConstants -- a missing
-- preset degrades to "no shake/no freeze," never to a wrong hit. EXCEPTION: MovementDust below (and
-- CameraShake.SlideStart, Constants.Camera.Sprint/Slide) are driven off LOCAL input/held-state
-- (Sprint held, Slide predicted-press) rather than a Combat_FeedbackEvent -- the same category
-- CombatAnimator's own Running/Walking crossfade already falls into, since raised WalkSpeed itself
-- has nothing a client needs to roll back from.
local FXConstants = {
	-- Camera shake presets. Amplitude is peak rotational offset in RADIANS (0.03 ~= 1.7 deg),
	-- Frequency the noise oscillation rate (higher = jitterier), DurationSeconds the decay time --
	-- CameraShake eases each to zero over its duration (see that module). Scaled by impact weight:
	-- a light basic hit barely nudges, a posture break / finisher slam rocks the frame.
	CameraShake = {
		HitLight = { Amplitude = 0.012, Frequency = 28, DurationSeconds = 0.18 },
		HitHeavy = { Amplitude = 0.025, Frequency = 24, DurationSeconds = 0.28 },
		Parry = { Amplitude = 0.03, Frequency = 34, DurationSeconds = 0.22 },
		PostureBreak = { Amplitude = 0.045, Frequency = 20, DurationSeconds = 0.4 },
		FinisherSlam = { Amplitude = 0.05, Frequency = 18, DurationSeconds = 0.45 },
		-- One-shot kick at Slide-start (CombatClient.lua's predictSlide/Combat_SlidePerformed) --
		-- lighter than any combat preset, a movement flourish rather than an impact.
		SlideStart = { Amplitude = 0.02, Frequency = 22, DurationSeconds = 0.2 },
		-- Per-axis math.noise decorrelation offsets so pitch/yaw/roll wander independently instead of
		-- in lockstep (which would read as a single diagonal jerk rather than a shake).
		NoiseSeeds = { Pitch = 0, Yaw = 37.2, Roll = 91.7 },
	},

	-- Hit-stop (freeze-frame) durations, in seconds.
	--
	-- VictimSeconds and PostureBreakSeconds are LIVE again as of Client/FX/HitStop.
	-- FreezeVictimMovement -- a brief freeze of the DEFENDER's own AssemblyLinearVelocity (via
	-- ParkourMotor.ApplyImpulse), not an animation-track freeze. See HitStop.lua's own header for why
	-- the mechanism changed: the original design (below) predates this codebase's combat rewrite and
	-- pauses the involved players' combat animation TRACKS, but no swing plays a body animation today
	-- (every Default move's AnimationId is ""), so an animation freeze would visibly do nothing for
	-- most hits. CombatFeedbackClient.lua wires it off Combat_Feedback for the DEFENDER role only, on
	-- the same Clean/Backstab/GuardBroken outcomes DamageConstants.Hitstun already grants a real
	-- lockout for -- Clean takes VictimSeconds, Backstab/GuardBroken take the heavier
	-- PostureBreakSeconds, the same asymmetry CombatFeedbackClient's own ShakePresets.Defender table
	-- already draws between those three kinds.
	--
	-- HeavyBonusSeconds and ParrySeconds are live since 2026-09-28: CombatFeedbackClient's exchange
	-- (animation) freeze adds the first to a Heavy move and uses the second for a parry clash, on both
	-- combatants. AttackerSeconds is still read by nothing -- the exchange freeze deliberately holds both
	-- bodies for the SAME beat (a shared stop), so a separate attacker length would only desync them.
	-- Kept rather than deleted because they are pre-tuned and cheap to keep, the same reasoning that
	-- left DamageConstants.AttackerLunge in place for the bodies it can still reach.
	--
	-- MinIntervalSeconds throttles back-to-back freezes (per HitStop.lua's own makeThrottledFreeze) so
	-- a multi-target swing, or a fast combo string, can't chain consecutive freezes into slow motion.
	HitStop = {
		AttackerSeconds = 0.06,
		VictimSeconds = 0.09,
		HeavyBonusSeconds = 0.03,
		ParrySeconds = 0.12,
		PostureBreakSeconds = 0.14,
		MinIntervalSeconds = 0.1,
		-- Flight landing-impact freeze (HitStop.FreezeFlightLanding, Client/FX/FlightAnimator.
		-- FreezeActiveFlightTrack) -- much lighter than a combat hit-stop since this is cosmetic
		-- feedback, not a clash beat; Hard is closer to PostureBreakSeconds' weight (a real, heavy
		-- landing), Soft barely more than a single frame.
		FlightLandingSoftSeconds = 0.05,
		FlightLandingHardSeconds = 0.16,
	},

	-- Victim hit-flash (a pooled Highlight, HitFlash.lua). DurationSeconds is how long the flash
	-- holds before fading; the color per resolution reads the same family the rest of combat
	-- feedback uses (white = a plain hit, gold = a parry deflection, red-gold = a posture break).
	HitFlash = {
		DurationSeconds = 0.12,
		-- Pool hard cap -- well under Roblox's 31-Highlight render limit (see HitFlash.lua), since
		-- this melee system only ever flashes the handful of characters in one player's view at once.
		PoolMaxSize = 6,
		HitColor = Color3.fromRGB(255, 255, 255),
		ParryColor = Color3.fromRGB(220, 180, 90),
		PostureBreakColor = Color3.fromRGB(230, 120, 70),
		-- The "parry window is OPEN right now" tell (HitFlash.FlashHold) -- a bright metal-blue
		-- highlight held for the whole window so an ATTACKER can read "they're parry-armed, be
		-- careful" and everyone (the same broadcast drives every client) sees who's about to deflect.
		-- Same BorderAccent steel-blue family as the aim/parry reticles (LockOnReticle/
		-- ShiftLockCrosshair/ParryReadyGlint) -- deflection reads as steel, distinct from the
		-- white/gold/red impact colours above so the "armed" tell can't be mistaken for a landed hit.
		ParryWindowColor = Color3.fromRGB(120, 200, 255),
		-- ONLY read by FlashHold (the ParryWindow tell) -- the one-shot Flash (Hit/Parry/PostureBreak)
		-- stays an instant pop, deliberately: those react to an impact that already happened, and a
		-- fast snap is what reads as "contact, right now" (same reasoning as Animation.Combat's
		-- SwingFadeSeconds comment). FlashHold is different: it opens on every parry-armed block press,
		-- not just a landed hit, so an instant full-opacity pop-in fired that often reads as a flicker/
		-- twitch rather than a clean reveal. Easing it in over a short window instead lets it read as a
		-- deliberate "guard tightening into a parry stance" rather than a jarring on/off snap -- part of
		-- the parry-feel pass that also retimed CombatAnimator's ParryFlashFadeSeconds for the same
		-- reason (see that constant's own comment).
		HoldFadeInSeconds = 0.08,
	},

	-- Floating combat-feedback numbers (Client/UI/Screens/CombatFeedback/init.lua).
	DamageNumbers = {
		-- How long a spawned one-off damage number (e.g. "PARRIED") stays in the list before being
		-- pruned -- comfortably longer than DamageNumberLabel's own rise-and-fade.
		LifetimeSeconds = 1.1,
		-- How long a damage stack stays open for the next hit to add onto before the next hit starts
		-- a fresh stack instead.
		StackWindowSeconds = 1,
	},

	-- Flight VFX (Client/FX/FlightVFX.lua) -- a single pooled "ring" Part factory reused across all
	-- three presets below rather than three separate pools, keeping the instance/pool-cap budget
	-- small per performance-optimization.md (this is a single-admin debug tool, not a multi-player
	-- combat effect that needs headroom for many concurrent instances).
	FlightRingPool = {
		PoolMaxSize = 8,
		-- Ring's starting state before it tweens out to a preset's MaxRadiusStuds/full transparency.
		StartSize = Vector3.new(0.2, 0.5, 0.5),
		StartTransparency = 0.2,
	},
	FlightTakeoffDust = {
		MaxRadiusStuds = 6,
		ExpandDurationSeconds = 0.4,
		Color = Color3.fromRGB(235, 235, 245),
	},
	FlightLandingRing = {
		SoftMaxRadiusStuds = 8,
		HardMaxRadiusStuds = 16,
		ExpandDurationSeconds = 0.5,
		SoftColor = Color3.fromRGB(200, 215, 255),
		HardColor = Color3.fromRGB(255, 220, 140),
	},
	FlightSonicBoom = {
		MaxRadiusStuds = 24,
		ExpandDurationSeconds = 0.35,
		Color = Color3.fromRGB(255, 255, 255),
	},

	-- Ground dust (Client/FX/MovementVFX.lua) -- pooled ParticleEmitters kicked up under the feet
	-- while sprinting (a steady trickle) or on Slide-start (one bigger burst), colored by the
	-- standing surface's Humanoid.FloorMaterial. Placeholder Color3 values -- retune in Studio once
	-- the actual look is visible; these are first-pass guesses, not sourced from a real reference.
	MovementDust = {
		-- A real dust-puff sprite (soft round smoke/dirt cloud, NOT Roblox's default ParticleEmitter
		-- texture -- that default is a 4-point sparkle/star, which is exactly what an untextured
		-- emitter here rendered as). Sourced from the reference "Running Model.rbxm" asset the user
		-- supplied (its own Dust ParticleEmitter used this same id) -- not fabricated, per this
		-- codebase's own "never guess an asset id" rule (see CombatAudio.lua/VitalIcon.lua headers).
		Texture = "rbxassetid://122434532",
		-- Well under the same render-budget spirit as HitFlash's PoolMaxSize -- this only ever needs
		-- to cover the handful of puffs alive under one moving player's own feet at once.
		PoolMaxSize = 16,
		-- Fixed approximation of the ground point below HumanoidRootPart -- no raycast per puff (see
		-- this feature's own scope notes on why).
		FootOffsetStuds = 3,
		TrickleIntervalSeconds = 0.15,
		TrickleParticleCount = 5,
		SlideBurstParticleCount = 20,
		-- Also schedules the pooled carrier Part's own Release() back to the pool.
		ParticleLifetimeSeconds = 0.6,
		-- Fraction of ParticleLifetimeSeconds used as the jittered LOW end of the emitter's own
		-- Lifetime NumberRange (the high end is ParticleLifetimeSeconds itself).
		LifetimeJitterFraction = 0.6,
		-- The invisible carrier Part's own Size -- never rendered (Transparency = 1), just needs to
		-- exist to host the ParticleEmitter.
		CarrierPartSize = Vector3.new(0.2, 0.2, 0.2),
		Speed = NumberRange.new(2, 5),
		SpreadAngle = Vector2.new(40, 40),
		SizeSequence = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.3),
			NumberSequenceKeypoint.new(0.4, 0.6),
			NumberSequenceKeypoint.new(1, 0.1),
		}),
		TransparencySequence = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.3),
			NumberSequenceKeypoint.new(1, 1),
		}),
		-- Deliberately broader than just the "natural terrain" materials -- Studio's own default
		-- baseplate is Plastic, and a stone-family surface could plausibly be authored as any of
		-- Rock/Slate/Basalt/Cobblestone/Granite/Limestone/Sandstone/Pavement/Asphalt/Concrete, not
		-- just "Rock" -- without an entry, a material silently falls through to DefaultColor
		-- regardless of what it actually looks like, which reads as "the color never changes."
		ColorByFloorMaterial = {
			[Enum.Material.Grass] = Color3.fromRGB(90, 75, 45),
			[Enum.Material.LeafyGrass] = Color3.fromRGB(90, 75, 45),
			[Enum.Material.Sand] = Color3.fromRGB(210, 190, 140),
			[Enum.Material.Concrete] = Color3.fromRGB(175, 175, 175),
			[Enum.Material.Pavement] = Color3.fromRGB(170, 170, 170),
			[Enum.Material.Asphalt] = Color3.fromRGB(90, 90, 95),
			[Enum.Material.Rock] = Color3.fromRGB(120, 110, 100),
			[Enum.Material.Slate] = Color3.fromRGB(110, 110, 115),
			[Enum.Material.Basalt] = Color3.fromRGB(70, 70, 75),
			[Enum.Material.Cobblestone] = Color3.fromRGB(130, 125, 120),
			[Enum.Material.Granite] = Color3.fromRGB(140, 130, 130),
			[Enum.Material.Limestone] = Color3.fromRGB(190, 180, 160),
			[Enum.Material.Sandstone] = Color3.fromRGB(200, 175, 135),
			[Enum.Material.Marble] = Color3.fromRGB(210, 205, 200),
			[Enum.Material.Wood] = Color3.fromRGB(130, 95, 65),
			[Enum.Material.WoodPlanks] = Color3.fromRGB(130, 95, 65),
			[Enum.Material.Snow] = Color3.fromRGB(235, 235, 245),
			[Enum.Material.Ice] = Color3.fromRGB(210, 230, 240),
			[Enum.Material.Mud] = Color3.fromRGB(80, 60, 40),
			[Enum.Material.Ground] = Color3.fromRGB(100, 85, 60),
			-- Studio's own default baseplate material -- without this, a fresh test place with no
			-- terrain shows the flat DefaultColor below regardless of the part's own BrickColor.
			[Enum.Material.Plastic] = Color3.fromRGB(160, 150, 145),
		} :: { [Enum.Material]: Color3 },
		DefaultColor = Color3.fromRGB(150, 140, 130),
	},

	-- Combat/flight animation-track fade times and the shared cross-rig priority weight -- were THREE
	-- independently maintained copies with no shared reference point: Server/Combat/BotAnimator.lua (a
	-- training bot's server-driven equivalent of the player-facing animator below, since a bot has no
	-- owning Player/client to run that module for it), Client/FX/CombatAnimator.lua (the local player's
	-- own combat tracks -- swings, block/parry, dash/slide, hit reactions, locomotion crossfade), and
	-- Client/FX/FlightAnimator.lua (flight's Hover/CruiseLoop/BoostLoop + Takeoff/LandingSoft/
	-- LandingHard one-shots) each hand-typed their own SWING_FADE_TIME/BLOCK_HOLD_FADE_TIME/etc and
	-- DOMINANT_WEIGHT locals. BotAnimator.lua's own header even says outright "Same fade times/weight as
	-- Client/FX/CombatAnimator.lua" -- a comment ADMITTING the duplication rather than pointing at a
	-- shared value, exactly the drift risk engineering-standards.md's one-source-of-truth rule exists to
	-- close (retuning a fade in one file silently leaves the other two on the stale number). Sub-tabled
	-- Combat/Flight since the two animators' fade needs only partially overlap (BotAnimator has no
	-- locomotion crossfade or dash/slide clips; FlightAnimator has no swing/block/hit-reaction clips) --
	-- DominantWeight is the one number genuinely shared by all three files (see CombatAnimator.lua's own
	-- DOMINANT_WEIGHT header for why a value this far above Roblox's default character rig's own
	-- implicit walk/run weight is necessary at all: same-priority tracks BLEND by Weight rather than
	-- either cleanly winning, so this needs to be dominant enough to reliably override the rig's own
	-- baked-in Animate script). NOTE: CombatAnimator.lua's ROLLBACK_FADE_TIME is deliberately NOT
	-- duplicated in here -- it already reads Constants.Combat.Prediction.RollbackFadeSeconds directly, a
	-- single existing source, so there was nothing to centralize for that one.
	Animation = {
		-- CombatAnimator.lua/BotAnimator.lua's combat-track fades. Not every field is read by both
		-- files today (BotAnimator has no locomotion crossfade), but both read from this same table.
		Combat = {
			-- One-shot swings play snappy -- a fast fade-in reads as immediate/responsive.
			SwingFadeSeconds = 0.05,
			-- Walking<->Running crossfade (a start, or a toggle-driven handoff between the two loops)
			-- -- softer than a genuine interrupt (LocomotionInterruptFadeSeconds below), since this one
			-- wants a blend, not a cut.
			LocomotionFadeSeconds = 0.2,
			BlockHoldFadeSeconds = 0.1,
			-- Deliberately NOT as fast as Dash/Slide's 0.03 below despite looking like the same "one-shot
			-- accent" shape -- those two play PREDICTED, at the instant of input (CombatAnimator.
			-- PlayPredictedDash/PlayPredictedSlide), so a hard snap reads as "immediate response to my
			-- press." ParryFlash never gets that prediction (CombatAnimator.PlayParryFlash's own header:
			-- parry availability is server-cooldown-gated state the client can't guess) -- it only ever
			-- plays after a full round trip, landing on top of a BlockHold pose that already eased in
			-- BLOCK_HOLD_FADE_TIME ago. A 0.03s snap arriving unpredictably late, on top of an already-
			-- settled pose, reads as a jarring second pop instead of a responsive first one. Blending it
			-- in over roughly BlockHoldFadeSeconds' own timescale instead lets the parry-armed pose read
			-- as the guard stance settling further, not a new, disconnected flinch.
			ParryFlashFadeSeconds = 0.12,
			-- No DashFadeSeconds/SlideFadeSeconds here any more. Both were read by exactly one thing --
			-- CombatAnimator.PlayPredictedDash/PlayPredictedSlide, deleted with the rest of the combat
			-- system -- and neither had a consumer anywhere in the codebase afterwards. The dash's
			-- blend now lives where the dash does: ParkourConstants.Animation.BlendProfiles.Snap,
			-- selected per clip by ParkourAnimator rather than by a second global fade table.
			HitReactionFadeSeconds = 0.05,
			-- A genuine locomotion interrupt (a combat action starting, or the character actually
			-- stopping) -- a fast cut, not the softer LocomotionFadeSeconds blend above.
			LocomotionInterruptFadeSeconds = 0.03,
		},
		-- FlightAnimator.lua's Hover/CruiseLoop/BoostLoop + Takeoff/LandingSoft/LandingHard fades.
		Flight = {
			OneShotFadeSeconds = 0.15,
			LoopFadeSeconds = 0.3,
		},
		-- Shared by all three files -- see this table's own header for why a value this far above 1
		-- is needed at all.
		DominantWeight = 100,
	},
}

return FXConstants
