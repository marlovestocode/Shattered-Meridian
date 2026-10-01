--!strict
--[[
	DevMenu/Types.lua

	Owns: the admin panel's handle -- the Values its driver (Client/DevTools/DevMenu/DevMenuClient.lua)
	writes and the one signal it listens to -- and the Intent union that signal carries.

	ONE SIGNAL, NOT FIFTY. The old panel exposed a BindableEvent per button (fifty-odd *Requested
	fields, each declared here, built in ContentArea, connected in the driver -- three edits to add a
	button). Every press is now an Intent: a small table whose Kind names the action and whose other
	fields carry exactly what it needs. The driver keeps one table of handlers keyed by Kind. A new
	button is one Intent variant here, one fire in a tab, one handler in the driver.

	THE TARGET IS NOT IN THE INTENT. Anything aimed at a player acts on SelectedUserId, which the
	driver reads at dispatch time -- so an intent can never carry a stale target captured when a row
	was built, and "who does this hit" has exactly one answer on the whole panel: the name on the
	Player tab's plate.

	RAW VALUES IN. The screen is handed the server's own shapes (Shared/Admin/AdminTypes.lua,
	Types.BugReportRecord, VehicleTypes) and formats them itself with Shared/Admin/AdminFormat.lua.

	Does not own: any of the values' meaning (the server's), or the network (the driver's).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local AdminTypes = require(ReplicatedStorage.Shared.Admin.AdminTypes)
local Types = require(ReplicatedStorage.Shared.Types)
local VehicleTypes = require(ReplicatedStorage.Shared.Vehicle.VehicleTypes)

export type OverrideName = "Godmode" | "Flight" | "FlightCollide" | "Frozen" | "Invisible"

export type Intent =
	-- Roster / Player tab. Every one of these acts on SelectedUserId.
	{ Kind: "Select", UserId: number }
	| { Kind: "Override", Override: OverrideName, Enabled: boolean }
	| { Kind: "Speed", Multiplier: number }
	| { Kind: "GoTo" }
	| { Kind: "Bring" }
	| { Kind: "Respawn" }
	| { Kind: "Spectate" }
	| { Kind: "Restore" }
	| { Kind: "Kill" }
	| { Kind: "GrantXP", Key: string }
	| { Kind: "GrantRerolls" }
	| { Kind: "RollEmote" }
	| { Kind: "Kick", Reason: string }
	| { Kind: "Mute", Enabled: boolean }
	| { Kind: "Flag", Enabled: boolean, Reason: string }
	| { Kind: "Ban", DurationKey: string, Reason: string }
	| { Kind: "ResetData" }
	-- World tab.
	| { Kind: "SpawnBot", Style: string, Difficulty: string, Weapon: string }
	| { Kind: "DespawnBots" }
	| { Kind: "SpawnDummy" }
	| { Kind: "DespawnDummies" }
	| { Kind: "DummyGuard", Enabled: boolean }
	| { Kind: "HitboxVolumes", Enabled: boolean }
	| { Kind: "TeleportCoords", X: number, Y: number, Z: number }
	| { Kind: "SpawnCoal" }
	| { Kind: "SpawnWater" }
	| { Kind: "FillFuel" }
	| { Kind: "VehiclesRefresh" }
	| { Kind: "VehiclesRescan" }
	| { Kind: "VehicleSpawn", VehicleId: string, Berth: string? }
	| { Kind: "VehicleDespawn", InstanceId: string }
	| { Kind: "VehiclesDespawnAll" }
	-- Server tab.
	| { Kind: "Announce", Message: string }
	| { Kind: "Shutdown" }
	| { Kind: "Restart" }
	| { Kind: "LookupBan", UserId: number }
	| { Kind: "Unban", UserId: number }
	| { Kind: "OfflineBan", UserId: number, DurationKey: string, Reason: string }
	-- Reports tab.
	| { Kind: "ReportsLoad", Mode: "First" | "Next" }
	| { Kind: "ReportStatus", Id: string, Status: string }
	| { Kind: "ReportPriority", Id: string, Priority: string }
	| { Kind: "ReportAssign", Id: string, Assign: boolean }
	| { Kind: "ReportNote", Id: string, Text: string }
	| { Kind: "ReportJump", Id: string }
	-- Tuning tab.
	| { Kind: "FlightSet", Field: string, Value: number }
	| { Kind: "FlightReset", Field: string }
	| { Kind: "FlightResetAll" }

export type DevMenuHandle = {
	IsOpen: Fusion.Value<boolean>,
	-- The footer's answer to the last action.
	StatusText: Fusion.Value<string>,
	-- The admin's own UserId, set by the driver once (the screen reads no LocalPlayer at mount -- it
	-- mounts in a headless test place too). Reports use it for "claimed by me".
	LocalUserId: Fusion.Value<number>,

	-- Polled.
	Roster: Fusion.Value<{ AdminTypes.RosterEntry }>,
	Server: Fusion.Value<AdminTypes.ServerOverview?>,
	-- The roster selection, i.e. the target of every Player-tab action. Written by the screen (a row
	-- press) and by the driver (defaulting to the admin on first open, clearing a player who left).
	SelectedUserId: Fusion.Value<number?>,
	Inspection: Fusion.Value<AdminTypes.Inspection?>,
	-- Whose camera the admin is looking through, nil when not spectating.
	SpectatingUserId: Fusion.Value<number?>,

	-- Vehicles (World tab), from one VehicleManager snapshot.
	VehicleCatalog: Fusion.Value<{ VehicleTypes.VehicleCatalogEntry }>,
	VehicleLive: Fusion.Value<{ VehicleTypes.LiveVehicleInfo }>,
	VehicleBerths: Fusion.Value<{ VehicleTypes.VehicleBerthInfo }>,
	VehicleRegistryText: Fusion.Value<string>,
	VehicleRejectionText: Fusion.Value<string?>,

	-- Server tab.
	BanLookup: Fusion.Value<AdminTypes.BanLookup?>,
	-- Mirrors the server's own arm windows for Shutdown/Restart, so the button says "confirm" exactly
	-- while the server would accept the confirm.
	ShutdownArmed: Fusion.Value<boolean>,
	RestartArmed: Fusion.Value<boolean>,

	-- Reports tab.
	Reports: Fusion.Value<{ Types.BugReportRecord }>,
	ReportsHasMore: Fusion.Value<boolean>,
	ReportsLoading: Fusion.Value<boolean>,

	-- Tuning tab.
	Flight: Fusion.Value<{ Types.FlightTuningInfo }>,

	-- Which tab is showing -- the driver seeds the tabs' data lazily off it.
	CurrentTab: Fusion.Value<string>,

	Intent: RBXScriptSignal<Intent>,
}

return {}
