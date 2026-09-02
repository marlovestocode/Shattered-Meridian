--!strict
--[[
	Components/Fade.lua

	Owns: the decorative fade-in every transient surface in this UI wears -- a visibility boolean
	sprung toward 1, and the transparency that is its inverse.

	THE SPLIT THIS ENCODES IS THE POINT, and all three components that hand-wrote it wrote the same
	comment explaining it: PRESENCE IS INSTANT, APPEARANCE EASES. Whether a surface is in the tree at
	all stays an unsmoothed boolean gate (Visible / a nil Display), because a panel that lingers
	half-faded is still catching input and still occluding what is behind it. Only the CONTENT's
	transparency is decorative, and only that is sprung. Getting this backwards -- springing the
	visibility itself -- is the mistake this module exists to make hard.

	Tokens.Motion.FadeSpring already held the two numbers. What was still duplicated was the
	construction on top of them: DeathOverlay, PostureBreakBanner and HoverLabel each aliased both
	tokens into a pair of file-locals and then built the identical eleven-line spring-and-invert. The
	numbers being shared did not stop the arithmetic being written three times.

	Does not own: whether a surface is visible (the caller's own Display/Visible prop), what the
	transparency is applied TO (each component decides which of its parts fade), or any composition
	with a resting translucency -- HoverLabel's border alpha-multiplies Alpha with
	Tokens.Border.Standard's own transparency, which is that component's own concern and stays there.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)

local Tokens = require(script.Parent.Parent.Tokens)

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>

local Fade = {}

export type FadeState = {
	-- 0 while hidden, springing toward 1 the moment the surface becomes visible. Read this when
	-- composing with another alpha; read Transparency when writing a *Transparency property.
	Alpha: Fusion.Computed<number>,
	-- 1 - Alpha, which is what every Roblox transparency property actually wants.
	Transparency: Fusion.Computed<number>,
}

-- Builds the pair. A component calls this once, in place of the spring and the inverting Computed it
-- used to declare for itself.
function Fade.New(scope: Scope, visible: UsedAs<boolean>): FadeState
	local alpha = scope:Spring(
		scope:Computed(function(use): number
			return if use(visible) then 1 else 0
		end),
		Tokens.Motion.FadeSpring.Speed,
		Tokens.Motion.FadeSpring.Damping
	)

	return {
		Alpha = alpha,
		Transparency = scope:Computed(function(use): number
			return 1 - use(alpha)
		end),
	}
end

return Fade
