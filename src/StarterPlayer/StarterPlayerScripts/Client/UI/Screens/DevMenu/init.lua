--!strict
--[[
	DevMenu/init.lua

	Owns: the mounted whitelist-gated developer menu panel's thin root -- ScreenGui > Root Panel >
	Header/Body/Footer, plus IsOpen/StatusText and the root panel's own TOP-LEVEL layout budget
	(ROOT_SIZE, the Sidebar/Content column-width split, and the shared Body row height each column
	receives). Everything else that used to live in this single ~1545-line file has moved to two
	sibling modules:

	- Sidebar.lua -- the persistent left-column roster + Player-Count stat header, visible regardless
	  of which ContentArea tab is selected.
	- ContentArea.lua -- every DevMenu tab (Spawn/Admin/Tuning/Reports) -- "Players" was dropped from
	  the tab strip in this phase (Phase 1), see that module's own header.
	- Types.lua -- every type both of the above share, so neither has to require the other.

	Phase 0 was a pure file split with byte-identical behavior (single vertical stack, "Players" still
	a tab). THIS PHASE (Phase 1) is the real shell restructure: a persistent Sidebar column next to a
	tabbed ContentArea column, side by side in a horizontal Body row -- see ROOT_SIZE/SIDEBAR_WIDTH/
	CONTENT_WIDTH/BODY_HEIGHT below for the explicit budget this splits into. Each column then owns
	ITS OWN internal budget below that split (Sidebar's stats-header-vs-roster-scroll, ContentArea's
	tab-strip-vs-scroll-area) -- this root only ever hands each column a `(width, bodyHeight)` pair,
	never dictates what a column does inside that footprint.

	Fixed-size layout throughout (not AutomaticSize) -- replaces an earlier revision that stacked all
	~23 controls in one AutomaticSize.XY panel with no scrolling anywhere in this UI framework, so the
	bottom section (hitbox tuner, reset) rendered off-screen on most viewports with no way to reach
	it. This module always mounts (same as every other Screen); staying hidden until a dev opens it is
	just IsOpen defaulting false, the same pattern Menus.lua already uses. Local-only visibility
	(should this player even see the menu) is DevMenuClient.lua's job, not this module's.

	TargetNameDisplay (rendered in the Header below) is owned by ContentArea.lua's handle (the Admin
	tab is what actually resolves/uses it) -- this root reads content.TargetNameDisplay to build its
	own Header label, the same way any Fusion Computed may read a Value it doesn't own.

	Follows CombatFeedback.lua's "screen exposes state/signals, client module drives from outside"
	precedent: DevMenuClient.lua doesn't exist yet at the moment this mounts (UI/init.lua mounts
	every Screen before Main.client.lua boots any client integration module), so a button can't
	take a callback prop directly -- each fires a BindableEvent instead, exposed on the nested
	Sidebar/Content handles, which DevMenuClient.lua connects to after mount. The one exception is
	the close button: IsOpen is already a Fusion.Value owned by this same Mount call, so closing
	just sets it directly rather than round-tripping through a signal.

	Does not own: authorization (DevMenuSystem.lua re-checks server-side regardless of whether this
	screen is even visible), or deciding whether the local player should see this at all
	(DevMenuClient.lua's local whitelist read, itself never trusted as real authorization).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)

local Tokens = require(script.Parent.Parent.Tokens)
local ModalScreen = require(script.Parent.Parent.Components.ModalScreen)
local Label = require(script.Parent.Parent.Components.Label)
local Button = require(script.Parent.Parent.Components.Button)

local DevMenuTypes = require(script.Types)
local Sidebar = require(script.Sidebar)
local ContentArea = require(script.ContentArea)

local Children = Fusion.Children

type Scope = Fusion.Scope<typeof(Fusion)>

-- Re-exported verbatim so external requirers (DevMenuClient.lua's `DevMenuModule.BugReportRowDisplay`/
-- `DevMenuModule.PlayerRosterRowDisplay`/`DevMenuModule.DevMenuHandle` type annotations, UI/init.lua's
-- `UIHandles.DevMenu: DevMenuModule.DevMenuHandle`) keep resolving through this same require path --
-- the actual declarations now live in Types.lua, shared with Sidebar.lua/ContentArea.lua.
export type DevMenuTabName = DevMenuTypes.DevMenuTabName
export type HitboxStageDisplayProps = DevMenuTypes.HitboxStageDisplayProps
export type HitboxStandaloneDisplayProps = DevMenuTypes.HitboxStandaloneDisplayProps
export type FlightTuningDisplayProps = DevMenuTypes.FlightTuningDisplayProps
export type BugReportRowDisplay = DevMenuTypes.BugReportRowDisplay
export type PlayerRosterRowDisplay = DevMenuTypes.PlayerRosterRowDisplay

export type DevMenuHandle = {
	IsOpen: Fusion.Value<boolean>,
	StatusText: Fusion.Value<string>,
	Sidebar: DevMenuTypes.SidebarHandle,
	Content: DevMenuTypes.ContentAreaHandle,
}

local DevMenu = {}

-- Root panel layout constants -- a fixed size (not AutomaticSize) is the structural fix for the
-- overflow bug described in the file header: every dimension below is a deliberate budget, not a
-- guess, so the math is spelled out rather than left implicit.
local HEADER_HEIGHT = 36
local FOOTER_HEIGHT = 24

-- The Sidebar/ContentArea column split -- widths are the only two numbers a future design pass
-- should need to touch to rebalance the two columns.
local SIDEBAR_WIDTH = 240
local CONTENT_WIDTH = 460
-- Root's usable width (ROOT_SIZE.X minus UIPadding.L left+right) must equal the two column widths
-- plus the one UIListLayout gap between them: 240 + 12 + 460 = 712.
local BODY_WIDTH = SIDEBAR_WIDTH + Tokens.Space.M + CONTENT_WIDTH
local ROOT_SIZE = UDim2.fromOffset(BODY_WIDTH + Tokens.Space.L * 2, 600)

-- Root height (600) minus UIPadding.L top+bottom (16*2=32) minus header/footer (36+24=60) minus the
-- 2 UIListLayout gaps around the Body row (Space.M=12 * 2 = 24) leaves the Body row's own height --
-- shared by both columns; each then subtracts its OWN internal row (Sidebar's stats header,
-- ContentArea's tab strip) from this same number, rather than this root guessing at either column's
-- internal split.
local BODY_HEIGHT = 600 - 32 - 60 - 24

function DevMenu.Mount(scope: Scope, playerGui: PlayerGui): DevMenuHandle
	local isOpen = scope:Value(false)
	local statusText = scope:Value("")

	local sidebar = Sidebar.Mount(scope, SIDEBAR_WIDTH, BODY_HEIGHT)
	local content = ContentArea.Mount(scope, CONTENT_WIDTH, BODY_HEIGHT)

	local targetLabelText = scope:Computed(function(use)
		return `Target: {use(content.TargetNameDisplay)}`
	end)

	ModalScreen(scope, playerGui, {
		Name = "DevMenu",
		Size = ROOT_SIZE,
		IsOpen = isOpen,

		Children = {
			-- Header: title, live resolved-target label, close button.
			scope:New "Frame" {
				Name = "Header",
				Size = UDim2.new(1, 0, 0, HEADER_HEIGHT),
				BackgroundTransparency = 1,
				LayoutOrder = 1,

				[Children] = {
					-- Neither label passes Size -- Label.lua's own default (AutomaticSize.XY when
					-- Size is omitted) is what makes each size itself to its text instead of
					-- rendering at a literal zero-size frame, which is what happens if Size is
					-- ever passed as fromScale(0, 0) here (Label.lua ties AutomaticSize to
					-- "was Size provided at all", not to the value passed).
					Label(scope, {
						Text = "Developer Menu",
						Scale = "Heading",
						AnchorPoint = Vector2.new(0, 0.5),
						Position = UDim2.fromScale(0, 0.5),
					}),
					Label(scope, {
						Text = targetLabelText,
						Scale = "Detail",
						Color = Tokens.Color.TextSecondary,
						AnchorPoint = Vector2.new(1, 0.5),
						Position = UDim2.new(1, -Tokens.Control.CloseButtonClearance, 0.5, 0),
						TextXAlignment = Enum.TextXAlignment.Right,
					}),
					Button(scope, {
						Text = "X",
						Size = UDim2.fromOffset(28, 28),
						AnchorPoint = Vector2.new(1, 0.5),
						Position = UDim2.fromScale(1, 0.5),
						OnActivated = function()
							isOpen:set(false)
						end,
					}),
				},
			},

			-- Body: the persistent Sidebar column next to the tabbed ContentArea column, side by
			-- side -- see this file's own header for the layout-budget split both receive.
			scope:New "Frame" {
				Name = "Body",
				Size = UDim2.fromOffset(BODY_WIDTH, BODY_HEIGHT),
				BackgroundTransparency = 1,
				LayoutOrder = 2,

				[Children] = {
					scope:New "UIListLayout" {
						FillDirection = Enum.FillDirection.Horizontal,
						HorizontalAlignment = Enum.HorizontalAlignment.Left,
						Padding = UDim.new(0, Tokens.Space.M),
						SortOrder = Enum.SortOrder.LayoutOrder,
					},
					sidebar.Root,
					content.Root,
				},
			},

			Label(scope, {
				Text = statusText,
				Scale = "Detail",
				Color = Tokens.Color.TextSecondary,
				Size = UDim2.new(1, 0, 0, FOOTER_HEIGHT),
				LayoutOrder = 30,
			}),
		},
	})

	return {
		IsOpen = isOpen,
		StatusText = statusText,
		Sidebar = sidebar,
		Content = content,
	}
end

return DevMenu
