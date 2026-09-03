--!strict
--[[
	IntroConstants.lua

	Owns: the cinematic awakening sequence's staging -- camera pan, vision effects, black-screen
	timing, the get-up beat and the greeting, for Client/Intro/IntroClient.lua + IntroCamera.lua +
	VisionEffects.lua + BlackScreen.lua.

	A DISTINCT SURFACE FROM CHARACTER CREATION despite sharing one player flow, for the reason its
	original header gave and this file keeps: CharacterCreationConstants owns race/attribute/name
	validation and the arrival teleport, this owns purely the camera/FX/animation staging wrapped
	around it.

	Does not own: the onboarding rules the cinematic brackets (Shared/CharacterCreationConstants.lua),
	or any animation asset id's authoring -- the placeholder ids here are deliberately shared with
	Flight's own unauthored slots rather than invented, and this codebase never guesses an asset id.

	Lifted out of Constants.lua. Constants.Intro re-exports this module, so every existing
	Constants.Intro.X call site keeps working unchanged; new code should require this module
	directly.
]]

-- Cinematic intro / awakening sequence (Client/Intro/IntroClient.lua + IntroCamera.lua +
-- VisionEffects.lua + BlackScreen.lua). A DISTINCT table from Constants.CharacterCreation despite
-- sharing one player flow -- CharacterCreation owns race/attribute/name validation and the
-- Threshold<->arrival teleport, this table owns purely the CAMERA/FX/animation staging wrapped
-- around it (ground pose -> cinematic pan -> [character creation] -> black screen -> teleport ->
-- first-person reveal -> get-up -> greeting), the same "distinct tuning surface, distinct table"
-- split Constants.BugReport/Constants.CharacterCreation's own headers already establish for each
-- other.
local IntroConstants = {
	-- Placeholder ids -- no lying-down/get-up clips have been authored yet (explicitly deferred by
	-- the user this pass). Reuses the SAME already-user-supplied placeholder Constants.Flight.
	-- AnimationIds shares across its own six unauthored slots, rather than fabricating a new id --
	-- this codebase never guesses an asset id (see CombatAudio.lua/VitalIcon.lua's headers). Swap
	-- either line to a real id later with no code change.
	AnimationIds = {
		LyingDown = "rbxassetid://125167812303491",
		GetUp = "rbxassetid://125167812303491",
	} :: { [string]: string },

	-- Camera staging (IntroCamera.lua). Every angle is in DEGREES (converted to radians at the one
	-- call site that needs it) -- easier to eyeball/retune than raw radians, matching this table's
	-- role as the thing a later in-Studio pass will actually adjust by feel.
	Camera = {
		-- Ground-level lying POV the cinematic opens on (and the first-person anchor after teleport
		-- returns to) -- a shallow height above the character's own root position (roughly chest/eye
		-- height while prone) looking steeply up, the same "point the camera at the sky" framing the
		-- pre-rework OnboardingClient.pointCameraAtSky established (now owned here instead).
		GroundHeightOffset = 1.5,
		GroundLookAngleDegrees = -78,
		-- The held overhead composition the cinematic pans up INTO, timed against the cinematic's
		-- own elapsed/duration fraction (Constants.CharacterCreation.CinematicDurationSeconds) --
		-- see IntroCamera.UpdateCinematicProgress. Held through character creation once reached.
		OverheadHeightOffset = 22,
		OverheadLookAngleDegrees = 80,
		-- Slow ambient yaw drift, held for the WHOLE cinematic + overhead-hold window -- same
		-- "a static shot reads as frozen/broken, not deliberate" reasoning pointCameraAtSky's own
		-- comment gave for its identical drift.
		OverheadYawDriftDegreesPerSecond = 2,
		-- Symmetric ease-in-out exponent for the ground->overhead position/pitch lerp (2 = a
		-- standard smoothstep-shaped ease, not linear).
		PanEasingPower = 2,
		-- First-person eye anchor height above the character's root once teleported into the arrival
		-- world, still lying down -- deliberately close to GroundHeightOffset (same lying pose) but
		-- its own number since the two moments aren't guaranteed to want an identical height once a
		-- real LyingDown clip exists.
		FirstPersonEyeHeightOffset = 1,
		-- Get-up camera follow: eases from the first-person lying anchor (still looking up) to a
		-- level, standing eye-height view over this many seconds -- tuned against the placeholder
		-- clip's own arbitrary length for now; retune once GetUp is a real authored animation with a
		-- real length to match.
		GetUpFollowDurationSeconds = 1.8,
		GetUpFollowStandingHeightOffset = 5,
	},

	-- First-person blur/blink reveal (VisionEffects.lua) -- a Lighting.ColorCorrectionEffect +
	-- BlurEffect pair, same asset-free approach and DipBrightness/DipSaturation/*Seconds shape as
	-- Constants.FX.Stun/Death, extended into a multi-stage sequence: an instant blackout snap (timed
	-- under BlackScreen's own opaque UI cover, so the snap itself is never seen), two partial
	-- "eyes cracking open" reveals each followed by a quick re-dip ("blink") back toward the
	-- blackout values, then one final ease to fully neutral.
	Vision = {
		BlackoutBrightness = -0.75,
		BlackoutSaturation = -0.9,
		BlackoutBlurSize = 48,
		-- How long the blackout holds (BlackScreen still opaque) before the reveal begins.
		BlackHoldSeconds = 1,

		Reveal1Brightness = -0.35,
		Reveal1Saturation = -0.5,
		Reveal1BlurSize = 18,
		Reveal1DurationSeconds = 0.9,
		Blink1DurationSeconds = 0.16,

		Reveal2Brightness = -0.12,
		Reveal2Saturation = -0.2,
		Reveal2BlurSize = 5,
		Reveal2DurationSeconds = 0.8,
		Blink2DurationSeconds = 0.16,

		FinalClearDurationSeconds = 0.6,
	},

	-- Greeting banner (reuses UI/Components/PostureBreakBanner.lua's generic StatusBanner directly --
	-- no new banner component). How long it holds before IntroClient.lua clears it.
	Greeting = {
		HoldSeconds = 3.5,
	},
}

return IntroConstants
