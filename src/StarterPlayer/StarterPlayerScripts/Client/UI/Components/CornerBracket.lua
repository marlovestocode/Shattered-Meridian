--!strict
--[[
	CornerBracket.lua

	Owns: the tactical corner-bracket accent -- an L-shaped arm pair plus a diamond rivet chip at the
	elbow, anchored to one corner of its parent via the same "anchor a frame's own corner to a parent
	corner point" trick used throughout this UI framework (see Geometry.lua's header, LockOnReticle's
	ReticleTicks). Originally a private helper inside Panel.lua, built for docs/design/frames/
	hotbar-frame.svg's corner-bracket treatment; extracted here once AbilitySlot.lua needed the same
	vocabulary at a much smaller scale (see that file's header for why) -- Panel.lua's own constants
	(12px arms) would read as oversized on a 40px tile, so this takes its geometry as props instead of
	hardcoding Panel's numbers, letting each caller pick a scale that fits its own tile size.

	Pure Frame composition, same "no image asset needed" discipline as VitalIcon.lua's procedural
	glyphs -- see that file's header for why this repo doesn't guess at rbxassetids.

	INSET EXISTS BECAUSE OF THE CHAMFER. Panel.lua's header records the rule that a bracket anchored
	at a rectangular corner must not be drawn over a CHAMFERED surface: the corner it anchors to has
	been cut away, so the elbow lands in the void and the arms float. Panel.lua answers that by
	dropping its brackets entirely whenever the chamfer is available. The hotbar dock wants both --
	the cut silhouette AND the bronze corner accents its design calls for -- and Inset is what makes
	that legal rather than a fudge: at Inset = ChamferedSurface.CHAMFER_PX the elbow sits exactly
	where the diagonal cut ends and the straight edge begins, so each arm runs ALONG a real edge and
	the pair reads as bracing the cut instead of ignoring it. Defaults to 0, the original flush-to-
	the-corner behavior every existing caller keeps.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Geometry = require(script.Parent.Parent.Geometry)

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>

export type CornerBracketProps = {
	ArmLength: number,
	ArmThickness: number,
	-- Omit both for a plain L-shape with no rivet chip -- the redesign's own brackets
	-- (docs/design/intro-redesign-figma-spec.md section 3.3) are unornamented. RivetInset only means
	-- anything alongside a real RivetSize, so the two are optional together; the existing
	-- hotbar-frame.svg-derived brackets (Panel.lua's CornerAccent, AbilitySlot.lua) keep passing both.
	RivetSize: number?,
	RivetInset: number?,
	Color: UsedAs<Color3>,
	Transparency: UsedAs<number>?,
	-- Pixels inward from the corner, on BOTH axes, before the elbow starts -- see this file's header
	-- on why this is the chamfer's answer. Defaults to 0 (flush to the corner).
	Inset: number?,
	-- EXTRA pixels inward, on ONE pair only, added to Inset. For a panel that is one HALF of an
	-- assembly: the corners on its joined edge are not the assembly's corners, so bracketing them
	-- marks the joint rather than the object.
	--
	-- Two of the four edges have a caller and therefore a prop; Bottom and Right get one the day
	-- something is joined along them. Screens/BlimpHelm passes TopInset (the furnace plate sinks into
	-- its top edge) and Screens/HUD passes LeftInset (the armament island sinks into the dock's left
	-- edge) -- the same joint twice, rotated ninety degrees.
	--
	-- A prop rather than a wrapper frame, and that is not a style call. A Scale-sized frame holding
	-- these inside an AutomaticSize panel inflates the panel to the viewport -- Components/Panel.lua's
	-- SurfaceTexture note measures exactly that -- and the first attempt at this did, taking a 212px
	-- console to 970. The arms themselves are offset-sized with scale-anchored Positions, so moving
	-- them is safe in a way moving their container is not.
	TopInset: number?,
	LeftInset: number?,
	ZIndex: number?,
}

local CornerBracket = {}

-- One corner's worth of pieces (two arms, plus a rivet if RivetSize is given). `corner` is one of
-- Geometry.CORNERS.
local function buildOne(scope: Scope, corner: Vector2, props: CornerBracketProps): { Instance }
	local transparency: UsedAs<number> = props.Transparency or 0
	local zIndex = props.ZIndex or 5

	-- Which way "inward" points depends on which corner this is -- the same sign question the rivet
	-- below already had to answer, hoisted here now that the elbow itself can move too.
	local inset = props.Inset or 0
	-- The pair on a JOINED edge can be pushed further in than its opposite -- see TopInset/LeftInset.
	local insetX = if corner.X == 0 then inset + (props.LeftInset or 0) else -inset
	local insetY = if corner.Y == 0 then inset + (props.TopInset or 0) else -inset
	local elbow = UDim2.new(corner.X, insetX, corner.Y, insetY)

	local pieces: { Instance } = {
		scope:New "Frame" {
			Name = "BracketArmHorizontal",
			AnchorPoint = corner,
			Position = elbow,
			Size = UDim2.fromOffset(props.ArmLength, props.ArmThickness),
			BackgroundColor3 = props.Color,
			BackgroundTransparency = transparency,
			BorderSizePixel = 0,
			ZIndex = zIndex,
		},
		scope:New "Frame" {
			Name = "BracketArmVertical",
			AnchorPoint = corner,
			Position = elbow,
			Size = UDim2.fromOffset(props.ArmThickness, props.ArmLength),
			BackgroundColor3 = props.Color,
			BackgroundTransparency = transparency,
			BorderSizePixel = 0,
			ZIndex = zIndex,
		},
	}

	if props.RivetSize then
		-- The rivet sits further inward along the same diagonal, measured from the elbow rather than
		-- from the corner, so an inset bracket carries its chip with it instead of leaving it behind
		-- out in the cut.
		local rivetInset = (props.RivetInset or 0) + inset
		local rivetX = if corner.X == 0 then rivetInset else -rivetInset
		local rivetY = if corner.Y == 0 then rivetInset else -rivetInset
		table.insert(
			pieces,
			scope:New "Frame" {
				Name = "BracketRivet",
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.new(corner.X, rivetX, corner.Y, rivetY),
				Size = UDim2.fromOffset(props.RivetSize, props.RivetSize),
				Rotation = 45,
				BackgroundColor3 = props.Color,
				BackgroundTransparency = transparency,
				BorderSizePixel = 0,
				ZIndex = zIndex,
			}
		)
	end

	return pieces
end

-- All four corners' pieces, flattened into one list -- the common case every current caller wants.
function CornerBracket.BuildAll(scope: Scope, props: CornerBracketProps): { Instance }
	local pieces: { Instance } = {}
	for _, corner in ipairs(Geometry.CORNERS) do
		for _, piece in ipairs(buildOne(scope, corner, props)) do
			table.insert(pieces, piece)
		end
	end
	return pieces
end

return CornerBracket
