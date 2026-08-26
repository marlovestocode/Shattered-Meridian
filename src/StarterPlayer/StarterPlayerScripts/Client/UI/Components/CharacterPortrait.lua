--!strict
--[[
	CharacterPortrait.lua

	Owns: the framed portrait plate at the top of the character menu's identity rail -- the PLAYER'S
	OWN AVATAR, bracketed in bronze and standing inside two faint meridian rings.

	IT IS THE REAL AVATAR, NOT A DRAWING (user, 2026-08-20: "instead of building a random fake person
	just insert the users avatar"). The first version drew a procedural robed figure, which is a
	stranger wearing your name -- the one thing a character portrait must never be.

	The image comes from a `rbxthumb://` content URL rather than Players:GetUserThumbnailAsync. Both
	resolve the same thumbnail; the content-URL form takes no yield, no pcall and no retry loop, and
	the engine fetches it asynchronously behind the ImageLabel -- so this component stays a pure
	build-time function with no async surface at all. It also does not breach this repo's "never guess
	at an rbxassetid" rule (VitalIcon.lua's header): nothing is guessed, the id is the player's own.

	NOT a ViewportFrame of the live rig, which would show the current outfit AND whatever tool the
	player happens to be holding. This menu mounts at boot for every player (Screens/Menus/init.lua);
	a viewport holding a cloned R15 character is exactly the always-on cost docs/architecture's client
	perf audit already flagged elsewhere in this UI, and the clone would have to be torn down and
	rebuilt on every respawn to stay current. A thumbnail is one ImageLabel that never needs rebinding.

	THE DRAWN FIGURE SURVIVES AS THE FALLBACK, and only as that. With no UserId -- a headless test
	place, the construction smoke test, any caller with no player to name -- the plate renders the
	silhouette instead of an empty bronze box. Frame, rings, scrim and brackets are identical across
	both paths, so the fallback is a different subject in the same portrait rather than a degraded
	second design.

	Geometry is authored in a fixed STAGE_WIDTH x STAGE_HEIGHT coordinate space and scaled to the
	caller's pixel size by a single UIScale, so every offset below can be read as a drawing rather
	than as a pile of size-dependent fractions.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Tokens = require(script.Parent.Parent.Tokens)
local CornerBracket = require(script.Parent.CornerBracket)
local Glow = require(script.Parent.Glow)

local Children = Fusion.Children

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>

export type CharacterPortraitProps = {
	-- Plate size in pixels. Real numbers rather than a UDim2 because the stage scale below has to be
	-- resolved at construction, and a scale-sized plate has no width to resolve it against.
	--
	-- Not square, unlike the design's aspect-ratio-1 frame. A square plate at the identity rail's
	-- full content width eats ~40% of the rail's visible height, which pushed tier progress -- the
	-- single most-referenced thing in the column -- below the fold on open. The figure is upright, so
	-- the width that gets given back was empty ground either side of it.
	Width: number,
	Height: number,
	-- Whose avatar to show. Omit (or pass nil) to render the drawn fallback instead -- see file
	-- header. Callers on the client pass `Players.LocalPlayer.UserId`, guarded, since LocalPlayer is
	-- nil on the server and this component is constructed by a headless smoke test.
	UserId: number?,
	LayoutOrder: UsedAs<number>?,
	-- Lights the chest core of the DRAWN FALLBACK only; the avatar path has no core to light.
	-- Defaults to the vitals' Qi cyan.
	CoreColor: UsedAs<Color3>?,
	BracketColor: UsedAs<Color3>?,
}

-- The drawing's own coordinate space. Sized so the figure occupies roughly the middle 60% of the
-- plate, leaving the rings room to breathe at the edges.
local STAGE_WIDTH = 120
local STAGE_HEIGHT = 150
local FIGURE_CENTER_X = 60

local BRACKET_ARM_LENGTH = 12
local BRACKET_ARM_THICKNESS = 1
local SCRIM_HEIGHT_FRACTION = 0.22

-- 420 is one of the sizes the thumbnail service actually serves for a bust; asking for an
-- unsupported size returns nothing at all rather than the nearest match, so this is not a number to
-- tune casually. It renders well below its native size on purpose -- a bust downsampled reads clean,
-- where upsampling one would put a soft head next to hairline chrome.
local AVATAR_THUMBNAIL = "rbxthumb://type=AvatarBust&id=%d&w=420&h=420"
-- The bust is drawn slightly larger than the plate is tall and hung off its bottom edge, so the
-- shoulders run out of frame under the scrim instead of floating with a gap beneath them.
local AVATAR_OVERSCAN = 1.18
local AVATAR_DROP = 1.06

-- One filled-and-stroked shape in stage coordinates, centred on (x, y). Every piece of the figure
-- is one of these, which is what keeps the drawing below readable as a list of parts.
local function shape(
	scope: Scope,
	name: string,
	x: number,
	y: number,
	width: number,
	height: number,
	options: {
		Color: UsedAs<Color3>,
		FillTransparency: number,
		StrokeTransparency: number,
		CornerRadius: UDim?,
		Rotation: number?,
		ZIndex: number?,
	}
): Frame
	return scope:New "Frame" {
		Name = name,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(x, y),
		Size = UDim2.fromOffset(width, height),
		Rotation = options.Rotation,
		ZIndex = options.ZIndex,
		BackgroundColor3 = options.Color,
		BackgroundTransparency = options.FillTransparency,
		BorderSizePixel = 0,

		[Children] = {
			scope:New "UICorner" {
				CornerRadius = options.CornerRadius or Tokens.Radius.Hairline,
			},
			scope:New "UIStroke" {
				Color = options.Color,
				Thickness = 1,
				Transparency = options.StrokeTransparency,
			},
		},
	} :: Frame
end

local function CharacterPortrait(scope: Scope, props: CharacterPortraitProps): Frame
	local accent = Tokens.Color.AccentPrimary
	local coreColor: UsedAs<Color3> = props.CoreColor or Tokens.VitalColor.Qi
	local bracketColor: UsedAs<Color3> = props.BracketColor or Tokens.Color.AccentSecondary
	local userId = props.UserId

	-- Fitted to whichever axis constrains first, so the drawing is always scaled uniformly -- a plate
	-- that is wider than it is tall shows more empty ground rather than a stretched figure.
	local stageScale = math.min(props.Width / STAGE_WIDTH, props.Height / STAGE_HEIGHT)

	local stageChildren: { Instance } = {
		scope:New "UIScale" {
			Scale = stageScale,
		},

		-- Two meridian rings. Drawn on BOTH paths -- they are the plate's own furniture rather than
		-- part of the fallback figure, and the avatar stands inside them exactly as the drawing does.
		-- No fill, stroke only, the outer one fainter, so they read as a diagram the subject is
		-- standing in rather than as a halo behind them.
		shape(scope, "RingOuter", FIGURE_CENTER_X, 78, 126, 126, {
			Color = accent,
			FillTransparency = 1,
			StrokeTransparency = 0.94,
			CornerRadius = UDim.new(1, 0),
			ZIndex = 1,
		}),
		shape(scope, "RingInner", FIGURE_CENTER_X, 78, 92, 92, {
			Color = accent,
			FillTransparency = 1,
			StrokeTransparency = 0.88,
			CornerRadius = UDim.new(1, 0),
			ZIndex = 1,
		}),
	}

	-- The drawn figure, built only when there is no avatar to show. A construction-time branch is
	-- correct here, unlike most state in this UI: UserId is known when the plate is built and cannot
	-- change for its lifetime, since a player's own id does not change mid-session.
	if not userId then
		local figure: { Instance } = {
			-- Sleeves first, so the robe body paints over where they meet the shoulders and the seam
			-- never shows. Rotated outward from vertical, which is what makes the figure read as
			-- standing with their hands folded rather than as a rectangle with two sticks.
			shape(scope, "SleeveLeft", FIGURE_CENTER_X - 26, 88, 16, 56, {
				Color = accent,
				FillTransparency = 0.93,
				StrokeTransparency = 0.72,
				CornerRadius = UDim.new(0, 7),
				Rotation = -12,
				ZIndex = 2,
			}),
			shape(scope, "SleeveRight", FIGURE_CENTER_X + 26, 88, 16, 56, {
				Color = accent,
				FillTransparency = 0.93,
				StrokeTransparency = 0.72,
				CornerRadius = UDim.new(0, 7),
				Rotation = 12,
				ZIndex = 2,
			}),

			-- The robe: a broad shoulder yoke over a longer body. Two pieces rather than one tapered
			-- silhouette because Roblox has no path fill -- the overlap is what suggests the taper.
			shape(scope, "Shoulders", FIGURE_CENTER_X, 62, 62, 26, {
				Color = accent,
				FillTransparency = 0.9,
				StrokeTransparency = 0.62,
				CornerRadius = UDim.new(0, 12),
				ZIndex = 3,
			}),
			shape(scope, "Robe", FIGURE_CENTER_X, 100, 52, 74, {
				Color = accent,
				FillTransparency = 0.92,
				StrokeTransparency = 0.68,
				CornerRadius = UDim.new(0, 10),
				ZIndex = 3,
			}),

			-- The head, at CornerRadius 1.0 so the Frame resolves to a true ellipse.
			shape(scope, "Head", FIGURE_CENTER_X, 30, 30, 34, {
				Color = accent,
				FillTransparency = 0.86,
				StrokeTransparency = 0.5,
				CornerRadius = UDim.new(1, 0),
				ZIndex = 4,
			}),

			-- The core, and the only warm point in the plate. Its glow is a sibling BELOW it (see
			-- Glow.lua's header on sibling ordering) so the halo never washes out the shape it is
			-- coming from.
			Glow(scope, {
				Color = coreColor,
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromOffset(FIGURE_CENTER_X, 92),
				Size = UDim2.fromOffset(14, 18),
				Rings = 3,
				Spread = 14,
				Transparency = 0.72,
				CornerRadius = UDim.new(1, 0),
				ZIndex = 4,
			}),
			shape(scope, "Core", FIGURE_CENTER_X, 92, 14, 18, {
				Color = coreColor,
				FillTransparency = 0.8,
				StrokeTransparency = 0.45,
				CornerRadius = UDim.new(1, 0),
				ZIndex = 5,
			}),
		}
		for _, piece in ipairs(figure) do
			table.insert(stageChildren, piece)
		end
	end

	local stage = scope:New "Frame" {
		Name = "Stage",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.52),
		Size = UDim2.fromOffset(STAGE_WIDTH, STAGE_HEIGHT),
		BackgroundTransparency = 1,
		ZIndex = 2,

		[Children] = stageChildren,
	}

	local brackets = CornerBracket.BuildAll(scope, {
		ArmLength = BRACKET_ARM_LENGTH,
		ArmThickness = BRACKET_ARM_THICKNESS,
		-- No rivets: this plate's brackets are the design's unornamented L, not hotbar-frame.svg's
		-- forged corner (see CornerBracket.lua's own note on the two vocabularies).
		Color = bracketColor,
		ZIndex = 6,
	})

	local children: { Instance } = {
		scope:New "UICorner" {
			CornerRadius = Tokens.Radius.Sharp,
		},
		scope:New "UIStroke" {
			Color = Tokens.Border.Standard.Color,
			Thickness = 1,
			Transparency = Tokens.Border.Standard.Transparency,
		},
		stage,
		-- The scrim: the plate's own fill fading up from the bottom edge, so the subject appears to
		-- stand IN the frame rather than being pasted onto it, and so the identity name below reads
		-- as continuing out of the portrait.
		scope:New "Frame" {
			Name = "Scrim",
			AnchorPoint = Vector2.new(0, 1),
			Position = UDim2.fromScale(0, 1),
			Size = UDim2.fromScale(1, SCRIM_HEIGHT_FRACTION),
			BackgroundColor3 = Tokens.Color.SurfaceElevated,
			BorderSizePixel = 0,
			ZIndex = 5,

			[Children] = scope:New "UIGradient" {
				Rotation = 90,
				Transparency = NumberSequence.new({
					NumberSequenceKeypoint.new(0, 1),
					NumberSequenceKeypoint.new(1, 0),
				}),
			},
		},
	}

	if userId then
		-- Above the rings (stage is ZIndex 2) and below the scrim (5), so the rings sit behind the
		-- subject and the scrim still fades their shoulders into the frame -- the same stacking the
		-- drawn figure gets, which is what keeps the two paths reading as one portrait.
		local avatarSide = math.round(props.Height * AVATAR_OVERSCAN)
		table.insert(
			children,
			scope:New "ImageLabel" {
				Name = "Avatar",
				AnchorPoint = Vector2.new(0.5, 1),
				Position = UDim2.fromScale(0.5, AVATAR_DROP),
				Size = UDim2.fromOffset(avatarSide, avatarSide),
				BackgroundTransparency = 1,
				BorderSizePixel = 0,
				ZIndex = 3,
				Image = string.format(AVATAR_THUMBNAIL, userId),
				-- Fit, not Stretch: a bust is square and the plate is not, and a stretched face is
				-- worse than empty ground beside one.
				ScaleType = Enum.ScaleType.Fit,
			}
		)
	end

	for _, bracket in ipairs(brackets) do
		table.insert(children, bracket)
	end

	return scope:New "Frame" {
		Name = "CharacterPortrait",
		Size = UDim2.fromOffset(props.Width, props.Height),
		LayoutOrder = props.LayoutOrder,
		BackgroundColor3 = Tokens.Color.SurfaceElevated,
		BorderSizePixel = 0,
		-- The rings are wider than the subject, the avatar deliberately overhangs the bottom edge,
		-- and the fallback's sleeves are rotated; all three would otherwise spill past the border.
		ClipsDescendants = true,

		[Children] = children,
	} :: Frame
end

return CharacterPortrait
