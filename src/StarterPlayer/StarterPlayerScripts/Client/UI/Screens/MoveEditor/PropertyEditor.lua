--!strict
--[[
	PropertyEditor.lua

	Owns: the Move Editor's content pane -- the full authoring form for whichever move is currently
	selected (props.Draft), now split by Sidebar.lua's Sections nav instead of one long scroll. A
	persistent toolbar (Test on Dummy / Save / Hotbar bind row / last-test-result) sits at the top
	regardless of which section is active; below it, exactly one of 9 Section(scope,...)-wrapped
	"detail pages" is Visible at a time (props.SelectedSection, owned by Sidebar.lua), all 9 mounted
	up front and toggled via Visible rather than re-mounted on nav clicks -- the same idiom
	Screens/DevMenu/ContentArea.lua's own `tabContent` already established for its 4-tab strip.

	The toolbar's Hotbar row (2026-08-10, the Move Creation System hotbar pass) is 5 small Tab.lua
	buttons, one per slot -- Selected reflects whether HotbarBindings currently maps that slot to
	THIS move's MoveId, and clicking toggles it (bind if not already this move, unbind if it is) via
	OnBindHotbarSlot. Hidden for a Default move for the exact same reason Test on Dummy is (see
	below) -- ThrowCustomMove's MoveRegistryManager.Get(moveId) lookup only ever knows Custom moves,
	so binding a Default move's MoveId would just be an always-MoveNotFound dead slot.

	Every numeric field is still a Components/NumericField.lua row; Shape is still a
	Components/Dropdown.lua selector; text fields (DisplayName/Category/AnimationId) still commit on
	FocusLost rather than per-keystroke. Related numerics that used to stack in one long vertical
	column (Size X/Y/Z, Offset X/Y/Z, the Timing quartet, the Damage quartet, ...) are now grouped
	side-by-side via the local `numericRow` helper -- the exact fractional-width Cell idiom
	ContentArea.lua's own Godmode/Flight/Collide row already uses (`UDim2.new(1/N, -Tokens.Space.XS,
	0, 0)` cells in a horizontal UIListLayout), just generalized to any column count. A row's fields
	all share one Visible condition (e.g. every Size X/Y/Z field is Visible=isBox), so when that
	condition is false every cell collapses to zero height and the whole row disappears with it --
	no separate row-level Visible needed.

	Every field's OnChanged handler still calls the shared `applyChange` helper: clone the current
	draft, mutate the ONE field that changed, hand the result to props.OnFieldChanged. That closure
	(owned by init.lua) sets props.Draft immediately (so this panel, Sidebar.lua's status dots, and
	PreviewViewport all feel instant) and forwards the same full draft to MoveEditorClient.lua over
	the OUTER DraftFieldChanged signal, which is what actually debounces the UpdateDraft network call
	-- see MoveEditor/Types.lua's header for that boundary. This panel never talks to a remote itself.

	ArcDegrees/MaxTargets are still always populated (never left nil) on every draft this screen
	produces -- v1 keeps every optional HitboxAttackDefinition field concrete rather than adding an
	enable/disable toggle for each one. Movement/Knockback/Projectile DO get an explicit toggle --
	unlike Arc/MaxTargets, "no movement grant," "no knockback," and "not a projectile" are all
	extremely common, expected states for a plain stationary hitbox. That toggle is now a real
	Components/Toggle.lua switch instead of a "+ Add X"/"- Remove X" Button text-swap. Enabling
	Projectile still nudges MaxTargets down to 1 -- see that Toggle's own OnChanged.

	Sub-table cloning is no longer this file's problem. `applyChange` now deep-copies through
	MoveTypes.Clone, so an OnChanged handler can mutate d.Movement/d.Knockback/d.Projectile in place
	and be correct. Eight hand-written `d.Knockback = table.clone(d.Knockback)` lines used to sit
	inside those handlers doing that job one field at a time -- each one guarding against the same
	failure (a shallow copy shares sub-table references, so mutating the new draft's Knockback would
	also mutate the OLD draft object still held in MoveList's MovesDisplay cache), and each one
	independently forgettable. See MoveTypes.Clone's own header for the depth it covers.

	Category == "Default" (Server/Combat/DefaultMoveRegistry.lua's reserved sentinel, see MoveTypes.
	lua's own header) changes this panel's chrome in three ways: DisplayName/Category/AnimationId
	render read-only (a plain Label sits where a TextField normally would -- see TextFieldRow's own
	`isReadOnly` param; MoveId/Author were never editable fields here to begin with, so nothing
	further is needed for those two); the toolbar shows BOTH Save (OnSave persists the move's current
	live values to a DataStore override, same button/handler shape a custom move's Save uses) AND
	"Reset to Default" (OnReset both live-reverts AND clears that override -- see MoveEditorSystem.
	lua's own header) side by side, rather than Save being replaced; and Movement/Knockback/
	Projectile's section content additionally hides even if SelectedSection still points at one of
	them (their nav items are already hidden by Sidebar.lua, but selection persists across a move
	switch by design -- see that file's header -- so this panel double-checks rather than trust the
	nav alone).

	"Test on Dummy" (TestFireMove/SpawnPreviewDummy) was removed alongside the rest of the combat
	system -- there is no server-side handler left to fire a move at a dummy with. StatsPanel/
	LastTestResultText below are left wired (see this file's own use of them further down): they are
	pure display, fed only by whatever handle.TestSamples holds, and now simply never receive a new
	sample -- no dead remote call to clean up on their side.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local MoveTypes = require(ReplicatedStorage.Shared.MoveTypes)
local Tokens = require(script.Parent.Parent.Parent.Tokens)
local Panel = require(script.Parent.Parent.Parent.Components.Panel)
local Label = require(script.Parent.Parent.Parent.Components.Label)
local Section = require(script.Parent.Parent.Parent.Components.Section)
local SectionIcon = require(script.Parent.Parent.Parent.Components.SectionIcon)
local Button = require(script.Parent.Parent.Parent.Components.Button)
local Tab = require(script.Parent.Parent.Parent.Components.Tab)
local TrackedLabel = require(script.Parent.Parent.Parent.Components.TrackedLabel)
local Toggle = require(script.Parent.Parent.Parent.Components.Toggle)
local TextField = require(script.Parent.Parent.Parent.Components.TextField)
local NumericField = require(script.Parent.Parent.Parent.Components.NumericField)
local MoveEditorTypes = require(script.Parent.Types)
local Copy = require(script.Parent.Copy)
local DraftBinding = require(script.Parent.DraftBinding)
local HitboxEditor = require(script.Parent.HitboxEditor)
local AnimationTimelineEditor = require(script.Parent.AnimationTimelineEditor)
local ObjectStunEditor = require(script.Parent.ObjectStunEditor)
local StatsPanel = require(script.Parent.StatsPanel)
local MoveStats = require(ReplicatedStorage.Shared.MoveStats)
local ArtConstants = require(ReplicatedStorage.Shared.ArtConstants)
local FrameTimeline = require(script.Parent.FrameTimeline)
local EditorTokens = require(script.Parent.EditorTokens)
local Dropdown = require(script.Parent.Parent.Parent.Components.Dropdown)

local Children = Fusion.Children
local peek = Fusion.peek

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>
type MoveDefinition = MoveTypes.MoveDefinition
type SectionId = MoveEditorTypes.SectionId

export type PropertyEditorProps = {
	Draft: Fusion.Value<MoveDefinition?>,
	LastTestResultText: UsedAs<string>,
	SelectedSection: UsedAs<SectionId>,
	OnFieldChanged: (MoveDefinition) -> (),
	OnSave: () -> (),
	-- Default-move-only, fires ALONGSIDE OnSave (not instead of it) when the current Draft's
	-- Category == "Default" -- see file header.
	OnReset: () -> (),
	-- Custom-move-only. Creates a fresh move seeded from the current draft -- see
	-- MoveEditorClient.lua's own handler for why this needs no new remote (blanking MoveId is what
	-- makes stampTrustedMetadata mint a new one through the existing UpdateDraft path).
	OnDuplicate: () -> (),
	-- Fired by the empty-state card's own "New Move" button, which is the only reachable action while
	-- nothing is selected -- the same signal Sidebar.lua's own "New Move" button already fires, routed
	-- here so an admin who is looking at the empty content pane doesn't have to find the sidebar.
	OnNew: () -> (),
	-- Whether the current draft differs from what was last SAVED or loaded (MoveTypes.Fingerprint
	-- comparison, owned by init.lua). Drives the toolbar's UNSAVED chip. Note this reports on the
	-- DataStore, not on the server's in-memory registry: an edit that UpdateDraft has already accepted
	-- is still unsaved, which is exactly the state that needs surfacing.
	IsDirty: UsedAs<boolean>,
	-- Live slot->MoveId snapshot (Client/Combat/HotbarBindings.lua via MoveEditor/init.lua's own
	-- handle) -- drives which of the toolbar's 5 slot buttons render Selected for the current Draft.
	HotbarBindings: UsedAs<{ [number]: string? }>,
	-- Fired with the clicked slot number when the toolbar's hotbar row is used -- init.lua resolves
	-- the current Draft's MoveId and forwards both to MoveEditorClient.lua (see that file's own
	-- OnBindHotbarSlot closure). This panel never calls HotbarBindings itself -- see file header on
	-- "this panel never talks to a remote/module itself."
	OnBindHotbarSlot: (number) -> (),
	-- Observed test-fire hits, owned by init.lua and appended to by MoveEditorClient.lua -- passed
	-- straight through to StatsPanel, which is the only thing here that reads it. See
	-- MoveEditor/Types.lua's MoveEditorHandle.TestSamples.
	TestSamples: Fusion.Value<{ MoveStats.TestSample }>,
}

local HOTBAR_SLOT_COUNT = 5
local HOTBAR_SLOT_BUTTON_SIZE = Tokens.Control.StepButtonSize

-- The toolbar is TWO rows, not one. At CONTENT_WIDTH 600 the inner pane is 576px, and a custom
-- move's action row alone (Test on Dummy 140 + Save 100 + Duplicate 100, plus gaps) already runs to
-- ~356 -- adding the hotbar row's ~230 and an UNSAVED chip to the same line overflowed silently,
-- which is how the last-test Label ended up with a hand-tuned `UDim2.new(1, -500, 1, 0)` and 76px to
-- render a full sentence in. Splitting actions from context gives the result string ~340px and
-- removes the magic number entirely.
-- The Timing section's to-scale phase widget. Two stacked bars -- see the phaseBar build for why
-- cooldown is its own bar rather than a fourth segment.

local TOOLBAR_ROW_HEIGHT = Tokens.Control.RowHeight
local TOOLBAR_HEIGHT = TOOLBAR_ROW_HEIGHT * 2 + Tokens.Space.XS
-- Spelled out rather than guessed: a 50px "Hotbar:" label, the gap after it, five slot buttons, and
-- the four gaps between them. Consumed by the last-test Label sharing that row.
local HOTBAR_ROW_WIDTH = 50
	+ Tokens.Space.XS
	+ HOTBAR_SLOT_COUNT * HOTBAR_SLOT_BUTTON_SIZE
	+ (HOTBAR_SLOT_COUNT - 1) * Tokens.Space.XS

local function applyChange(props: PropertyEditorProps, mutate: (MoveDefinition) -> ()): ()
	local current = peek(props.Draft)
	if not current then
		return
	end
	-- MoveTypes.Clone, not table.clone: a shallow copy shares every sub-table with the draft it came
	-- from, so mutating updated.Knockback would reach back and mutate the OLD draft object still held
	-- in MovesDisplay's cache. This file used to compensate with eight hand-written
	-- `d.Knockback = table.clone(d.Knockback)` lines inside the individual OnChanged handlers; they
	-- are gone, because one deep clone here cannot be forgotten the way a ninth of those could.
	local updated = MoveTypes.Clone(current)
	mutate(updated)
	props.OnFieldChanged(updated)
end

-- Reads one field off the current draft, or `default` while nothing is selected -- every Computed
-- below is built from this so a NumericField/Dropdown never has to nil-check its own Value prop.
local function fieldValue<T>(
	props: PropertyEditorProps,
	scope: Scope,
	getter: (MoveDefinition) -> T,
	default: T
): Fusion.Computed<T>
	return scope:Computed(function(use)
		local draft = use(props.Draft)
		return if draft then getter(draft) else default
	end)
end

-- `isReadOnly` (optional, default false): for Category == "Default" (MoveId/DisplayName/Category/
-- AnimationId, see file header) mounts a read-only Label in the TextField's place instead -- both are
-- mounted up front and Visible-toggled off `isReadOnly`, the same "mount both, toggle Visible" idiom
-- sectionContent below already uses, rather than trying to make TextField.lua itself support a
-- disabled state it has no prop for today.
local function TextFieldRow(
	scope: Scope,
	props: PropertyEditorProps,
	label: string,
	layoutOrder: number,
	getter: (MoveDefinition) -> string,
	setter: (MoveDefinition, string) -> (),
	isReadOnly: UsedAs<boolean>?
): Frame
	local localText = scope:Value("")

	scope:Observer(props.Draft):onChange(function()
		local draft = peek(props.Draft)
		localText:set(if draft then getter(draft) else "")
	end)

	local readOnly: UsedAs<boolean> = if isReadOnly == nil then false else isReadOnly
	local editableVisible = scope:Computed(function(use)
		return not use(readOnly)
	end)

	return scope:New "Frame" {
		Name = label,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		LayoutOrder = layoutOrder,

		[Children] = {
			scope:New "UIListLayout" {
				FillDirection = Enum.FillDirection.Vertical,
				Padding = UDim.new(0, Tokens.Space.XS),
				SortOrder = Enum.SortOrder.LayoutOrder,
			},
			Label(scope, { Text = label, Scale = "Body", Color = Tokens.Color.TextPrimary, LayoutOrder = 1 }),
			-- TextField.lua has no Visible/Disabled prop of its own -- wrapped in a plain Frame so the
			-- editable and read-only presentations can still be mounted-both/Visible-toggled, the same
			-- idiom sectionContent below uses for its own Visible-gated panes.
			scope:New "Frame" {
				Name = "Editable",
				Size = UDim2.fromScale(1, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				BackgroundTransparency = 1,
				LayoutOrder = 2,
				Visible = editableVisible,

				[Children] = TextField(scope, {
					Text = localText,
					OnFocusLost = function(newText: string)
						applyChange(props, function(draft)
							setter(draft, newText)
						end)
					end,
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

-- Groups related fields side-by-side into `columns` even cells -- the exact fractional-width idiom
-- Screens/DevMenu/ContentArea.lua's own Godmode/Flight/Collide row already uses
-- (`UDim2.new(1/N, -Tokens.Space.XS, 0, 0)`), generalized to any column count. See this file's own
-- header for why a row never needs its own separate Visible prop.
-- Wraps a child that has no Visible prop of its own in a full-width, auto-height Frame that does.
-- Components/Dropdown.lua and this file's own TextFieldRow both predate any caller needing to hide
-- them reactively; giving each its own Visible prop for one call site would widen two shared APIs
-- where one local wrapper does the same job. Collapses to zero height when hidden, so the section's
-- UIListLayout closes the gap rather than leaving a hole.
local function visibleWhen(scope: Scope, layoutOrder: number, visible: UsedAs<boolean>, child: Instance): Frame
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

-- Windup/Active/Recovery authored in FRAMES, matching the Figma Make reference ("WINDUP (FRAMES)",
-- stepped by -6/-1/+1/+6). MoveDefinition still stores seconds and HitboxResolver still resolves in
-- seconds -- this converts at the field boundary only, the same display-unit split
-- FrameTimeline.lua's own header describes.
--
-- Cooldown deliberately stays in SECONDS and keeps its own row. The reference authors the three
-- PHASES in frames because they are the move's own moment-to-moment shape, but reports cooldown as a
-- seconds value ("Cooldown 2.5s" on its stat card) -- it is a gap between uses measured from the
-- move's start, not a span of animation frames, and framing it would invite reading it as a fourth
-- phase, which is the exact misreading FrameTimeline.lua exists to avoid.
--
-- Rounding is one-way-safe: seconds -> frames rounds for display, frames -> seconds divides exactly,
-- so a value the author never touches is never rewritten by the conversion. A field they DO touch
-- lands on a whole frame, which is the point of authoring in frames at all.
local function frameField(
	scope: Scope,
	props: PropertyEditorProps,
	label: string,
	hint: string,
	secondsValue: Fusion.UsedAs<number>,
	maxFrames: number,
	apply: (MoveDefinition, number) -> ()
): Instance
	return NumericField.Mount(scope, {
		Label = label,
		Unit = "frames",
		Hint = hint,
		Value = scope:Computed(function(use)
			return EditorTokens.ToFrames(use(secondsValue))
		end),
		Min = 1,
		Max = maxFrames,
		Steps = { 1, 6 },
		Decimals = 0,
		OnChanged = function(frames: number)
			applyChange(props, function(d)
				apply(d, frames / EditorTokens.DisplayFPS)
			end)
		end,
	})
end

local function numericRow(scope: Scope, layoutOrder: number, columns: number, fields: { Instance }): Frame
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
		Name = "NumericRow",
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		LayoutOrder = layoutOrder,

		[Children] = cells,
	} :: Frame
end

-- The toolbar's 5-button "which hotbar slot(s) is this move bound to" row -- see file header. Built
-- as its own local function (not inlined into the toolbar table below) for the same reason
-- numericRow above is: 5 near-identical buttons that only differ by slot number.
local function hotbarBindRow(
	scope: Scope,
	props: PropertyEditorProps,
	moveId: UsedAs<string>,
	visible: UsedAs<boolean>
): Frame
	local slotButtons: { Instance } = {
		scope:New "UIListLayout" {
			FillDirection = Enum.FillDirection.Horizontal,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			Padding = UDim.new(0, Tokens.Space.XS),
			SortOrder = Enum.SortOrder.LayoutOrder,
		},
	}
	for slot = 1, HOTBAR_SLOT_COUNT do
		table.insert(
			slotButtons,
			Tab(scope, {
				Text = tostring(slot),
				Selected = scope:Computed(function(use)
					local bindings = use(props.HotbarBindings)
					local currentMoveId = use(moveId)
					return currentMoveId ~= "" and bindings[slot] == currentMoveId
				end),
				Size = UDim2.fromOffset(HOTBAR_SLOT_BUTTON_SIZE, HOTBAR_SLOT_BUTTON_SIZE),
				LayoutOrder = slot,
				OnActivated = function()
					props.OnBindHotbarSlot(slot)
				end,
			})
		)
	end

	return scope:New "Frame" {
		Name = "HotbarBindRow",
		Size = UDim2.fromOffset(0, Tokens.Control.RowHeight),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundTransparency = 1,
		LayoutOrder = 4,
		Visible = visible,

		[Children] = {
			scope:New "UIListLayout" {
				FillDirection = Enum.FillDirection.Horizontal,
				VerticalAlignment = Enum.VerticalAlignment.Center,
				Padding = UDim.new(0, Tokens.Space.XS),
				SortOrder = Enum.SortOrder.LayoutOrder,
			},
			Label(scope, {
				Text = "Hotbar:",
				Scale = "Body",
				Color = Tokens.Color.TextSecondary,
				Size = UDim2.fromOffset(50, Tokens.Control.RowHeight),
				LayoutOrder = 1,
			}),
			scope:New "Frame" {
				Name = "Slots",
				Size = UDim2.fromOffset(0, Tokens.Control.RowHeight),
				AutomaticSize = Enum.AutomaticSize.X,
				BackgroundTransparency = 1,
				LayoutOrder = 2,

				[Children] = slotButtons,
			},
		},
	} :: Frame
end

local PropertyEditorModule = {}

function PropertyEditorModule.Mount(scope: Scope, width: number, height: number, props: PropertyEditorProps): Frame
	local hasDraft = scope:Computed(function(use)
		return use(props.Draft) ~= nil
	end)
	-- Category == "Default" -- drives the read-only BasicInfo/Animation fields, the toolbar's Save
	-- <-> Reset-to-Default / Test-on-Dummy swap, and the Movement/Knockback/Projectile section-content
	-- hide-even-if-selected guard below -- see file header.
	local isDefaultMove = scope:Computed(function(use)
		local draft = use(props.Draft)
		return draft ~= nil and draft.Category == MoveTypes.DefaultCategory
	end)
	-- Not simply `not isDefaultMove`: with NO draft selected both of these are false, which is what
	-- keeps the toolbar's custom-only actions hidden on an empty editor rather than flashing them
	-- while the pane itself is already hidden. Named once here because four separate toolbar slots
	-- ask the same question.
	local isCustomMove = scope:Computed(function(use)
		local draft = use(props.Draft)
		return draft ~= nil and draft.Category ~= MoveTypes.DefaultCategory
	end)
	-- Feeds hotbarBindRow's own Selected computation per slot -- "" (never a real MoveId) while
	-- nothing is selected, so that check is always false rather than needing its own nil-guard.
	local draftMoveId = scope:Computed(function(use)
		local draft = use(props.Draft)
		return if draft then draft.MoveId else ""
	end)
	local hasMovement = scope:Computed(function(use)
		local draft = use(props.Draft)
		return draft ~= nil and draft.Movement ~= nil
	end)
	local hasArt = scope:Computed(function(use)
		local draft = use(props.Draft)
		return draft ~= nil and draft.Art ~= nil
	end)
	-- Built once from the roster, not per render -- the tree list is static content
	-- (ArtConstants.ArtTrees) and cannot change while the editor is open.
	local treeOptions: { { Value: string, Text: string } } = {}
	for _, tree in ipairs(ArtConstants.ArtTrees) do
		table.insert(treeOptions, { Value = tree.TreeId, Text = tree.DisplayName })
	end
	local artTreeId = fieldValue(props, scope, function(d)
		return if d.Art then d.Art.TreeId else ArtConstants.ArtTrees[1].TreeId
	end, ArtConstants.ArtTrees[1].TreeId)
	local artNode = fieldValue(props, scope, function(d)
		return if d.Art then d.Art.Node else 1
	end, 1)
	local artQiCost = fieldValue(props, scope, function(d)
		return if d.Art then d.Art.QiCost else 15
	end, 15)
	local artRequiredTier = fieldValue(props, scope, function(d)
		return if d.Art then d.Art.RequiredTier else 1
	end, 1)
	local hasKnockback = scope:Computed(function(use)
		local draft = use(props.Draft)
		return draft ~= nil and draft.Knockback ~= nil
	end)
	local hasProjectile = scope:Computed(function(use)
		local draft = use(props.Draft)
		return draft ~= nil and draft.Projectile ~= nil
	end)

	local offsetX = fieldValue(props, scope, function(d)
		return d.Offset.X
	end, 0)
	local offsetY = fieldValue(props, scope, function(d)
		return d.Offset.Y
	end, 0)
	local offsetZ = fieldValue(props, scope, function(d)
		return d.Offset.Z
	end, -3)
	local function setOffsetAxis(draft: MoveDefinition, axis: "X" | "Y" | "Z", value: number): ()
		local current = draft.Offset
		if axis == "X" then
			draft.Offset = CFrame.new(value, current.Y, current.Z)
		elseif axis == "Y" then
			draft.Offset = CFrame.new(current.X, value, current.Z)
		else
			draft.Offset = CFrame.new(current.X, current.Y, value)
		end
	end

	local windup = fieldValue(props, scope, function(d)
		return d.WindupSeconds
	end, 0.2)
	local active = fieldValue(props, scope, function(d)
		return d.ActiveSeconds
	end, 0.15)
	local recovery = fieldValue(props, scope, function(d)
		return d.RecoverySeconds
	end, 0.3)
	local cooldown = fieldValue(props, scope, function(d)
		return d.Cooldown
	end, 0.6)
	local damage = fieldValue(props, scope, function(d)
		return d.Damage
	end, 5)
	local postureDamage = fieldValue(props, scope, function(d)
		return d.PostureDamage
	end, 5)
	local arcDegrees = fieldValue(props, scope, function(d)
		return d.ArcDegrees or 100
	end, 100)
	local maxTargets = fieldValue(props, scope, function(d)
		return d.MaxTargets or 5
	end, 5)

	local lungeDistance = fieldValue(props, scope, function(d)
		return if d.Movement then d.Movement.LungeDistanceStuds else 8
	end, 8)
	local lungeDuration = fieldValue(props, scope, function(d)
		return if d.Movement then d.Movement.LungeDurationSeconds else 0.2
	end, 0.2)
	local knockUp = fieldValue(props, scope, function(d)
		return if d.Knockback then d.Knockback.UpVelocity else 20
	end, 20)
	local knockHorizontal = fieldValue(props, scope, function(d)
		return if d.Knockback then d.Knockback.HorizontalVelocity else 10
	end, 10)
	local knockRagdoll = fieldValue(props, scope, function(d)
		return if d.Knockback then d.Knockback.RagdollSeconds else 0.6
	end, 0.6)
	local knockStartsAirCombo = fieldValue(props, scope, function(d)
		return d.Knockback ~= nil and d.Knockback.StartsAirCombo == true
	end, false)
	local projectileSpeed = fieldValue(props, scope, function(d)
		return if d.Projectile then d.Projectile.Speed else 40
	end, 40)
	local projectileMaxRange = fieldValue(props, scope, function(d)
		return if d.Projectile then d.Projectile.MaxRange else 60
	end, 60)

	local innerWidth = width - Tokens.Space.M * 2
	-- Spelled out, and it MOVES when the toolbar does: this Panel's own vertical padding, the toolbar
	-- band, and the list gap under it. TOOLBAR_HEIGHT went 40 -> 84 when the toolbar became two rows,
	-- so this went 608 -> 564. Roblox's UIListLayout has no flex-grow, which is why the "fills the
	-- rest" pane has to compute its own height rather than being told to take what's left.
	local contentHeight = height - Tokens.Space.M * 2 - TOOLBAR_HEIGHT - Tokens.Space.S
	local contentSize = UDim2.fromOffset(innerWidth, contentHeight)

	-- Movement/Knockback/Projectile are non-functional for a Default move (see file header) -- their
	-- nav items are already hidden by Sidebar.lua, but SelectedSection deliberately persists across a
	-- move switch (that file's own header), so a section content pane still double-checks here rather
	-- than trusting the nav alone to keep the admin off it.
	local HIDDEN_FOR_DEFAULT: { [string]: boolean } =
		{ Movement = true, Knockback = true, Projectile = true, ObjectStun = true, Art = true }

	-- One ScrollingFrame per section, all mounted up front, Visible-toggled by props.SelectedSection
	-- -- see this file's own header and ContentArea.lua's `tabContent` precedent.
	-- `summary` (optional): a live right-aligned readout on the section card's title row -- what this
	-- section's own fields currently add up to. Only Timing passes one today. See Section.lua's own
	-- header on why it is reactive while `title` deliberately is not.
	local function sectionContent(
		sectionId: SectionId,
		title: string,
		description: string,
		fields: { any },
		summary: UsedAs<string>?
	): ScrollingFrame
		local hiddenForDefault = HIDDEN_FOR_DEFAULT[sectionId] == true
		local isVisible = scope:Computed(function(use)
			if hiddenForDefault and use(isDefaultMove) then
				return false
			end
			return use(hasDraft) and use(props.SelectedSection) == sectionId
		end)
		-- sectionId doubles as SectionIcon's own Glyph -- see Sidebar.lua's identical reasoning
		-- (SectionId and SectionIconGlyphKind are structurally the same nine-member union by
		-- construction). AccentPrimaryBright, not a Computed -- this icon sits on an already-Visible-
		-- gated ScrollingFrame with no idle/selected state of its own to react to, unlike Sidebar's
		-- nav icon.
		local icon = SectionIcon(scope, { Glyph = sectionId, Color = Tokens.Color.AccentPrimaryBright })

		return scope:New "ScrollingFrame" {
			Name = sectionId .. "Content",
			Size = contentSize,
			LayoutOrder = 2,
			Visible = isVisible,
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			ScrollingDirection = Enum.ScrollingDirection.Y,
			AutomaticCanvasSize = Enum.AutomaticSize.Y,
			CanvasSize = UDim2.fromScale(0, 0),
			ScrollBarThickness = 3,
			ScrollBarImageColor3 = Tokens.Border.Standard.Color,
			ScrollBarImageTransparency = Tokens.Border.Standard.Transparency,

			[Children] = {
				scope:New "UIPadding" { PaddingRight = UDim.new(0, Tokens.Space.XS) },
				scope:New "UIListLayout" {
					FillDirection = Enum.FillDirection.Vertical,
					Padding = UDim.new(0, Tokens.Space.M),
					SortOrder = Enum.SortOrder.LayoutOrder,
				},
				Section(scope, title, 1, fields, description, icon, true, summary),
			},
		} :: ScrollingFrame
	end

	local basicInfoContent = sectionContent("BasicInfo", "Basic Info", Copy.Sections.BasicInfo, {
		TextFieldRow(scope, props, "Display Name", 3, function(d)
			return d.DisplayName
		end, function(d, v)
			d.DisplayName = v
		end, isDefaultMove),
		TextFieldRow(scope, props, "Category", 4, function(d)
			return d.Category
		end, function(d, v)
			-- The reserved sentinel is refused HERE as well as server-side (MoveRegistryManager.
			-- Validate returns "ReservedCategory" for it). Belt and braces on purpose: the server gate
			-- is the one that matters for correctness, but bouncing it at the point of typing lets the
			-- editor say WHY in plain words, where the remote path could only surface a generic
			-- rejection code in the status line. Silently leaving the old value is the right recovery
			-- -- the field re-renders from the draft, which never changed.
			if v == MoveTypes.DefaultCategory then
				return
			end
			d.Category = v
		end, isDefaultMove),
	})

	-- Hitbox/Animation/ObjectStun/Stats hand their whole content off to a dedicated sibling module
	-- rather than building fields inline the way every section around them still does. Each of those
	-- four outgrew an inline block (twelve shapes reading twelve different subsets of eight
	-- measurement fields; an ordered clip list with per-clip start/stop/blend rules; an Object Stun
	-- config with its own follow-up sub-form; a stats readout with graphs), and each is a form over
	-- this same draft, so they take the shared DraftContext below and return the section's children.
	local draftContext: DraftBinding.DraftContext = {
		Draft = props.Draft,
		OnFieldChanged = props.OnFieldChanged,
	}

	local hitboxContent =
		sectionContent("Hitbox", "Hitbox", Copy.Sections.Hitbox, HitboxEditor.Build(scope, draftContext))

	-- One field per row -- see Hitbox's Size X/Y/Z comment above on why a 3-column numericRow doesn't
	-- fit a full NumericField at this content pane's width.
	local offsetContent = sectionContent("Offset", "Offset", Copy.Sections.Offset, {
		NumericField.Mount(scope, {
			Label = "Offset X",
			Unit = Copy.Field("Offset.X").Unit,
			Hint = Copy.Field("Offset.X").Hint,
			Value = offsetX,
			Min = -5,
			Max = 10,
			Steps = { 0.1, 1 },
			LayoutOrder = 3,
			OnChanged = function(v)
				applyChange(props, function(d)
					setOffsetAxis(d, "X", v)
				end)
			end,
		}),
		NumericField.Mount(scope, {
			Label = "Offset Y",
			Unit = Copy.Field("Offset.Y").Unit,
			Hint = Copy.Field("Offset.Y").Hint,
			Value = offsetY,
			Min = -5,
			Max = 10,
			Steps = { 0.1, 1 },
			LayoutOrder = 4,
			OnChanged = function(v)
				applyChange(props, function(d)
					setOffsetAxis(d, "Y", v)
				end)
			end,
		}),
		NumericField.Mount(scope, {
			Label = "Offset Z",
			Unit = Copy.Field("Offset.Z").Unit,
			Hint = Copy.Field("Offset.Z").Hint,
			Value = offsetZ,
			Min = -5,
			Max = 10,
			Steps = { 0.1, 1 },
			LayoutOrder = 5,
			OnChanged = function(v)
				applyChange(props, function(d)
					setOffsetAxis(d, "Z", v)
				end)
			end,
		}),
	})

	-- The reference design's frame-timeline card (see FrameTimeline.lua). Replaces the two-bar
	-- phase+cooldown strip that used to be built inline here; that element's own reasoning about why
	-- Cooldown must not be drawn as a fourth segment is preserved and expanded in that module's
	-- header, which is where it belongs now.
	local phaseBar = FrameTimeline.Build(scope, props.Draft, 3)

	-- Fed to Section's `summary` slot -- the same numbers the bar draws, stated. use(), never peek():
	-- a peek inside a Computed reads without subscribing, which would freeze this at its first value.
	local timingSummary = scope:Computed(function(use)
		local d = use(props.Draft)
		if not d then
			return ""
		end
		return string.format(
			"%.2fs total  /  %.2fs cooldown",
			d.WindupSeconds + d.ActiveSeconds + d.RecoverySeconds,
			d.Cooldown
		)
	end)

	local timingContent = sectionContent("Timing", "Timing", Copy.Sections.Timing, {
		phaseBar,
		-- One field per row, full width, matching the reference's stacked Timing layout rather than
		-- the 2-up grid the other numeric sections use -- these three are the section's whole subject
		-- and the frame timeline directly above is already reading left-to-right across them.
		frameField(scope, props, "Windup", Copy.Field("Timing.Windup").Hint, windup, 300, function(d, seconds)
			d.WindupSeconds = seconds
		end),
		frameField(scope, props, "Active", Copy.Field("Timing.Active").Hint, active, 3000, function(d, seconds)
			d.ActiveSeconds = seconds
		end),
		frameField(scope, props, "Recovery", Copy.Field("Timing.Recovery").Hint, recovery, 300, function(d, seconds)
			d.RecoverySeconds = seconds
		end),
		numericRow(scope, 4, 1, {
			NumericField.Mount(scope, {
				Label = "Cooldown",
				Unit = Copy.Field("Timing.Cooldown").Unit,
				Hint = Copy.Field("Timing.Cooldown").Hint,
				Value = cooldown,
				Min = 0.01,
				Max = 5,
				Steps = { 0.01, 0.1 },
				OnChanged = function(v)
					applyChange(props, function(d)
						d.Cooldown = v
					end)
				end,
			}),
		}),
	}, timingSummary)

	local damageContent = sectionContent("Damage", "Damage", Copy.Sections.Damage, {
		numericRow(scope, 3, 2, {
			NumericField.Mount(scope, {
				Label = "Damage",
				Unit = Copy.Field("Damage.Damage").Unit,
				Hint = Copy.Field("Damage.Damage").Hint,
				Value = damage,
				Min = 0,
				Max = 200,
				Steps = { 1, 5 },
				Decimals = 0,
				OnChanged = function(v)
					applyChange(props, function(d)
						d.Damage = v
					end)
				end,
			}),
			NumericField.Mount(scope, {
				Label = "Posture Damage",
				Unit = Copy.Field("Damage.PostureDamage").Unit,
				Hint = Copy.Field("Damage.PostureDamage").Hint,
				Value = postureDamage,
				Min = 0,
				Max = 200,
				Steps = { 1, 5 },
				Decimals = 0,
				OnChanged = function(v)
					applyChange(props, function(d)
						d.PostureDamage = v
					end)
				end,
			}),
		}),
		numericRow(scope, 4, 2, {
			NumericField.Mount(scope, {
				Label = "Arc",
				Unit = Copy.Field("Damage.ArcDegrees").Unit,
				Hint = Copy.Field("Damage.ArcDegrees").Hint,
				Value = arcDegrees,
				Min = 1,
				Max = 360,
				Steps = { 5, 45 },
				Decimals = 0,
				OnChanged = function(v)
					applyChange(props, function(d)
						d.ArcDegrees = v
					end)
				end,
			}),
			NumericField.Mount(scope, {
				Label = "Max Targets",
				Unit = Copy.Field("Damage.MaxTargets").Unit,
				Hint = Copy.Field("Damage.MaxTargets").Hint,
				Value = maxTargets,
				Min = 1,
				Max = 50,
				Steps = { 1, 5 },
				Decimals = 0,
				OnChanged = function(v)
					applyChange(props, function(d)
						d.MaxTargets = math.floor(v)
					end)
				end,
			}),
		}),
	})

	-- The Default-move note stays here rather than moving into AnimationTimelineEditor: it is a fact
	-- about DEFAULT moves (their animation comes from CombatAnimator's own DebugName inference, never
	-- from authored data -- see Server/Combat/DefaultMoveRegistry.lua's header), not about the timeline
	-- model, and the timeline editor has no notion of a Default move at all.
	local animationChildren: { Instance } = {
		Label(scope, {
			Text = "Default moves ignore these clips -- their animation is inferred automatically from "
				.. "the attack's own name.",
			Scale = "Detail",
			Color = Tokens.Color.TextSecondary,
			AutoHeight = true,
			LineHeight = Tokens.Leading.Prose,
			Size = UDim2.fromScale(1, 0),
			LayoutOrder = 2,
			Visible = isDefaultMove,
		}),
	}
	for _, child in ipairs(AnimationTimelineEditor.Build(scope, draftContext)) do
		table.insert(animationChildren, child)
	end

	local animationContent = sectionContent("Animation", "Animation", Copy.Sections.Animation, animationChildren)

	local movementContent = sectionContent("Movement", "Movement", Copy.Sections.Movement, {
		Toggle(scope, {
			Label = "Enable Forward Lunge",
			Value = hasMovement,
			LayoutOrder = 3,
			OnChanged = function(enabled: boolean)
				applyChange(props, function(d)
					if enabled then
						d.Movement = { LungeDistanceStuds = 8, LungeDurationSeconds = 0.2 }
					else
						d.Movement = nil
					end
				end)
			end,
		}),
		numericRow(scope, 4, 2, {
			NumericField.Mount(scope, {
				Label = "Lunge Distance",
				Unit = Copy.Field("Movement.LungeDistance").Unit,
				Hint = Copy.Field("Movement.LungeDistance").Hint,
				Value = lungeDistance,
				Min = 0,
				Max = 30,
				Steps = { 1, 5 },
				Decimals = 1,
				Visible = hasMovement,
				OnChanged = function(v)
					applyChange(props, function(d)
						if d.Movement then
							d.Movement.LungeDistanceStuds = v
						end
					end)
				end,
			}),
			NumericField.Mount(scope, {
				Label = "Lunge Duration",
				Unit = Copy.Field("Movement.LungeDuration").Unit,
				Hint = Copy.Field("Movement.LungeDuration").Hint,
				Value = lungeDuration,
				Min = 0.05,
				Max = 3,
				Steps = { 0.05, 0.2 },
				Visible = hasMovement,
				OnChanged = function(v)
					applyChange(props, function(d)
						if d.Movement then
							d.Movement.LungeDurationSeconds = v
						end
					end)
				end,
			}),
		}),
	})

	local knockbackContent = sectionContent("Knockback", "Knockback", Copy.Sections.Knockback, {
		Toggle(scope, {
			Label = "Enable Knockback",
			Value = hasKnockback,
			LayoutOrder = 3,
			OnChanged = function(enabled: boolean)
				applyChange(props, function(d)
					if enabled then
						d.Knockback = {
							UpVelocity = 20,
							HorizontalVelocity = 10,
							RagdollSeconds = 0.6,
							StartsAirCombo = false,
						}
					else
						d.Knockback = nil
					end
				end)
			end,
		}),
		-- One field per row -- see Hitbox's Size X/Y/Z comment above on why a 3-column numericRow
		-- doesn't fit a full NumericField at this content pane's width.
		NumericField.Mount(scope, {
			Label = "Up Velocity",
			Unit = Copy.Field("Knockback.UpVelocity").Unit,
			Hint = Copy.Field("Knockback.UpVelocity").Hint,
			Value = knockUp,
			Min = 0,
			Max = 150,
			Steps = { 5, 20 },
			Decimals = 0,
			Visible = hasKnockback,
			LayoutOrder = 4,
			OnChanged = function(v)
				applyChange(props, function(d)
					if d.Knockback then
						d.Knockback.UpVelocity = v
					end
				end)
			end,
		}),
		NumericField.Mount(scope, {
			Label = "Horizontal Velocity",
			Unit = Copy.Field("Knockback.HorizontalVelocity").Unit,
			Hint = Copy.Field("Knockback.HorizontalVelocity").Hint,
			Value = knockHorizontal,
			Min = 0,
			Max = 150,
			Steps = { 5, 20 },
			Decimals = 0,
			Visible = hasKnockback,
			LayoutOrder = 5,
			OnChanged = function(v)
				applyChange(props, function(d)
					if d.Knockback then
						d.Knockback.HorizontalVelocity = v
					end
				end)
			end,
		}),
		NumericField.Mount(scope, {
			Label = "Ragdoll",
			Unit = Copy.Field("Knockback.RagdollSeconds").Unit,
			Hint = Copy.Field("Knockback.RagdollSeconds").Hint,
			Value = knockRagdoll,
			Min = 0,
			Max = 5,
			Steps = { 0.1, 0.5 },
			Visible = hasKnockback,
			LayoutOrder = 6,
			OnChanged = function(v)
				applyChange(props, function(d)
					if d.Knockback then
						d.Knockback.RagdollSeconds = v
					end
				end)
			end,
		}),
		Toggle(scope, {
			Label = "Starts Aerial Combo",
			Value = knockStartsAirCombo,
			LayoutOrder = 7,
			Visible = hasKnockback,
			OnChanged = function(enabled: boolean)
				applyChange(props, function(d)
					if d.Knockback then
						d.Knockback.StartsAirCombo = enabled
					end
				end)
			end,
		}),
	})

	local projectileContent = sectionContent("Projectile", "Projectile", Copy.Sections.Projectile, {
		Label(scope, {
			Text = "MaxTargets (Damage section) doubles as pierce count while this is on (1 = stops on first hit).",
			Scale = "Detail",
			Color = Tokens.Color.TextSecondary,
			AutoHeight = true,
			LineHeight = Tokens.Leading.Prose,
			Size = UDim2.fromScale(1, 0),
			LayoutOrder = 3,
		}),
		Toggle(scope, {
			Label = "Make Projectile",
			Value = hasProjectile,
			LayoutOrder = 4,
			OnChanged = function(enabled: boolean)
				applyChange(props, function(d)
					if enabled then
						d.Projectile = { Speed = 40, MaxRange = 60 }
						-- A normal (non-piercing) projectile should stop on its first hit -- see
						-- this section's own explanatory Label above.
						d.MaxTargets = 1
					else
						d.Projectile = nil
					end
				end)
			end,
		}),
		numericRow(scope, 5, 2, {
			NumericField.Mount(scope, {
				Label = "Speed",
				Unit = Copy.Field("Projectile.Speed").Unit,
				Hint = Copy.Field("Projectile.Speed").Hint,
				Value = projectileSpeed,
				Min = 5,
				Max = 2000,
				Steps = { 5, 20 },
				Decimals = 0,
				Visible = hasProjectile,
				OnChanged = function(v)
					applyChange(props, function(d)
						if d.Projectile then
							d.Projectile.Speed = v
						end
					end)
				end,
			}),
			NumericField.Mount(scope, {
				Label = "Max Range",
				Unit = Copy.Field("Projectile.MaxRange").Unit,
				Hint = Copy.Field("Projectile.MaxRange").Hint,
				Value = projectileMaxRange,
				Min = 5,
				Max = 2000,
				Steps = { 5, 20 },
				Decimals = 0,
				Visible = hasProjectile,
				OnChanged = function(v)
					applyChange(props, function(d)
						if d.Projectile then
							d.Projectile.MaxRange = v
						end
					end)
				end,
			}),
		}),
	})

	local objectStunContent = sectionContent(
		"ObjectStun",
		"Object Stun",
		Copy.Sections.ObjectStun,
		ObjectStunEditor.Build(scope, draftContext)
	)

	-- The only read-only section, and the only one needing anything beyond the draft: it plots the
	-- move's COMPUTED damage profile against the OBSERVED hits from test-firing it, and the observed
	-- half lives on props.TestSamples. innerWidth (the same width sectionContent sizes its panes to)
	-- is handed down so the graphs can size themselves in pixels -- a graph is one of the few things
	-- here that cannot lay itself out from a scale-based parent alone.
	-- Art -----------------------------------------------------------------------------------------
	-- The "convert an existing move into an art" surface. Deliberately the LAST authoring section and
	-- built as a single toggle plus four fields, because that is the whole workflow: everything an
	-- art DOES was already authored in the sections above it. Flipping Enable writes a
	-- MoveTypes.MoveArtBinding onto the draft; the move is otherwise untouched, which is exactly why
	-- an existing, already-tuned move can become an art without being rebuilt.
	--
	-- Defaults on enable are the shallowest legal art (node 1, no prerequisite, tier 1, a modest Qi
	-- cost) rather than empty fields: node 1 is always unlockable, so a designer who flips this and
	-- saves immediately gets a working entry-level art rather than something gated behind nothing.
	local artContent = sectionContent("Art", "Art", Copy.Sections.Art, {
		Toggle(scope, {
			Label = "Enable as Art",
			Value = hasArt,
			LayoutOrder = 3,
			OnChanged = function(enabled: boolean)
				applyChange(props, function(d)
					if enabled then
						d.Art = {
							TreeId = ArtConstants.ArtTrees[1].TreeId,
							Node = 1,
							QiCost = 15,
							RequiredTier = 1,
							Prerequisite = nil,
						}
					else
						d.Art = nil
					end
				end)
			end,
		}),
		visibleWhen(
			scope,
			4,
			hasArt,
			Dropdown.Mount(scope, {
				Label = "Tree",
				Options = treeOptions,
				Value = artTreeId,
				OnChanged = function(treeId: string)
					applyChange(props, function(d)
						if d.Art then
							d.Art.TreeId = treeId
							-- A prerequisite only ever refers to an art in the SAME tree
							-- (ArtTreeManager.AuditPrerequisites treats a cross-tree one as a defect), so
							-- moving trees clears it rather than silently carrying a now-invalid reference.
							d.Art.Prerequisite = nil
						end
					end)
				end,
			})
		),
		numericRow(scope, 5, 3, {
			NumericField.Mount(scope, {
				Label = "Node",
				Hint = "Depth in the tree. Node 1 is an entry form and is never gated behind a prerequisite.",
				Value = artNode,
				Min = ArtConstants.Limits.Node.Min,
				Max = ArtConstants.Limits.Node.Max,
				Steps = { 1 },
				Decimals = 0,
				Visible = hasArt,
				OnChanged = function(v)
					applyChange(props, function(d)
						if d.Art then
							d.Art.Node = v
						end
					end)
				end,
			}),
			NumericField.Mount(scope, {
				Label = "Qi Cost",
				Hint = "Spent from the caster's pool on every use. 0 is legal.",
				Value = artQiCost,
				Min = ArtConstants.Limits.QiCost.Min,
				Max = ArtConstants.Limits.QiCost.Max,
				Steps = { 1, 5 },
				Decimals = 0,
				Visible = hasArt,
				OnChanged = function(v)
					applyChange(props, function(d)
						if d.Art then
							d.Art.QiCost = v
						end
					end)
				end,
			}),
			NumericField.Mount(scope, {
				Label = "Required Tier",
				Hint = "Minimum tier before a player can unlock this art.",
				Value = artRequiredTier,
				Min = ArtConstants.Limits.RequiredTier.Min,
				Max = ArtConstants.Limits.RequiredTier.Max,
				Steps = { 1 },
				Decimals = 0,
				Visible = hasArt,
				OnChanged = function(v)
					applyChange(props, function(d)
						if d.Art then
							d.Art.RequiredTier = v
						end
					end)
				end,
			}),
		}),
		-- Prerequisite is a free-text MoveId rather than a dropdown of sibling arts, and that is a
		-- deliberate v1 limit rather than an oversight: this panel only ever holds ONE move (the draft),
		-- and the list of every other art in the same tree lives in the registry, which this file has no
		-- reference to and would have to reach through a new remote to read. The server validates the
		-- value either way -- a self-reference is rejected outright at save, and a prerequisite that is
		-- missing, in another tree, or not shallower is reported by ArtTreeManager.AuditPrerequisites --
		-- so a typo costs an unreachable art that an audit names, never a wrongly-granted one.
		visibleWhen(
			scope,
			6,
			hasArt,
			TextFieldRow(scope, props, "Prerequisite Art Id", 1, function(d)
				return if d.Art and d.Art.Prerequisite then d.Art.Prerequisite else ""
			end, function(d, text)
				if d.Art then
					local trimmed = text:match("^%s*(.-)%s*$") or ""
					d.Art.Prerequisite = if trimmed == "" then nil else trimmed
				end
			end)
		),
	})

	local statsContent = sectionContent(
		"Stats",
		"Stats",
		Copy.Sections.Stats,
		StatsPanel.Build(scope, {
			Context = draftContext,
			TestSamples = props.TestSamples,
			ContentWidth = innerWidth,
		})
	)

	-- Shown while nothing is selected, in the SAME slot the section panes occupy and at the same size,
	-- so selecting a move swaps content in place rather than shifting the whole pane. Replaces a bare
	-- "Select or create a move to edit." line, which described the state an admin was already looking
	-- at without saying what the screen was for or what to do next -- and left the entire content
	-- column empty while doing it.
	local emptyState = Panel(scope, {
		Name = "EmptyState",
		Size = contentSize,
		LayoutOrder = 1,
		Elevated = true,
		Visible = scope:Computed(function(use)
			return not use(hasDraft)
		end),

		Children = {
			scope:New "UIPadding" {
				PaddingTop = UDim.new(0, Tokens.Space.XL),
				PaddingBottom = UDim.new(0, Tokens.Space.XL),
				PaddingLeft = UDim.new(0, Tokens.Space.XL),
				PaddingRight = UDim.new(0, Tokens.Space.XL),
			},
			scope:New "UIListLayout" {
				FillDirection = Enum.FillDirection.Vertical,
				HorizontalAlignment = Enum.HorizontalAlignment.Left,
				Padding = UDim.new(0, Tokens.Space.M),
				SortOrder = Enum.SortOrder.LayoutOrder,
			},
			Label(scope, {
				Text = Copy.Empty.Title,
				Scale = "CardTitle",
				LayoutOrder = 1,
			}),
			Label(scope, {
				Text = Copy.Empty.Body,
				Scale = "Body",
				Color = Tokens.Color.TextSecondary,
				AutoHeight = true,
				LineHeight = Tokens.Leading.Prose,
				Size = UDim2.fromScale(1, 0),
				LayoutOrder = 2,
			}),
			scope:New "Frame" {
				Name = "NewMoveSlot",
				Size = UDim2.fromOffset(140, Tokens.Control.RowHeight),
				BackgroundTransparency = 1,
				LayoutOrder = 3,

				[Children] = Button(scope, {
					Text = "New Move",
					Variant = "Primary",
					Size = UDim2.fromOffset(140, Tokens.Control.RowHeight),
					OnActivated = props.OnNew,
				}),
			},
			Label(scope, {
				Text = Copy.Empty.Shortcuts,
				Scale = "Detail",
				Color = Tokens.Color.TextDisabled,
				LayoutOrder = 4,
			}),
		},
	}) :: Frame

	local toolbar = scope:New "Frame" {
		Name = "Toolbar",
		Size = UDim2.new(1, 0, 0, TOOLBAR_HEIGHT),
		BackgroundTransparency = 1,
		Visible = hasDraft,
		LayoutOrder = 1,

		[Children] = {
			scope:New "UIListLayout" {
				FillDirection = Enum.FillDirection.Vertical,
				Padding = UDim.new(0, Tokens.Space.XS),
				SortOrder = Enum.SortOrder.LayoutOrder,
			},

			-- ROW 1 -- the actions. A fixed-height band rather than a plain horizontal list, because
			-- the UNSAVED chip has to sit hard right and a UIListLayout has no way to push one child
			-- to the far end of a row.
			scope:New "Frame" {
				Name = "ActionRow",
				Size = UDim2.new(1, 0, 0, TOOLBAR_ROW_HEIGHT),
				BackgroundTransparency = 1,
				LayoutOrder = 1,

				[Children] = {
					scope:New "Frame" {
						Name = "Actions",
						Size = UDim2.fromOffset(0, TOOLBAR_ROW_HEIGHT),
						AutomaticSize = Enum.AutomaticSize.X,
						BackgroundTransparency = 1,

						[Children] = {
							scope:New "UIListLayout" {
								FillDirection = Enum.FillDirection.Horizontal,
								VerticalAlignment = Enum.VerticalAlignment.Center,
								Padding = UDim.new(0, Tokens.Space.S),
								SortOrder = Enum.SortOrder.LayoutOrder,
							},
							-- Save is always visible (both Custom and Default moves persist).
							scope:New "Frame" {
								Name = "SaveSlot",
								Size = UDim2.fromOffset(100, Tokens.Control.RowHeight),
								BackgroundTransparency = 1,
								LayoutOrder = 2,

								[Children] = Button(scope, {
									Text = "Save",
									Variant = "Primary",
									Size = UDim2.fromOffset(100, Tokens.Control.RowHeight),
									OnActivated = props.OnSave,
								}),
							},
							-- Custom-only: a Default move's identity is a fixed synthetic MoveId backed by
							-- a live Constants table, so there is nothing to mint a second copy of.
							scope:New "Frame" {
								Name = "DuplicateSlot",
								Size = UDim2.fromOffset(100, Tokens.Control.RowHeight),
								BackgroundTransparency = 1,
								LayoutOrder = 3,
								Visible = isCustomMove,

								[Children] = Button(scope, {
									Text = "Duplicate",
									Size = UDim2.fromOffset(100, Tokens.Control.RowHeight),
									OnActivated = props.OnDuplicate,
								}),
							},
							-- Default-move-only, sits alongside Save (not in place of it) -- reverts to
							-- the pristine Constants.lua file value AND clears any previously-saved
							-- override, see file header.
							scope:New "Frame" {
								Name = "ResetToDefaultSlot",
								Size = UDim2.fromOffset(150, Tokens.Control.RowHeight),
								BackgroundTransparency = 1,
								LayoutOrder = 4,
								Visible = isDefaultMove,

								[Children] = Button(scope, {
									Text = "Reset to Default",
									Variant = "Primary",
									Size = UDim2.fromOffset(150, Tokens.Control.RowHeight),
									OnActivated = props.OnReset,
								}),
							},
						},
					},
					-- The unsaved-changes chip. UpdateDraft has already applied this edit to the
					-- server's IN-MEMORY registry (so Test on Dummy sees it immediately), but only Save
					-- writes the DataStore -- this chip is the only thing on screen that says so.
					-- Warning bronze rather than Danger: nothing is wrong, there is just uncommitted
					-- work. Paired with a stroke as well as a fill, per Tokens.Color's Critical States
					-- rule that hue is never the only signal.
					scope:New "Frame" {
						Name = "UnsavedChip",
						AnchorPoint = Vector2.new(1, 0.5),
						Position = UDim2.fromScale(1, 0.5),
						Size = UDim2.fromOffset(0, Tokens.Control.StepButtonSize),
						AutomaticSize = Enum.AutomaticSize.X,
						BackgroundColor3 = Tokens.Wash.AccentFill.Color,
						BackgroundTransparency = Tokens.Wash.AccentFill.Transparency,
						BorderSizePixel = 0,
						Visible = props.IsDirty,

						[Children] = {
							scope:New "UIStroke" {
								Color = Tokens.Color.Warning,
								Thickness = 1,
								Transparency = 0.5,
							},
							scope:New "UIPadding" {
								PaddingLeft = UDim.new(0, Tokens.Space.S),
								PaddingRight = UDim.new(0, Tokens.Space.S),
							},
							scope:New "UIListLayout" {
								FillDirection = Enum.FillDirection.Horizontal,
								VerticalAlignment = Enum.VerticalAlignment.Center,
								SortOrder = Enum.SortOrder.LayoutOrder,
							},
							TrackedLabel(scope, {
								Text = "UNSAVED",
								Scale = "Action",
								Color = Tokens.Color.Warning,
							}),
						},
					},
				},
			},

			-- ROW 2 -- context: which hotbar slots this move occupies, and how the last test went.
			scope:New "Frame" {
				Name = "ContextRow",
				Size = UDim2.new(1, 0, 0, TOOLBAR_ROW_HEIGHT),
				BackgroundTransparency = 1,
				LayoutOrder = 2,

				[Children] = {
					scope:New "UIListLayout" {
						FillDirection = Enum.FillDirection.Horizontal,
						VerticalAlignment = Enum.VerticalAlignment.Center,
						Padding = UDim.new(0, Tokens.Space.S),
						SortOrder = Enum.SortOrder.LayoutOrder,
					},
					hotbarBindRow(scope, props, draftMoveId, isCustomMove),
					Label(scope, {
						Text = props.LastTestResultText,
						Scale = "Body",
						Color = Tokens.Color.TextPrimary,
						LayoutOrder = 5,
						-- Spelled out rather than the magic `-500` this carried while it shared ONE row
						-- with every action button: it now only has to clear the hotbar row beside it,
						-- which leaves roughly 340px for the result string instead of 76.
						Size = UDim2.new(1, -(HOTBAR_ROW_WIDTH + Tokens.Space.S), 1, 0),
					}),
				},
			},
		},
	} :: Frame

	return Panel(scope, {
		Name = "PropertyEditor",
		Size = UDim2.fromOffset(width, height),
		CornerAccent = true,

		Children = {
			scope:New "UIPadding" {
				PaddingTop = UDim.new(0, Tokens.Space.M),
				PaddingBottom = UDim.new(0, Tokens.Space.M),
				PaddingLeft = UDim.new(0, Tokens.Space.M),
				PaddingRight = UDim.new(0, Tokens.Space.M),
			},
			scope:New "UIListLayout" {
				FillDirection = Enum.FillDirection.Vertical,
				HorizontalAlignment = Enum.HorizontalAlignment.Left,
				Padding = UDim.new(0, Tokens.Space.S),
				SortOrder = Enum.SortOrder.LayoutOrder,
			},
			toolbar,
			emptyState,
			basicInfoContent,
			hitboxContent,
			offsetContent,
			timingContent,
			damageContent,
			animationContent,
			movementContent,
			knockbackContent,
			projectileContent,
			objectStunContent,
			artContent,
			statsContent,
		},
	}) :: Frame
end

return PropertyEditorModule
