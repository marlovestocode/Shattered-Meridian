--!strict
--[[
	DevMenu/init.lua

	Owns: the admin panel -- the screen, its Values and its one signal (Types.lua). Rebuilt from nothing
	on 2026-09-29 to the Move Editor's shape; see docs/design/admin-panel-guide.md for how it is used.

	THE FRAME IS Components/ScreenFrame, tabbed: Player / World / Server / Reports / Tuning. The body is
	a row of three, and each column is there for what it is FOR while an admin works:

	    Roster (rail)      everyone in the server, live -- where you go to pick a TARGET
	    Tabs (fill)        what you can do: to the target (Player), to the server's contents (World),
	                       to the server itself (Server), for the players who wrote in (Reports), and
	                       to live numbers (Tuning)
	    Inspector (rail)   the target, live -- the RESULT of whatever you just did to them

	Both rails are pinned, for the Move Editor readout's reason: the roster is who you can act on from
	any tab (a report about a player is one click from selecting them), and the inspector is the
	answer to an action on the Player tab, which is worthless a tab switch away. The tabs take whatever
	the rails leave (Stack.Fill).

	WHAT THE OLD PANEL GOT WRONG, and this one is shaped against:
	- Every "target" action (Godmode, Freeze, Bring, Teleport-to...) was wired to the calling admin and
	  nobody else; "Teleport to target" teleported you to yourself. The roster selection is the target
	  now, named on the Player tab's plate.
	- The roster showed "HP -- | Posture --" for everyone, forever: its data source was the deleted
	  combat system. The overview is built from the systems that exist.
	- Cards inside a bordered panel (Section, Panel-per-row), a single-field flight cycler, an ability
	  slot demo the Storybook (F7) already covers, a Spectate button that could never find a target, and
	  a fire-once fetch of everything at join that tripped the panel's own rate limit.

	NO CARDS: groups are bronze SectionHeadings and spacing (Kit.lua), exactly as in the Move Editor.

	Does not own: any network call, polling, authorization, or what an intent does --
	Client/DevTools/DevMenu/DevMenuClient.lua drives this screen from outside. Nothing here reads
	Players.LocalPlayer at mount: the screen mounts in the headless test place too
	(Tests/UI/ScreenFrameScreens.spec.lua).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local AdminTypes = require(ReplicatedStorage.Shared.Admin.AdminTypes)
local Types = require(ReplicatedStorage.Shared.Types)
local VehicleTypes = require(ReplicatedStorage.Shared.Vehicle.VehicleTypes)

local ScreenFrame = require(script.Parent.Parent.Parent.Components.ScreenFrame)
local Stack = require(script.Parent.Parent.Parent.Components.Stack)

local DevMenuTypes = require(script.Types)
local Inspector = require(script.Inspector)
local PlayerTab = require(script.PlayerTab)
local ReportsTab = require(script.ReportsTab)
local Roster = require(script.Roster)
local ServerTab = require(script.ServerTab)
local TuningTab = require(script.TuningTab)
local WorldTab = require(script.WorldTab)

type Scope = Fusion.Scope<typeof(Fusion)>

export type DevMenuHandle = DevMenuTypes.DevMenuHandle
export type Intent = DevMenuTypes.Intent

local DevMenu = {}

local ROOT_WIDTH = 1240
local ROOT_HEIGHT = 780
local ROSTER_WIDTH = 264
local INSPECTOR_WIDTH = 320

local TAB_NAMES: { string } = { "Player", "World", "Server", "Reports", "Tuning" }

function DevMenu.Mount(scope: Scope, playerGui: PlayerGui): DevMenuHandle
	local isOpen = scope:Value(false)
	local statusText = scope:Value("")
	local localUserId = scope:Value(0)
	local roster = scope:Value({} :: { AdminTypes.RosterEntry })
	local server = scope:Value(nil :: AdminTypes.ServerOverview?)
	local selectedUserId = scope:Value(nil :: number?)
	local inspection = scope:Value(nil :: AdminTypes.Inspection?)
	local spectatingUserId = scope:Value(nil :: number?)
	local vehicleCatalog = scope:Value({} :: { VehicleTypes.VehicleCatalogEntry })
	local vehicleLive = scope:Value({} :: { VehicleTypes.LiveVehicleInfo })
	local vehicleBerths = scope:Value({} :: { VehicleTypes.VehicleBerthInfo })
	local vehicleRegistryText = scope:Value("Open this tab to read the vehicle registry.")
	local vehicleRejectionText = scope:Value(nil :: string?)
	local banLookup = scope:Value(nil :: AdminTypes.BanLookup?)
	local shutdownArmed = scope:Value(false)
	local restartArmed = scope:Value(false)
	local reports = scope:Value({} :: { Types.BugReportRecord })
	local reportsHasMore = scope:Value(false)
	local reportsLoading = scope:Value(false)
	local flight = scope:Value({} :: { Types.FlightTuningInfo })
	local tabs = ScreenFrame.NewTabState(scope, TAB_NAMES)

	-- Registered with the scope so a Studio hot reload that re-runs Mount cleans it up.
	local intentEvent = Instance.new("BindableEvent")
	table.insert(scope, intentEvent)
	local function fire(intent: Intent): ()
		intentEvent:Fire(intent)
	end

	-- A roster press (or "Select in roster" from a report): the target changes here, at once, and the
	-- driver is told so it re-inspects without waiting for the next poll. The stale inspection is
	-- dropped in the same frame, so the Player tab never shows one player's name over another's state.
	local function selectPlayer(userId: number): ()
		if Fusion.peek(selectedUserId) ~= userId then
			selectedUserId:set(userId)
			inspection:set(nil)
		end
		fire({ Kind = "Select", UserId = userId })
	end

	-- The Player tab's plate and switches must describe the SELECTED player, so an inspection that is
	-- still in flight for the previous selection is ignored rather than briefly shown.
	local currentInspection = scope:Computed(function(use): AdminTypes.Inspection?
		local current = use(inspection)
		return if current and current.UserId == use(selectedUserId) then current else nil
	end)

	local pages = Stack.New(scope, {
		Name = "Tabs",
		LayoutOrder = 2,
		ClipsDescendants = true,
		Children = {
			PlayerTab(scope, {
				Visible = tabs.Selected.Player,
				Inspection = currentInspection,
				SpectatingUserId = spectatingUserId,
				Fire = fire,
			}),
			WorldTab(scope, {
				Visible = tabs.Selected.World,
				Server = server,
				VehicleCatalog = vehicleCatalog,
				VehicleLive = vehicleLive,
				VehicleBerths = vehicleBerths,
				VehicleRegistryText = vehicleRegistryText,
				VehicleRejectionText = vehicleRejectionText,
				Fire = fire,
			}),
			ServerTab(scope, {
				Visible = tabs.Selected.Server,
				Server = server,
				BanLookup = banLookup,
				ShutdownArmed = shutdownArmed,
				RestartArmed = restartArmed,
				Fire = fire,
			}),
			ReportsTab(scope, {
				Visible = tabs.Selected.Reports,
				Reports = reports,
				HasMore = reportsHasMore,
				Loading = reportsLoading,
				LocalUserId = localUserId,
				Roster = roster,
				Fire = fire,
				OnSelectPlayer = function(userId: number)
					selectPlayer(userId)
					tabs.Current:set("Player")
				end,
			}),
			TuningTab(scope, {
				Visible = tabs.Selected.Tuning,
				Flight = flight,
				Fire = fire,
			}),
		},
	})

	ScreenFrame.Mount(scope, playerGui, {
		Name = "DevMenu",
		Size = UDim2.fromOffset(ROOT_WIDTH, ROOT_HEIGHT),
		IsOpen = isOpen,
		Tabs = tabs,
		Wordmark = "ADMIN",
		StatusText = statusText,
		OnClose = function()
			isOpen:set(false)
		end,
		Body = Stack.Row(scope, {
			Name = "Body",
			Children = {
				Roster(scope, {
					Width = ROSTER_WIDTH,
					LayoutOrder = 1,
					Roster = roster,
					Server = server,
					SelectedUserId = selectedUserId,
					OnSelect = selectPlayer,
				}),
				Stack.Fill(scope, pages),
				Inspector(scope, {
					Width = INSPECTOR_WIDTH,
					LayoutOrder = 3,
					Inspection = currentInspection,
					SelectedUserId = selectedUserId,
					SpectatingUserId = spectatingUserId,
				}),
			},
		}),
	})

	return {
		IsOpen = isOpen,
		StatusText = statusText,
		LocalUserId = localUserId,
		Roster = roster,
		Server = server,
		SelectedUserId = selectedUserId,
		Inspection = inspection,
		SpectatingUserId = spectatingUserId,
		VehicleCatalog = vehicleCatalog,
		VehicleLive = vehicleLive,
		VehicleBerths = vehicleBerths,
		VehicleRegistryText = vehicleRegistryText,
		VehicleRejectionText = vehicleRejectionText,
		BanLookup = banLookup,
		ShutdownArmed = shutdownArmed,
		RestartArmed = restartArmed,
		Reports = reports,
		ReportsHasMore = reportsHasMore,
		ReportsLoading = reportsLoading,
		Flight = flight,
		CurrentTab = tabs.Current,
		Intent = intentEvent.Event,
	}
end

return DevMenu
