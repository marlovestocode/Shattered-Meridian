--!strict
--[[
	StatusTag.lua

	Owns: the small filled caps chip the character menu uses wherever a single fact needs to sit
	beside other facts without becoming a row of its own -- a race, a faction, "NO ACTIVE EFFECTS",
	"CORRUPTION 0", a bounty's ACTIVE/EXPIRED state, an art's LOCKED marker.

	One hue drives the whole chip. The design expresses a tag as its color at three strengths -- so
	this takes a single Color and derives all of them rather than asking each call site to hand-type
	a matching set, which is exactly the drift Tokens.lua's own Tint type exists to prevent one layer
	down.

	A BADGE MUST NOT LOOK LIKE A BUTTON, and the first version of this component did (user, 2026-08-20:
	"make buttons actually have interactions or obvious its a badge"). It drew the design's 25% outline
	over a 3% fill, which is stroke-on-near-nothing -- the exact silhouette Components/Button.lua's
	Secondary variant uses. Eight inert tags and a real action control were indistinguishable, so a
	locked art's "LOCKED" marker read as something you could press.

	The split is now structural rather than a matter of degree:
	  * A badge is FILLED and has NO outline, plus a solid 2px bar down its leading edge. It is a
	    painted label -- flat, inert, nothing to press.
	  * A button is OUTLINED over a neutral wash and lights up under the cursor (Button.lua).
	Nothing here responds to hover, and that is the point.

	TRACKED IS OPT-IN, AND THE REASON IS TrackedLabel'S. Components/TrackedLabel.lua renders one
	TextLabel per character and therefore reads its string ONCE at construction (see its header), so
	a chip whose text is live -- a corruption number, a race that arrives with the character sheet a
	second after the menu mounts -- would freeze at whatever it happened to say on mount. Those pass
	a reactive Label and get a single TextLabel in the same Chip face at the same size, losing only
	the letter-spacing. Genuinely static chips pass Tracked = true and get the real tracked run. Same
	call Tab.lua's own TrackedCaps flag already makes, for the same reason.

	Does not own: layout. A chip is AutomaticSize.X at a fixed height, so a caller arranges runs of
	them with its own UIListLayout (Wraps = true where a row can overflow) rather than this component
	guessing at a wrap width.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Tokens = require(script.Parent.Parent.Tokens)
local TrackedLabel = require(script.Parent.TrackedLabel)

local Children = Fusion.Children
local peek = Fusion.peek

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>

export type StatusTagProps = {
	-- Uppercased on the way in either path, so callers write it in whatever case reads best in source.
	Label: UsedAs<string>,
	-- Drives fill, leading edge and text together -- see file header. Defaults to the muted text
	-- color, which is this UI's neutral chip.
	Color: UsedAs<Color3>?,
	-- Static text only. See file header before setting this.
	Tracked: boolean?,
	LayoutOrder: UsedAs<number>?,
	Visible: UsedAs<boolean>?,
	ZIndex: UsedAs<number>?,
}

-- The one hue at two strengths: a fill you can actually see (14%, up from the design's 3% -- at 3%
-- the outline was carrying the whole shape, which is what made it read as a button) and the solid
-- leading edge.
local FILL_TRANSPARENCY = 0.86
local EDGE_WIDTH = 2

-- Fixed so a row of chips lines up regardless of which of the two text paths each one took --
-- TrackedLabel's per-glyph frames and a plain TextLabel do not measure to the same height on their
-- own. Deliberately well under Tokens.Control.StepButtonSize: a badge is shorter than any button in
-- this UI, so the two never line up in a row and read as siblings.
local HEIGHT = 24
local PADDING_LEFT = 9
local PADDING_RIGHT = 9

local function StatusTag(scope: Scope, props: StatusTagProps): Frame
	local color: UsedAs<Color3> = props.Color or Tokens.Color.TextSecondary

	local content: Instance
	if props.Tracked then
		content = TrackedLabel(scope, {
			-- Peek'd once -- see file header.
			Text = string.upper(peek(props.Label)),
			Scale = "Chip",
			Color = color,
			LayoutOrder = 3,
			ZIndex = props.ZIndex,
		})
	else
		local chipStep = Tokens.Type.Chip
		content = scope:New "TextLabel" {
			Name = "Label",
			Size = UDim2.fromOffset(0, chipStep.Size + 2),
			AutomaticSize = Enum.AutomaticSize.X,
			BackgroundTransparency = 1,
			LayoutOrder = 3,
			ZIndex = props.ZIndex,
			Text = scope:Computed(function(use)
				return string.upper(use(props.Label))
			end),
			FontFace = chipStep.Face,
			TextSize = chipStep.Size,
			TextColor3 = color,
			TextXAlignment = Enum.TextXAlignment.Left,
		}
	end

	return scope:New "Frame" {
		Name = "StatusTag",
		Size = UDim2.fromOffset(0, HEIGHT),
		AutomaticSize = Enum.AutomaticSize.X,
		LayoutOrder = props.LayoutOrder,
		Visible = props.Visible,
		ZIndex = props.ZIndex,
		BackgroundColor3 = color,
		BackgroundTransparency = FILL_TRANSPARENCY,
		BorderSizePixel = 0,

		[Children] = {
			scope:New "UICorner" {
				CornerRadius = Tokens.Radius.Sharp,
			},
			-- A UIListLayout rather than scale-positioned children: AutomaticSize.X resolves reliably
			-- against a layout's measured content, and does not against a child that anchors itself
			-- to a fraction of the very width being measured.
			--
			-- The inset is spacer Frames in the run rather than a UIPadding on this frame, because a
			-- UIPadding insets EVERY child -- including the leading edge, which has to touch the tag's
			-- actual left border to read as part of its silhouette instead of as a stripe floating
			-- inside it.
			scope:New "UIListLayout" {
				FillDirection = Enum.FillDirection.Horizontal,
				HorizontalAlignment = Enum.HorizontalAlignment.Left,
				VerticalAlignment = Enum.VerticalAlignment.Center,
				SortOrder = Enum.SortOrder.LayoutOrder,
			},
			scope:New "Frame" {
				Name = "Edge",
				Size = UDim2.new(0, EDGE_WIDTH, 1, 0),
				BackgroundColor3 = color,
				BorderSizePixel = 0,
				LayoutOrder = 1,
			},
			scope:New "Frame" {
				Name = "LeadIn",
				Size = UDim2.fromOffset(PADDING_LEFT, HEIGHT),
				BackgroundTransparency = 1,
				LayoutOrder = 2,
			},
			content,
			scope:New "Frame" {
				Name = "LeadOut",
				Size = UDim2.fromOffset(PADDING_RIGHT, HEIGHT),
				BackgroundTransparency = 1,
				LayoutOrder = 4,
			},
		},
	} :: Frame
end

return StatusTag
