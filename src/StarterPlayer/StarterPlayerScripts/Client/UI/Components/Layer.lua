--!strict
--[[
	Layer.lua

	Owns: the separation between children a layout ARRANGES and children pinned to the CONTAINER.

	A UIListLayout positions every GuiObject child of the frame it sits in. Not the ones the caller
	was thinking of -- every one. That single fact caused three separate bugs during the character
	menu rebuild, all with the same shape and all found by eye rather than by any tool:

	  * the tab strip's closing rule was swept into the tab row as a fifth flow item, which pushed
	    the fourth tab clean off the panel;
	  * StatusTag's leading edge bar landed inside its own text run;
	  * the header and footer band rules were inset by the band's UIPadding instead of spanning the
	    panel, so each read as a stray underline rather than as the seam between two bands.

	Each was fixed by hand-writing a nested wrapper frame. That wrapper is the whole of this module.
	With 171 UIListLayout instances in this tree, the pattern is a recurring bug class rather than
	three accidents (docs/architecture/2026-08-20-ui-velocity-plan.md section 2.2).

		Layer(scope, {
			Size = UDim2.new(1, 0, 0, TAB_STRIP_HEIGHT),
			Content = Stack.Row(scope, { Children = tabButtons }),
			Over = { bandRule(scope, "Bottom"), closeButton },
		})

	Content fills the Layer and owns its own layout. Over and Under are siblings of it, in their own
	frames, which no layout ever touches -- so a rule anchored to the container's bottom edge lands on
	the container's bottom edge, by construction rather than by remembering.

	WHY WRAPPER FRAMES rather than assigning ZIndex to the passed instances: those instances were
	built by whichever component the caller called, and reaching into another component's instance to
	rewrite a property is how two files end up disagreeing about who owns it -- the same call
	Components/SectionHeading.lua's Accessory holder already makes. The cost is two Frames per Layer,
	both transparent and neither laid out.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)

local Children = Fusion.Children

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>

export type LayerProps = {
	Name: string?,
	Size: UsedAs<UDim2>?,
	Position: UsedAs<UDim2>?,
	AnchorPoint: UsedAs<Vector2>?,
	LayoutOrder: UsedAs<number>?,
	Visible: UsedAs<boolean>?,
	ClipsDescendants: boolean?,
	BackgroundColor3: UsedAs<Color3>?,
	BackgroundTransparency: UsedAs<number>?,
	-- Painted behind Content. Surface textures, bloom, a full-bleed fill.
	Under: { Instance }?,
	-- The arranged body -- typically a Stack. Exactly one instance, because "the thing the layout
	-- owns" is singular by definition; a caller with two of them wants a Stack holding both.
	Content: Instance?,
	-- Pinned to this container and untouched by any layout: closing rules, corner brackets, a close
	-- button, an overlay scrim. Each positions itself with its own AnchorPoint/Position against the
	-- Layer's own box.
	Over: { Instance }?,
}

-- Under sits below Content sits below Over. Explicit rather than relying on insertion order --
-- Roblox renders same-ZIndex siblings in an unspecified order, the same reason Bar.lua's glow
-- carries an explicit lower value than the fill it sits behind.
local UNDER_Z = 1
local CONTENT_Z = 2
local OVER_Z = 3

-- A transparent, full-size, layout-free holder. Both slots need exactly this, and neither may ever
-- grow a UIListLayout -- that would reintroduce the bug this module exists to close.
local function pinnedHolder(scope: Scope, name: string, zIndex: number, contents: { Instance }): Frame
	return scope:New "Frame" {
		Name = name,
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ZIndex = zIndex,

		[Children] = contents,
	} :: Frame
end

local function Layer(scope: Scope, props: LayerProps): Frame
	local layerChildren: { Instance } = {}

	if props.Under and #props.Under > 0 then
		table.insert(layerChildren, pinnedHolder(scope, "Under", UNDER_Z, props.Under))
	end

	if props.Content then
		-- Wrapped for the same reason the two holders are: this sets the ZIndex that orders the three
		-- bands, and it sets it on a frame this module owns rather than on the caller's instance.
		table.insert(layerChildren, pinnedHolder(scope, "Content", CONTENT_Z, { props.Content }))
	end

	if props.Over and #props.Over > 0 then
		table.insert(layerChildren, pinnedHolder(scope, "Over", OVER_Z, props.Over))
	end

	return scope:New "Frame" {
		Name = props.Name or "Layer",
		Position = props.Position,
		AnchorPoint = props.AnchorPoint,
		Size = props.Size or UDim2.fromScale(1, 1),
		LayoutOrder = props.LayoutOrder,
		Visible = props.Visible,
		ClipsDescendants = props.ClipsDescendants,
		BackgroundColor3 = props.BackgroundColor3,
		BackgroundTransparency = if props.BackgroundTransparency ~= nil then props.BackgroundTransparency else 1,
		BorderSizePixel = 0,

		[Children] = layerChildren,
	} :: Frame
end

return Layer
