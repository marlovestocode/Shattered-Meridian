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
		-- A PERFECT parry (DefenseConstants.PerfectParry) -- sharper and longer than Parry, both roles.
		PerfectParry = { Amplitude = 0.042, Frequency = 40, DurationSeconds = 0.32 },
		-- A body slammed into a wall (EnvironmentReactionSystem's wall splat). Low and heavy, the victim's
		-- read; the attacker gets the lighter HitHeavy.
		WallSplat = { Amplitude = 0.05, Frequency = 16, DurationSeconds = 0.42 },
		PostureBreak = { Amplitude = 0.045, Frequency = 20, DurationSeconds = 0.4 },
		FinisherSlam = { Amplitude = 0.05, Frequency = 18, DurationSeconds = 0.45 },
		-- One-shot kick at Slide-start (CombatClient.lua's predictSlide/Combat_SlidePerformed) --
		-- lighter than any combat preset, a movement flourish rather than an impact.
		SlideStart = { Amplitude = 0.02, Frequency = 22, DurationSeconds = 0.2 },
		-- One-shot at roll start (Client/FX/MovementVFX.OnStateChanged), local player only. Lighter
		-- still than SlideStart and slower-oscillating -- a body tucking and turning over, not an impact.
		-- Gated by settings.Comfort.CameraShake like every preset here, through CameraShake.SetEnabled.
		Roll = { Amplitude = 0.014, Frequency = 16, DurationSeconds = 0.22 },
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
		-- A PERFECT parry's clash freeze, both bodies (CombatFeedbackClient). Longer than any hit's on
		-- purpose: the perfect parry is the one moment the whole exchange should visibly stop.
		PerfectParrySeconds = 0.2,
		PostureBreakSeconds = 0.14,
		MinIntervalSeconds = 0.1,
		-- After a combat freeze the frozen clips play this much faster until the time the freeze cost is won
		-- back (AnimationTrackUtil FreezeTracks' catchUp) -- the server's swing never paused, so without it
		-- every landed hit left the clip behind the swing and the next swing cut its follow-through short.
		-- 1.5 recovers a 0.09s freeze over the next 0.18s. Combat only; the flight freeze does not catch up.
		CatchUpSpeedMultiplier = 1.5,
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
		-- Skip the flash on the LOCAL player's own body. It is the most expensive one on this client --
		-- an always-on-top outline and fill over the largest model on screen -- and it tells the player
		-- nothing the shake, the impact sound and the health bar have not already said. Everyone else
		-- still sees it on them, on their own clients. Set false to flash yourself too.
		SkipLocalCharacter = true,
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
		-- A roll's two puffs, at the tuck and at the stand-up (MovementVFX.PlayRollBurst). Smaller than a
		-- slide's: a roll is over in half a second and kicks up two short scuffs, not a sustained scrape.
		RollBurstParticleCount = 12,
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

	-- Contact sparks (Client/FX/ImpactSparks.lua) -- a pooled particle burst at the contact point of a
	-- steel-on-steel outcome, fired off Combat_Feedback on both participants' clients. The TEXTURE IS
	-- ROBLOX'S OWN DEFAULT on purpose: the 4-point sparkle MovementDust had to override to stop reading
	-- as "stars" is exactly what a spark should look like, so there is no asset to guess or upload.
	ImpactSparks = {
		-- A burst is alive for its longest Lifetime; four simultaneous exchanges on screen is already a
		-- brawl, and a burst past the cap is dropped rather than allocated.
		PoolMaxSize = 8,
		CarrierPartSize = Vector3.new(0.2, 0.2, 0.2),
		-- Per outcome. Parried is the loudest by a distance -- the parry is the game's signature read and
		-- the one moment this whole pass exists to make land. Blocked is a small, common spit of steel;
		-- Trade a white clash; GuardBroken a slower, heavier shatter that falls under gravity.
		Presets = {
			Parried = {
				Count = 30,
				Color = ColorSequence.new(Color3.fromRGB(255, 235, 170), Color3.fromRGB(220, 160, 70)),
				Speed = NumberRange.new(18, 34),
				LifetimeSeconds = NumberRange.new(0.14, 0.3),
				Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.35), NumberSequenceKeypoint.new(1, 0) }),
				Drag = 7,
				Acceleration = Vector3.new(0, -20, 0),
				LightEmission = 1,
			},
			Blocked = {
				Count = 8,
				Color = ColorSequence.new(Color3.fromRGB(235, 235, 245)),
				Speed = NumberRange.new(10, 18),
				LifetimeSeconds = NumberRange.new(0.08, 0.18),
				Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.2), NumberSequenceKeypoint.new(1, 0) }),
				Drag = 8,
				Acceleration = Vector3.new(0, -20, 0),
				LightEmission = 0.8,
			},
			Trade = {
				Count = 18,
				Color = ColorSequence.new(Color3.fromRGB(255, 255, 255)),
				Speed = NumberRange.new(14, 26),
				LifetimeSeconds = NumberRange.new(0.1, 0.24),
				Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.28), NumberSequenceKeypoint.new(1, 0) }),
				Drag = 7,
				Acceleration = Vector3.new(0, -20, 0),
				LightEmission = 1,
			},
			-- A PERFECT parry: the Parried burst, hotter, denser and faster, with a white-hot core. Picked
			-- by CombatFeedbackClient off Combat_Feedback.Perfect, never by an outcome kind of its own --
			-- the server's vocabulary stays "Parried".
			ParriedPerfect = {
				Count = 55,
				Color = ColorSequence.new({
					ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 255, 240)),
					ColorSequenceKeypoint.new(0.35, Color3.fromRGB(255, 225, 140)),
					ColorSequenceKeypoint.new(1, Color3.fromRGB(235, 150, 60)),
				}),
				Speed = NumberRange.new(26, 48),
				LifetimeSeconds = NumberRange.new(0.18, 0.38),
				Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.45), NumberSequenceKeypoint.new(1, 0) }),
				Drag = 6,
				Acceleration = Vector3.new(0, -20, 0),
				LightEmission = 1,
			},
			-- A block while the guard is CRACKING (Combat_Feedback.GuardCracking, DefenseConstants.GuardCrack).
			-- Sits between Blocked and GuardBroken on purpose: the GuardBroken palette (orange falling to red)
			-- at a fraction of its count, so the sparks themselves say "this is what a break will look like".
			BlockedCracking = {
				Count = 18,
				Color = ColorSequence.new(Color3.fromRGB(255, 205, 140), Color3.fromRGB(230, 100, 60)),
				Speed = NumberRange.new(9, 20),
				LifetimeSeconds = NumberRange.new(0.2, 0.45),
				Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.32), NumberSequenceKeypoint.new(1, 0) }),
				Drag = 4,
				Acceleration = Vector3.new(0, -45, 0),
				LightEmission = 0.75,
			},
			GuardBroken = {
				Count = 36,
				Color = ColorSequence.new(Color3.fromRGB(255, 190, 120), Color3.fromRGB(230, 90, 60)),
				Speed = NumberRange.new(8, 20),
				LifetimeSeconds = NumberRange.new(0.35, 0.7),
				Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.5), NumberSequenceKeypoint.new(1, 0) }),
				Drag = 3,
				Acceleration = Vector3.new(0, -55, 0),
				LightEmission = 0.6,
			},
			-- A projectile ending on world geometry (Client/FX/ProjectileFX.lua) -- not an exchange, so
			-- small and cool: the Qi of the shot scattering off stone. A shot that hits a BODY gets its
			-- outcome's own preset through Combat_Feedback, like any other contact.
			ProjectileWorld = {
				Count = 10,
				Color = ColorSequence.new(Color3.fromRGB(215, 200, 255), Color3.fromRGB(140, 110, 230)),
				Speed = NumberRange.new(6, 14),
				LifetimeSeconds = NumberRange.new(0.12, 0.28),
				Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.3), NumberSequenceKeypoint.new(1, 0) }),
				Drag = 6,
				Acceleration = Vector3.new(0, -10, 0),
				LightEmission = 1,
			},
		},
		-- The camera punch a preset carries, if any -- a fast FOV tighten-and-release through FOVOffset (so
		-- the settings.Comfort.FieldOfViewEffects toggle covers it), on both participants' clients. Keyed
		-- by preset, not outcome, so the perfect parry's harder punch is data rather than a branch.
		Punches = {
			Parried = { FOVDelta = -4, OutSeconds = 0.04, BackSeconds = 0.2 },
			ParriedPerfect = { FOVDelta = -8, OutSeconds = 0.035, BackSeconds = 0.32 },
		} :: { [string]: { FOVDelta: number, OutSeconds: number, BackSeconds: number } },
	},

	-- Per-move presentation (Shared/Combat/MovePresentationTypes.lua, Client/FX/MovePresentation.lua): the
	-- budget every move-authored cue plays inside, on ONE client. A cue past a cap is dropped, never
	-- allocated -- the same rule every pool above keeps.
	--
	-- Per-client ceiling, all of it pooled and none of it growing with the number of moves:
	--   * templates     MaxActiveTemplates live clones at once, at most TemplatePoolPerName of any one
	--                   template (FXPool per name, carriers reused)
	--   * one-shots     MoveSoundPoolSize 2D + MoveSoundPoolSize positional Sounds per DISTINCT authored
	--                   sound id (SoundManager, round-robin -- no instance per play)
	--   * shot loops    MaxLoopingShots looping Sounds, one per volley at most, each living on a pooled
	--                   ProjectileFX carrier and stopped when the carrier is released
	--   * sparks        the existing ImpactSparks pool (ImpactSparks.PoolMaxSize); overrides recolour a
	--                   pooled burst, they never add one
	MovePresentation = {
		-- ReplicatedStorage.<TemplateFolder> holds authored effect templates (an Attachment, ParticleEmitter,
		-- Beam, Part or Model), placed in Studio beside Workspace.Weapons. A cue names one by Name.
		TemplateFolder = "MoveFX",
		TemplatePoolPerName = 4,
		MaxActiveTemplates = 16,
		-- A template's ParticleEmitters are fired with :Emit(EmitCount attribute, else this).
		TemplateDefaultEmitCount = 16,
		-- A template is released after its LifetimeSeconds attribute, else its longest emitter lifetime,
		-- never longer than this.
		TemplateMaxLifetimeSeconds = 3,
		MoveSoundPoolSize = 3,
		-- The volume a move-authored sound plays at before the cue's Volume scale -- the authored layer has
		-- no SoundDefinition of its own to carry one.
		MoveSoundBaseVolume = 0.6,
		MaxLoopingShots = 6,
		-- Looping cue sounds playing at once on one client (a cue's Loop = "RestOfMove": a swing's or a realm's
		-- sound repeating until the move ends). Past it a loop does not start. One real Sound each, so bounded.
		MaxLoopingCues = 8,
	},

	-- Shots in flight (Client/FX/ProjectileFX.lua). The DEFAULT look -- a move's own In flight cue
	-- (MovePresentationTypes) overrides any of it per move, field by field. The drawn core IS the hit volume
	-- (its diameter is twice the move's Size), so what a player dodges is what the server tests; a move's
	-- SizeScale scales the glow and the trail around it, never the core.
	Projectile = {
		-- Shots drawn at once on one client; past it a launch is not drawn (the server still flies it).
		PoolMaxSize = 128,
		CoreColor = Color3.fromRGB(205, 185, 255),
		CoreTransparency = 0.15,
		-- The glow shell around the core, as a multiple of its size.
		GlowScale = 1.8,
		GlowTransparency = 0.7,
		-- Shots drawn WITH their glow at once. The glow is a second, larger ForceField ball per shot -- the
		-- dearer half of drawing one -- so a flood (a realm's strikes, a wide volley) past this draws the
		-- rest as bare cores. The core is the hit volume and is always drawn.
		MaxGlowingShots = 24,
		TrailColor = ColorSequence.new(Color3.fromRGB(215, 200, 255), Color3.fromRGB(120, 90, 220)),
		TrailLifetimeSeconds = 0.18,
		TrailTransparency = NumberSequence.new(0.35, 1),
		-- A shot whose End never arrives (a dropped batch) is cleaned up this long past its lifetime.
		OrphanGraceSeconds = 1,
		-- How fast a drawn shot eases onto a corrected position from the server, rather than snapping.
		CorrectionSeconds = 0.08,
	},

	-- Realms (Client/FX/DomainFX.lua). The DEFAULT look -- a domain move's own Realm established cue
	-- (MovePresentationTypes, CoreColor/GlowColor) overrides the two colours per move. The drawn shell IS
	-- the gameplay boundary (DomainGeometry), so the edge a player sees is the edge the server enforces.
	Domain = {
		-- The realm's tint: the colour grade laid over the screen of anyone under its law.
		CoreColor = Color3.fromRGB(70, 40, 120),
		-- The shell's colour -- the ForceField rim glow that draws the edge.
		GlowColor = Color3.fromRGB(190, 150, 255),
		-- THE SHELL'S THREE LOOKS, picked by how much of the screen it covers -- never by which side of the
		-- edge the camera is on (see Client/FX/DomainFX.lua's header, FRAME COST):
		--   Far     small on screen: the animated ForceField (ShellMaterial), whose rim draws the edge.
		--   Near    the camera is outside, but the realm fills much of the view (a big realm from close by,
		--           or a third-person camera poking out behind a body standing inside near its edge): a
		--           plain, nearly clear surface -- one cheap blended layer, never a screen-sized shader pass.
		--   Inside  hidden (a fully transparent part is culled) except within EdgeRevealStuds of the edge.
		ShellMaterial = Enum.Material.ForceField,
		ShellPlainMaterial = Enum.Material.SmoothPlastic,
		ShellTransparency = 0.82,
		ShellNearTransparency = 0.88,
		ShellInsideTransparency = 0.9,
		-- Far -> Near once the realm's bounding sphere spans this fraction of the camera's half vertical field
		-- of view (DomainGeometry.AngularRadius), and back to Far only below ShellFillExit -- the gap keeps a
		-- camera hovering at the threshold from swapping materials every frame. 0.6 of the half-FOV is a disc
		-- about a fifth of a 16:9 screen; past that the ForceField's per-pixel cost stops being small.
		ShellFillEnter = 0.6,
		ShellFillExit = 0.5,
		-- From inside, the shell is hidden (culled) unless the camera is within this many studs of the edge,
		-- where it fades in -- so it only ever covers the screen when a player is about to meet it.
		EdgeRevealStuds = 8,
		-- THE VICTIM'S VIEW (Client/FX/DomainFX.lua's header): to a body the realm governs that is not its
		-- owner, the barrier is a solid wall of this colour. Neon, because Neon is unlit -- a lit black
		-- surface still catches specular and ambient and reads charcoal, where an emissive black is black.
		VictimInteriorColor = Color3.new(0, 0, 0),
		VictimInteriorMaterial = Enum.Material.Neon,
		-- A pulse's point cues: at most this many bodies per pulse, and only those this near the camera.
		MaxPulseBursts = 6,
		PulseRangeStuds = 200,
		-- The colour grade for a body inside: how far toward the tint, and how much colour is drained.
		InsideTintBlend = 0.35,
		InsideSaturation = -0.35,
		InsideContrast = 0.12,
		-- How the grade eases in and out as the local player crosses the edge or the realm folds.
		GradeFadeSeconds = 0.4,
		-- The shell's unfurl ease: it grows from nothing to full over the realm's activation, with this ease
		-- out; it folds back over the ending the same way.
		UnfurlEasingStyle = Enum.EasingStyle.Quint,
		-- A barred edge's owning-client prediction: the local body is held this far from the line.
		PredictedMarginStuds = 1,
		-- Realm effect pulses drawn at the bodies they touched when the move authors no DomainPulse sparks.
		PulseSparks = "ProjectileWorld",
	},

	-- The strained guard (Client/FX/GuardStrainPose.lua) -- a procedural brace-and-tremble layered over
	-- whatever block pose is playing, on every client, for every body whose guard is cracking
	-- (DefenseConstants.GuardCrack). Written to Motor6D.Transform after the animation step, so it rides
	-- on top of the authored clip rather than replacing it -- the arms still hold the weapon's own guard,
	-- they just shake under it. Angles in DEGREES (converted once at require), R6 joint names.
	GuardStrain = {
		-- The sag: the torso leans back off the incoming weight, the head dips behind the guard, and
		-- both arms are driven down a touch, as if the guard is being pushed into the body.
		TorsoLeanDegrees = 7,
		HeadDipDegrees = 9,
		ArmPressDegrees = 8,
		-- The tremble: a small, fast, per-joint decorrelated noise. Fast enough to read as muscle
		-- failing, not as a sway; small enough never to move the guard off the body.
		TrembleDegrees = 2.2,
		TrembleFrequency = 13,
		-- How fast the whole layer fades in when the tag appears and out when it clears, so the pose
		-- does not snap the moment the guard crosses the line.
		BlendInSeconds = 0.18,
		BlendOutSeconds = 0.25,
		-- Only while the guard is actually up -- a cracking guard that has been lowered is just a
		-- low number on a HUD, and a strained pose on a body not blocking would be a lie.
		GuardStates = { Raising = true, ParryWindow = true, Blocking = true } :: { [string]: boolean },
		-- Bodies further than this from the camera are not posed at all: a tremble of two degrees is
		-- invisible at range, and every posed body is per-frame Transform writes.
		MaxDistanceStuds = 150,
	},

	-- The hit flinch (Client/FX/HitFlinchPose.lua): the recoil every body plays, on every client, when a hit
	-- stuns it. Angles in DEGREES, R6 joints, composed on top of whatever the body's clips are doing.
	HitFlinch = {
		-- The recoil: torso rocked back off the blow and twisted (alternating side per hit), head snapped
		-- back, both arms thrown behind the body. Big enough to read at fighting distance, small enough
		-- that a string of hits reads as one body being driven back, not as a ragdoll.
		TorsoLeanDegrees = 12,
		TorsoTwistDegrees = 6,
		HeadSnapDegrees = 14,
		ArmThrowDegrees = 14,
		-- Near-instant onset (the hit IS the rise) and an eased settle, well inside the shortest stun (0.40s
		-- on a Fists jab) so the body is upright again by the time it can act.
		RiseSeconds = 0.04,
		SettleSeconds = 0.28,
		MaxDistanceStuds = 150,
	},

	-- Environmental reactions (Client/FX/EnvironmentFX.lua) -- dust and chipped debris where a swing
	-- scuffs a wall or a body is slammed into one (EnvironmentReactionSystem's Combat_EnvironmentFX, plus
	-- the attacker's own locally-predicted swing scuff). Colored by the surface that was hit.
	EnvironmentImpact = {
		-- A burst's dust carrier lives for its dust's longest lifetime; chips are loose Parts.
		DustPoolMaxSize = 10,
		ChipPoolMaxSize = 40,
		CarrierPartSize = Vector3.new(0.2, 0.2, 0.2),
		-- Reuses MovementDust's authored puff sprite (the default emitter texture is a sparkle, which is
		-- exactly wrong for dust -- see MovementDust.Texture's own header).
		DustTexture = "rbxassetid://122434532",
		-- Per kind of event. A swing scuff is a glancing strike (small); a wall splat is a whole body
		-- hitting stone (large). Chips are real flying Parts in the surface's own color and material --
		-- a sprite could not borrow the surface's look.
		Presets = {
			SwingScuff = {
				DustCount = 10,
				DustSpeed = NumberRange.new(3, 7),
				DustSize = NumberSequence.new({
					NumberSequenceKeypoint.new(0, 0.4),
					NumberSequenceKeypoint.new(0.4, 1.1),
					NumberSequenceKeypoint.new(1, 1.4),
				}),
				DustLifetimeSeconds = NumberRange.new(0.35, 0.7),
				ChipCount = 4,
				ChipSize = NumberRange.new(0.15, 0.32),
				ChipSpeed = NumberRange.new(10, 18),
				ChipLifetimeSeconds = 0.5,
			},
			WallSplat = {
				DustCount = 26,
				DustSpeed = NumberRange.new(4, 11),
				DustSize = NumberSequence.new({
					NumberSequenceKeypoint.new(0, 0.9),
					NumberSequenceKeypoint.new(0.4, 2.2),
					NumberSequenceKeypoint.new(1, 2.8),
				}),
				DustLifetimeSeconds = NumberRange.new(0.5, 1.0),
				ChipCount = 10,
				ChipSize = NumberRange.new(0.2, 0.5),
				ChipSpeed = NumberRange.new(12, 24),
				ChipLifetimeSeconds = 0.7,
			},
		},
		-- Fraction of a chip's launch that is along the surface normal rather than scattered across it:
		-- chips come OFF the wall, not along it.
		ChipNormalBias = 0.65,
		ChipUpwardSpeed = 6,
		DustTransparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.35),
			NumberSequenceKeypoint.new(1, 1),
		}),
		-- A surface that has no material color entry (MovementDust.ColorByFloorMaterial) and is not a
		-- BasePart with its own Color falls back to this.
		DefaultColor = Color3.fromRGB(150, 140, 130),
	},

	-- The roll's afterimage (Client/FX/RollAfterimage.lua) -- translucent copies of the rolling rig left
	-- behind across the server's evade window, so "the evade frames are live right now" is something
	-- every player can SEE rather than something the roller has to trust. Played on the roller's own
	-- client at the predicted transition and on everyone else's off the replicated ParkourState
	-- Attribute (Client/FX/RemoteMovementFX.lua).
	RollAfterimage = {
		-- Ghost SETS, not parts: one set is one limb-for-limb copy of an R6 rig (six parts). Sized for
		-- a few rollers on screen at once with every stamp of every roll alive -- 3 stamps x 4 rolls --
		-- and never more; a roll past the cap simply leaves fewer ghosts.
		PoolMaxSize = 12,
		-- Stamps per roll, the first at StartDelaySeconds and the rest every IntervalSeconds after.
		-- StartDelay matches DefenseConstants.Evade's startup (now 0 -- the evade is live on the press) and
		-- the three stamps span the front of the evade glide (EvadeConstants.DurationSeconds, 0.24s -- most
		-- of its distance is covered in the first 0.15s) inside the evade's 0.30s window, so the trail of
		-- ghosts IS the dodge, drawn.
		StampCount = 3,
		StartDelaySeconds = 0,
		IntervalSeconds = 0.07,
		-- How long one ghost takes to fade from StartTransparency to gone.
		FadeSeconds = 0.3,
		StartTransparency = 0.55,
		-- Pale steel-blue, the same family as HitFlash.ParryWindowColor: an evade is a defensive
		-- read, and steel is the colour this codebase already uses for "defence is live".
		Color = Color3.fromRGB(150, 200, 255),
		-- THE EVADED FLASH -- one brighter ghost on the dodger's rig when the server confirms a swing
		-- went through them (Combat_Feedback Evaded). Brighter and a touch longer than a roll stamp, so
		-- a successful dodge reads as its own event rather than as one more stamp.
		EvadeFlashColor = Color3.fromRGB(210, 235, 255),
		EvadeFlashStartTransparency = 0.25,
		EvadeFlashFadeSeconds = 0.4,
		-- Another player's roll is drawn only within this distance of the local camera
		-- (Client/FX/RemoteMovementFX.lua). Past it the ghosts are a few pixels tall and the pool is
		-- better spent on the fight in front of you.
		RemoteMaxDistanceStuds = 160,
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
