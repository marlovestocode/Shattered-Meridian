--!strict
--[[
	LockOnReticle.lua

	Owns: the minimal lock-on reticle from docs/ui-ux-philosophy.md's Lock-On UI section --
	precise, tactical corner ticks around a screen-space point plus an optional target name.
	Hidden whenever it isn't given a target to display, which is the only honest state right now:
	see CombatFeedback.lua's header for why nothing currently drives this.

	Does not own: finding a target, deciding when a lock-on is active, or projecting a world
	position to screen space -- all of that is a future client-side aim/camera module's job, built
	once CombatSystem's lock-on targeting (combat-philosophy.md's "Established systems") actually
	exists server-side. This component only draws whatever ScreenPosition it's handed, the same
	"already-computed value in, presentation out" boundary Bar.lua/VitalIcon.lua use for their
	Value/Max props.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Tokens = require(script.Parent.Parent.Tokens)
local Geometry = require(script.Parent.Parent.Geometry)
local Label = require(script.Parent.Label)

local Children = Fusion.Children

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>

export type LockOnTargetDisplay = {
	-- Scale-based (0-1 across the viewport) so the reticle stays correct across resolutions
	-- without this component needing to know the viewport size.
	ScreenPosition: UDim2,
	Name: string?,
}

export type LockOnReticleProps = {
	-- nil = no current lock-on target = hidden. See file header for why this is display state
	-- handed in, not something this component computes itself.
	Target: UsedAs<LockOnTargetDisplay?>,
}

local RETICLE_SIZE = 46
local TICK_LENGTH = 9
local TICK_THICKNESS = 2

-- Spring tuning for the reticle chasing its target -- doc: "smooth movement". Snappier than a
-- vital's fill spring since this tracks a fast-moving combat target, not an easing meter. Values
-- live in Tokens.Motion.FollowSpring now (see that table's header) -- kept as local aliases so
-- every call site below is unchanged.
local FOLLOW_SPRING_SPEED = Tokens.Motion.FollowSpring.Speed
local FOLLOW_SPRING_DAMPING = Tokens.Motion.FollowSpring.Damping

-- A short two-arm tick at one corner, pointing inward -- the same anchor-at-corner trick
-- Panel.lua's CornerBracket uses (anchoring a frame's own corner to a parent corner point extends
-- it inward automatically), without that bracket's rivet chip -- a targeting reticle stays leaner
-- than a panel frame. Geometry.CORNERS is the shared corner-point list both this and Panel.lua
-- iterate over.
local function ReticleTick(scope: Scope, corner: Vector2): { Instance }
	return {
		scope:New "Frame" {
			Name = "TickHorizontal",
			AnchorPoint = corner,
			Position = UDim2.fromScale(corner.X, corner.Y),
			Size = UDim2.fromOffset(TICK_LENGTH, TICK_THICKNESS),
			BackgroundColor3 = Tokens.Color.BorderAccent,
			BorderSizePixel = 0,
		},
		scope:New "Frame" {
			Name = "TickVertical",
			AnchorPoint = corner,
			Position = UDim2.fromScale(corner.X, corner.Y),
			Size = UDim2.fromOffset(TICK_THICKNESS, TICK_LENGTH),
			BackgroundColor3 = Tokens.Color.BorderAccent,
			BorderSizePixel = 0,
		},
	}
end

local function LockOnReticle(scope: Scope, props: LockOnReticleProps): Frame
	local hasTarget = scope:Computed(function(use)
		return use(props.Target) ~= nil
	end)

	local rawPosition = scope:Computed(function(use)
		local target = use(props.Target)
		return if target then target.ScreenPosition else UDim2.fromScale(0.5, 0.5)
	end)
	local followedPosition = scope:Spring(rawPosition, FOLLOW_SPRING_SPEED, FOLLOW_SPRING_DAMPING)

	local targetName = scope:Computed(function(use)
		local target = use(props.Target)
		return if target and target.Name then target.Name else ""
	end)

	local ticks: { Instance } = {}
	for _, corner in ipairs(Geometry.CORNERS) do
		for _, piece in ipairs(ReticleTick(scope, corner)) do
			table.insert(ticks, piece)
		end
	end

	return scope:New "Frame" {
		Name = "LockOnReticle",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = followedPosition,
		Size = UDim2.fromOffset(RETICLE_SIZE, RETICLE_SIZE),
		BackgroundTransparency = 1,
		Visible = hasTarget,

		[Children] = {
			ticks,
			Label(scope, {
				Text = targetName,
				Scale = "Caption",
				Color = Tokens.Color.TextPrimary,
				AnchorPoint = Vector2.new(0.5, 1),
				Position = UDim2.new(0.5, 0, 0, -6),
				TextXAlignment = Enum.TextXAlignment.Center,
			}),
		},
	} :: Frame
end

return LockOnReticle
