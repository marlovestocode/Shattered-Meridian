--!strict
--[[
	CameraConstants.lua

	Owns: the camera's own feel -- FOV pulls, shift-lock offsets, sprint/slide framing and the
	comfort-scaled shake amplitudes the accessibility toggles attenuate.

	PRESENTATION ONLY, the same load-bearing line FXConstants draws: nothing here may decide an
	outcome. These run on the client, where a player can change them, so a value that reached a
	gameplay decision would be one a client could edit in its own favour.

	Does not own: the comfort PREFERENCES that scale these (Types.ComfortSettings, carried by the
	settings remotes in SettingsConstants.lua), the parkour camera's own behaviour
	(ParkourConstants), or the aboard-a-blimp camera (BlimpCameraMath, which is a physics read rather
	than a tuning table).

	Lifted out of Constants.lua. Constants.Camera re-exports this module, so every existing
	Constants.Camera.X call site keeps working unchanged; new code should require this module
	directly.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ParkourConstants = require(ReplicatedStorage.Shared.Parkour.ParkourConstants)

-- Custom shift-lock camera tunables (Client/Camera/CombatCamera.lua) -- combat-philosophy.md's
-- "Established systems" list names combat camera behavior as bespoke, not default Roblox behavior.
-- Client-only data living in Constants.lua for the same reason Keybinds above does: static tunable
-- defaults every client module should agree on, never authoritative state, never crosses
-- NetworkBridge.
local CameraConstants = {
	ShiftLock = {
		-- Over-the-right-shoulder framing while shift-locked (applied via Humanoid.CameraOffset,
		-- so default-camera zoom/collision keep working). X is the sideways shoulder distance
		-- (positive = right, matching the engine's own 1.75); the small Y lift keeps the
		-- character's head from sitting dead-center in front of the aim point.
		ShoulderOffset = Vector3.new(1.75, 0.5, 0),
		-- Exponential ease rate for CameraOffset toward/away from ShoulderOffset -- higher =
		-- snappier engage/release. Applied framerate-independently (alpha = 1 - e^(-rate * dt)).
		OffsetLerpSpeed = 10,
		-- Camera-to-root-part distance below which the shoulder offset backs off to zero -- at
		-- near-first-person zoom an off-center offset just shoves the camera into the character's
		-- own head/shoulder geometry. First person itself already locks the mouse and steers the
		-- character natively, so shift lock has nothing to add there.
		FirstPersonDistanceThreshold = 2,
		-- LOCKED, BUT LOOSE. The body turns to face where the camera looks on a critically damped spring
		-- rather than being snapped onto it every frame, so the character swings round a beat behind the
		-- view. Natural frequency in rad/s: at 20 a flick is ~63% turned in 0.11s and settled by ~0.25s --
		-- loose enough to read, tight enough that a swing still goes where you are looking. Higher is
		-- tighter; 0 restores the old rigid snap. Damping 1 is critical: it arrives without swinging past.
		-- Also what brings the body round when swing tracking or a traversal hands it back.
		BodyTurnFrequency = 20,
		BodyTurnDamping = 1,
	},

	-- Flight camera feel (Client/Camera/FlightCamera.lua) -- FOV scaling and CameraOffset chase
	-- pull-back with flight speed, plus an optional bank-matched roll. Lives beside ShiftLock above
	-- since both are camera-domain presentation tunables, not gameplay.
	Flight = {
		-- Max FOV increase (degrees) at full boosted speed, eased from whatever the camera's own FOV
		-- was when flight started (never assumes a hardcoded base FOV).
		FOVMaxDeltaAtBoost = 12,
		FOVEaseSpeed = 6,
		-- Extra backward CameraOffset (studs) at max speed -- a chase pull-back so fast flight reads
		-- as fast without needing to touch actual Camera.CFrame math.
		ChasePullBackMaxStuds = 4,
		ChaseEaseSpeed = 8,
		-- Fraction of the character's OWN bank angle (Constants.Flight.MaxBankAngleDegrees) mirrored
		-- onto camera roll -- 0 disables it outright without touching call sites.
		BankRollFraction = 0.4,
	},

	-- Sprint/Slide FOV feel (Client/FX/FOVOffset.lua, driven from CombatClient.lua's Sprint
	-- input/predictSlide) -- both write through FOVOffset's named-slot composition rather than
	-- camera.FieldOfView directly, the same primitive SwingEffect's combat punch and Flight's zoom
	-- now also go through, so none of the three fight each other for the property.
	Sprint = {
		-- Continuous zoom-in while sprinting, eased in/out (FOVOffset.SetContinuous). Negative =
		-- narrower FOV (a focused "picking up speed" read) -- deliberately the opposite sign from
		-- Flight.FOVMaxDeltaAtBoost's widening convention, since flight and sprint are different
		-- feelings (soaring vs. sprinting).
		-- -2 since 2026-10-27 (was -3): the sprint narrowing still reads, without pinching the view in a fight.
		FOVDelta = -2,
		FOVEaseSpeed = 6,
	},
	Slide = {
		-- One-shot FOV kick at slide-start (FOVOffset.Punch), same punch-and-recover shape as
		-- SwingEffect's combat punch.
		FOVPunchDelta = -4,
		FOVPunchOutSeconds = 0.08,
		FOVPunchBackSeconds = 0.3,
	},

	-- Combat swing camera "punch" (Client/FX/SwingEffect.lua) -- a tiny asset-free FOV dip-and-recover
	-- that plays the instant the local player's OWN attack is confirmed accepted (Combat_AttackStarted),
	-- well before any hit-resolution feedback (damage number/sound, or nothing at all on a whiff) could
	-- possibly arrive. Routed through FOVOffset.lua's named "SwingPunch" slot (see that module's header)
	-- rather than tweening camera.FieldOfView directly, the same composition primitive Sprint/Slide
	-- above and Flight's own zoom now share so none of the three fight each other for the property. Were
	-- four module-local constants in SwingEffect.lua (BASIC_FOV_DELTA/HEAVY_FOV_DELTA/PUNCH_OUT_SECONDS/
	-- PUNCH_BACK_SECONDS) -- moved here as a sibling to Sprint/Slide since all three are camera-domain
	-- FOV presentation tunables living under Constants.Camera, not gameplay. Heavy gets a slightly
	-- larger punch than Basic so a Heavy throw reads as weightier through this one asset-free cue, tuned
	-- soft enough not to be disorienting on its own per docs/ui-ux-philosophy.md's Critical States rule
	-- ("controlled... not excessive"). Both legs use InOut easing (ramps up AND down smoothly, no
	-- instant-velocity snap at the start of either tween) rather than Out/In, which is what made the
	-- original punch read as a jolt rather than a dip.
	SwingPunch = {
		BasicFOVDelta = -0.6,
		HeavyFOVDelta = -1.2,
		PunchOutSeconds = 0.09,
		PunchBackSeconds = 0.22,
	},

	-- The smoothed follow (Client/Camera/CameraFollow.lua, arithmetic in Shared/CameraFollowMath.lua): the
	-- camera's focus trails the body on a critically damped spring instead of being welded to it, so a
	-- lunge, a step-in, a landing or a traversal pop moves the view with weight rather than in one frame.
	-- Small on purpose -- the trail is capped at about a stud, which is enough to take the jerk out of a
	-- 2-4 stud punch step without the camera ever visibly lagging a running body.
	Follow = {
		Enabled = true,
		-- Natural frequency (rad/s). At 14 the camera reaches the body ~0.25s after it stops. Vertical is
		-- a touch stiffer so a jump's rise and fall do not read as floaty.
		-- Tuned 2026-10-27 (was 14 / 16, lag 1.1 / 0.8): a tighter, shorter trail -- the jerk of a step-in is still
		-- taken out, but the view no longer visibly lags a body darting about in a fight.
		HorizontalFrequency = 16,
		VerticalFrequency = 18,
		-- Critical: settles as fast as possible without swinging past the body.
		Damping = 1,
		MaxHorizontalLagStuds = 0.8,
		MaxVerticalLagStuds = 0.6,
		-- One-frame jumps bigger than this are teleports/respawns: re-seat instead of animating.
		TeleportStuds = 8,
		-- Below this camera-to-focus distance the camera is effectively first person, where an offset
		-- focus would push the view out of the head. The follow stands down there, like the shoulder
		-- offset does (ShiftLock.FirstPersonDistanceThreshold).
		FirstPersonDistanceThreshold = 2,
		-- How fast the trail is released when the follow stands down (flight, a vessel, first person),
		-- so handing off never snaps the view by the last trail's worth.
		ReleaseEaseSpeed = 12,
	},

	-- The movement-responsive camera (Client/Camera/CameraMotion.lua, arithmetic in Shared/CameraMotionMath.lua): a lean
	-- into lateral acceleration, a pull-back and a FOV that grow with speed, and a compression on landing, all derived from
	-- the body's measured velocity. The smoothed Follow above is its sibling and covers the acceleration LAG of the view;
	-- this covers everything else. It took over the speed FOV, the landing dip and the wall-run tilt's roll from
	-- Client/Parkour/ParkourCamera, which are no longer there.
	--
	-- RESTRAINT IS THE REQUIREMENT (docs/ui-ux-philosophy.md, Critical States): the lean tops out at 3.5 degrees -- the
	-- wall-run tilt it shares a roll channel with is 9 -- because rotating the horizon under a player is what makes a camera
	-- sickening, and a fight needs a steady horizon more than a lively one. Each channel is bounded, damped and returns to
	-- neutral on its own.
	Motion = {
		Enabled = true,
		-- Per-channel multipliers, the reduce-motion knobs: 1 is the shipped feel, 0 silences a channel. The player-facing
		-- switch is Settings -> Gameplay -> Camera effects (Parkour.CameraEffects), which turns the whole module off.
		Scale = {
			Lean = 1,
			Pull = 1,
			Fov = 1,
			Landing = 1,
		},
		Sampling = {
			-- Time constants of about 33 ms and 63 ms: enough to turn the engine's velocity steps into an acceleration
			-- that does not buzz at 60 fps, little enough that a strafe start is felt on the frame it begins.
			VelocityFilterRate = 30,
			AccelFilterRate = 16,
			MaxStepSeconds = 0.1,
		},
		Lean = {
			-- Tuned down 2026-10-27 (was 3.5 deg, full at 80, damping 0.8): in a fast fight a strafe-start rocked the
			-- horizon on every exchange. Now a hard turn reads, a sidestep barely does, and it settles without a wobble.
			MaxDegrees = 2,
			-- A strafe from a standing sprint or a full reversal is 100-250 studs/s^2; a wide turn at sprint pace is
			-- about 50. 80 puts a hard turn at nearly full lean and a gentle arc at a visible fraction of it.
			FullAccel = 110,
			Deadzone = 0.12,
			-- Below this planar speed the lean fades out: a body shuffling in place should not rock the horizon.
			MinSpeed = 10,
			-- Slightly under critical: the view arrives with a hint of weight and settles in about a fifth of a second.
			Frequency = 10,
			Damping = 0.9,
		},
		Pull = {
			-- Starts above walking pace (18) and is full at the speed the old parkour speed FOV was full at.
			-- Tuned down 2026-10-27 (was 20 -> 1.6 studs): starts above sprint-jog pace and pulls back a stud at most, so
			-- the opponent does not shrink on screen every time either of you runs.
			StartSpeed = 24,
			FullSpeed = 46,
			MaxStuds = 1,
			EaseRate = 4,
		},
		Fov = {
			-- Widening above sprint: the same 0..7 degrees over the same band the parkour speed FOV had, so a body at
			-- sprint pace or below is framed exactly as before. StartSpeed is ParkourConstants.Locomotion.SprintSpeed,
			-- read there so the two cannot drift.
			StartSpeed = ParkourConstants.Locomotion.SprintSpeed,
			FullSpeed = 46,
			MaxDelta = 7,
			-- FOVOffset's ease rate for the whole channel (the parkour speed FOV's was 5 as well).
			EaseSpeed = 5,
			-- Free fall: widens past the speed an ordinary jump reaches (about 53) and is full at a long drop.
			FallStartSpeed = 60,
			FallFullSpeed = 140,
			FallMaxDelta = 4,
		},
		Landing = {
			-- The landing bands the parkour framework used (a 9-stud fall is soft, 22 hard), as the speed they land at:
			-- sqrt(2 * 196.2 * height) is 59 and 93, and a drop of 60 studs is 150. An ordinary jump (53) is not felt.
			MinImpactSpeed = 58,
			FullImpactSpeed = 150,
			SoftDipStuds = 0.25,
			HardDipStuds = 1.2,
			-- Underdamped: the view compresses, rebounds a little and settles in about a third of a second.
			Frequency = 13,
			Damping = 0.55,
			MaxReboundStuds = 0.3,
			CooldownSeconds = 0.2,
			-- Severity (0..1) from which the impact also shakes, and the shake it plays (scaled by severity).
			ShakeSeverity = 0.4,
			Shake = { Amplitude = 0.035, Frequency = 22, DurationSeconds = 0.28 },
		},
		-- Eases a released slot (a stand-down to flight, a vessel, first person) back to neutral at this rate.
		ReleaseEaseSpeed = 12,
		-- Camera-to-focus distance below which the camera is first person and every offset stands down.
		FirstPersonDistanceThreshold = 2,
		-- The named slots this feature owns in each composer.
		Slots = {
			Offset = "Motion",
			Fov = "MotionSpeed",
			Roll = "MotionLean",
		},
	},
}

return CameraConstants
