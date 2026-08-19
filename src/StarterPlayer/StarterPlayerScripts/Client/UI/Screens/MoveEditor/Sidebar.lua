--!strict
--[[
	Sidebar.lua

	Owns: the Move Editor's single left column -- the Moves list (MoveList.lua, unchanged internals)
	stacked above a Sections nav (Basic Info/Hitbox/Offset/Timing/Damage/Animation/Movement/
	Knockback/Projectile), inside ONE bordered card. Replaces the old bare `MoveList.Mount` call as
	init.lua's left-column child.

	Two different navigation axes -- which MOVE, and which field-GROUP of that move -- read as one
	competing pair of rails if given two separate columns; a real settings/docs site has exactly one
	left nav. Stacking both groups in a single visual card (a Divider.Plain seam between them) keeps
	it reading as one sidebar while still keeping the two lists functionally distinct.

	Nav items are a small file-local `navItem` helper, not a Tab.lua reuse and not promoted to
	Components/ -- Tab.lua's centered-chip Selected treatment is a tab-STRIP idiom (see that file's
	own header), the wrong shape for a left-aligned nav row with a left accent bar. Only this file
	calls it today; per this codebase's own "promote on second consumer" convention (Section.lua's
	header), it stays local until a second screen actually needs the same shape.

	selectedSection deliberately does NOT reset when the admin switches which move is selected --
	comparing e.g. Damage across several moves in a row by clicking through the Moves list while
	staying on the Damage section is a real, expected workflow this preserves.

	Movement/Knockback/Projectile's nav items show a small live status dot when that sub-table is
	present on the current draft -- a cheap "this section actually has content" affordance, read
	directly off `props.Draft` so it updates the instant PropertyEditor.lua's own Toggle flips it.

	Those same three nav items are HIDDEN entirely (not merely disabled) whenever the current draft's
	Category == "Default" -- Movement/Knockback/Projectile are non-functional for a Default move
	(consumed only by CombatSystem.ThrowCustomMove's own code path, see Server/Combat/
	DefaultMoveRegistry.lua's own header), so there is nothing legitimate to navigate to; showing a
	live nav item for a section that visibly does nothing would be worse than not showing it.

	Each nav item also renders Components/SectionIcon.lua's matching glyph -- SectionId and
	SectionIconGlyphKind share the same nine members by construction, so `section.Id` is passed
	straight through with no lookup table. Tinted the same way the item's own text is (TextSecondary
	idle, TextPrimary selected) so the icon reinforces rather than competes with the text state.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local MoveTypes = require(ReplicatedStorage.Shared.MoveTypes)
local Tokens = require(script.Parent.Parent.Parent.Tokens)
local Panel = require(script.Parent.Parent.Parent.Components.Panel)
local Label = require(script.Parent.Parent.Parent.Components.Label)
local TrackedLabel = require(script.Parent.Parent.Parent.Components.TrackedLabel)
local Divider = require(script.Parent.Parent.Parent.Components.Divider)
local SectionIcon = require(script.Parent.Parent.Parent.Components.SectionIcon)
local ScrollArea = require(script.Parent.Parent.Parent.Components.ScrollArea)
local MoveList = require(script.Parent.MoveList)
local MoveEditorTypes = require(script.Parent.Types)

local Children = Fusion.Children
local OnEvent = Fusion.OnEvent

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>
type SectionId = MoveEditorTypes.SectionId

export type SidebarProps = {
	MovesDisplay: UsedAs<{ MoveTypes.MoveDefinition }>,
	SelectedMoveId: UsedAs<string?>,
	-- Feeds the Movement/Knockback/Projectile nav items' status dots -- see file header.
	Draft: UsedAs<MoveTypes.MoveDefinition?>,
	OnNew: () -> (),
	OnSelect: (string) -> (),
	OnDelete: (string) -> (),
}

export type SidebarHandle = {
	Root: Frame,
	SelectedSection: Fusion.Value<SectionId>,
}

