--!strict
--[[
	DevMenu/Types.lua

	Owns: every type Sidebar.lua/ContentArea.lua/init.lua share -- extracted verbatim from the
	pre-split DevMenu/init.lua (a single ~1545-line file) so Sidebar and ContentArea can each depend
	on this one shared leaf instead of forming a Sidebar<->ContentArea require cycle, or duplicating
	the same display-prop shapes in two places. Pure type declarations only, the same role
	Shared/Types.lua plays for the whole client/server boundary, scoped down to this one screen.

	Does not own any Mount()/rendering logic, and does not own authorization or request validation
	(DevMenuSystem.lua, server-side, same as before this split) -- see init.lua's own header for the
	full ownership boundary this screen operates under.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)

-- "Players" dropped in Phase 1 -- the roster moved from a Content tab to the persistent Sidebar
-- position (see Sidebar.lua/ContentArea.lua's own headers), so it's no longer one of the tab strip's
-- selectable values.
export type DevMenuTabName = "Spawn" | "Admin" | "Tuning" | "Reports" | "Vehicles"

-- Pre-formatted strings, not raw numbers, per this screen's "already-computed value in, presentation
-- out" boundary (see init.lua's own header) -- DevMenuClient.lua owns number->string formatting, this
-- module only ever displays what it's handed. Used only by the flight-feel tuner now -- the
-- equivalent hitbox-timing/standalone-attack tuner props this file used to declare (
-- HitboxStageDisplayProps/HitboxStandaloneDisplayProps) moved out of DevMenu entirely, into the Move
-- Editor's "Default" moves section (see Server/Combat/DefaultMoveRegistry.lua's own header).
export type FlightTuningDisplayProps = {
	TitleText: string,
	ValueText: string,
}

-- One internal triage note, already formatted for display -- same "already-computed value in,
-- presentation out" contract as BugReportRowDisplay below.
export type BugReportNoteDisplay = {
	Id: string,
	AuthorName: string,
	Text: string,
	TimeText: string,
}

-- One bug report, already formatted for display -- same "already-computed value in, presentation
-- out" contract as HitboxStageDisplayProps above. All number/Vector3/timestamp formatting happens
-- in DevMenuClient.lua; this screen only ever renders ready-made strings. Status/Category/Priority
-- are kept as real values (not pre-formatted) since the "Reports" tab's triage row and its
-- Status/Category filter row both need to compare against them directly -- the same reasoning
-- BugReportRowDisplay.Status already used before this comment, extended to the two new fields.
-- ReporterName is likewise real (not just baked into HeaderText) so the search box can match
-- against it without re-parsing HeaderText.
export type BugReportRowDisplay = {
	Id: string,
	HeaderText: string,
	DescriptionText: string,
	ContextText: string,
	Status: "Open" | "InProgress" | "Resolved" | "Dismissed",
	Category: "Bug" | "Exploit" | "Suggestion" | "Other",
	ReporterName: string,
	Priority: "Low" | "Normal" | "High" | "Urgent",
	PriorityText: string,
	-- "Unassigned" or "Claimed by <admin name>" -- IsAssignedToMe drives which of Claim/Release the
	-- row's assign button shows, the same "real boolean alongside its own pre-formatted text" split
	-- PlayerRosterRowDisplay.Muted uses below.
	AssignedText: string,
	IsAssignedToMe: boolean,
	Notes: { BugReportNoteDisplay },
}

-- One roster row ("Players" tab) -- already-formatted strings, same "already-computed value in,
-- presentation out" contract as BugReportRowDisplay above; DevMenuClient.lua owns all number/ping
-- formatting. Muted stays a real boolean (not pre-formatted) since the row's Mute button needs to
-- know which label/Selected state to render, the same reason BugReportRowDisplay.Status stays real.
export type PlayerRosterRowDisplay = {
	UserId: number,
	Name: string,
	HealthText: string,
	PostureText: string,
	PingText: string,
	Muted: boolean,
	-- ModerationSystem.IsSuspectedCheater(UserId) at fetch time -- same "real boolean, not
	-- pre-formatted" reasoning as Muted above, for the row's Flag-Suspected-Cheater icon.
	SuspectedCheater: boolean,
}

-- === Vehicles tab (DevMenu/VehiclesTab.lua) ===
--
-- All three row types below follow this file's own "already-computed value in, presentation out"
-- contract: DevMenuClient.lua turns the server's VehicleTypes snapshot (studs, seconds, Vector3
-- positions) into these strings, and the tab renders nothing it has to format itself.

