--!strict
--[[
	DamageNumberLabel.lua

	Owns: a single floating combat-feedback number (docs/ui-ux-philosophy.md's Damage Numbers
	section) -- distinct visual identity per Kind (Normal/Heavy/Critical/Posture) using only
	existing Tokens.lua colors, plus a one-shot rise-and-fade so it reads as "short-lived" rather
	than a static label.

	Does not own: when a damage number appears, what its value is, or how long it stays in the
	list before being removed -- that's CombatFeedback.lua's job (spawn/expiry), which itself only
	acts once a future CombatSystem-integration module calls it. This component only knows how to
	render one entry it's handed; it never fabricates a value of its own.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Tokens = require(script.Parent.Parent.Tokens)
local Label = require(script.Parent.Label)

type Scope = Fusion.Scope<typeof(Fusion)>

export type DamageKind = "Normal" | "Heavy" | "Critical" | "Posture"

export type DamageNumberLabelProps = {
	Text: string,
	Kind: DamageKind?,
	-- Where the number starts, in the parent's scale-space. Defaults to dead center so a caller
	-- without a real hit-location yet still gets a sane on-screen position.
	Position: UDim2?,
}

local RISE_OFFSET = Tokens.Motion.RiseSpring.RiseOffset
local RISE_SPRING_SPEED = Tokens.Motion.RiseSpring.Speed
local RISE_SPRING_DAMPING = Tokens.Motion.RiseSpring.Damping

-- Kind-specific scale/color communicates impact per the doc ("Heavy: larger size... Critical:
-- larger emphasis... Posture: separate visual language") without needing a different animation
-- curve per kind -- every kind rises and fades the same way, only the type styling differs.
local KIND_STYLE: { [DamageKind]: { Scale: Label.LabelScale, Color: Color3 } } = {
	Normal = { Scale = "Body", Color = Tokens.Color.TextPrimary },
	Heavy = { Scale = "Heading", Color = Tokens.Color.TextPrimary },
	Critical = { Scale = "Display", Color = Tokens.Color.Danger },
	Posture = { Scale = "Subheading", Color = Tokens.Color.Posture },
}

local function DamageNumberLabel(scope: Scope, props: DamageNumberLabelProps): TextLabel
	local style = KIND_STYLE[props.Kind or "Normal"]

	-- Springs from 0 to 1 once, driving both the rise offset and the fade curve below -- the
	-- classic Fusion "animate on mount" shape: a Value that starts at the resting state and is
	-- nudged to its target on the next tick, with the Spring easing the transition.
	local progressGoal = scope:Value(0)
	local progress = scope:Spring(progressGoal, RISE_SPRING_SPEED, RISE_SPRING_DAMPING)
	task.defer(function()
		progressGoal:set(1)
	end)

	local fadeTransparency = scope:Computed(function(use)
		local t = use(progress)
		if t < 0.15 then
			return 1 - (t / 0.15)
		end
		return math.clamp((t - 0.55) / 0.45, 0, 1)
	end)

	local position = scope:Computed(function(use)
		local base = props.Position or UDim2.fromScale(0.5, 0.5)
		return base + UDim2.fromOffset(0, -RISE_OFFSET * use(progress))
	end)

	return Label(scope, {
		Text = props.Text,
		Scale = style.Scale,
		Color = style.Color,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = position,
		Size = UDim2.fromOffset(140, 32),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextTransparency = fadeTransparency,
		StrokeColor3 = Tokens.Color.Background,
		StrokeTransparency = fadeTransparency,
		ZIndex = 10,
	}) :: TextLabel
end

return DamageNumberLabel
