--!strict
--[[
	DraftBinding.lua

	Owns: the three primitives every Move Editor form panel is built out of, so the four of them
	(PropertyEditor.lua and the HitboxEditor/AnimationTimelineEditor/ObjectStunEditor sub-panels it
	hosts) share one implementation instead of four copies:

	  * Apply  -- clone the current draft, mutate exactly the field that changed, hand the whole
	              record to OnFieldChanged. Every control in every panel commits through this.
	  * Field  -- read one field off the current draft as a Computed, falling back to a default while
	              nothing is selected, so no control ever has to nil-check its own Value prop.
	  * Row    -- lay related controls out side by side in N even columns.

	These lived as file-local helpers in PropertyEditor.lua while it was the only form panel. Once
	the hitbox, animation-timeline and object-stun editors became their own files -- each of which is
	a form over the same draft -- they had to be shared or triplicated, and triplicating the
	clone-then-mutate rule in particular is how a panel ends up quietly mutating the PREVIOUS draft
	in place (see Apply's own header for why that is worse than it sounds).

	Does not own: the draft itself, or what happens after OnFieldChanged fires -- MoveEditor/init.lua
	owns both (it sets its own Draft value optimistically and forwards the same record to
	MoveEditorClient.lua, which debounces the network call). No panel here ever talks to a remote.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local MoveTypes = require(ReplicatedStorage.Shared.MoveTypes)
local Tokens = require(script.Parent.Parent.Parent.Tokens)

local Children = Fusion.Children
local peek = Fusion.peek

type Scope = Fusion.Scope<typeof(Fusion)>
type MoveDefinition = MoveTypes.MoveDefinition

-- The minimum every form panel needs from its host: what to read, and where to send an edit. Panels
-- take this rather than the two fields separately so adding a third shared concern later doesn't
-- mean re-threading four call sites.
export type DraftContext = {
	Draft: Fusion.Value<MoveDefinition?>,
	OnFieldChanged: (MoveDefinition) -> (),
}

local DraftBinding = {}

-- Clone-then-mutate-then-publish. The clone is SHALLOW, which is exactly why every caller mutating
-- a SUB-table (Dimensions, Knockback, ObjectStun, a clip) must clone that sub-table too before
-- touching it: a shallow clone copies only the top-level field references, so writing through
-- `updated.Dimensions.Width` would also rewrite the OLD draft's Dimensions -- the same table object
-- still held by whatever last received that draft (MoveList's own MovesDisplay cache, for one) --
-- out from under it. Panels do this explicitly at each site rather than deep-cloning here, because
-- deep-cloning the whole record on every keystroke of a slider drag is real cost for a guarantee
-- only a handful of fields need.
function DraftBinding.Apply(context: DraftContext, mutate: (MoveDefinition) -> ()): ()
	local current = peek(context.Draft)
	if not current then
		return
	end
	local updated = table.clone(current)
	mutate(updated)
	context.OnFieldChanged(updated)
end

function DraftBinding.Field<T>(
	context: DraftContext,
	scope: Scope,
	getter: (MoveDefinition) -> T,
	default: T
): Fusion.Computed<T>
	return scope:Computed(function(use)
		local draft = use(context.Draft)
		return if draft then getter(draft) else default
	end)
end

-- Groups related controls side by side into `columns` even cells -- the fractional-width idiom
-- Screens/DevMenu/ContentArea.lua's own Godmode/Flight/Collide row established, generalized to any
-- column count.
--
-- A row never needs its own Visible prop: when every control in it shares one Visible condition
-- (e.g. all three Size fields are Visible=isBox), each cell collapses to zero height when that
-- condition is false and the row disappears with them.
function DraftBinding.Row(scope: Scope, layoutOrder: number, columns: number, fields: { Instance }): Frame
	local cells: { Instance } = {
		scope:New "UIListLayout" {
			FillDirection = Enum.FillDirection.Horizontal,
			Padding = UDim.new(0, Tokens.Space.XS),
			SortOrder = Enum.SortOrder.LayoutOrder,
		},
	}
	for index, field in ipairs(fields) do
		table.insert(
			cells,
			scope:New "Frame" {
				Name = "Cell" .. index,
				Size = UDim2.new(1 / columns, -Tokens.Space.XS, 0, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				BackgroundTransparency = 1,
				LayoutOrder = index,

				[Children] = field,
			}
		)
	end

	return scope:New "Frame" {
		Name = "FieldRow",
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		LayoutOrder = layoutOrder,

		[Children] = cells,
	} :: Frame
end

-- A plain vertical stack, for a panel assembling a variable number of children (a clip list, a
-- shape's dimension fields) where the count isn't known until render. Saves each of them
-- hand-rolling the same Frame + UIListLayout pair.
function DraftBinding.Stack(scope: Scope, layoutOrder: number, spacing: number, children: { Instance }): Frame
	local stacked: { Instance } = {
		scope:New "UIListLayout" {
			FillDirection = Enum.FillDirection.Vertical,
			HorizontalAlignment = Enum.HorizontalAlignment.Left,
			Padding = UDim.new(0, spacing),
			SortOrder = Enum.SortOrder.LayoutOrder,
		},
	}
	for _, child in ipairs(children) do
		table.insert(stacked, child)
	end

	return scope:New "Frame" {
		Name = "Stack",
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		LayoutOrder = layoutOrder,

		[Children] = stacked,
	} :: Frame
end

return DraftBinding
