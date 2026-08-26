--!strict
--[[
	DraftBinding.lua

	Owns: the primitives every Move Editor form panel is built out of, so all of them
	(PropertyEditor.lua and the HitboxEditor/AnimationTimelineEditor/ObjectStunEditor/EffectsEditor/
	ArtBindingEditor sub-panels it hosts) share one implementation instead of six copies:

	  * Apply   -- clone the current draft, mutate exactly the field that changed, hand the whole
	               record to OnFieldChanged. Every control in every panel commits through this.
	  * Field   -- read one field off the current draft as a Computed, falling back to a default while
	               nothing is selected, so no control ever has to nil-check its own Value prop.
	  * Row     -- lay related controls out side by side in N even columns.
	  * Stack   -- lay a variable number of children out vertically.
	  * TextRow -- a labelled string field that reseeds from the draft and commits on FocusLost.

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
local Tokens = require(script.Parent.Parent.Parent.Parent.Tokens)
local Label = require(script.Parent.Parent.Parent.Parent.Components.Label)
local TextField = require(script.Parent.Parent.Parent.Parent.Components.TextField)

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

-- Four Body-scale lines plus the box's own padding -- enough for the two or three sentences a
-- field like a move's Description actually attracts, without the box dominating a section that
-- also has to show real controls.
local MULTILINE_HEIGHT = 88

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
-- Screens/DevTools/DevMenu/ContentArea.lua's own Godmode/Flight/Collide row established, generalized to any
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

-- A labelled single-line string field over the draft: display name, category, an animation id, an
-- art's prerequisite. Three files had independently grown the same shape before this existed --
-- PropertyEditor.lua's TextFieldRow, ObjectStunEditor.lua's stunTextRow, and the Art section's copy
-- of the first -- because none of it is expressible as a Computed: TextField.lua owns a real
-- Fusion.Value that it writes into as the author types, so the row has to hold that Value itself and
-- RESEED it whenever the draft changes underneath (a move switch, a server reconcile). Getting that
-- reseed wrong is invisible until an admin switches moves and the old text is still sitting there.
--
-- The caller owns the WRITE (OnCommit), not just the value: a row over a top-level field commits
-- through a plain Apply, while one over a sub-table has to go through that sub-table's own
-- clone-then-mutate helper (ObjectStunEditor's applyStun, EffectsEditor's applyToSubTable). Taking a
-- `(draft, text) -> ()` setter instead would have to run inside Apply and could not reach those.
export type TextRowProps = {
	Label: string,
	LayoutOrder: number,
	-- Reads this row's current text off the draft. Re-run on every draft change to reseed the field.
	Get: (MoveDefinition) -> string,
	-- Called with the committed text on FocusLost -- never per keystroke, so a half-typed id never
	-- reaches the draft (and, through it, the debounced UpdateDraft).
	OnCommit: (string) -> (),
	Placeholder: string?,
	-- A wrapping, fixed-height box instead of a single line -- for a field whose content is prose
	-- rather than an identifier. The height is fixed rather than auto-grown because the box lives
	-- inside a ScrollingFrame with AutomaticCanvasSize: a box that grows as you type re-measures the
	-- canvas and slides the cursor out from under the pointer mid-sentence.
	Multiline: boolean?,
	-- Caps what can be typed, enforced by TextField itself. Only meaningful for a field the server
	-- also bounds -- pass the SAME number the server truncates at, or the box will accept text the
	-- save silently shortens.
	MaxLength: number?,
	Visible: Fusion.UsedAs<boolean>?,
	-- Mounts a plain read-only Label where the TextField would go. Both are built up front and
	-- Visible-toggled, rather than teaching TextField.lua a disabled state it has no prop for.
	ReadOnly: Fusion.UsedAs<boolean>?,
}

function DraftBinding.TextRow(scope: Scope, context: DraftContext, props: TextRowProps): Frame
	local localText = scope:Value("")
	local function reseed(): ()
		local draft = peek(context.Draft)
		localText:set(if draft then props.Get(draft) else "")
	end
	scope:Observer(context.Draft):onChange(reseed)
	-- Once up front too, not only on change: a row mounted while a draft is ALREADY selected would
	-- otherwise render blank until the next edit reseeded it.
	reseed()

	local readOnly: Fusion.UsedAs<boolean> = if props.ReadOnly == nil then false else props.ReadOnly
	local editableVisible = scope:Computed(function(use)
		return not use(readOnly)
	end)

	return scope:New "Frame" {
		Name = props.Label,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		LayoutOrder = props.LayoutOrder,
		Visible = if props.Visible == nil then true else props.Visible,

		[Children] = {
			scope:New "UIListLayout" {
				FillDirection = Enum.FillDirection.Vertical,
				Padding = UDim.new(0, Tokens.Space.XS),
				SortOrder = Enum.SortOrder.LayoutOrder,
			},
			Label(scope, { Text = props.Label, Scale = "Body", Color = Tokens.Color.TextPrimary, LayoutOrder = 1 }),
			-- TextField.lua has no Visible prop of its own -- wrapped in a plain Frame so the editable and
			-- read-only presentations can be mounted-both/Visible-toggled without widening that API.
			scope:New "Frame" {
				Name = "Editable",
				Size = UDim2.fromScale(1, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				BackgroundTransparency = 1,
				LayoutOrder = 2,
				Visible = editableVisible,

				[Children] = TextField(scope, {
					Text = localText,
					PlaceholderText = props.Placeholder,
					Multiline = props.Multiline,
					MaxLength = props.MaxLength,
					Size = if props.Multiline
						then UDim2.new(1, 0, 0, MULTILINE_HEIGHT)
						else UDim2.new(1, 0, 0, Tokens.Control.RowHeight),
					OnFocusLost = props.OnCommit,
				}),
			},
			Label(scope, {
				Text = localText,
				Scale = "Body",
				Color = Tokens.Color.TextSecondary,
				LayoutOrder = 2,
				Visible = readOnly,
			}),
		},
	} :: Frame
end

-- Wraps a child that has no Visible prop of its own in a full-width, auto-height Frame that does.
-- Components/Dropdown.lua and TextRow above both predate any caller needing to hide them reactively;
-- giving each its own Visible prop for a handful of call sites would widen two shared APIs where one
-- wrapper does the same job. Collapses to zero height when hidden, so the section's UIListLayout
-- closes the gap rather than leaving a hole.
function DraftBinding.VisibleWhen(
	scope: Scope,
	layoutOrder: number,
	visible: Fusion.UsedAs<boolean>,
	child: Instance
): Frame
	return scope:New "Frame" {
		Name = "VisibleWhen",
		LayoutOrder = layoutOrder,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		Visible = visible,

		[Children] = {
			scope:New "UIListLayout" {
				FillDirection = Enum.FillDirection.Vertical,
				SortOrder = Enum.SortOrder.LayoutOrder,
			},
			child,
		},
	} :: Frame
end

return DraftBinding
