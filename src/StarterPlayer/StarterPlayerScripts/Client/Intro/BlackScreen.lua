--!strict
--[[
	BlackScreen.lua

	Owns: a trivial full-screen opaque Frame, faded in/out by a single Fusion.Value<boolean> --
	the transition cover between character creation and the arrival-world first-person reveal.
	Follows the same "component exposes state, caller drives it" convention as every other screen/
	component in this UI framework (UI/Components/PostureBreakBanner.lua's StatusBanner is the closest
	precedent: a Value the caller flips, a spring inside doing the actual fade) -- Client/Intro/
	IntroClient.lua is the only caller, and owns every decision about WHEN IsOpaque flips; this module
	only knows how to render whatever it currently says.

	Lives in Client/Intro/ rather than UI/Components/ -- unlike StatusBanner (reused by two different
	combat-feedback cases), this is a one-off, intro-exclusive transition cover with exactly one
	caller and no reason to generalize; UI/Components/ is for shared building blocks, not single-use
	screens (see e.g. UI/Screens/Onboarding/'s own screens, which live beside the flow that uses them
	for the identical reason).

	Mounted into the SAME Fusion scope IntroClient.lua already creates for the whole intro (not its
	own root scope) -- see that module's header for why one scope covers the Onboarding screens and
	this cover together, torn down once at the very end.

	Does not own: WHEN to fade (IntroClient.lua), or anything about the reveal underneath it
	(VisionEffects.lua owns the Lighting-level blur/blink -- this is a plain UI-layer color, not a
	world effect).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Tokens = require(script.Parent.Parent.UI.Tokens)

type Scope = Fusion.Scope<typeof(Fusion)>

local Children = Fusion.Children

export type BlackScreenHandle = {
	-- true = fully opaque. Springs rather than snaps (Tokens.Motion.FadeSpring, the same "one-shot
	-- entrance fade" preset PostureBreakBanner/StatusBanner already use) so both the fade-in (started
	-- concurrently with Confirmation.lua's own 1.2s success-beat fracture-out) and the fade-out (once
	-- VisionEffects.EnterBlackout has already snapped the world dark/blurred underneath) read as
	-- deliberate transitions, not hard cuts.
	IsOpaque: Fusion.Value<boolean>,
	Root: ScreenGui,
}

-- DisplayOrder 11: just above Screens/Onboarding/init.lua's own ScreenGui (DisplayOrder = 10, see
-- that file's header) so this covers the creator screens once opaque, and well below Screens/
-- StartMenu/init.lua's 30 / Screens/Loading/init.lua's 20 -- neither of which is still mounted by the
-- time this exists (both tear their own scopes down before Client/Intro/IntroClient.Run() starts).
local DISPLAY_ORDER = 11

local function BlackScreen(scope: Scope, playerGui: PlayerGui): BlackScreenHandle
	local isOpaque: Fusion.Value<boolean> = scope:Value(false)

	local opacity = scope:Spring(
		scope:Computed(function(use)
			return if use(isOpaque) then 1 else 0
		end),
		Tokens.Motion.FadeSpring.Speed,
		Tokens.Motion.FadeSpring.Damping
	)
	local backgroundTransparency = scope:Computed(function(use)
		return 1 - use(opacity)
	end)

	local frame = scope:New "Frame" {
		Name = "Cover",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Tokens.Color.Background,
		BackgroundTransparency = backgroundTransparency,
		BorderSizePixel = 0,
	} :: Frame

	local screenGui = scope:New "ScreenGui" {
		Name = "BlackScreen",
		ResetOnSpawn = false,
		Enabled = true,
		DisplayOrder = DISPLAY_ORDER,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Parent = playerGui,

		[Children] = frame,
	} :: ScreenGui

	return {
		IsOpaque = isOpaque,
		Root = screenGui,
	}
end

return { Mount = BlackScreen }
