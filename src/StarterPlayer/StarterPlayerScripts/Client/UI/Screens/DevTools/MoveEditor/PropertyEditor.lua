--!strict
--[[
	PropertyEditor.lua

	Owns: the Move Editor's content pane -- the full authoring form for whichever move is currently
	selected (props.Draft), now split by Sidebar.lua's Sections nav instead of one long scroll. A
	persistent toolbar (Spawn/Despawn Dummy / Save / Hotbar bind row / last-test-result) sits at the
	top regardless of which section is active; below it, exactly one Section(scope,...)-wrapped
	"detail page" per MoveEditor/Types.lua SectionId is Visible at a time (props.SelectedSection,
	owned by Sidebar.lua), all of them mounted up front and toggled via Visible rather than
	re-mounted on nav clicks -- the same idiom Screens/DevTools/DevMenu/ContentArea.lua's own `tabContent`
	already established for its 4-tab strip.

	MOST OF THOSE PAGES ARE NO LONGER BUILT HERE. This file mounts every section and owns the chrome
	around it, but only BasicInfo/Offset/Timing/Damage -- plain forms over top-level draft fields --
	still have their controls written inline. Everything with real structure of its own delegates to
	a sibling module through the shared DraftBinding.DraftContext:

	  Hitbox              -> HitboxEditor.lua
	  Animation           -> AnimationTimelineEditor.lua
	  Movement, Knockback,
	  Grab, Projectile    -> EffectsEditor.lua (Build* per section)
	  ObjectStun          -> ObjectStunEditor.lua
	  Art                 -> ArtBindingEditor.lua
	  Stats               -> StatsPanel.lua

	The last two of those moved out when this file was 1662 lines, which is the only reason the split
	happened where it did: Effects (four near-identical enable-toggle-plus-numbers blocks over four
	optional sub-tables) and Art (the one section that talks to a system outside combat) were the two
	groups with nothing tying them to their neighbours. What is left is the toolbar, the section
	chrome, and the four sections that are genuinely just fields.

	The toolbar's Hotbar row (2026-08-10, the Move Creation System hotbar pass) is 5 small Tab.lua
	buttons, one per slot -- Selected reflects whether HotbarBindings currently maps that slot to
	THIS move's MoveId, and clicking toggles it (bind if not already this move, unbind if it is) via
	OnBindHotbarSlot, which now equips a real Art server-side (ArtSystem.DevGrantAndEquip) rather
	than writing a client-only binding -- see HotbarBindings.lua's own header. Hidden for a Default
	move: a Default move is a fixed weapon stage, never authored with a MoveTypes.MoveArtBinding, so
	binding one would only ever come back "NotAnArt" -- there is no affordance to add here because
	there is nothing a Default move could legally occupy a slot as.

	Every numeric field is a Components/NumericField.lua row; text fields commit on FocusLost rather
	than per-keystroke (DraftBinding.TextRow). Related numerics that used to stack in one long
	vertical column (Offset X/Y/Z, the Timing quartet, the Damage quartet, ...) are grouped
	side-by-side via DraftBinding.Row -- the exact fractional-width Cell idiom ContentArea.lua's own
	Godmode/Flight/Collide row already uses (`UDim2.new(1/N, -Tokens.Space.XS, 0, 0)` cells in a
	horizontal UIListLayout), generalized to any column count. This file had its own byte-identical
	`numericRow` copy of that until the split; there is one now. A row's fields all share one Visible
	condition (e.g. every Size X/Y/Z field is Visible=isBox), so when that condition is false every
	cell collapses to zero height and the whole row disappears with it -- no separate row-level
	Visible needed.

	Every field's OnChanged handler still calls the shared `applyChange` helper: clone the current
	draft, mutate the ONE field that changed, hand the result to props.OnFieldChanged. That closure
	(owned by init.lua) sets props.Draft immediately (so this panel, Sidebar.lua's status dots, and
	PreviewViewport all feel instant) and forwards the same full draft to MoveEditorClient.lua over
	the OUTER DraftFieldChanged signal, which is what actually debounces the UpdateDraft network call
	-- see MoveEditor/Types.lua's header for that boundary. This panel never talks to a remote itself.

	ArcDegrees/MaxTargets are still always populated (never left nil) on every draft this screen
	produces -- v1 keeps every optional HitboxAttackDefinition field concrete rather than adding an
	enable/disable toggle for each one. The optional sub-tables DO each get an explicit toggle --
	unlike Arc/MaxTargets, "no movement grant," "no knockback," and "not a projectile" are all
	extremely common, expected states for a plain stationary hitbox. Those toggles now live in
	EffectsEditor.lua/ArtBindingEditor.lua with the fields they gate.

	Sub-table cloning is not this file's problem: `applyChange` deep-copies through MoveTypes.Clone,
	so a handler here can mutate in place and be correct. That matters less than it used to now that
	every sub-table-editing section has moved out (those panels commit through DraftBinding.Apply,
	whose clone is shallow, and each owns one clone-then-mutate helper for its own block -- see
	EffectsEditor.lua's applyToSubTable). What remains here writes top-level fields only.

	Category == "Default" (Server/Combat/DefaultMoveRegistry.lua's reserved sentinel, see MoveTypes.
	lua's own header) changes this panel's chrome in three ways: DisplayName/Category/AnimationId
	render read-only (a plain Label sits where a TextField normally would -- see DraftBinding.TextRow's
	own `ReadOnly` prop; MoveId/Author were never editable fields here to begin with, so nothing
	further is needed for those two); the toolbar shows BOTH Save (OnSave persists the move's current
	live values to a DataStore override, same button/handler shape a custom move's Save uses) AND
	"Reset to Default" (OnReset both live-reverts AND clears that override -- see MoveEditorSystem.
	lua's own header) side by side, rather than Save being replaced; and every section in
	MoveEditor/Types.lua's HiddenForDefaultSections additionally hides its CONTENT even if
	SelectedSection still points at one of them (their nav items are already hidden by Sidebar.lua,
	but selection persists across a move switch by design -- see that file's header -- so this panel
	double-checks rather than trust the nav alone).

	"Test on Dummy" is REAL AGAIN (2026-08-19, the Move Editor repair pass) -- see
	MoveEditor/Types.lua's own MoveEditorHandle header for the rebuilt pipeline. This panel's own part
	of it is small: the toolbar's "Spawn Dummy"/"Despawn Dummy" buttons (OnSpawnTestDummy/
	OnDespawnTestDummy) sit beside Save, and StatsPanel/LastTestResultText below are unchanged --
	still pure display, fed by whatever handle.TestSamples holds -- because MoveEditorClient.lua is
	what now actually writes into it again, not this file.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local MoveTypes = require(ReplicatedStorage.Shared.MoveTypes)
local Tokens = require(script.Parent.Parent.Parent.Parent.Tokens)
local Panel = require(script.Parent.Parent.Parent.Parent.Components.Panel)
local Label = require(script.Parent.Parent.Parent.Parent.Components.Label)
local Section = require(script.Parent.Parent.Parent.Parent.Components.Section)
local SectionIcon = require(script.Parent.Parent.Parent.Parent.Components.SectionIcon)
local Button = require(script.Parent.Parent.Parent.Parent.Components.Button)
local Tab = require(script.Parent.Parent.Parent.Parent.Components.Tab)
local TrackedLabel = require(script.Parent.Parent.Parent.Parent.Components.TrackedLabel)
local NumericField = require(script.Parent.Parent.Parent.Parent.Components.NumericField)
local ScrollArea = require(script.Parent.Parent.Parent.Parent.Components.ScrollArea)
local MoveEditorTypes = require(script.Parent.Types)
local Copy = require(script.Parent.Copy)
local DraftBinding = require(script.Parent.DraftBinding)
local HitboxEditor = require(script.Parent.HitboxEditor)
local AnimationTimelineEditor = require(script.Parent.AnimationTimelineEditor)
local ObjectStunEditor = require(script.Parent.ObjectStunEditor)
local EffectsEditor = require(script.Parent.EffectsEditor)
local ArtBindingEditor = require(script.Parent.ArtBindingEditor)
local StatsPanel = require(script.Parent.StatsPanel)
local MoveStats = require(ReplicatedStorage.Shared.MoveStats)
local FrameTimeline = require(script.Parent.FrameTimeline)
local EditorTokens = require(script.Parent.EditorTokens)

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
	-- Toolbar's single toggling "Spawn Dummy"/"Despawn Dummy" button -- MoveEditorClient.lua routes
	-- both directions through DevMenuSystem's own DevMenu_SpawnDummy/DevMenu_DespawnAllDebugDummies
	-- remotes (Server/Systems/DebugDummySystem.lua) rather than a second dummy implementation.
	-- HasTestDummy is this client's own best-effort local guess (flipped optimistically on a
	-- successful Spawn/Despawn, not polled from the server) -- worst case it mislabels the button for
	-- one click, which the request underneath tolerates fine either way (spawning again just makes a
	-- second dummy, MaxActive eviction handles the overflow; despawning with none active is a no-op).
	HasTestDummy: UsedAs<boolean>,
	OnToggleTestDummy: () -> (),
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
-- below is built from this so a NumericField never has to nil-check its own Value prop.
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

-- The toolbar's 5-button "which hotbar slot(s) is this move bound to" row -- see file header. Built
-- as its own local function (not inlined into the toolbar table below) for the same reason
-- DraftBinding.Row is: 5 near-identical buttons that only differ by slot number.
--
-- Pressing a slot EQUIPS this move as an art (MoveEditor_EquipArtSlot -> ArtSystem
-- .DevGrantAndEquip), which is why `isArt` gates the buttons: a hotbar slot holds exactly one
-- thing and that thing is always an art, so a move with no Art binding is refused server-side with
-- "NotAnArt". Rather than let an admin press a button that can only fail, the buttons are replaced
-- in place by the one sentence that says what to do about it -- the Art section is right there in
-- the nav.
local function hotbarBindRow(
	scope: Scope,
	props: PropertyEditorProps,
	moveId: UsedAs<string>,
	visible: UsedAs<boolean>,
	isArt: UsedAs<boolean>
): Frame
	local notArt = scope:Computed(function(use)
		return not use(isArt)
	end)
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
				Visible = isArt,
				OnActivated = function()
					props.OnBindHotbarSlot(slot)
				end,
			})
		)
	end
	table.insert(
		slotButtons,
		Label(scope, {
			Text = "Add an Art binding to put this on a slot.",
			Scale = "Detail",
			Color = Tokens.Color.TextSecondary,
			Size = UDim2.fromOffset(240, Tokens.Control.RowHeight),
			LayoutOrder = HOTBAR_SLOT_COUNT + 1,
			Visible = notArt,
		})
	)

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
	-- Whether this move is an ART, i.e. carries a MoveArtBinding -- which is now the same question as
	-- "can this go on a hotbar slot", because a slot only ever holds an art (see hotbarBindRow).
	local hasArtBinding = scope:Computed(function(use)
		local draft = use(props.Draft)
		return draft ~= nil and draft.Art ~= nil
	end)
	-- Feeds hotbarBindRow's own Selected computation per slot -- "" (never a real MoveId) while
	-- nothing is selected, so that check is always false rather than needing its own nil-guard.
	local draftMoveId = scope:Computed(function(use)
		local draft = use(props.Draft)
		return if draft then draft.MoveId else ""
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

	local innerWidth = width - Tokens.Space.M * 2
	-- Spelled out, and it MOVES when the toolbar does: this Panel's own vertical padding, the toolbar
	-- band, and the list gap under it. TOOLBAR_HEIGHT went 40 -> 84 when the toolbar became two rows,
	-- so this went 608 -> 564. Roblox's UIListLayout has no flex-grow, which is why the "fills the
	-- rest" pane has to compute its own height rather than being told to take what's left.
	local contentHeight = height - Tokens.Space.M * 2 - TOOLBAR_HEIGHT - Tokens.Space.S
	local contentSize = UDim2.fromOffset(innerWidth, contentHeight)

	-- The optional-sub-table sections are non-functional for a Default move -- their nav items are
	-- already hidden by Sidebar.lua, but SelectedSection deliberately persists across a move switch
	-- (that file's own header), so a content pane still double-checks here rather than trusting the
	-- nav alone to keep the admin off it. The LIST is MoveEditor/Types.lua's, shared with Sidebar.lua
	-- rather than hand-written twice -- see that table's own header for the drift that caused.
	local HIDDEN_FOR_DEFAULT = MoveEditorTypes.HiddenForDefaultSections

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
		-- (SectionId and SectionIconGlyphKind are structurally the same union, member for member, by
		-- construction). AccentPrimaryBright, not a Computed -- this icon sits on an already-Visible-
		-- gated ScrollingFrame with no idle/selected state of its own to react to, unlike Sidebar's
		-- nav icon.
		local icon = SectionIcon(scope, { Glyph = sectionId, Color = Tokens.Color.AccentPrimaryBright })

		return ScrollArea(scope, {
			Name = sectionId .. "Content",
			Size = contentSize,
			LayoutOrder = 2,
			Visible = isVisible,

			Children = {
				scope:New "UIPadding" { PaddingRight = UDim.new(0, Tokens.Space.XS) },
				scope:New "UIListLayout" {
					FillDirection = Enum.FillDirection.Vertical,
					Padding = UDim.new(0, Tokens.Space.M),
					SortOrder = Enum.SortOrder.LayoutOrder,
				},
				Section(scope, title, 1, fields, description, icon, true, summary),
			},
		})
	end

	-- MOST sections now hand their whole content off to a dedicated sibling module rather than
	-- building fields inline: Hitbox, Animation, ObjectStun and Stats always did (each outgrew an
	-- inline block -- twelve shapes reading twelve different subsets of eight measurement fields; an
	-- ordered clip list with per-clip start/stop/blend rules; an Object Stun config with its own
	-- follow-up sub-form; a stats readout with graphs), and Movement/Knockback/Grab/Projectile
	-- (EffectsEditor.lua) and Art (ArtBindingEditor.lua) joined them when this file was split. All of
	-- them are forms over this same draft, so they take the shared DraftContext below and return the
	-- section's children; this file supplies the card chrome and keeps only BasicInfo/Offset/Timing/
	-- Damage, which are plain top-level-field forms with nothing to extract.
	local draftContext: DraftBinding.DraftContext = {
		Draft = props.Draft,
		OnFieldChanged = props.OnFieldChanged,
	}

	local basicInfoContent = sectionContent("BasicInfo", "Basic Info", Copy.Sections.BasicInfo, {
		-- ReadOnly rather than absent for a Default move: its name and category are real, meaningful
		-- values an admin still wants to READ while tuning it -- they just aren't the admin's to change
		-- (see file header).
		DraftBinding.TextRow(scope, draftContext, {
			Label = "Display Name",
			LayoutOrder = 3,
			ReadOnly = isDefaultMove,
			Get = function(d)
				return d.DisplayName
			end,
			OnCommit = function(text: string)
				applyChange(props, function(d)
					d.DisplayName = text
				end)
			end,
		}),
		-- Multiline, and LAST in the section: it is the only field here that is prose rather than an
		-- identifier, and a tall box between two short ones reads as a layout accident.
		DraftBinding.TextRow(scope, draftContext, {
			Label = "Description",
			LayoutOrder = 5,
			Multiline = true,
			-- The same 400 MoveRegistryManager truncates at -- a box that accepts more than the save
			-- keeps would silently drop the end of a paragraph someone just wrote.
			MaxLength = 400,
			Placeholder = "What is this move for?",
			ReadOnly = isDefaultMove,
			Get = function(d)
				return d.Description
			end,
			OnCommit = function(text: string)
				applyChange(props, function(d)
					d.Description = text
				end)
			end,
		}),
		Label(scope, {
			Text = Copy.Field("BasicInfo.Description").Hint,
			Scale = "Detail",
			Color = Tokens.Color.TextSecondary,
			AutoHeight = true,
			LineHeight = Tokens.Leading.Prose,
			Size = UDim2.fromScale(1, 0),
			LayoutOrder = 6,
		}),
		DraftBinding.TextRow(scope, draftContext, {
			Label = "Category",
			LayoutOrder = 4,
			ReadOnly = isDefaultMove,
			Get = function(d)
				return d.Category
			end,
			OnCommit = function(text: string)
				-- The reserved sentinel is refused HERE as well as server-side (MoveRegistryManager.
				-- Validate returns "ReservedCategory" for it). Belt and braces on purpose: the server
				-- gate is the one that matters for correctness, but bouncing it at the point of typing
				-- lets the editor say WHY in plain words, where the remote path could only surface a
				-- generic rejection code in the status line. Silently leaving the old value is the right
				-- recovery -- the field re-renders from the draft, which never changed.
				if text == MoveTypes.DefaultCategory then
					return
				end
				applyChange(props, function(d)
					d.Category = text
				end)
			end,
		}),
	})

	local hitboxContent =
		sectionContent("Hitbox", "Hitbox", Copy.Sections.Hitbox, HitboxEditor.Build(scope, draftContext))

	-- One field per row -- a full NumericField (label, unit, value readout, two step buttons) doesn't
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
		-- Zeroes the offset AND its rotation in one commit, so the hitbox sits exactly on the
		-- attacker's own origin. Deliberately not "reset to the authoring default" (0, 0, -3): this
		-- codebase has no single source of truth for a field's default -- see NumericField.lua's own
		-- header on why it has no reset-to-default affordance either -- but ORIGIN is a fact about
		-- geometry, not a remembered number, so it is the one reset that cannot drift.
		--
		-- One applyChange, not three: three would push three drafts through the debounce and three
		-- entries onto the undo stack for what an author performed as one action.
		Button(scope, {
			Text = "Reset to Origin",
			Size = UDim2.fromOffset(140, Tokens.Control.RowHeight),
			LayoutOrder = 6,
			OnActivated = function()
				applyChange(props, function(d)
					d.Offset = CFrame.new()
					d.OffsetRotation = Vector3.zero
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
		DraftBinding.Row(scope, 4, 1, {
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
		DraftBinding.Row(scope, 3, 2, {
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
		DraftBinding.Row(scope, 4, 2, {
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

	-- Movement/Knockback/Grab/Projectile all live in EffectsEditor.lua -- one enable toggle plus a
	-- few numbers over one optional sub-table each, four times over, with nothing tying them to the
	-- sections around them. See that file's header.
	local movementContent =
		sectionContent("Movement", "Movement", Copy.Sections.Movement, EffectsEditor.BuildMovement(scope, draftContext))
	local knockbackContent = sectionContent(
		"Knockback",
		"Knockback",
		Copy.Sections.Knockback,
		EffectsEditor.BuildKnockback(scope, draftContext)
	)
	local grabContent = sectionContent("Grab", "Grab", Copy.Sections.Grab, EffectsEditor.BuildGrab(scope, draftContext))
	local projectileContent = sectionContent(
		"Projectile",
		"Projectile",
		Copy.Sections.Projectile,
		EffectsEditor.BuildProjectile(scope, draftContext)
	)

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
	-- Art is ArtBindingEditor.lua's -- the "convert an existing move into an art" surface, and the
	-- only section whose fields mean something to a system outside combat entirely (ArtSystem).
	local artContent = sectionContent("Art", "Art", Copy.Sections.Art, ArtBindingEditor.Build(scope, draftContext))

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

								[Children] = {
									Button(scope, {
										Text = "Save",
										Variant = "Primary",
										Size = UDim2.fromOffset(100, Tokens.Control.RowHeight),
										OnActivated = props.OnSave,
									}),
									-- A dot on the corner rather than the reference's "● Save" text. Button.lua's
									-- Primary variant renders through TrackedLabel, which peeks its text ONCE at
									-- construction (see both files' headers) -- so live text here would mean either
									-- dropping the Variant (losing the tracked-caps look every primary action in
									-- this UI shares) or widening that component for one caller. An overlaid dot
									-- says the same thing, in the same amber as the chip and the title readout.
									scope:New "Frame" {
										Name = "SaveDirtyDot",
										AnchorPoint = Vector2.new(1, 0),
										Position = UDim2.new(1, -Tokens.Space.XS, 0, Tokens.Space.XS),
										Size = UDim2.fromOffset(6, 6),
										BackgroundColor3 = EditorTokens.Dirty,
										BorderSizePixel = 0,
										ZIndex = 5,
										Visible = props.IsDirty,

										[Children] = scope:New "UICorner" { CornerRadius = UDim.new(0.5, 0) },
									},
								},
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
							-- Visible for BOTH Custom and Default moves -- see PropertyEditorProps' own
							-- HasTestDummy/OnToggleTestDummy comment. Not gated on isCustomMove/isDefaultMove at
							-- all: spawning a target has nothing to do with which kind of move is selected, only
							-- that a move IS selected (the whole toolbar's own Visible = hasDraft already covers
							-- that). ONE toggling button, not a Spawn/Despawn pair -- reoccupies the exact 140px
							-- slot the old "Test on Dummy" button held (see this file's own width-budget comment
							-- above), so this row's fit against the UNSAVED chip is unchanged from before.
							scope:New "Frame" {
								Name = "TestDummySlot",
								Size = UDim2.fromOffset(140, Tokens.Control.RowHeight),
								BackgroundTransparency = 1,
								LayoutOrder = 5,

								[Children] = Button(scope, {
									Text = scope:Computed(function(use)
										return if use(props.HasTestDummy) then "Despawn Dummy" else "Spawn Dummy"
									end),
									Size = UDim2.fromOffset(140, Tokens.Control.RowHeight),
									OnActivated = props.OnToggleTestDummy,
								}),
							},
						},
					},
					-- The unsaved-changes chip. UpdateDraft has already applied this edit to the
					-- server's IN-MEMORY registry (so Test on Dummy sees it immediately), but only Save
					-- writes the DataStore -- this chip is the only thing on screen that says so.
					-- EditorTokens.Dirty, not Tokens.Color.Warning: nothing is WRONG, there is just
					-- uncommitted work, and that distinction is the entire reason EditorTokens.Dirty exists
					-- as its own entry (see its header). The same amber marks the title-bar readout and the
					-- Save button's own dot, so one colour means one thing across all three.
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
								Color = EditorTokens.Dirty,
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
								Color = EditorTokens.Dirty,
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
					hotbarBindRow(scope, props, draftMoveId, isCustomMove, hasArtBinding),
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
			grabContent,
			projectileContent,
			objectStunContent,
			artContent,
			statsContent,
		},
	}) :: Frame
end

return PropertyEditorModule
