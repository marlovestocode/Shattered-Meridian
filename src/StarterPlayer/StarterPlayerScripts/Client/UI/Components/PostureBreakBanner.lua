--!strict
--[[
	PostureBreakBanner.lua

	Owns: StatusBanner, a generic, high-visibility status banner (docs/ui-ux-philosophy.md's Posture
	Break Feedback section originated the visual language: a single controlled fade-in rather than a
	repeating flash -- that doc's Critical States rule, "never use excessive flashing"). Originally
	built for the Posture Break case only, then generalized to a Title/Subtitle/Color-driven component
	so the Disarmed banner could reuse the exact same visual structure -- and now the ONLY thing this
	file owns, since the Posture Break case itself (the PostureBreakBanner adapter, CombatFeedback.lua
	as its one caller) was removed alongside the rest of the combat system.

	Kept at this path/name rather than renamed: Client/Intro/IntroClient.lua's own greeting banner is
	the current real caller of StatusBanner (reusing the same visual structure Posture Break/Disarmed
	used to), and renaming would only be churn for what is, underneath, still the same "high-visibility
	banner" shape -- see this file's own history for why a Rojo-path rename was already once avoided
	for the identical reason.

	Does not own: deciding when to show, for how long, or what text to display -- the caller owns all
	of that and hands this component only the already-decided display state. This component only draws
	whatever it's given.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Tokens = require(script.Parent.Parent.Tokens)
local Panel = require(script.Parent.Panel)
local Label = require(script.Parent.Label)
local Fade = require(script.Parent.Fade)

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>

export type StatusBannerDisplay = {
	Title: string,
	Subtitle: string,
	Color: Color3,
}

export type StatusBannerProps = {
	-- nil = nothing to show right now = hidden.
	Display: UsedAs<StatusBannerDisplay?>,
	-- Vertical offset from the top of the screen (Tokens.Space units) -- lets two banners stack
	-- without overlapping if more than one is ever active at once. Ignored when Tiled is true.
	YOffset: number?,
	-- TRUE = this banner is a Shell/Regions tile and MUST NOT PLACE ITSELF. A region frame's
	-- UIListLayout writes Position on every child on every layout pass, so a self-placing tile either
	-- fights the layout or silently loses -- see Components/Reveal.lua's header for the long version
	-- of the same constraint. Screens/CombatFeedback passes this; Client/Intro/IntroClient does not,
	-- because its greeting banner is on its own boot surface with no region host in existence yet.
	Tiled: boolean?,
}

local function StatusBanner(scope: Scope, props: StatusBannerProps): Frame
	local isVisible = scope:Computed(function(use)
		return use(props.Display) ~= nil
	end)

	-- Decorative fade-in -- see Components/Fade.lua. Visibility itself (whether the banner is in the
	-- tree at all) stays an instant, unsmoothed boolean gate, same as Menus.lua's IsOpen.
	local fade = Fade.New(scope, isVisible)
	local contentTransparency = fade.Transparency

	local borderColor = scope:Computed(function(use)
		local display = use(props.Display)
		return if display then display.Color else Tokens.VitalColor.Posture
	end)

	return Panel(scope, {
		Name = "StatusBanner",
		-- nil, not a default, when tiled: Fusion leaves the property alone rather than writing one the
		-- region's layout would then have to overwrite.
		AnchorPoint = if props.Tiled then nil else Vector2.new(0.5, 0),
		Position = if props.Tiled then nil else UDim2.new(0.5, 0, 0, Tokens.Space.XXL + (props.YOffset or 0)),
		Size = UDim2.fromOffset(300, 64),
		Visible = isVisible,
		Elevated = true,
		CornerAccent = true,
		BorderColor3 = borderColor,
		BorderThickness = 1.5,
		BorderTransparency = contentTransparency,

		Children = {
			-- The banner's own headline -- a section title, not an inline row label (docs/design/
			-- intro-redesign-handoff.md Phase F's Subheading sweep), so CardTitle (serif) rather
			-- than BodyLarge.
			Label(scope, {
				Text = scope:Computed(function(use)
					local display = use(props.Display)
					return if display then display.Title else ""
				end),
				Scale = "CardTitle",
				Color = borderColor,
				TextTransparency = contentTransparency,
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.35),
				TextXAlignment = Enum.TextXAlignment.Center,
			}),
			Label(scope, {
				Text = scope:Computed(function(use)
					local display = use(props.Display)
					return if display then display.Subtitle else ""
				end),
				Scale = "Detail",
				Color = Tokens.Color.TextSecondary,
				TextTransparency = contentTransparency,
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.7),
				TextXAlignment = Enum.TextXAlignment.Center,
			}),
		},
	}) :: Frame
end

return {
	StatusBanner = StatusBanner,
}
