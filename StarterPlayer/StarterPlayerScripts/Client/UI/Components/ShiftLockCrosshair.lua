--!strict
--[[
	ShiftLockCrosshair.lua

	Owns: the center-screen aim marker shown while the custom shift-lock camera mode is engaged
	(Client/Camera/ShiftLockCamera.lua) -- the game-styled replacement for the engine's stock
	mouse-locked cursor texture, which docs/ui-ux-philosophy.md's "avoid generic Roblox UI styles"
	rule reads as off-brand. Deliberately minimal and modern: four 1px hairline cardinal ticks in
	the same BorderAccent metal-blue as LockOnReticle.lua's corner ticks (the two reticles read as
	one family -- corner ticks mark a *target*, cardinal ticks mark *your own aim*), each held a
	fixed gap off dead-center and pointing outward, around a single small Qi-cyan dot. The gap keeps
	the exact aim point unobstructed; the hairline weight and slight tick transparency keep it a
	quiet, precise marker rather than a heavy overlay (the doc's "minimal, out of the player's way"
	HUD rule, and its Lock-On "avoid blocking enemy animations" applied to a permanent marker). Pale
	cyan center per the Qi color language ("spiritual energy, internal power": the aim point as the
	player's own focused intent). Pure Frame geometry, no image asset -- same no-upload-pipeline
	reasoning as VitalIcon.lua's procedural glyph fallback.

	Does not own: deciding when shift lock is engaged (ShiftLockCamera.lua), hiding the engine
	cursor (also ShiftLockCamera.lua -- UserInputService is input policy, not presentation), or
	lock-on targeting (LockOnReticle.lua). This component only renders whatever Engaged says --
	the same "already-computed value in, presentation out" boundary every component here uses.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Tokens = require(script.Parent.Parent.Tokens)

local Children = Fusion.Children

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>

export type ShiftLockCrosshairProps = {
	-- true = shift lock engaged = visible. Display state handed in, never computed here.
	Engaged: UsedAs<boolean>,
}

-- Hairline weights, small footprint -- much quieter than LockOnReticle's 46px target box, since
-- this sits at screen center every frame the mode is on. TICK_GAP is the clear radius kept around
-- the exact aim point; each tick starts there and extends TICK_LENGTH outward.
local TICK_GAP = 3
local TICK_LENGTH = 4
local TICK_THICKNESS = 1
local TICK_TRANSPARENCY = 0.1
local CENTER_DOT_SIZE = 2

-- Bounding box sized exactly to the tick span so the component reports its true footprint.
local CROSSHAIR_SIZE = (TICK_GAP + TICK_LENGTH) * 2

-- Outward unit direction per cardinal tick; horizontal (X ~= 0) ticks lie flat, vertical ones
-- stand -- see the size/position math in the loop below.
local TICK_DIRECTIONS = {
	Vector2.new(0, -1),
	Vector2.new(0, 1),
	Vector2.new(-1, 0),
	Vector2.new(1, 0),
}

local function ShiftLockCrosshair(scope: Scope, props: ShiftLockCrosshairProps): Frame
	local ticks: { Instance } = {}
	for index, direction in ipairs(TICK_DIRECTIONS) do
		local horizontal = direction.X ~= 0
		local size = if horizontal
			then UDim2.fromOffset(TICK_LENGTH, TICK_THICKNESS)
			else UDim2.fromOffset(TICK_THICKNESS, TICK_LENGTH)
		-- Offset from center to the tick's own midpoint: past the gap, then half its length.
		local distance = TICK_GAP + TICK_LENGTH / 2
		table.insert(
			ticks,
			scope:New "Frame" {
				Name = `Tick{index}`,
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.new(0.5, direction.X * distance, 0.5, direction.Y * distance),
				Size = size,
				BackgroundColor3 = Tokens.Color.BorderAccent,
				BackgroundTransparency = TICK_TRANSPARENCY,
				BorderSizePixel = 0,
			}
		)
	end

	return scope:New "Frame" {
		Name = "ShiftLockCrosshair",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(CROSSHAIR_SIZE, CROSSHAIR_SIZE),
		BackgroundTransparency = 1,
		Visible = props.Engaged,

		[Children] = {
			ticks,
			scope:New "Frame" {
				Name = "CenterDot",
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromOffset(CENTER_DOT_SIZE, CENTER_DOT_SIZE),
				BackgroundColor3 = Tokens.Color.Qi,
				BorderSizePixel = 0,
			},
		},
	} :: Frame
end

return ShiftLockCrosshair