-- One catalog row -- a vehicle that COULD be spawned.
export type VehicleCatalogRowDisplay = {
	-- The registry key, which is what a Spawn request carries -- never DisplayName, which a designer
	-- may retitle at any time.
	Id: string,
	NameText: string,
	DetailText: string,
	-- True when this vehicle is already at its own live cap, so the next spawn recycles the oldest
	-- rather than adding one. A real boolean, not pre-formatted, because the row's own button label
	-- changes with it -- the same split BugReportRowDisplay.Status already uses.
	AtCapacity: boolean,
}

-- One live row -- a vehicle currently in the world.
export type VehicleLiveRowDisplay = {
	InstanceId: string,
	NameText: string,
	DetailText: string,
}

-- One berth row in the spawn-target picker. `Label` is pre-formatted (it carries the occupied marker
-- and the accept-list), while `Name` stays the raw berth name the Spawn request sends -- the same
-- "real value alongside its own display text" split PlayerRosterRowDisplay.Muted uses.
export type VehicleBerthRowDisplay = {
	Name: string,
	Label: string,
}

-- Handle returned by VehiclesTab.Build(scope). Unlike SidebarHandle/ContentAreaHandle below it
-- carries no Root: ContentArea.lua still owns this tab's ScrollingFrame and visibility, and this
-- module only supplies the sections that go inside it (see VehiclesTab.lua's own header).
export type VehiclesTabHandle = {
	Children: { Instance },
	CatalogDisplay: Fusion.Value<{ VehicleCatalogRowDisplay }>,
	LiveDisplay: Fusion.Value<{ VehicleLiveRowDisplay }>,
	BerthDisplay: Fusion.Value<{ VehicleBerthRowDisplay }>,
	-- Where the server's registry actually resolved, e.g. "ServerStorage.Vehicles (2 vehicles)".
	RegistryText: Fusion.Value<string>,
	-- Registry entries the server rejected and why, or nil when there were none -- surfaced in the tab
	-- rather than only in the server log, since a builder whose model does not appear has no reason to
	-- go looking there.
	RejectionText: Fusion.Value<string?>,
	Loading: Fusion.Value<boolean>,
	RefreshRequested: RBXScriptSignal,
	ReloadRegistryRequested: RBXScriptSignal,
	-- Fires (vehicleId, berthName?) -- nil berth means "in front of me", which the tab resolves from
	-- its own picker before firing, so the client module never re-derives it.
	SpawnRequested: RBXScriptSignal<(string, string?)>,
	DespawnRequested: RBXScriptSignal<string>,
	DespawnAllRequested: RBXScriptSignal,
}

-- Handle returned by Sidebar.Mount(scope, ...) -- the persistent left-column roster surface (Phase 1
-- onward: a permanent sidebar position, visible regardless of which Content tab is selected, not a
-- "Players" tab anymore -- see Sidebar.lua's own header). Same "screen exposes state/signals, client
-- module drives from outside" shape as every other DevMenu section -- DevMenuClient.lua reaches into
-- DevMenuHandle.Sidebar.X for these exactly as it used to reach into the flat handle before the
-- Phase 0 split.
export type SidebarHandle = {
	PlayersDisplay: Fusion.Value<{ PlayerRosterRowDisplay }>,
	PlayersLoading: Fusion.Value<boolean>,
	RefreshPlayersRequested: RBXScriptSignal,
	ActionReasonText: Fusion.Value<string>,
	-- All five fire the row's UserId.
	KickPlayerRequested: RBXScriptSignal<number>,
	BanPlayerRequested: RBXScriptSignal<number>,
	-- Irreversible -- wipes the target's SAVED progression data. Same "fires the row's UserId only, no
	-- reason text" shape as KickPlayerRequested/BanPlayerRequested.
	ResetPlayerDataRequested: RBXScriptSignal<number>,
	TeleportToPlayerRequested: RBXScriptSignal<number>,
	-- Fires (UserId, enabled) -- enabled is the OPPOSITE of that row's current Muted display, the
	-- same "screen computes the real state flip, never tracks its own separate toggle" pattern
	-- Godmode/Flight/Collide's Tab buttons already use.
	MutePlayerRequested: RBXScriptSignal<(number, boolean)>,
	-- Fires (UserId, enabled) -- same "the screen computes the real state flip" contract as
	-- MutePlayerRequested above, enabled = NOT that row's current SuspectedCheater display.
	SetSuspectedCheaterRequested: RBXScriptSignal<(number, boolean)>,
	-- Sidebar stats header (DevMenu_GetSidebarStats) -- nil until the first fetch resolves (or if it
	-- ever fails), same "Loading..." placeholder contract ContentArea's HitboxStageDisplay/etc.
	-- already use. Player Count has no equivalent field here -- it's a purely local Fusion.Value
	-- internal to Sidebar.Mount (Players.PlayerAdded/PlayerRemoving), never fetched and so never
	-- something DevMenuClient.lua needs to drive from outside.
	BugReportOpenCount: Fusion.Value<number?>,
	SuspectedCheaterCount: Fusion.Value<number?>,
	-- The fully self-contained sidebar column Instance (stats header + roster scroll), sized and
	-- positioned by init.lua's own Body row layout -- init.lua never reaches inside this, it only
	-- places it next to ContentAreaHandle.Root.
	Root: Frame,
}

-- Handle returned by ContentArea.Mount(scope, ...) -- every DevMenu tab (Spawn/Admin/Tuning/Reports
-- -- "Players" dropped from the tab strip in Phase 1, see ContentArea.lua's own header).
export type ContentAreaHandle = {
	-- The Vehicles tab, whose own state/signals live on their own nested handle rather than being
	-- flattened in here -- five tabs' worth of fields in one table is what made this type unreadable
	-- before the Sidebar/Content split, and the Vehicles tab is the first one built as its own module.
	Vehicles: VehiclesTabHandle,
	-- The fully self-contained content column Instance (tab strip + the 4 tab ScrollingFrames
	-- stacked, only one Visible at a time), sized and positioned by init.lua's own Body row layout.
	Root: Frame,

	-- "Self" -- mirrors DevMenuSystem.resolveActionTarget's own resolution exactly (see
	-- DevMenuClient.lua's watchTarget), so an admin always knows who Godmode/Flight is about to hit
	-- before pressing it. Read by init.lua's own Header.
	TargetNameDisplay: Fusion.Value<string>,
	GodmodeActive: Fusion.Value<boolean>,
	FlightActive: Fusion.Value<boolean>,
	CollideActive: Fusion.Value<boolean>,
	-- One-shot test trigger for the Emote System's roll path (DevMenu_RollEmote, always against the
	-- "RareEmotes" pool -- see DevMenuSystem.handleRollEmote). No payload, fire-and-forget -- there is
	-- still no client-facing way to roll an arbitrary pool.
	RollRareEmoteRequested: RBXScriptSignal,
	-- Grants the resolved target a fixed batch of bloodline rerolls
	-- (BloodlineConstants.DevGrantRerollAmount). No payload, same fire-and-forget shape as
	-- RollRareEmoteRequested above and for the same reason: the amount is a server constant, not a
	-- client choice, so there is nothing for the press to carry.
	GrantBloodlineRerollsRequested: RBXScriptSignal,
	SetGodmodeRequested: RBXScriptSignal<boolean>,
	SetFlightRequested: RBXScriptSignal<boolean>,
	SetFlightCollideRequested: RBXScriptSignal<boolean>,
	-- Swing-volume visualiser (DevMenu_GetHitboxDebug/SetHitboxDebug -> HitboxEngine.
	-- SetDebugVolumesEnabled). SERVER-WIDE, not a personal overlay: the engine draws real server-side
	-- Parts, so every player in the place sees them. Seeded once when the menu opens and refreshed from
	-- whatever the server reports actually took effect, never optimistically from the press.
	HitboxDebugActive: Fusion.Value<boolean>,
	SetHitboxDebugRequested: RBXScriptSignal<boolean>,
	FlightTuningDisplay: Fusion.Value<FlightTuningDisplayProps?>,
	CycleFlightTuningPrevRequested: RBXScriptSignal,
	CycleFlightTuningNextRequested: RBXScriptSignal,
	AdjustFlightTuningRequested: RBXScriptSignal<number>,
	ResetFlightTuningRequested: RBXScriptSignal,
	ReportsDisplay: Fusion.Value<{ BugReportRowDisplay }>,
	ReportsHasMore: Fusion.Value<boolean>,
	ReportsLoading: Fusion.Value<boolean>,
	LoadFirstReportsRequested: RBXScriptSignal,
	LoadMoreReportsRequested: RBXScriptSignal,
	UpdateReportStatusRequested: RBXScriptSignal<(string, string)>,
	-- Triage mutations added alongside UpdateReportStatusRequested above -- all fire the row's Id
	-- first. SetReportPriorityRequested's second argument is the new BugReportPriority string;
	-- AssignReportRequested's second argument is the target assign state (true = claim, false =
	-- release), the same "screen computes the real state flip" contract
	-- MutePlayerRequested/SetSuspectedCheaterRequested already use. JumpToReporterRequested carries
	-- only the Id -- the server resolves the reporter's live Player from the stored record.
	AddReportNoteRequested: RBXScriptSignal<(string, string)>,
	SetReportPriorityRequested: RBXScriptSignal<(string, string)>,
	AssignReportRequested: RBXScriptSignal<(string, boolean)>,
	JumpToReporterRequested: RBXScriptSignal<string>,
	FrozenActive: Fusion.Value<boolean>,
	InvisibleActive: Fusion.Value<boolean>,
	SpeedMultiplierActive: Fusion.Value<number>,
	SetFrozenRequested: RBXScriptSignal<boolean>,
	SetInvisibleRequested: RBXScriptSignal<boolean>,
	SetSpeedMultiplierRequested: RBXScriptSignal<number>,
	TeleportToTargetRequested: RBXScriptSignal,
	BringTargetRequested: RBXScriptSignal,
	TeleportToCoordinatesRequested: RBXScriptSignal<(number, number, number)>,
	ForceRespawnTargetRequested: RBXScriptSignal,
	BroadcastAnnouncementRequested: RBXScriptSignal<string>,
	ShutdownServerRequested: RBXScriptSignal,
	-- Same two-press server-armed confirm shape as ShutdownServerRequested above (see
	-- DevMenuSystem.handleInstantRestartServer), just with no countdown delay on confirm.
	InstantRestartServerRequested: RBXScriptSignal,
	-- Passive "a newer version has been published" banner (DevMenu_GetServerVersionInfo,
	-- Server/Systems/VersionWatchSystem.lua) -- fetched once on DevMenuClient.Start(), same
	-- fetch-once contract as BugReportOpenCount/SuspectedCheaterCount above. Already-formatted text
	-- (this screen's own "already-computed value in, presentation out" rule) -- nil means "nothing to
	-- show," both before the fetch resolves and for the ordinary case where no newer version exists.
	VersionBannerText: Fusion.Value<string?>,
	SpectatingActive: Fusion.Value<boolean>,
	SpectateLockedTargetRequested: RBXScriptSignal,

	-- Debug dummy (Spawn tab, Server/Systems/DebugDummySystem.lua) -- SpawnDebugDummyRequested/
	-- DespawnAllDebugDummiesRequested are fire-and-forget, same shape as RollRareEmoteRequested above.
	-- DummyGuardActive is SERVER-WIDE (one toggle for every currently-active dummy, not a per-instance
	-- picker -- see DebugDummySystem.SetGuard's own header), seeded once on open (DevMenu_
	-- GetDebugDummyState) and refreshed from whatever the server reports actually took effect, never
	-- optimistically from the press -- same "never let the client guess a server-wide toggle" contract
	-- HitboxDebugActive above already keeps. ActiveDummyCountDisplay is advisory only, same fetch/
	-- refresh shape.
	DummyGuardActive: Fusion.Value<boolean>,
	ActiveDummyCountDisplay: Fusion.Value<number>,
	SpawnDebugDummyRequested: RBXScriptSignal,
	DespawnAllDebugDummiesRequested: RBXScriptSignal,
	SetDummyGuardRequested: RBXScriptSignal<boolean>,

	-- Blimp Fuel System test nodes (Spawn tab, Server/Systems/ResourceGatheringSystem.
	-- SpawnDebugNode) -- fire-and-forget, same shape as SpawnDebugDummyRequested above.
	SpawnCoalDepositRequested: RBXScriptSignal,
	SpawnWaterSourceRequested: RBXScriptSignal,
	FillCarriedFuelRequested: RBXScriptSignal,
}

return {}
