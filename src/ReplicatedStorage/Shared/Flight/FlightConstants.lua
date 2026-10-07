--!strict
--[[
	FlightConstants.lua

	Owns: the admin/dev-menu "Superman flight" feature's full tuning and presentation surface --
	cruise/boost/acceleration curves, bank/pitch response, takeoff/landing/hover thresholds, and the
	wired-but-unauthored AnimationIds/Sound registrations that go with them. Extracted from
	Shared/Constants.lua (formerly Constants.Flight) for the same reason Constants.Combat was split
	out to Shared/Combat/CombatConstants.lua alongside this file: Server/DevMenu/FlightTuning.lua's
	SetField/ResetField mutate this table's fields directly, BY REFERENCE, from a live admin remote
	(DevMenu_SetFlightTuning) -- FlightTuning.lua's own header has always said "Constants.Flight is
	read BY REFERENCE every frame... mutating a field here takes effect on the very next Heartbeat."
	A module literally named "Constants" being rewritten by a running server is exactly the surprise
	docs/architecture/2026-08-audit.md section 5's "Constants facade/replication split" finding (3.4)
	called out, and Flight was the largest genuinely-tuned block left sitting inside it once Combat's
	own equivalent (CombatConstants.lua) was split out the same way.

	Standalone for the same reason AttackConstants.lua/DamageConstants.lua/DefenseConstants.lua/
	HitboxEngineConstants.lua/CombatConstants.lua all are: a system that can be added or removed
	without editing the game's central constants table is the concrete form of "this is a module."

	Does not own: whether flight is currently active (the Flying Humanoid Attribute,
	AttributeConstants.Flying) or Collide-mode's own toggle (FlyCollide) -- both cross-system
	Attribute names stay in Shared/Constants.lua's Attributes registry since other systems key off
	them by name; this file owns only the numbers that describe HOW flight moves and sounds once it
	is on.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundTypes = require(ReplicatedStorage.Shared.SoundTypes)

local FlightConstants = {
	-- Baseline cruise speed with no boost held -- same number the old bare-noclip FlightController's
	-- FLIGHT_SPEED used, so a non-boosted flight keeps its established travel-observation pace.
	CruiseSpeed = 60,
	-- Boosted top speed = CruiseSpeed * this. 1.8x reads as a genuine "kick it into high gear"
	-- without breaking Collide mode's usefulness for map-navigability testing (still controllable).
	BoostSpeedMultiplier = 1.8,
	-- Studs/s^2 ramp toward the desired velocity while NOT boosting -- reaches CruiseSpeed in 0.75s,
	-- fast enough to feel responsive, slow enough to read as momentum rather than an instant snap.
	Acceleration = 80,
	-- Studs/s^2 ramp while boosting -- snappier than base Acceleration so holding Boost reads as an
	-- active push, not just a higher ceiling.
	BoostAcceleration = 140,
	-- Studs/s^2 ramp-down when input is released/reversed -- deliberately higher than Acceleration
	-- (brakes harder than it accelerates), which is what makes flight feel steerable rather than
	-- boat-like when trying to hold position over a specific spot.
	Deceleration = 120,
	-- Vertical (Space/LeftControl) axis speed as a fraction of the CURRENT horizontal-equivalent max
	-- speed, so climbing/descending isn't as fast as forward cruise -- reads as flight, not an
	-- elevator.
	VerticalSpeedFraction = 0.7,
	-- Max roll (banking into a turn), in degrees -- Superman-style lean, not an arcade-flight-sim
	-- barrel roll.
	MaxBankAngleDegrees = 35,
	-- Max pitch (nose up/down with vertical intent or speed change), in degrees.
	MaxPitchAngleDegrees = 25,
	-- How strongly yaw turn-rate (radians/sec) maps to bank angle before MaxBankAngleDegrees clamps
	-- it -- see Shared/FlightMath.ComputeBankAngle. Higher = a gentler turn already reads as a hard
	-- lean.
	BankTurnRateSensitivity = 2.5,
	-- Ease rate (alpha = 1 - e^(-rate*dt), same idiom as Constants.Camera.ShiftLock.OffsetLerpSpeed)
	-- for the RENDERED orientation (bank/pitch/facing) chasing its target every frame -- separates
	-- "how quickly should velocity change" (Acceleration/Deceleration above) from "how quickly should
	-- the BODY visually lean into that change," which is what actually reads as inertia instead of a
	-- rigid nose always pointed exactly at the input vector.
	OrientationResponsiveness = 8,
	-- Initial upward kick (studs/s) applied the instant Flying flips true while grounded -- a real
	-- "leap into the air" launch beat rather than gently floating off the ground.
	TakeoffBurstUpSpeed = 22,
	-- Initial forward kick (studs/s), same launch beat, biased toward current facing.
	TakeoffBurstForwardSpeed = 10,
	-- Downward raycast distance (studs) used at flight-start to decide "was this character grounded"
	-- -- gates whether the takeoff burst/dust/sound play at all (skip them if flight was toggled on
	-- already mid-air).
	TakeoffGroundCheckStuds = 4,
	-- Small vertical sine-wave offset (studs) blended in only near-zero speed (see
	-- HoverSpeedThreshold) so hovering in place doesn't read as frozen in space.
	HoverBobAmplitudeStuds = 0.35,
	HoverBobPeriodSeconds = 2.2,
	-- Below this speed (studs/s) the hover bob blends fully in; above it, blends fully out -- avoids
	-- a visible seam at a hard cutoff.
	HoverSpeedThreshold = 4,
	-- Downward raycast distance (studs) used every flight frame to detect ground proximity for the
	-- IN-FLIGHT landing/graze event (Collide-mode skimming the ground) -- separate from the
	-- post-flight free-fall landing path (RecentlyFlyingGraceSeconds below), which uses the
	-- Humanoid's own native Landed state instead.
	LandingRaycastDistance = 4,
	-- Must climb back above this height (studs) after a landing event before another one can fire --
	-- debounces repeatedly re-triggering while skimming/hovering just off the ground.
	LandingRearmHeightStuds = 3,
	-- Downward speed (studs/s) below which a ground touch is ignored entirely (no soft/hard event,
	-- no FX) -- a light graze while flying low shouldn't spam a landing thump.
	LandingSpeedDeadzone = 3,
	-- Minimum seconds between landing-fire re-arms -- a live playtest showed the position-only rearm
	-- (LandingRearmHeightStuds) can fire twice within a few milliseconds (a brief touch-clear-touch
	-- flicker right at the moment of landing); this adds a time floor alongside it.
	LandingFireDebounceSeconds = 0.5,
	-- Downward speed (studs/s) below which a landing is "soft" (light thump, brief anim, no camera
	-- shake/hit-stop).
	SoftLandingSpeedThreshold = 15,
	-- Downward speed (studs/s) at/above which a landing is "hard" (full shockwave: camera shake +
	-- pooled ring VFX + brief hit-stop) -- see FXConstants.FlightLandingRing/HitStop fields.
	HardLandingSpeedThreshold = 45,
	-- Seconds after Flying flips false during which a genuine free-fall-to-ground landing (detected
	-- via the Humanoid's native Landed state, not this module's own raycast) still counts as a
	-- flight landing for shockwave purposes -- covers "flew up high, turned flight off, fell, hit the
	-- ground," the natural way an admin actually ends a flight session from altitude.
	RecentlyFlyingGraceSeconds = 3,
	-- Horizontal speed (studs/s) at/above which crossing the threshold triggers the sonic-boom
	-- one-shot -- set just under max boosted cruise (60 * 1.8 = 108) so it's reachable only while
	-- boosting, not on a plain cruise.
	SonicBoomSpeedThreshold = 95,
	-- Minimum seconds between sonic-boom triggers while sustained above threshold -- without this a
	-- boosted straight-line flight would refire it every frame.
	SonicBoomCooldownSeconds = 4,
	-- Collide toggle's default when a character has never had it explicitly set (GetAttribute
	-- returns nil) -- false = noclip, matching this feature's locked-in default (map-observation
	-- flight bypasses collision unless an admin opts into Collide).
	DefaultCollideMode = false,
	-- Collide-mode LinearVelocity.MaxForce (Client/Flight/FlightPhysics.lua's EnterCollideMode) -- how
	-- hard the velocity drive is allowed to push the flying character's rootPart toward its commanded
	-- velocity every frame. Large-but-finite rather than math.huge: too low and the character's own
	-- momentum/gravity fights the drive (reads sluggish, sinks below the commanded path); too high and
	-- wall contact reads as a violent stop instead of a controlled halt. Was a module-local constant in
	-- FlightPhysics.lua, itself flagged in that file's own comment as "a Studio-tune item" -- moved here
	-- alongside every other Flight tunable so a future live-tuning pass (Server/DevMenu/FlightTuning.lua,
	-- same fetch-once/adjust/reset shape as the hitbox timing tuner) has the option to expose it without
	-- the number living somewhere that tool can't already reach.
	VelocityDriveMaxForce = 100000,

	-- One shared placeholder clip (rbxassetid://125167812303491, user-supplied) across every slot
	-- for now -- no distinct per-state animations exist yet, so every flight pose/transition reuses
	-- the same clip until real ones are authored. Loop states (Hover/CruiseLoop/BoostLoop) vs
	-- one-shots (Takeoff/LandingSoft/LandingHard) -- see FlightAnimator.lua's own header for which
	-- is which. Swap any individual slot to its own id later with no code change, same
	-- wired-but-unauthored convention as CombatConstants.AnimationIds' Heavy1/Heavy2/etc.
	AnimationIds = {
		Takeoff = "rbxassetid://125167812303491",
		LandingSoft = "rbxassetid://125167812303491",
		LandingHard = "rbxassetid://125167812303491",
		Hover = "rbxassetid://125167812303491",
		CruiseLoop = "rbxassetid://125167812303491",
		BoostLoop = "rbxassetid://125167812303491",
	} :: { [string]: string },

	-- Sound registrations (Client/FX/FlightAudio.lua registers these with SoundManager.lua at load).
	-- Empty SoundId is the same safe placeholder SoundManager.Play already no-ops on. No PoolSize --
	-- unlike CombatConstants.Sound's hit/block/parry trio, none of these can naturally re-trigger
	-- faster than they finish playing (you can't take off or land twice in the same second), so the
	-- single-instance default is correct here, not an oversight.
	Sound = {
		Takeoff = { SoundId = "", Volume = 0.6 } :: SoundTypes.SoundDefinition,
		LandingSoft = { SoundId = "", Volume = 0.5 } :: SoundTypes.SoundDefinition,
		LandingHard = { SoundId = "", Volume = 0.85 } :: SoundTypes.SoundDefinition,
		SonicBoom = { SoundId = "", Volume = 0.9 } :: SoundTypes.SoundDefinition,
		-- Continuous wind-rush loop (SoundManager.PlayLooped/StopLooped, new capability -- see
		-- FlightAudio.lua). LoopSoundDefinition, not SoundDefinition -- a loop has no single Volume,
		-- only a ramped range: Volume/PlaybackSpeed are eased every frame between these bounds based
		-- on current speed fraction (FlightAudio.SetWindIntensity), not fixed values like every
		-- sibling above.
		WindLoop = {
			SoundId = "",
			MaxVolume = 0.5,
			MinPlaybackSpeed = 0.9,
			MaxPlaybackSpeed = 1.3,
		} :: SoundTypes.LoopSoundDefinition,
	},
}

return FlightConstants
