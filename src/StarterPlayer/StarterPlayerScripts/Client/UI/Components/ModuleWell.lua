--!strict
--[[
	ModuleWell.lua

	Owns: the recessed group box this UI puts around one cluster of readouts -- a RailScrim fill, a
	hairline corner, a hairline stroke, and an inset. Nothing else.

	Does NOT own: what goes in it, how the cluster is arranged beyond direction and gap, or whether a
	surface should be grouped at all. It is a container with a look, and the look is the whole of it.

	WHY IT EXISTS NOW AND NOT BEFORE. CLAUDE.md's bar for promoting a shared module is three
	independently hand-written call sites, and Screens/BlimpHelm/init.lua's own `well` helper
	pre-registered the trigger in as many words: "DELIBERATELY NOT A SHARED COMPONENT YET... this is
	the second. The third caller is what collapses these into Components/ModuleWell.lua; until then
	the tokens are the contract." Screens/BlimpFuel is the third. This is that collapse.

	The three were already drifting in the way three copies do -- not in the chrome, which was
	byte-identical, but in everything around it: the dock's group is a horizontal run that sizes to
	its contents on both axes and centres them, the helm's is a full-width column that sizes only its
	height. Both are correct for their caller, which is exactly why the shared thing has to take
	direction and sizing as arguments rather than picking one and making the other caller fight it.

	THE GROUPING IS THE CONTAINER, NOT A LINE BESIDE IT. Screens/HUD/init.lua reached this first and
	its `moduleGroup` comment is the canonical statement: the dock used to band itself with
	Divider.Plain rules and dropped them when the wells arrived, because "the container carries the
	grouping, so the line between two containers doesn't have to." A rule plus a well states the same
	thing twice, and on a console-sized panel two rules are a real fraction of the vertical budget.
	Spend a divider only BETWEEN wells, never inside one.

	THE CHILDREN ARE SAFE AMONG A Stack'S OWN because none of the three decorations is a GuiObject --
	a UIListLayout arranges GuiObject children only, which is the distinction Components/Layer.lua's
	header is about. That is why this can hand its caller's children straight through without a
	wrapper frame between the box and its contents.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)

local Tokens = require(script.Parent.Parent.Tokens)
local Stack = require(script.Parent.Stack)
local Inset = require(script.Parent.Inset)

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>

export type ModuleWellProps = {
	Name: string?,
	-- Defaults to "Vertical" -- a column of readouts, which is what a corner instrument holds. The
	-- dock passes "Horizontal" for its runs of vitals and ability slots.
	Direction: ("Vertical" | "Horizontal")?,
	-- Space between the children, in Tokens.Space steps. No default: how tightly a cluster packs is
	-- the caller's decision and the one number it is expected to think about, exactly as Stack's own
	-- Gap note says.
	Gap: number,
	-- Defaults per direction: a vertical well is full-width and sizes its own height (so a well whose
	-- rows collapse gets shorter rather than part-empty); a horizontal one sizes both axes to its
	-- contents. Pass explicitly to override either.
	Size: UsedAs<UDim2>?,
	AutomaticSize: Enum.AutomaticSize?,
	-- Cross-axis alignment, passed straight to Stack. A horizontal run of differently-tall readouts
	-- usually wants Center; a column almost never sets it.
	AlignX: Enum.HorizontalAlignment?,
	AlignY: Enum.VerticalAlignment?,
	-- The box's internal padding. Defaults to the tighter of the two shipped values (S/XS), which is
	-- what a corner instrument wants; the dock passes M/S because its modules hold 40px tiles and a
	-- tight inset would crowd them against the stroke.
	Inset: { X: number, Y: number }?,
	LayoutOrder: UsedAs<number>?,
	Visible: UsedAs<boolean>?,
	Children: UsedAs<{ Instance }>?,
}

-- The corner instrument's inset, and the default because two of the three callers want it. See the
-- Inset prop above for why the dock does not.
local DEFAULT_INSET = { X = Tokens.Space.S, Y = Tokens.Space.XS }

local function ModuleWell(scope: Scope, props: ModuleWellProps): Frame
	local direction = props.Direction or "Vertical"
	local isVertical = direction == "Vertical"
	local inset = props.Inset or DEFAULT_INSET

	local build = if isVertical then Stack.New else Stack.Row

	return build(scope, {
		Name = props.Name,
		Gap = props.Gap,
		AlignX = props.AlignX,
		AlignY = props.AlignY,
		-- A vertical well fills the column it is dropped in and grows downward; a horizontal one is
		-- as wide and as tall as what it holds. Both are content-driven on at least one axis, which
		-- is the property that lets a well shrink when its cluster does.
		Size = props.Size or (if isVertical then UDim2.fromScale(1, 0) else UDim2.fromOffset(0, 0)),
		AutomaticSize = props.AutomaticSize or (if isVertical then Enum.AutomaticSize.Y else Enum.AutomaticSize.XY),
		LayoutOrder = props.LayoutOrder,
		Visible = props.Visible,
		BackgroundColor3 = Tokens.Wash.RailScrim.Color,
		BackgroundTransparency = Tokens.Wash.RailScrim.Transparency,

		Children = {
			scope:New("UICorner")({
				CornerRadius = Tokens.Radius.Hairline,
			}),
			scope:New("UIStroke")({
				Color = Tokens.Border.Hairline.Color,
				Transparency = Tokens.Border.Hairline.Transparency,
				Thickness = 1,
			}),
			Inset(scope, inset),
			props.Children,
		},
	})
end

return ModuleWell
