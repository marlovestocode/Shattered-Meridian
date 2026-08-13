--!strict
--[[
	SectionIcon.lua

	Owns: nine small procedural glyphs (Frame/UIStroke composition, no SVG/asset upload -- the exact
	technique Components/ActionIcon.lua and Components/VitalIcon.lua already established) identifying
	the Move Editor's customization sections at a glance. The SAME glyph renders in both
	Screens/MoveEditor/Sidebar.lua's nav rail and Components/Section.lua's own card header (via
	PropertyEditor.lua's Icon prop), so opening a section visually reconfirms the nav row that led
	there rather than introducing a second, unrelated icon vocabulary.

	A closed union (SectionIconGlyphKind), not a generic "pass any icon" API -- the same shape
	ActionIcon.lua's own ActionIconGlyphKind already uses, for the same reason: this is a small,
	enumerable vocabulary tied to one editor's own field-group taxonomy (its members deliberately
	match MoveEditor/Types.lua's SectionId 1:1), not a general-purpose icon system other screens are
	expected to extend.

	Every rotated piece uses one of exactly two proven-safe anchor/pivot shapes already shipped in
	ActionIcon.lua, rather than inventing a third:
	- `throughCenter`: AnchorPoint AND Position both (0.5, 0.5) -- the shape's own center coincides
	  with the icon box's true center, so Rotation pivots cleanly through it. BanGlyph/MuteGlyph's own
	  "Slash" already does exactly this.
	- `edgeArm`: AnchorPoint/Position both pinned to the SAME point of the box; Rotation pivots around
	  the shape's OWN center, which sits inward from that point by half its length, so two arms
	  sharing one anchor point converge into a "V"/chevron vertex there. KickGlyph's own chevron arms
	  already do exactly this.
	Every UN-rotated piece (dots, a plain horizontal/vertical bar anchored at one point and extending
	outward from it, a non-rotated outline box) has no pivot ambiguity at all -- Rotation only
	introduces one, and these never set it -- so `anchoredBar` below can safely be genuinely one-sided
	(e.g. a clock hand extending from the box's exact center in only one direction), unlike the two
	rotated shapes above.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)

local Children = Fusion.Children

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>

export type SectionIconGlyphKind =
	"BasicInfo"
	| "Hitbox"
	| "Offset"
	| "Timing"
	| "Damage"
	| "Animation"
	| "Movement"
	| "Knockback"
	| "Projectile"
	| "ObjectStun"
	| "Art"
	| "Stats"

export type SectionIconProps = {
	Glyph: SectionIconGlyphKind,
	Color: UsedAs<Color3>,
	LayoutOrder: UsedAs<number>?,
}

local ICON_SIZE = 16
local THICKNESS = 2

local function throughCenter(scope: Scope, length: number, rotation: number, color: UsedAs<Color3>): Frame
	return scope:New "Frame" {
		Name = "Bar",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(length, THICKNESS),
		Rotation = rotation,
		BackgroundColor3 = color,
		BorderSizePixel = 0,
	} :: Frame
end

local function edgeArm(scope: Scope, length: number, rotation: number, color: UsedAs<Color3>, anchor: Vector2): Frame
	return scope:New "Frame" {
		Name = "Arm",
		AnchorPoint = anchor,
		Position = UDim2.fromScale(anchor.X, anchor.Y),
		Size = UDim2.fromOffset(length, THICKNESS),
		Rotation = rotation,
		BackgroundColor3 = color,
		BorderSizePixel = 0,
	} :: Frame
end

-- Un-rotated, so `anchor` alone places it exactly -- see file header on why this is safe to be
-- genuinely one-sided (e.g. extends from the box's true center in only ONE direction) where the two
-- rotated shapes above can't be.
local function anchoredBar(
	scope: Scope,
	sizeX: number,
	sizeY: number,
	color: UsedAs<Color3>,
	anchor: Vector2,
	position: Vector2
): Frame
	return scope:New "Frame" {
		Name = "Bar",
		AnchorPoint = anchor,
		Position = UDim2.fromScale(position.X, position.Y),
		Size = UDim2.fromOffset(sizeX, sizeY),
		BackgroundColor3 = color,
		BorderSizePixel = 0,
	} :: Frame
end

local function centerDot(scope: Scope, diameter: number, color: UsedAs<Color3>, position: UDim2?): Frame
	return scope:New "Frame" {
		Name = "Dot",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = position or UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(diameter, diameter),
		BackgroundColor3 = color,
		BorderSizePixel = 0,
		[Children] = scope:New "UICorner" { CornerRadius = UDim.new(0.5, 0) },
	} :: Frame
end

local function centerRing(scope: Scope, diameter: number, color: UsedAs<Color3>): Frame
	return scope:New "Frame" {
		Name = "Ring",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(diameter, diameter),
		BackgroundTransparency = 1,
		[Children] = {
			scope:New "UICorner" { CornerRadius = UDim.new(0.5, 0) },
			scope:New "UIStroke" { Color = color, Thickness = THICKNESS },
		},
	} :: Frame
end

-- "i" -- a dot over a stem, the plainest available "identity/info" reading.
local function BasicInfoGlyph(scope: Scope, color: UsedAs<Color3>): { Instance }
	return {
		centerDot(scope, 3, color, UDim2.fromScale(0.5, 0.24)),
		anchoredBar(scope, THICKNESS, 8, color, Vector2.new(0.5, 1), Vector2.new(0.5, 0.92)),
	}
end

-- A plain outline box -- the hitbox's own bounding-volume reading.
local function HitboxGlyph(scope: Scope, color: UsedAs<Color3>): { Instance }
	return {
		scope:New "Frame" {
			Name = "Box",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(11, 11),
			BackgroundTransparency = 1,
			[Children] = scope:New "UIStroke" { Color = color, Thickness = THICKNESS },
		} :: Frame,
	}
end

-- A target reticle -- ring plus a center dot, the "a position relative to something" reading.
local function OffsetGlyph(scope: Scope, color: UsedAs<Color3>): { Instance }
	return {
		centerRing(scope, 13, color),
		centerDot(scope, 3, color),
	}
end

-- A clock face -- ring plus two hands extending from the box's true center (safe: neither hand is
-- rotated, see file header).
local function TimingGlyph(scope: Scope, color: UsedAs<Color3>): { Instance }
	return {
		centerRing(scope, 14, color),
		anchoredBar(scope, THICKNESS, 5, color, Vector2.new(0.5, 1), Vector2.new(0.5, 0.5)),
		anchoredBar(scope, 4, THICKNESS, color, Vector2.new(0, 0.5), Vector2.new(0.5, 0.5)),
	}
end

-- An 8-point burst through the box's true center -- the "impact" reading, distinct from Knockback's
-- diamond silhouette below.
local function DamageGlyph(scope: Scope, color: UsedAs<Color3>): { Instance }
	return {
		throughCenter(scope, 12, 0, color),
		throughCenter(scope, 12, 45, color),
		throughCenter(scope, 12, 90, color),
		throughCenter(scope, 12, 135, color),
	}
end

-- A three-bar waveform -- the "clip/timeline" reading, distinct from Timing's clock even though both
-- are about time.
local function AnimationGlyph(scope: Scope, color: UsedAs<Color3>): { Instance }
	return {
		anchoredBar(scope, THICKNESS, 6, color, Vector2.new(0.5, 1), Vector2.new(0.28, 0.82)),
		anchoredBar(scope, THICKNESS, 10, color, Vector2.new(0.5, 1), Vector2.new(0.5, 0.82)),
		anchoredBar(scope, THICKNESS, 4, color, Vector2.new(0.5, 1), Vector2.new(0.72, 0.82)),
	}
end

-- A forward chevron -- the exact KickGlyph technique (ActionIcon.lua), just re-anchored to fit this
-- smaller 16px box. Reads as "this move propels the attacker forward."
local function MovementGlyph(scope: Scope, color: UsedAs<Color3>): { Instance }
	local anchor = Vector2.new(0.68, 0.5)
	return {
		edgeArm(scope, 8, 45, color, anchor),
		edgeArm(scope, 8, -45, color, anchor),
	}
end

-- A diamond outline (a rotated square, safely pivoting through its own true center) -- an impact
-- silhouette distinct from Damage's burst and Hitbox's own non-rotated square.
local function KnockbackGlyph(scope: Scope, color: UsedAs<Color3>): { Instance }
	return {
		scope:New "Frame" {
			Name = "Diamond",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(10, 10),
			Rotation = 45,
			BackgroundTransparency = 1,
			[Children] = scope:New "UIStroke" { Color = color, Thickness = THICKNESS },
		} :: Frame,
	}
end

-- A shaft plus a chevron arrowhead (MovementGlyph's own chevron, reused as the arrowhead) -- the
-- "something traveling away from the attacker" reading.
local function ProjectileGlyph(scope: Scope, color: UsedAs<Color3>): { Instance }
	local tip = Vector2.new(0.78, 0.5)
	return {
		anchoredBar(scope, 9, THICKNESS, color, Vector2.new(0, 0.5), Vector2.new(0.12, 0.5)),
		edgeArm(scope, 6, 45, color, tip),
		edgeArm(scope, 6, -45, color, tip),
	}
end

-- A solid wall down the right edge, with a chevron driving into it -- the "knocked INTO something"
-- reading. Deliberately built from ProjectileGlyph's own travel-toward-a-point vocabulary (a shaft
-- plus a chevron) rather than a new one, because Object Stun IS that motion terminating against
-- geometry; the wall bar is the only thing that distinguishes them.
local function ObjectStunGlyph(scope: Scope, color: UsedAs<Color3>): { Instance }
	local impact = Vector2.new(0.62, 0.5)
	return {
		anchoredBar(scope, THICKNESS, 14, color, Vector2.new(1, 0.5), Vector2.new(0.98, 0.5)),
		anchoredBar(scope, 7, THICKNESS, color, Vector2.new(0, 0.5), Vector2.new(0.06, 0.5)),
		edgeArm(scope, 6, 45, color, impact),
		edgeArm(scope, 6, -45, color, impact),
	}
end

-- Three rising bars sharing a baseline -- the plainest available "this section is a chart" reading,
-- and the only glyph here that is about the PANEL rather than about a move's mechanics.
local function StatsGlyph(scope: Scope, color: UsedAs<Color3>): { Instance }
	local baseline = 0.86
	return {
		anchoredBar(scope, THICKNESS, 5, color, Vector2.new(0.5, 1), Vector2.new(0.22, baseline)),
		anchoredBar(scope, THICKNESS, 10, color, Vector2.new(0.5, 1), Vector2.new(0.5, baseline)),
		anchoredBar(scope, THICKNESS, 14, color, Vector2.new(0.5, 1), Vector2.new(0.78, baseline)),
	}
end

-- A trunk with two branch nodes -- a tree, which is literally what an art belongs to. Built from
-- anchoredBar/dot primitives already used above rather than a new shape vocabulary.
local function ArtGlyph(scope: Scope, color: UsedAs<Color3>): { Instance }
	return {
		anchoredBar(scope, THICKNESS, 13, color, Vector2.new(0.5, 1), Vector2.new(0.5, 0.95)),
		edgeArm(scope, 6, -45, color, Vector2.new(0.5, 0.5)),
		edgeArm(scope, 6, 45, color, Vector2.new(0.5, 0.5)),
		throughCenter(scope, 4, 45, color),
	}
end

local GLYPH_BUILDERS: { [SectionIconGlyphKind]: (Scope, UsedAs<Color3>) -> { Instance } } = {
	BasicInfo = BasicInfoGlyph,
	Hitbox = HitboxGlyph,
	Offset = OffsetGlyph,
	Timing = TimingGlyph,
	Damage = DamageGlyph,
	Animation = AnimationGlyph,
	Movement = MovementGlyph,
	Knockback = KnockbackGlyph,
	Projectile = ProjectileGlyph,
	ObjectStun = ObjectStunGlyph,
	Art = ArtGlyph,
	Stats = StatsGlyph,
}

local function SectionIcon(scope: Scope, props: SectionIconProps): Frame
	local builder = GLYPH_BUILDERS[props.Glyph]
	return scope:New "Frame" {
		Name = "SectionIcon_" .. props.Glyph,
		Size = UDim2.fromOffset(ICON_SIZE, ICON_SIZE),
		BackgroundTransparency = 1,
		LayoutOrder = props.LayoutOrder,
		[Children] = builder(scope, props.Color),
	} :: Frame
end

return SectionIcon
