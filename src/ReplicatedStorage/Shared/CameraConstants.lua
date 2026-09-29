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

-- Custom shift-lock camera tunables (Client/Camera/ShiftLockCamera.lua) -- combat-philosophy.md's
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
		-- When a swing's tracking (Client/Combat/SwingTracking.lua) or a parkour traversal hands the body's
		-- rotation back, the body used to snap to the camera's yaw in one frame -- on every swing of a
		-- string, since tracking turns the body toward the target and then lets go. For this long after a
		-- hand-back the body instead eases to the camera's yaw at FacingReturnRate (an exponential rate,
		-- per second: 20 is ~95% of the way in 0.15s), then tracks it exactly as before.
		FacingReturnSeconds = 0.25,
		FacingReturnRate = 20,
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
		FOVDelta = -3,
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
		HorizontalFrequency = 14,
		VerticalFrequency = 16,
		-- Critical: settles as fast as possible without swinging past the body.
		Damping = 1,
		MaxHorizontalLagStuds = 1.1,
		MaxVerticalLagStuds = 0.8,
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
}

return CameraConstants