-- Fixed budget for the Moves group (header + ~3 visible two-line cards before it scrolls -- see
-- MoveList.lua's own ROW_HEIGHT). The Sections nav below it takes whatever height remains AND
-- scrolls within it.
--
-- It used to be a plain auto-sizing Frame, on the reasoning that all nine items always fit. They
-- only just did, and the eleventh (Object Stun, Stats) pushed the last two entries past the panel's
-- own fixed height, where they rendered but were clipped and therefore unreachable -- a nav item you
-- cannot scroll to is indistinguishable from one that was never added. Scrolling makes the group
-- independent of the item count instead of re-inviting that failure the next time one is added.
-- 210 -> 250 when MoveList.lua gained its search box (+32px row, +8px gap). The moves list keeps the
-- same ~2 visible rows it had before rather than losing one to the new control: MoveList's own Rows
-- ScrollingFrame subtracts header + search + filter + gaps from this budget, so raising it by exactly
-- the search row's cost leaves the scrollable area unchanged. The Sections nav below absorbs the
-- difference and already scrolls (see below), so nothing becomes unreachable.
local MOVES_GROUP_HEIGHT = 250
-- Divider.Plain's own default thickness, and the two UIListLayout gaps between this panel's three
-- children -- subtracted below so the nav claims exactly the leftover height rather than overflowing
-- the panel it lives in.
local DIVIDER_HEIGHT = 1
local NAV_ITEM_HEIGHT = Tokens.Control.RowHeight
local NAV_ACCENT_WIDTH = 4
local NAV_ICON_SIZE = 16 -- matches SectionIcon.lua's own fixed icon box size
local STATUS_DOT_SIZE = 7

local SECTION_ORDER: { { Id: SectionId, Text: string } } = {
	{ Id = "BasicInfo", Text = "Basic Info" },
	{ Id = "Hitbox", Text = "Hitbox" },
	{ Id = "Offset", Text = "Offset" },
	{ Id = "Timing", Text = "Timing" },
	{ Id = "Damage", Text = "Damage" },
	{ Id = "Animation", Text = "Animation" },
	{ Id = "Movement", Text = "Movement" },
	{ Id = "Knockback", Text = "Knockback" },
	{ Id = "Grab", Text = "Grab" },
	{ Id = "Projectile", Text = "Projectile" },
	{ Id = "ObjectStun", Text = "Object Stun" },
	{ Id = "Art", Text = "Art" },
	-- Last, and after the optional sub-tables rather than among them: Stats reports on everything
	-- above it instead of authoring anything of its own -- see MoveEditor/Types.lua's SectionId.
	{ Id = "Stats", Text = "Stats" },
}

local function navItem(
	scope: Scope,
	-- SectionId, not SectionIcon's own SectionIconGlyphKind -- the two unions are structurally
	-- identical by construction (see file header), and SectionId is already an established type
	-- reference in this file (MoveEditorTypes.SectionId), where reaching into a sibling module that
	-- returns a bare function (SectionIcon.lua returns `SectionIcon`, not a table) for its own
	-- `export type` has no working precedent anywhere else in this codebase.
	glyph: SectionId,
	text: string,
	layoutOrder: number,
	selected: UsedAs<boolean>,
	showDot: UsedAs<boolean>,
	visible: UsedAs<boolean>,
	onActivated: () -> ()
): TextButton
	local isHovering = scope:Value(false)

	local backgroundColor = scope:Computed(function(use)
		if use(selected) then
			return Tokens.Wash.AccentFill.Color
		end
		return Tokens.Color.SurfaceElevated
	end)
	local backgroundTransparency = scope:Computed(function(use)
		if use(selected) then
			return Tokens.Wash.AccentFill.Transparency
		end
		return if use(isHovering) then 0 else 1
	end)
	-- Icon and text share this exact Computed -- see file header on why the icon reinforces the
	-- text's own state instead of getting a separate color story.
	local foregroundColor = scope:Computed(function(use)
		return if use(selected) then Tokens.Color.TextPrimary else Tokens.Color.TextSecondary
	end)

	local iconInset = NAV_ACCENT_WIDTH + Tokens.Space.S
	local labelInset = iconInset + NAV_ICON_SIZE + Tokens.Space.XS

	return scope:New "TextButton" {
		Name = text,
		Size = UDim2.new(1, 0, 0, NAV_ITEM_HEIGHT),
		LayoutOrder = layoutOrder,
		Visible = visible,
		BackgroundColor3 = backgroundColor,
		BackgroundTransparency = backgroundTransparency,
		BorderSizePixel = 0,
		AutoButtonColor = false,
		Text = "",

		[OnEvent "MouseEnter"] = function()
			isHovering:set(true)
		end,
		[OnEvent "MouseLeave"] = function()
			isHovering:set(false)
		end,
		[OnEvent "Activated"] = onActivated,

		[Children] = {
			scope:New "Frame" {
				Name = "AccentBar",
				Size = UDim2.new(0, NAV_ACCENT_WIDTH, 1, 0),
				BackgroundColor3 = Tokens.Color.AccentPrimary,
				BorderSizePixel = 0,
				Visible = selected,
			},
			scope:New "Frame" {
				Name = "IconSlot",
				AnchorPoint = Vector2.new(0, 0.5),
				Position = UDim2.new(0, iconInset, 0.5, 0),
				Size = UDim2.fromOffset(NAV_ICON_SIZE, NAV_ICON_SIZE),
				BackgroundTransparency = 1,

				[Children] = SectionIcon(scope, { Glyph = glyph, Color = foregroundColor }),
			},
			Label(scope, {
				Text = text,
				Scale = "Body",
				Color = foregroundColor,
				AnchorPoint = Vector2.new(0, 0.5),
				Position = UDim2.new(0, labelInset, 0.5, 0),
				Size = UDim2.new(1, -(labelInset + Tokens.Space.M), 1, 0),
			}),
			scope:New "Frame" {
				Name = "StatusDot",
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.new(1, -Tokens.Space.S, 0.5, 0),
				Size = UDim2.fromOffset(STATUS_DOT_SIZE, STATUS_DOT_SIZE),
				BackgroundColor3 = Tokens.Color.AccentPrimaryBright,
				BorderSizePixel = 0,
				Visible = showDot,

				[Children] = scope:New "UICorner" { CornerRadius = Tokens.Radius.Sharp },
			},
		},
	} :: TextButton
end

local SidebarModule = {}

function SidebarModule.Mount(scope: Scope, width: number, height: number, props: SidebarProps): SidebarHandle
	local selectedSection: Fusion.Value<SectionId> = scope:Value("BasicInfo" :: SectionId)

	local innerWidth = width - Tokens.Space.M * 2

	local moveListRoot = MoveList.Mount(scope, innerWidth, MOVES_GROUP_HEIGHT, {
		MovesDisplay = props.MovesDisplay,
		SelectedMoveId = props.SelectedMoveId,
		OnNew = props.OnNew,
		OnSelect = props.OnSelect,
		OnDelete = props.OnDelete,
	})

	local hasMovement = scope:Computed(function(use)
		local draft = use(props.Draft)
		return draft ~= nil and draft.Movement ~= nil
	end)
	local hasKnockback = scope:Computed(function(use)
		local draft = use(props.Draft)
		return draft ~= nil and draft.Knockback ~= nil
	end)
	local hasGrab = scope:Computed(function(use)
		local draft = use(props.Draft)
		return draft ~= nil and draft.Grab ~= nil
	end)
	local hasProjectile = scope:Computed(function(use)
		local draft = use(props.Draft)
		return draft ~= nil and draft.Projectile ~= nil
	end)
	-- Enabled, not merely present: unlike the three above, an ObjectStun sub-table is written the
	-- moment its section is opened and stays behind an Enabled flag, so presence alone would light the
	-- dot for every move whose Object Stun section had ever been looked at.
	local hasObjectStun = scope:Computed(function(use)
		local draft = use(props.Draft)
		return draft ~= nil and draft.ObjectStun ~= nil and draft.ObjectStun.Enabled
	end)
	local statusDots: { [string]: Fusion.Computed<boolean> } = {
		Movement = hasMovement,
		Knockback = hasKnockback,
		Grab = hasGrab,
		Projectile = hasProjectile,
		ObjectStun = hasObjectStun,
	}

	-- Movement/Knockback/Grab/Projectile/ObjectStun are non-functional for a Default move -- see this
	-- file's own header -- so those five (and only those five) nav items hide entirely whenever the
	-- current draft's Category == "Default". Every other section stays visible regardless.
	local HIDDEN_FOR_DEFAULT: { [string]: boolean } =
		{ Movement = true, Knockback = true, Grab = true, Projectile = true, ObjectStun = true }
	local isDefaultMove = scope:Computed(function(use)
		local draft = use(props.Draft)
		return draft ~= nil and draft.Category == MoveTypes.DefaultCategory
	end)

	local navItems: { Instance } = {}
	for index, section in ipairs(SECTION_ORDER) do
		local selected = scope:Computed(function(use)
			return use(selectedSection) == section.Id
		end)
		local showDot: UsedAs<boolean> = statusDots[section.Id] or false
		local visible: UsedAs<boolean> = if HIDDEN_FOR_DEFAULT[section.Id]
			then scope:Computed(function(use)
				return not use(isDefaultMove)
			end)
			else true
		table.insert(
			navItems,
			navItem(scope, section.Id, section.Text, index, selected, showDot, visible, function()
				selectedSection:set(section.Id)
			end)
		)
	end

	local root = Panel(scope, {
		Name = "Sidebar",
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
				Padding = UDim.new(0, Tokens.Space.M),
				SortOrder = Enum.SortOrder.LayoutOrder,
			},
			moveListRoot,
			Divider.Plain(scope, { LayoutOrder = 2 }),
			ScrollArea(scope, {
				Name = "SectionsGroup",
				-- Exactly the height left over once the Moves group, the divider and the two list gaps
				-- above have taken theirs -- see MOVES_GROUP_HEIGHT's own comment on why this scrolls.
				-- Matches PropertyEditor.lua's own section panes, so the two scrollable regions of this
				-- screen read as the same control rather than two different ones.
				Size = UDim2.new(1, 0, 1, -(MOVES_GROUP_HEIGHT + DIVIDER_HEIGHT + Tokens.Space.M * 2)),
				LayoutOrder = 3,

				Children = {
					-- Keeps the last nav item clear of the scrollbar's own track, the same inset the
					-- section panes use.
					scope:New "UIPadding" { PaddingRight = UDim.new(0, Tokens.Space.XS) },
					scope:New "UIListLayout" {
						FillDirection = Enum.FillDirection.Vertical,
						HorizontalAlignment = Enum.HorizontalAlignment.Left,
						Padding = UDim.new(0, Tokens.Space.XS),
						SortOrder = Enum.SortOrder.LayoutOrder,
					},
					TrackedLabel(scope, {
						Text = "SECTIONS",
						Scale = "Action",
						Color = Tokens.Color.TextPrimary,
						LayoutOrder = 1,
					}),
					table.unpack(navItems),
				},
			}),
		},
	}) :: Frame

	return {
		Root = root,
		SelectedSection = selectedSection,
	}
end

return SidebarModule
