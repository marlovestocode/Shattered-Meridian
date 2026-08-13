--!strict
--[[
	DeathOverlay.lua

	Owns: the death-to-respawn overlay card (docs/ui-ux-philosophy.md's "Death/respawn and kill
	feed" surface) -- who or what killed the local player, and a live countdown to their own
	respawn. Shown only to the player who died: Client/Combat/CombatClient.lua gates its call into
	Screens/DeathFeed's ShowDeath to the feedback payload's TargetUserId being the local player
	before this component's Display is ever set, so the killer's own screen never renders this.
	Cleared the moment the dying player's own CharacterAdded fires (respawn).

	Modeled on Components/PostureBreakBanner.lua's Title/Subtitle/Color StatusBanner shape -- same
	fade-in-only entrance (docs/ui-ux-philosophy.md's Critical States rule, "never use excessive
	flashing") -- but centered and larger, since for the next few seconds this is the single most
	important thing on screen rather than a corner status tell.

	Tone: combat-philosophy.md frames death as "a setback, not a session-ender," and
	gameplay-philosophy.md's anti-pattern against punishing engagement rules out anything that reads
	as a punishment screen -- so this card is informative (who/what killed you, how long until
	you're back) rather than accusatory. It deliberately does NOT darken or hide the ragdolled
	corpse behind it -- Server/Combat/RagdollController.lua's confirmDeath leaves that corpse limp on
	purpose (see that module's own header: "genuinely present to look at"), so this component adds no
	full-screen scrim of its own. The screen-wide desaturation dip that DOES accompany this beat is
	Client/FX/DeathEffect.lua's job, played/cleared independently by CombatClient.lua alongside this
	component's own Display, not drawn by this component.

	Does not own: deciding when to show/hide, what the countdown number currently is, or resolving a
	killer's UserId to a display name -- Screens/DeathFeed/init.lua owns the countdown timer and
	Client/Combat/CombatClient.lua resolves the killer's name before ever calling in. This component
	only renders whatever already-decided display state it's handed, the same boundary every other
	CombatFeedback-family component in this UI tree already follows.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Tokens = require(script.Parent.Parent.Tokens)
local Panel = require(script.Parent.Panel)
local Label = require(script.Parent.Label)

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>

-- KillerName nil means an environmental/non-attributed death -- CombatSystem.lua's confirmDeath
-- reports AttackerUserId as nil for a fall/void/unattributed ApplyServerDamage caller, the only
-- cause signal that exists today (see that function's own header).
export type DeathOverlayDisplay = {
	KillerName: string?,
}

export type DeathOverlayProps = {
	-- nil = not currently dead = hidden.
	Display: UsedAs<DeathOverlayDisplay?>,
	-- Whole seconds remaining until the local respawn -- Screens/DeathFeed/init.lua's own countdown
	-- (see that module's header for why it's a generation-guarded task.delay chain rather than a
	-- per-frame clock).
	SecondsRemaining: UsedAs<number>,
}

local FADE_SPRING_SPEED = Tokens.Motion.FadeSpring.Speed
local FADE_SPRING_DAMPING = Tokens.Motion.FadeSpring.Damping

local function DeathOverlay(scope: Scope, props: DeathOverlayProps): Frame
	local isVisible = scope:Computed(function(use)
		return use(props.Display) ~= nil
	end)

	-- One-shot entrance, same shape as StatusBanner's own fadeIn -- see PostureBreakBanner.lua's
	-- header for why a controlled fade rather than a flash.
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

	local subtitle = scope:Computed(function(use)
		local display = use(props.Display)
		if not display then
			return ""
		end
		if display.KillerName then
			return `Slain by {display.KillerName}`
		end
		return "Lost to the world"
	end)

	local countdownText = scope:Computed(function(use)
		return `Returning in {math.max(0, math.floor(use(props.SecondsRemaining)))}`
	end)

	return Panel(scope, {
		Name = "DeathOverlay",
		AnchorPoint = Vector2.new(0.5, 0.5),
		-- Slightly above true center, not dead-center -- leaves the lower half of the screen (where
		-- the ragdolled corpse most often settles relative to the last combat camera framing) clearer
		-- to look at, per this file's own header.
		Position = UDim2.fromScale(0.5, 0.4),
		Size = UDim2.fromOffset(360, 168),
		Visible = isVisible,
		Elevated = true,
		CornerAccent = true,
		-- Same Danger token the Disarmed status banner already uses (CombatFeedback.lua) for "a bad
		-- thing just happened to you" -- keeps this card in the same feedback-color family instead of
		-- inventing a fourth critical-state hue.
		BorderColor3 = Tokens.Color.Danger,
		BorderThickness = 1.5,
		BorderTransparency = contentTransparency,

		Children = {
			Label(scope, {
				Text = "DEFEATED",
				Scale = "Heading",
				Color = Tokens.Color.Danger,
				TextTransparency = contentTransparency,
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.26),
				TextXAlignment = Enum.TextXAlignment.Center,
			}),
			Label(scope, {
				Text = subtitle,
				Scale = "BodyLarge",
				Color = Tokens.Color.TextSecondary,
				TextTransparency = contentTransparency,
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.54),
				TextXAlignment = Enum.TextXAlignment.Center,
			}),
			Label(scope, {
				Text = countdownText,
				Scale = "Detail",
				Color = Tokens.Color.TextSecondary,
				TextTransparency = contentTransparency,
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.8),
				TextXAlignment = Enum.TextXAlignment.Center,
			}),
		},
	}) :: Frame
end

return DeathOverlay
