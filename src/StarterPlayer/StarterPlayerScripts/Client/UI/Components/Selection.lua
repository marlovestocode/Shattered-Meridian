--!strict
--[[
	Components/Selection.lua

	Owns: the one fact every interactive primitive in this codebase renders its "the player is on
	this control right now" treatment from -- which is TWO facts, not one, the moment a gamepad is
	in play: the mouse is over it, OR the gamepad's selection has landed on it.

	WHY THIS EXISTS RATHER THAN A SECOND Value PER COMPONENT. Seven components (Button, Tab, Toggle,
	Dropdown, Stepper, ActionIcon, and the screens that hand-roll the same shape) each already had a
	`local isHovering = scope:Value(false)` driven off MouseEnter/MouseLeave, and each fed it into
	between two and six visual Computeds. Adding gamepad selection meant, in each of them, a second
	Value plus an edit to every one of those Computeds to read `hover or selected` -- roughly forty
	edited Computeds, every one of which is a place to miss one. `Active` below is that OR, computed
	once, so the components' existing Computeds are untouched: they keep reading a single boolean and
	no longer care which device produced it. This is the same argument Components/KeyCap.lua's own
	header makes about three surfaces hand-rolling one key well.

	EVERY GuiButton IN THIS CODEBASE SETS AutoButtonColor = false, so there is no engine-provided
	selection feedback to fall back on -- a gamepad player with no `Selected` wiring sees literally
	nothing move as they traverse a panel. That is not a polish gap, it is the difference between a
	navigable menu and an unusable one, which is why this is baked into the primitives rather than
	remembered per screen (docs/ui-ux-philosophy.md's rule; Components/Bar.lua's CriticalBelow is the
	template).

	SELECTION AND HOVER SHARE ONE TREATMENT DELIBERATELY. They are the same sentence to the player --
	"this is the control you are about to act on" -- and a distinct third visual state would have to
	be designed, tokenised and then justified at every call site. They also cannot meaningfully occur
	at once: a player is driving a mouse or a pad, not both. Keeping them as two SEPARATE Values that
	are OR-ed (rather than one Value both sources write) is what makes the impossible case behave
	anyway -- a mouse resting over control A while the pad selects control B leaves A lit until the
	mouse moves, instead of B's selection-lost silently clearing A's hover.

	Does NOT own: setting GuiService.SelectedObject, the traversal graph, or which control a panel
	focuses first -- all of that is Shell/Focus.lua's job. This file is only the per-control state
	those selections land on, and it is deliberately usable by a component that Focus never touches.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)

type Scope = Fusion.Scope<typeof(Fusion)>

export type SelectionState = {
	-- What a component's visual Computeds should read. True while the pointer is over the control OR
	-- the gamepad selection is on it.
	Active: Fusion.Computed<boolean>,
	-- Driven by the component's own MouseEnter/MouseLeave handlers.
	PointerOver: Fusion.Value<boolean>,
	-- Driven by the component's own SelectionGained/SelectionLost handlers.
	Selected: Fusion.Value<boolean>,
}

local Selection = {}

-- Builds the pair plus the OR over them. A component calls this once, in place of the
-- `scope:Value(false)` it used to declare for hover, and binds all four events below to the two
-- Values -- see this file's header for why they stay separate.
function Selection.New(scope: Scope): SelectionState
	local pointerOver: Fusion.Value<boolean> = scope:Value(false)
	local selected: Fusion.Value<boolean> = scope:Value(false)

	return {
		Active = scope:Computed(function(use): boolean
			return use(pointerOver) or use(selected)
		end),
		PointerOver = pointerOver,
		Selected = selected,
	}
end

return Selection
