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

local Tokens = require(script.Parent.Parent.Parent.Tokens)
local ScreenFrame = require(script.Parent.Parent.Parent.Components.ScreenFrame)
local Stack = require(script.Parent.Parent.Parent.Components.Stack)
local Inset = require(script.Parent.Parent.Parent.Components.Inset)
local Label = require(script.Parent.Parent.Parent.Components.Label)

local DevMenuTypes = require(script.Types)
local Sidebar = require(script.Sidebar)
local ContentArea = require(script.ContentArea)

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
export type VehicleCatalogRowDisplay = DevMenuTypes.VehicleCatalogRowDisplay
export type VehicleLiveRowDisplay = DevMenuTypes.VehicleLiveRowDisplay
export type VehicleBerthRowDisplay = DevMenuTypes.VehicleBerthRowDisplay

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
--
-- The header and footer bands are gone from this list entirely: they are Components/ScreenFrame.lua's
-- now, and BodySize below is a function of that module's own heights rather than the 600-32-60-24
-- sum this file used to carry (four terms, three of them somebody else's numbers).
--
-- The Sidebar/ContentArea column split -- widths are the only two numbers a future design pass
-- should need to touch to rebalance the two columns.
local SIDEBAR_WIDTH = 240
local CONTENT_WIDTH = 460
local ROOT_WIDTH = SIDEBAR_WIDTH + Tokens.Space.M + CONTENT_WIDTH + Tokens.Space.L * 2
local ROOT_HEIGHT = 600

-- Width is discarded: this panel is sized FROM its two columns rather than the other way round.
local _, BODY_BAND_HEIGHT = ScreenFrame.BodySize(ROOT_WIDTH, ROOT_HEIGHT)
-- What each column actually gets, once the body's own inset is removed. Both columns are handed this
-- same number and each then subtracts its OWN internal row (Sidebar's stats header, ContentArea's tab
-- strip) from it, rather than this root guessing at either column's internal split.
local COLUMN_HEIGHT = BODY_BAND_HEIGHT - Tokens.Space.M - Tokens.Space.L

function DevMenu.Mount(scope: Scope, playerGui: PlayerGui): DevMenuHandle
	local isOpen = scope:Value(false)
	local statusText = scope:Value("")

	local sidebar = Sidebar.Mount(scope, SIDEBAR_WIDTH, COLUMN_HEIGHT)
	local content = ContentArea.Mount(scope, CONTENT_WIDTH, COLUMN_HEIGHT)

	local targetLabelText = scope:Computed(function(use)
		return `Target: {use(content.TargetNameDisplay)}`
	end)

	ScreenFrame.Mount(scope, playerGui, {
		Name = "DevMenu",
		Size = UDim2.fromOffset(ROOT_WIDTH, ROOT_HEIGHT),
		IsOpen = isOpen,
		-- No tabs at frame level: this panel's four tabs (Spawn/Admin/Tuning/Reports) belong to the
		-- ContentArea column and switch only that column, with the Sidebar persisting across all four.
		-- Hoisting them into the strip would make the sidebar look like it changes with them.
		Title = "Developer Menu",
		-- The live resolved-target readout, pinned to the strip's right edge clear of the close
		-- control. It belongs to the whole panel rather than to any one tab -- every action in every
		-- tab applies to whoever this says.
		HeaderAccessory = Label(scope, {
			Text = targetLabelText,
			Scale = "Detail",
			Color = Tokens.Color.TextSecondary,
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -(Tokens.Control.CloseButtonClearance + ScreenFrame.BandPaddingX), 0.5, 0),
			TextXAlignment = Enum.TextXAlignment.Right,
		}),
		Wordmark = "DEV MENU",
		StatusText = statusText,
		OnClose = function()
			isOpen:set(false)
		end,

		-- The persistent Sidebar column next to the tabbed ContentArea column, side by side -- see this
		-- file's own header for the layout-budget split both receive.
		Body = Stack.Row(scope, {
			Name = "Body",
			Gap = Tokens.Space.M,
			Children = {
				Inset(scope, { Top = Tokens.Space.M, Bottom = Tokens.Space.L, X = Tokens.Space.L }),
				sidebar.Root,
				content.Root,
			},
		}),
	})

	return {
		IsOpen = isOpen,
		StatusText = statusText,
		Sidebar = sidebar,
		Content = content,
	}
end

return DevMenu
