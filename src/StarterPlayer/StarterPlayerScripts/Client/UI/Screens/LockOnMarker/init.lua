--!strict
--[[
	LockOnMarker/init.lua

	Owns: the marker drawn over the local player's lock-on target -- four corner brackets around the
	target, and under them a thin bar showing that target's guard. The guard bar is the read: a guard that
	is nearly empty is one heavy from breaking, and a full one is worth a feint.

	THE RETICLE FAMILY. The brackets are the same AccentPrimary hairlines as ShiftLockCrosshair.lua's ticks,
	so the two read as one set: cardinal ticks mark your own aim, corner brackets mark a target. The guard
	fill is the Posture amber the HUD's own guard pill uses, and turns Danger once the guard is cracking
	(DefenseConstants.GuardCrack.EnterFraction) -- the same line the defender's strain pose starts at.

	PURE PRESENTATION, DRIVEN FROM OUTSIDE, the FurnacePrompt split: Client/Combat/LockOnController.lua
	owns the target, projects its position into this surface's own (scaled) space every frame, and reads
	its guard off the replicated GuardFraction Attribute. This file never reads the camera or the world.

	Its own surface on the World band rather than a region tile, because it tracks a point in the world.

	Does not own: which combatant is the target, when a lock breaks, or where the target is on screen
	(all LockOnController), or what a guard fraction means (DefenseSystem).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)

local DefenseConstants = require(ReplicatedStorage.Shared.Defense.DefenseConstants)
local LockOnConstants = require(ReplicatedStorage.Shared.Combat.LockOnConstants)
local Tokens = require(script.Parent.Parent.Tokens)
local Layers = require(script.Parent.Parent.Shell.Layers)
local Surface = require(script.Parent.Parent.Shell.Surface)
local Fade = require(script.Parent.Parent.Components.Fade)

local Children = Fusion.Children

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>

export type LockOnMarkerHandle = {
	SetVisible: (visible: boolean) -> (),
	-- The target's marker point, already in this surface's own coordinate space.
	SetPosition: (position: Vector2) -> (),
	-- The target's guard as a 0..1 fraction of its max, or nil when it has no guard to show.
	SetGuard: (fraction: number?) -> (),
}

local LockOnMarker = {}

-- The bracket box. Corner arms are BRACKET_ARM long, BRACKET_THICKNESS thick.
local BOX_SIZE = 34
local BRACKET_ARM = 8
local BRACKET_THICKNESS = 1
local BRACKET_TRANSPARENCY = 0.05

local GUARD_GAP = 5
local GUARD_WIDTH = LockOnConstants.Marker.GuardBarWidth
local GUARD_HEIGHT = LockOnConstants.Marker.GuardBarHeight
local GUARD_TRACK_TRANSPARENCY = 0.35

local MARKER_WIDTH = math.max(BOX_SIZE, GUARD_WIDTH)
local MARKER_HEIGHT = BOX_SIZE + GUARD_GAP + GUARD_HEIGHT

-- Each corner: its anchor within the box and which way its two arms run.
local CORNERS = {
	{ Anchor = Vector2.new(0, 0), X = 1, Y = 1 },
	{ Anchor = Vector2.new(1, 0), X = -1, Y = 1 },
	{ Anchor = Vector2.new(0, 1), X = 1, Y = -1 },
	{ Anchor = Vector2.new(1, 1), X = -1, Y = -1 },
}

local function Brackets(scope: Scope, transparency: UsedAs<number>): { Instance }
	local parts: { Instance } = {}
	for index, corner in CORNERS do
		local position = UDim2.fromScale(corner.Anchor.X, corner.Anchor.Y)
		local function arm(horizontal: boolean): Instance
			return scope:New "Frame" {
				Name = `Corner{index}{if horizontal then "H" else "V"}`,
				AnchorPoint = corner.Anchor,
				Position = position,
				Size = if horizontal
					then UDim2.fromOffset(BRACKET_ARM, BRACKET_THICKNESS)
					else UDim2.fromOffset(BRACKET_THICKNESS, BRACKET_ARM),
				BackgroundColor3 = Tokens.Color.AccentPrimaryBright,
				BackgroundTransparency = scope:Computed(function(use): number
					return 1 - (1 - BRACKET_TRANSPARENCY) * (1 - use(transparency))
				end),
				BorderSizePixel = 0,
			}
		end
		table.insert(parts, arm(true))
		table.insert(parts, arm(false))
	end
	return parts
end

local function Marker(scope: Scope, visible: UsedAs<boolean>, position: UsedAs<Vector2>, guard: UsedAs<number?>): Frame
	local fade = Fade.New(scope, visible)

	local hasGuard = scope:Computed(function(use): boolean
		return use(guard) ~= nil
	end)

	return scope:New "Frame" {
		Name = "LockOnMarker",
		AnchorPoint = Vector2.new(0.5, 0),
		Size = UDim2.fromOffset(MARKER_WIDTH, MARKER_HEIGHT),
		Position = scope:Computed(function(use): UDim2
			local point = use(position)
			-- Centred on the point horizontally, with the bracket box centred on it vertically.
			return UDim2.fromOffset(point.X, point.Y - BOX_SIZE / 2)
		end),
		BackgroundTransparency = 1,
		Visible = visible,

		[Children] = {
			scope:New "Frame" {
				Name = "Box",
				AnchorPoint = Vector2.new(0.5, 0),
				Position = UDim2.fromScale(0.5, 0),
				Size = UDim2.fromOffset(BOX_SIZE, BOX_SIZE),
				BackgroundTransparency = 1,
				[Children] = Brackets(scope, fade.Transparency),
			},

			scope:New "Frame" {
				Name = "GuardTrack",
				AnchorPoint = Vector2.new(0.5, 0),
				Position = UDim2.new(0.5, 0, 0, BOX_SIZE + GUARD_GAP),
				Size = UDim2.fromOffset(GUARD_WIDTH, GUARD_HEIGHT),
				BackgroundColor3 = Tokens.Color.Background,
				BackgroundTransparency = scope:Computed(function(use): number
					return 1 - (1 - GUARD_TRACK_TRANSPARENCY) * (1 - use(fade.Transparency))
				end),
				BorderSizePixel = 0,
				Visible = hasGuard,

				[Children] = {
					scope:New "Frame" {
						Name = "GuardFill",
						Size = scope:Computed(function(use): UDim2
							return UDim2.fromScale(math.clamp(use(guard) or 0, 0, 1), 1)
						end),
						BackgroundColor3 = scope:Computed(function(use): Color3
							local fraction = use(guard) or 0
							return if fraction < DefenseConstants.GuardCrack.EnterFraction
								then Tokens.Color.DangerBright
								else Tokens.VitalColor.Posture
						end),
						BackgroundTransparency = fade.Transparency,
						BorderSizePixel = 0,
					},
				},
			},
		},
	}
end

function LockOnMarker.Mount(scope: Scope, playerGui: PlayerGui, scale: UsedAs<number>): LockOnMarkerHandle
	local visible = scope:Value(false)
	local position = scope:Value(Vector2.zero)
	local guard: Fusion.Value<number?> = scope:Value(nil :: number?)

	Surface.New(scope, {
		Name = "LockOnMarker",
		Layer = Layers.World,
		Parent = playerGui,
		Scaled = true,
		Scale = scale,
		Children = {
			Marker(scope, visible, position, guard),
		},
	})

	return {
		SetVisible = function(newVisible: boolean)
			visible:set(newVisible)
		end,
		SetPosition = function(newPosition: Vector2)
			position:set(newPosition)
		end,
		SetGuard = function(fraction: number?)
			guard:set(fraction)
		end,
	}
end

return LockOnMarker
