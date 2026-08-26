--!strict
--[[
	DevMenu/Sidebar.lua

	Owns: the persistent left-column roster -- stats header (Player Count, Bug-Reports-Open,
	Suspected-Cheaters) + the player roster list, visible regardless of which ContentArea tab is
	selected. Phase 0 extracted this out of the pre-split DevMenu/init.lua as a pure file move (roster
	still living inside a "Players" tab); Phase 1 was the real shell restructure (persistent sidebar
	position, Player-Count stat added). THIS PHASE (Phase 3) redesigns the roster row's actions as
	icon tiles (Components/ActionIcon.lua) and wires the other two stats to the new
	DevMenu_GetSidebarStats remote.

	PlayerCount stays a local Fusion.Value<number> kept in sync from Players.PlayerAdded/
	Players.PlayerRemoving -- client-only, no remote, no server round trip, since this data already
	replicates to every client for free (a Phase 1 decision, unchanged here). BugReportOpenCount/
	SuspectedCheaterCount are fetched eagerly at Mount (same "pay one round trip even if the admin
	never looks" trade-off ListPlayers/ListBugReports/the three tuner fetches already accept in
	DevMenuClient.lua) and re-fetched after a successful Flag/Unflag action (mirroring how
	MutePlayerRequested's own handler already re-triggers fetchPlayers() on success).

	Roster row actions: 4 primary ActionIcons in a fixed order (Kick, Ban, Mute, Flag-Suspected-
	Cheater), then one overflow "⋯" ActionIcon that reveals Reset-Combat-State and Teleport-To --
	the two actions judged lower-frequency than the primary four -- as an INLINE row directly below
	the icon row (Visible tied to the same toggle the "⋯" icon flips), not a floating popover.
	Deliberate choice, not the Figma-literal one: this codebase's UI runs every screen's ScreenGui at
	the default ZIndexBehavior.Sibling, under which a later sibling row's opaque Panel background
	would paint OVER an earlier row's popover the instant that popover extended past its own row's
	bounds (Sibling ordering never lets a nested descendant escape above an unrelated later sibling
	subtree, regardless of ZIndex) -- true for every row except the very last one visible, so a real
	floating popover would render broken for most of the roster. An inline reveal has no such
	escape-the-hierarchy problem: it's still just another row in the SAME Panel's own UIListLayout, so
	a following row is naturally pushed down instead of drawn over it, exactly like every other
	Visible-toggle in this codebase (ContentArea's own tabContent). Ban's arm/confirm two-press
	friction (isBanArmed/banArmGeneration) carries over unchanged from Phase 0; only its RENDERING
	changed, from a text button that swapped "Ban" -> "Confirm Ban?" to an icon whose Armed prop
	drives a bright/thick border in the same spot, since an icon has no text to swap.

	Follows CombatFeedback.lua's "screen exposes state/signals, client module drives from outside"
	precedent, same as every other DevMenu section -- DevMenuClient.lua connects to
	RefreshPlayersRequested/KickPlayerRequested/etc. from outside, exactly as it did before every
	earlier split/restructure.

	Does not own: authorization (DevMenuSystem.lua re-checks server-side regardless of what this
	screen renders), or number/ping formatting (DevMenuClient.lua owns turning a
	Types.PlayerRosterEntry into this module's own PlayerRosterRowDisplay).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)

local Constants = require(ReplicatedStorage.Shared.Constants)
local Tokens = require(script.Parent.Parent.Parent.Parent.Tokens)
local Panel = require(script.Parent.Parent.Parent.Parent.Components.Panel)
local Label = require(script.Parent.Parent.Parent.Parent.Components.Label)
local Button = require(script.Parent.Parent.Parent.Parent.Components.Button)
local ActionIcon = require(script.Parent.Parent.Parent.Parent.Components.ActionIcon)
local TextField = require(script.Parent.Parent.Parent.Parent.Components.TextField)
local ScrollArea = require(script.Parent.Parent.Parent.Parent.Components.ScrollArea)
local DevMenuTypes = require(script.Parent.Types)

local Children = Fusion.Children
local peek = Fusion.peek

type Scope = Fusion.Scope<typeof(Fusion)>
type PlayerRosterRowDisplay = DevMenuTypes.PlayerRosterRowDisplay
type SidebarHandle = DevMenuTypes.SidebarHandle

local Sidebar = {}

-- The overflow icon's own inline reveal -- see this file's own header for why this is an inline row
-- (Visible tied to `isOpen`) rather than a floating popover. `onActivated` also closes the row
-- (`close()`) after firing, so it never lingers open after its one action was taken. Full-width, a
-- single action -- "Reset Combat" (Server/Systems/CombatSystem.lua's own reset) sat alongside
-- "Teleport To" here before the combat system was removed.
local function overflowRow(
	scope: Scope,
	isOpen: Fusion.Value<boolean>,
	layoutOrder: number,
	onTeleportTo: () -> ()
): Frame
	local function close(): ()
		isOpen:set(false)
	end

	local function overflowAction(text: string, order: number, onActivated: () -> ()): TextButton
		return Button(scope, {
			Text = text,
			Size = UDim2.fromScale(1, 1),
			LayoutOrder = order,
			OnActivated = function()
				onActivated()
				close()
			end,
		})
	end

	return scope:New "Frame" {
		Name = "OverflowRow",
		Size = UDim2.new(1, 0, 0, Tokens.Control.RowHeight),
		BackgroundTransparency = 1,
		Visible = isOpen,
		LayoutOrder = layoutOrder,

		[Children] = {
			scope:New "UIListLayout" {
				FillDirection = Enum.FillDirection.Horizontal,
				Padding = UDim.new(0, Tokens.Space.XS),
				SortOrder = Enum.SortOrder.LayoutOrder,
			},
			overflowAction("Teleport To", 1, onTeleportTo),
		},
	} :: Frame
end

-- One roster row -- `onKick`/`onBan`/`onMute`/`onFlagSuspected`/`onResetPlayerData`/
-- `onTeleportTo` all receive the row's already-known UserId, so the caller never has to thread it
-- back through a shared "currently selected row" piece of state.
local function playerRosterRow(
	scope: Scope,
	display: PlayerRosterRowDisplay,
	layoutOrder: number,
	onKick: () -> (),
	onBan: () -> (),
	onMute: () -> (),
	onFlagSuspected: () -> (),
	onResetPlayerData: () -> (),
	onTeleportTo: () -> ()
): Frame
	-- Ban arm/confirm -- purely local UX friction, scoped to this row instance. Ban is permanent and
	-- DataStore-backed (survives rejoin) where Kick is a cheap, reversible disconnect (rejoining
	-- undoes it), so Ban earns a two-press confirm and Kick stays single-press. Mirrors the SHAPE of
	-- ShutdownServer's server-armed two-press confirm (Constants.Debug.DevMenu.
	-- ShutdownConfirmWindowSeconds) but the arm state itself lives entirely here, not on the server --
	-- see BanConfirmWindowSeconds's own header for why. banArmGeneration guards the delayed disarm the
	-- same way CombatFeedback's flashParryReady guards its own delayed reset: a stale timer from an
	-- earlier arm press must never disarm a LATER press's still-open window.
	local isBanArmed = scope:Value(false)
	local banArmGeneration = 0

	local function onBanActivated(): ()
		if peek(isBanArmed) then
			banArmGeneration += 1
			isBanArmed:set(false)
			onBan()
			return
		end
		banArmGeneration += 1
		local generation = banArmGeneration
		isBanArmed:set(true)
		task.delay(Constants.Debug.DevMenu.BanConfirmWindowSeconds, function()
			if banArmGeneration == generation then
				isBanArmed:set(false)
			end
		end)
	end

	-- Reset-Player-Data arm/confirm -- same two-press shape/reasoning as isBanArmed above, its own
	-- independent Value/generation counter/window constant (ResetPlayerDataConfirmWindowSeconds, not
	-- BanConfirmWindowSeconds) since this is a DISTINCT action with its own severity, not a Ban
	-- variant -- a data wipe has no reversal path at all (Ban can still be lifted/expired), so it
	-- earns the same friction even though the two windows happen to be equal today.
	local isDataResetArmed = scope:Value(false)
	local dataResetArmGeneration = 0

	local function onDataResetActivated(): ()
		if peek(isDataResetArmed) then
			dataResetArmGeneration += 1
			isDataResetArmed:set(false)
			onResetPlayerData()
			return
		end
		dataResetArmGeneration += 1
		local generation = dataResetArmGeneration
		isDataResetArmed:set(true)
		task.delay(Constants.Debug.DevMenu.ResetPlayerDataConfirmWindowSeconds, function()
			if dataResetArmGeneration == generation then
				isDataResetArmed:set(false)
			end
		end)
	end

	local isOverflowOpen = scope:Value(false)

	return Panel(scope, {
		Name = "PlayerRow_" .. tostring(display.UserId),
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = layoutOrder,

		Children = {
			scope:New "UIPadding" {
				PaddingTop = UDim.new(0, Tokens.Space.S),
				PaddingBottom = UDim.new(0, Tokens.Space.S),
				PaddingLeft = UDim.new(0, Tokens.Space.S),
				PaddingRight = UDim.new(0, Tokens.Space.S),
			},
			scope:New "UIListLayout" {
				FillDirection = Enum.FillDirection.Vertical,
				HorizontalAlignment = Enum.HorizontalAlignment.Left,
				Padding = UDim.new(0, Tokens.Space.XS),
				SortOrder = Enum.SortOrder.LayoutOrder,
			},
			-- An inline row label (the roster row's own name), not a section title -- BodyLarge
			-- (sans), where the deprecated Subheading alias already pointed (docs/design/
			-- intro-redesign-handoff.md Phase F's Subheading sweep).
			Label(scope, { Text = display.Name, Scale = "BodyLarge", LayoutOrder = 1 }),
			Label(scope, {
				Text = `{display.HealthText} | {display.PostureText} | {display.PingText}`,
				Scale = "Detail",
				Color = Tokens.Color.TextSecondary,
				LayoutOrder = 2,
			}),
			scope:New "Frame" {
				Name = "ActionRow",
				Size = UDim2.new(1, 0, 0, Tokens.Control.StepButtonSize),
				BackgroundTransparency = 1,
				LayoutOrder = 3,

				[Children] = {
					scope:New "UIListLayout" {
						FillDirection = Enum.FillDirection.Horizontal,
						Padding = UDim.new(0, Tokens.Space.XS),
						SortOrder = Enum.SortOrder.LayoutOrder,
					},
					ActionIcon(scope, {
						Glyph = "Kick",
						Text = "Kick",
						LayoutOrder = 1,
						OnActivated = onKick,
					}),
					ActionIcon(scope, {
						Glyph = "Ban",
						Text = "Ban",
						LayoutOrder = 2,
						Armed = isBanArmed,
						OnActivated = onBanActivated,
					}),
					ActionIcon(scope, {
						Glyph = "Mute",
						Text = if display.Muted then "Unmute" else "Mute",
						LayoutOrder = 3,
						Selected = display.Muted,
						OnActivated = onMute,
					}),
					ActionIcon(scope, {
						Glyph = "FlagSuspected",
						Text = if display.SuspectedCheater
							then "Unflag Suspected Cheater"
							else "Flag Suspected Cheater",
						LayoutOrder = 4,
						Selected = display.SuspectedCheater,
						OnActivated = onFlagSuspected,
					}),
					ActionIcon(scope, {
						Glyph = "Overflow",
						Text = "More Actions",
						LayoutOrder = 5,
						Selected = isOverflowOpen,
						OnActivated = function()
							isOverflowOpen:set(not peek(isOverflowOpen))
						end,
					}),
					-- Furthest from the low-stakes icons above (LayoutOrder 6, trailing edge) --
					-- deliberately not grouped with Kick/Ban/Mute/Flag despite sharing Ban's
					-- arm/confirm mechanism, to reduce misclick risk on this codebase's single most
					-- destructive admin action (see this file's header + Constants.lua's own
					-- ResetTargetPlayerData comment for the full severity reasoning).
					ActionIcon(scope, {
						Glyph = "ResetData",
						Text = "Reset Player Data",
						LayoutOrder = 6,
						Armed = isDataResetArmed,
						OnActivated = onDataResetActivated,
					}),
				},
			},
			overflowRow(scope, isOverflowOpen, 4, onTeleportTo),
		},
	}) :: Frame
end

-- Stats-header row height -- a Sidebar-internal layout decision (unlike `width`/`bodyHeight` below,
-- which come from init.lua's own top-level column split), the same way ContentArea.lua owns its own
-- TAB_STRIP_HEIGHT rather than having init.lua dictate it. Three stacked stat rows this phase.
local STATS_HEIGHT = Tokens.Control.RowHeight * 3 + Tokens.Space.XS * 2

-- `width`/`bodyHeight` are init.lua's explicit top-level column-split budget (see that module's own
-- ROOT_SIZE/SIDEBAR_WIDTH math) -- this module never guesses its own placement inside the Root
-- panel. Everything below that split (stats header vs. roster scroll) is this module's own budget.
function Sidebar.Mount(scope: Scope, width: number, bodyHeight: number): SidebarHandle
	-- Root (bodyHeight) minus the stats header minus the one UIListLayout gap between the header and
	-- the roster scroll leaves the roster's own scrollable height.
	local rosterScrollHeight = bodyHeight - STATS_HEIGHT - Tokens.Space.M
	local rosterScrollSize = UDim2.fromOffset(width, rosterScrollHeight)

	local playersDisplay: Fusion.Value<{ PlayerRosterRowDisplay }> = scope:Value({} :: { PlayerRosterRowDisplay })
	local playersLoading = scope:Value(false)
	local actionReasonText = scope:Value("")

	-- Client-only Player-Count stat -- see this module's own header for why this never touches a
	-- remote. Seeded from the players already connected at mount time, then kept in sync by a plain
	-- +1/-1 on join/leave rather than recomputing `#Players:GetPlayers()` on every event (that count
	-- already reflects the leaving player's removal by the time PlayerRemoving fires in some cases,
	-- which would double-count a same-frame join+leave -- a direct increment/decrement has no such
	-- ambiguity).
	local playerCount = scope:Value(#Players:GetPlayers())
	Players.PlayerAdded:Connect(function()
		playerCount:set(peek(playerCount) + 1)
	end)
	Players.PlayerRemoving:Connect(function()
		playerCount:set(peek(playerCount) - 1)
	end)

	-- Server-backed stats (DevMenu_GetSidebarStats) -- nil until the first fetch resolves, same
	-- "Loading..." placeholder contract ContentArea's tuner sections already use.
	local bugReportOpenCount: Fusion.Value<number?> = scope:Value(nil :: number?)
	local suspectedCheaterCount: Fusion.Value<number?> = scope:Value(nil :: number?)

	local playerCountText = scope:Computed(function(use)
		return `Players: {use(playerCount)}`
	end)
	local bugReportOpenCountText = scope:Computed(function(use)
		local count = use(bugReportOpenCount)
		return if count then `Bug Reports: {count}` else "Bug Reports: --"
	end)
	local suspectedCheaterCountText = scope:Computed(function(use)
		local count = use(suspectedCheaterCount)
		return if count then `Suspected Cheaters: {count}` else "Suspected Cheaters: --"
	end)

	-- Held alive by each Button's OnActivated closure below for as long as the mounted UI tree
	-- exists (which is the lifetime of this client) -- see DevMenu/init.lua's own header for why a
	-- BindableEvent rather than a callback prop.
	local refreshPlayersRequestedEvent = Instance.new("BindableEvent")
	local kickPlayerRequestedEvent = Instance.new("BindableEvent")
	local banPlayerRequestedEvent = Instance.new("BindableEvent")
	local mutePlayerRequestedEvent = Instance.new("BindableEvent")
	local setSuspectedCheaterRequestedEvent = Instance.new("BindableEvent")
	local resetPlayerDataRequestedEvent = Instance.new("BindableEvent")
	local teleportToPlayerRequestedEvent = Instance.new("BindableEvent")

	local playerRefreshButtonText = scope:Computed(function(use)
		return if use(playersLoading) then "Loading..." else "Refresh"
	end)

	-- scope:ForPairs, same primitive CombatFeedback/init.lua's damage-number list and ContentArea's
	-- own Reports-tab rows use -- keyed by UserId so a refresh reuses/updates the same row Instance
	-- rather than tearing down and rebuilding every row.
	local playerRows = scope:ForPairs(playersDisplay, function(_use, innerScope, index, display)
		return display.UserId,
			playerRosterRow(innerScope, display, 10 + index, function()
				kickPlayerRequestedEvent:Fire(display.UserId)
			end, function()
				banPlayerRequestedEvent:Fire(display.UserId)
			end, function()
				mutePlayerRequestedEvent:Fire(display.UserId, not display.Muted)
			end, function()
				setSuspectedCheaterRequestedEvent:Fire(display.UserId, not display.SuspectedCheater)
			end, function()
				resetPlayerDataRequestedEvent:Fire(display.UserId)
			end, function()
				teleportToPlayerRequestedEvent:Fire(display.UserId)
			end)
	end)

	-- Stats header -- a small bordered panel above the roster scroll, always visible regardless of
	-- which ContentArea tab is selected.
	local statsHeader = Panel(scope, {
		Name = "SidebarStats",
		Size = UDim2.fromOffset(width, STATS_HEIGHT),
		LayoutOrder = 1,

		Children = {
			scope:New "UIPadding" {
				PaddingLeft = UDim.new(0, Tokens.Space.S),
				PaddingRight = UDim.new(0, Tokens.Space.S),
			},
			scope:New "UIListLayout" {
				FillDirection = Enum.FillDirection.Vertical,
				HorizontalAlignment = Enum.HorizontalAlignment.Left,
				VerticalAlignment = Enum.VerticalAlignment.Center,
				Padding = UDim.new(0, Tokens.Space.XS),
				SortOrder = Enum.SortOrder.LayoutOrder,
			},
			Label(scope, { Text = playerCountText, Scale = "Body", LayoutOrder = 1 }),
			Label(scope, { Text = bugReportOpenCountText, Scale = "Body", LayoutOrder = 2 }),
			Label(scope, { Text = suspectedCheaterCountText, Scale = "Body", LayoutOrder = 3 }),
		},
	})

	local rosterScroll = ScrollArea(scope, {
		Name = "RosterScroll",
		Size = rosterScrollSize,
		LayoutOrder = 2,

		Children = {
			-- Right padding keeps roster row panels clear of the scrollbar, same convention
			-- ContentArea.lua's own tabContent uses.
			scope:New "UIPadding" {
				PaddingRight = UDim.new(0, Tokens.Space.XS),
			},
			scope:New "UIListLayout" {
				FillDirection = Enum.FillDirection.Vertical,
				HorizontalAlignment = Enum.HorizontalAlignment.Left,
				Padding = UDim.new(0, Tokens.Space.S),
				SortOrder = Enum.SortOrder.LayoutOrder,
			},
			TextField(scope, {
				Text = actionReasonText,
				PlaceholderText = "Kick/Ban/Flag reason (optional)...",
				Size = UDim2.new(1, 0, 0, Tokens.Control.RowHeight),
				LayoutOrder = 1,
			}),
			Button(scope, {
				Text = playerRefreshButtonText,
				Size = UDim2.new(1, 0, 0, Tokens.Control.RowHeight),
				LayoutOrder = 2,
				Disabled = playersLoading,
				OnActivated = function()
					refreshPlayersRequestedEvent:Fire()
				end,
			}),
			playerRows,
		},
	})

	local root = scope:New "Frame" {
		Name = "Sidebar",
		Size = UDim2.fromOffset(width, bodyHeight),
		BackgroundTransparency = 1,

		[Children] = {
			scope:New "UIListLayout" {
				FillDirection = Enum.FillDirection.Vertical,
				HorizontalAlignment = Enum.HorizontalAlignment.Left,
				Padding = UDim.new(0, Tokens.Space.M),
				SortOrder = Enum.SortOrder.LayoutOrder,
			},
			statsHeader,
			rosterScroll,
		},
	} :: Frame

	return {
		PlayersDisplay = playersDisplay,
		PlayersLoading = playersLoading,
		RefreshPlayersRequested = refreshPlayersRequestedEvent.Event,
		ActionReasonText = actionReasonText,
		KickPlayerRequested = kickPlayerRequestedEvent.Event,
		BanPlayerRequested = banPlayerRequestedEvent.Event,
		MutePlayerRequested = mutePlayerRequestedEvent.Event,
		SetSuspectedCheaterRequested = setSuspectedCheaterRequestedEvent.Event,
		ResetPlayerDataRequested = resetPlayerDataRequestedEvent.Event,
		TeleportToPlayerRequested = teleportToPlayerRequestedEvent.Event,
		BugReportOpenCount = bugReportOpenCount,
		SuspectedCheaterCount = suspectedCheaterCount,
		Root = root,
	}
end

return Sidebar
