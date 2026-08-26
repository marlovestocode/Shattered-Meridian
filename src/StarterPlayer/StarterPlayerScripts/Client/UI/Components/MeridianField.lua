--!strict
--[[
	MeridianField.lua

	Owns: the decorative surface texture layered behind a Panel's content -- sparse vertical
	"meridian threads" with a handful of lit nodes along them, plus a soft bottom-up qi bloom.
	Purely ornamental: it never encodes state, never reacts, and is skipped entirely by callers that
	don't opt in (Panel.lua's SurfaceTexture prop).

	REPLACES Components/LatticeOverlay.lua, which drew the old hex-lattice tile. That component could
	only ever render a real uploaded 60x69 hexagon texture, no id for it was ever uploaded, so it
	returned nil at every call site and the one caller that asked for it (Onboarding/CreatorFrame.lua)
	silently got nothing. The hex motif is also gone by design decision (user, 2026-08-20 -- the
	background shapes in the character-menu spec were rejected), so the replacement is procedural
	rather than another asset-blocked stub: threads and nodes are plain Frames + UIGradients, so this
	renders the first time it's mounted and needs no upload step.

	WHY THREADS AND NOT A TILE. A tiled pattern at this opacity reads as noise; a small number of
	long, unevenly-spaced verticals reads as structure -- and structure is on-theme here, since the
	thing the game is named for IS a lattice of channels. The x positions below are deliberately
	irregular (never a constant gap) so the field never resolves into a barcode, and each thread fades
	in and out over its own vertical span so no two terminate at the same height.

	Cost is bounded and fixed: THREADS + NODES Frames plus one gradient each, ~25 instances total
	regardless of panel size, because nothing here tiles. That's the whole reason the geometry is a
	hardcoded table rather than a density-per-pixel computation.

	NEVER MOUNT THIS INSIDE AN AutomaticSize CONTAINER. Every layer here is Scale-sized against the
	panel it decorates -- that is the entire point of a surface grain -- and Roblox's AutomaticSize
	measures a child's whole SUBTREE, with ClipsDescendants providing no protection. A Scale-sized
	grandchild resolves against the enclosing host rather than against the auto-sizing frame, so the
	frame grows to match and stays there: the hotbar dock rendered at full screen height this way on
	2026-08-25. Give any panel using this an explicit Size. Components/Panel.lua's SurfaceTexture prop
	carries the full measured rule, including which shapes ARE safe.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Tokens = require(script.Parent.Parent.Tokens)

local Children = Fusion.Children

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>

export type MeridianFieldProps = {
	-- Where this layer sits relative to its siblings. Panel.lua passes 1 (above the fill, below
	-- Content); a caller mounting this directly picks its own.
	ZIndex: number?,
	-- The thread hue. Defaults to the primary accent -- the same violet the panel borders use, so the
	-- field reads as the surface's own grain rather than as a second color in the frame.
	Color: UsedAs<Color3>?,
	-- The lit-node hue. Defaults to the vitals' Qi cyan: the nodes are the only warm/cool contrast in
	-- the whole field, and cyan is what this game already means by "a point where qi gathers."
	NodeColor: UsedAs<Color3>?,
	-- Scales every layer's opacity at once, 0 (invisible) to 1 (as authored). Lets one caller run the
	-- field hotter than another without each re-deriving a full set of transparencies.
	Intensity: number?,
}

-- One entry per thread. X is a scale across the panel; Top/Bottom are the scale heights at which the
-- thread reaches and leaves full brightness (it fades from nothing at 0 and back to nothing at 1);
-- Alpha is its own resting transparency before Intensity is applied. Gaps between successive X
-- values are deliberately all different -- see this file's header.
local THREADS: { { X: number, Top: number, Bottom: number, Alpha: number } } = {
	{ X = 0.045, Top = 0.18, Bottom = 0.72, Alpha = 0.955 },
	{ X = 0.113, Top = 0.06, Bottom = 0.55, Alpha = 0.93 },
	{ X = 0.207, Top = 0.34, Bottom = 0.95, Alpha = 0.96 },
	{ X = 0.268, Top = 0.12, Bottom = 0.66, Alpha = 0.94 },
	{ X = 0.401, Top = 0.24, Bottom = 0.88, Alpha = 0.955 },
	{ X = 0.489, Top = 0.04, Bottom = 0.44, Alpha = 0.935 },
	{ X = 0.607, Top = 0.3, Bottom = 0.92, Alpha = 0.95 },
	{ X = 0.724, Top = 0.1, Bottom = 0.6, Alpha = 0.94 },
	{ X = 0.812, Top = 0.4, Bottom = 0.97, Alpha = 0.96 },
	{ X = 0.943, Top = 0.16, Bottom = 0.7, Alpha = 0.945 },
}

-- Lit points along (or between) threads. Each is a 45-degree square -- the same diamond vocabulary
-- Divider.Flourish and CornerBracket's rivet already use, so the field shares a shape language with
-- the chrome instead of introducing a third one.
local NODES: { { X: number, Y: number, Size: number, Alpha: number } } = {
	{ X = 0.113, Y = 0.31, Size = 4, Alpha = 0.82 },
	{ X = 0.401, Y = 0.58, Size = 3, Alpha = 0.88 },
	{ X = 0.607, Y = 0.21, Size = 3, Alpha = 0.9 },
	{ X = 0.724, Y = 0.45, Size = 5, Alpha = 0.86 },
	{ X = 0.812, Y = 0.78, Size = 3, Alpha = 0.9 },
}

-- The bloom's resting transparency at its brightest (bottom) edge. Faint enough that it reads as the
-- panel being lit from below rather than as a second fill color.
local BLOOM_ALPHA = 0.962

-- Applies Intensity to an authored transparency. 1 leaves it exactly as written; 0 pushes every
-- layer to fully transparent, which is what makes Intensity a single dial rather than ten edits.
local function dim(alpha: number, intensity: number): number
	return 1 - (1 - alpha) * intensity
end

local function MeridianField(scope: Scope, props: MeridianFieldProps): Frame
	local intensity = props.Intensity or 1
	local color: UsedAs<Color3> = props.Color or Tokens.Color.AccentPrimary
	local nodeColor: UsedAs<Color3> = props.NodeColor or Tokens.VitalColor.Qi
	local zIndex = props.ZIndex or 1

	local pieces: { Instance } = {
		-- The bloom. Painted first and left at the bottom of the local stack so threads read over it.
		scope:New "Frame" {
			Name = "Bloom",
			Size = UDim2.fromScale(1, 1),
			BackgroundColor3 = color,
			BackgroundTransparency = dim(BLOOM_ALPHA, intensity),
			BorderSizePixel = 0,
			ZIndex = zIndex,

			[Children] = scope:New "UIGradient" {
				-- Rotation 90 runs the gradient top-to-bottom. Transparency 1 at t=0 means the top
				-- edge contributes nothing at all and the wash pools along the bottom.
				Rotation = 90,
				Transparency = NumberSequence.new({
					NumberSequenceKeypoint.new(0, 1),
					NumberSequenceKeypoint.new(0.55, 0.72),
					NumberSequenceKeypoint.new(1, 0),
				}),
			},
		},
	}

	for index, thread in ipairs(THREADS) do
		table.insert(
			pieces,
			scope:New "Frame" {
				Name = `Thread{index}`,
				AnchorPoint = Vector2.new(0.5, 0),
				Position = UDim2.fromScale(thread.X, 0),
				Size = UDim2.new(0, 1, 1, 0),
				BackgroundColor3 = color,
				BackgroundTransparency = dim(thread.Alpha, intensity),
				BorderSizePixel = 0,
				ZIndex = zIndex,

				[Children] = scope:New "UIGradient" {
					Rotation = 90,
					-- Invisible at both ends, full across Top..Bottom. The keypoint times have to be
					-- strictly increasing, which is why Top/Bottom are authored well inside 0..1
					-- rather than allowed to touch either edge.
					Transparency = NumberSequence.new({
						NumberSequenceKeypoint.new(0, 1),
						NumberSequenceKeypoint.new(thread.Top, 0),
						NumberSequenceKeypoint.new(thread.Bottom, 0),
						NumberSequenceKeypoint.new(1, 1),
					}),
				},
			}
		)
	end

	for index, node in ipairs(NODES) do
		table.insert(
			pieces,
			scope:New "Frame" {
				Name = `Node{index}`,
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(node.X, node.Y),
				Size = UDim2.fromOffset(node.Size, node.Size),
				Rotation = 45,
				BackgroundColor3 = nodeColor,
				BackgroundTransparency = dim(node.Alpha, intensity),
				BorderSizePixel = 0,
				-- One above the threads so a node sitting on top of its own thread still reads as a
				-- bead ON the line rather than as a break in it.
				ZIndex = zIndex + 1,
			}
		)
	end

	return scope:New "Frame" {
		Name = "MeridianField",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ZIndex = zIndex,
		-- The threads are full-height and the nodes are rotated, so both can overhang a panel whose
		-- corners are bracketed or chamfered. Clipping here (rather than asking every caller to clip
		-- its own Panel, which would also clip that caller's content) keeps the field inside the frame.
		ClipsDescendants = true,

		[Children] = pieces,
	} :: Frame
end

return MeridianField
