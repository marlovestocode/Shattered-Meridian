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
	-- without overlapping if more than one is ever active at once.
	YOffset: number?,
}

-- One-shot entrance -- "high-impact" per the doc without becoming a repeating flash. Values live
-- in Tokens.Motion.FadeSpring now (see that table's header) -- kept as local aliases so every call
-- site below is unchanged.
local FADE_SPRING_SPEED = Tokens.Motion.FadeSpring.Speed
local FADE_SPRING_DAMPING = Tokens.Motion.FadeSpring.Damping

local function StatusBanner(scope: Scope, props: StatusBannerProps): Frame
	local isVisible = scope:Computed(function(use)
		return use(props.Display) ~= nil
	end)

	-- Decorative fade-in -- 0 while hidden, springs toward 1 the moment a display state arrives,
	-- so the banner settles in instead of snapping. Visibility itself (whether it's in the tree at
	-- all) stays an instant, unsmoothed boolean gate, same as Menus.lua's IsOpen -- only the fade
	-- of its contents is decorative.
	local fadeIn = scope:Spring(
		scope:Computed(function(use)
			return if use(isVisible) then 1 else 0
		end),
		FADE_SPRING_SPEED,
		FADE_SPRING_DAMPING
	)

	local contentTransparency = scope:Computed(function(use)
		return 1 - use(fadeIn)
	end)

	local borderColor = scope:Computed(function(use)
		local display = use(props.Display)
		return if display then display.Color else Tokens.VitalColor.Posture
	end)

	return Panel(scope, {
		Name = "StatusBanner",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, Tokens.Space.XXL + (props.YOffset or 0)),
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
