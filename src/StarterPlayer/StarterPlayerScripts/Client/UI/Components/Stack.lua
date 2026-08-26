--!strict
--[[
	Stack.lua

	Owns: the one-dimensional layout container -- a Frame plus its UIListLayout, plus the ability for
	exactly one child to absorb whatever height (or width) the others left over.

	THIS EXISTS TO DELETE LAYOUT ARITHMETIC. Before it, every scrolling container in this UI computed
	its own size by subtracting a hand-summed constant from its parent:

		local HEADER_ALLOWANCE = HEADING_HEIGHT * 2 + SLOT_STRIP_HEIGHT + TREE_STRIP_HEIGHT
			+ DESCRIPTION_ALLOWANCE + GAP * 5
		ScrollArea(scope, { Size = UDim2.new(1, 0, 1, -HEADER_ALLOWANCE) })

	There were ten of those (docs/architecture/2026-08-20-ui-velocity-plan.md section 2.1). Each is
	correct for exactly one set of child heights, and raising a single Tokens.Type step by one pixel
	invalidates every one of them silently -- no compile error, no runtime error, just a container
	that clips or leaves a gap until someone opens Studio and notices. That plan's own type passes
	re-derived all ten by hand three times in one session.

		Stack.New(scope, {
			Gap = Tokens.Space.S,
			Children = {
				SectionHeading(scope, { Text = "Arts" }),
				treeStrip,
				description,
				Stack.Fill(scope, rowsScrollArea),   -- takes whatever is left
			},
		})

	Stack.Fill attaches a UIFlexItem in Fill mode, which is the engine's own answer to this and was
	used ZERO times in this codebase before now. The layout resolves it; nothing here measures
	anything, so nothing here can be wrong about a measurement.

	WHAT IT DOES NOT OWN, deliberately:
	- Padding. That is Components/Inset.lua, dropped into Children like any other layout modifier --
	  a container that also owned its own inset would need four more props on every call site that
	  does not want one.
	- Anything positioned against the CONTAINER rather than the flow (a closing rule, a pinned close
	  button, a background texture). A UIListLayout arranges every GuiObject child of the frame it
	  sits in, so those belong in Components/Layer.lua's Over/Under slots instead. Putting one in a
	  Stack's Children is the exact bug that hit three separate times during the character menu
	  rebuild -- see Layer.lua's own header.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)

local Children = Fusion.Children

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>

local Stack = {}

export type StackProps = {
	Name: string?,
	-- Defaults to "Vertical". Stack.Row below is the same thing with this preset, for call sites
	-- where the direction is the most important thing about the container.
	Direction: ("Vertical" | "Horizontal")?,
	-- Space between children, in pixels. A Tokens.Space step, always -- this is the one number a
	-- caller is expected to pass, and it is why the ten allowance constants could stop counting gaps.
	Gap: number?,
	-- Cross-axis alignment. The default for each is the start edge (Left / Top), which is what every
	-- list in this UI wants; a centred row passes them explicitly.
	AlignX: Enum.HorizontalAlignment?,
	AlignY: Enum.VerticalAlignment?,
	-- Wraps a horizontal run onto further lines. Off by default.
	Wraps: boolean?,
	-- Defaults to filling the parent. A Stack that is itself a child of another Stack usually wants
	-- UDim2.new(1, 0, 0, <its own height>) instead, or AutomaticSize.Y with a scale-1 width.
	Size: UsedAs<UDim2>?,
	Position: UsedAs<UDim2>?,
	AnchorPoint: UsedAs<Vector2>?,
	AutomaticSize: Enum.AutomaticSize?,
	LayoutOrder: UsedAs<number>?,
	Visible: UsedAs<boolean>?,
	ClipsDescendants: boolean?,
	-- Omit both for the usual transparent container.
	BackgroundColor3: UsedAs<Color3>?,
	BackgroundTransparency: UsedAs<number>?,
	Children: UsedAs<{ Instance }>?,
}

local function build(scope: Scope, props: StackProps, direction: "Vertical" | "Horizontal"): Frame
	local isVertical = direction == "Vertical"

	return scope:New "Frame" {
		Name = props.Name or (if isVertical then "Stack" else "Row"),
		Position = props.Position,
		AnchorPoint = props.AnchorPoint,
		Size = props.Size or UDim2.fromScale(1, 1),
		AutomaticSize = props.AutomaticSize,
		LayoutOrder = props.LayoutOrder,
		Visible = props.Visible,
		ClipsDescendants = props.ClipsDescendants,
		BackgroundColor3 = props.BackgroundColor3,
		BackgroundTransparency = if props.BackgroundTransparency ~= nil then props.BackgroundTransparency else 1,
		BorderSizePixel = 0,

		[Children] = {
			scope:New "UIListLayout" {
				FillDirection = if isVertical then Enum.FillDirection.Vertical else Enum.FillDirection.Horizontal,
				Padding = UDim.new(0, props.Gap or 0),
				HorizontalAlignment = props.AlignX or Enum.HorizontalAlignment.Left,
				VerticalAlignment = props.AlignY or Enum.VerticalAlignment.Top,
				Wraps = props.Wraps,
				-- LayoutOrder, never child order: a caller that inserts a conditional child mid-list
				-- must not have every sibling after it silently renumber.
				SortOrder = Enum.SortOrder.LayoutOrder,
			},
			props.Children,
		},
	} :: Frame
end

-- A vertical stack. The common case, and the one that replaces the allowance math.
function Stack.New(scope: Scope, props: StackProps): Frame
	return build(scope, props, props.Direction or "Vertical")
end

-- A horizontal run. Identical to Stack.New with Direction = "Horizontal"; it exists because at a
-- call site the direction IS the point, and reading it off a prop three lines down is how a row ends
-- up written as a column.
function Stack.Row(scope: Scope, props: StackProps): Frame
	return build(scope, props, "Horizontal")
end

-- Marks `child` as the one that absorbs whatever space the fixed-size siblings left over. Returns
-- the same instance so it can be written inline in a Children list.
--
-- MUTATES NOTHING AND MEASURES NOTHING. It parents a UIFlexItem to the child and the engine's own
-- layout does the rest -- which is the entire reason this is trustworthy where a computed size was
-- not. A computed size is a claim about how tall five other things are; this is a request to the
-- thing that already knows.
--
-- WORKS ON ANY CHILD OF ANY UIListLayout, not only on a Stack's. Four call sites rely on that:
-- Components/Panel.lua owns a list layout of its own (Screens/MoveEditor/Sidebar.lua and
-- PreviewViewport.lua both fill inside one), Components/ModalScreen.lua does too (Components/
-- ScreenFrame.lua's body band fills inside THAT), and Screens/Onboarding/CreatorFrame.lua's panel is
-- a third. The flex item is a property of the child and the layout above it, so a container this
-- module did not build is no different to the engine -- and marking one is still strictly better than
-- the subtraction it replaces, whoever owns the layout.
--
-- At most one Fill child per Stack in practice. Two is legal (they split the remainder) but has no
-- caller here, and a list with two "whatever is left" children usually means the layout wanted a
-- different shape.
function Stack.Fill(scope: Scope, child: GuiObject): GuiObject
	scope:New "UIFlexItem" {
		FlexMode = Enum.UIFlexMode.Fill,
		Parent = child,
	}
	return child
end

return Stack
