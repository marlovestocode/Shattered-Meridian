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
export type DevMenuTabName = "Spawn" | "Admin" | "Tuning" | "Reports"

-- What the hitbox-timing tuner section (ContentArea.lua) renders for whichever stage
-- DevMenuClient.lua currently has selected -- pre-formatted strings, not raw numbers, per this
-- screen's "already-computed value in, presentation out" boundary (see init.lua's own header) --
-- DevMenuClient.lua owns number->string formatting, this module only ever displays what it's handed.
export type HitboxStageDisplayProps = {
	TitleText: string,
	WindupText: string,
	ActiveText: string,
	RecoveryText: string,
}

-- Same "pre-formatted strings, presentation only" contract as HitboxStageDisplayProps above, for
-- the standalone-attack tuner (DashPunch/DashHit) -- OffsetText is the one field that section has
-- and the weapon-stage one doesn't (see Types.HitboxStandaloneInfo's own header for why).
export type HitboxStandaloneDisplayProps = {
	TitleText: string,
	WindupText: string,
	ActiveText: string,
	RecoveryText: string,
	OffsetText: string,
}

-- Same "pre-formatted strings, presentation only" contract as the two above, for the flight-feel
-- tuner -- a single Value per field (unlike the three-field Windup/Active/Recovery tuners above),
-- since Constants.Flight's tunable fields are each their own independent number, not a trio that's
-- always tuned together.
export type FlightTuningDisplayProps = {
	TitleText: string,
	ValueText: string,
}

-- One bug report, already formatted for display -- same "already-computed value in, presentation
-- out" contract as HitboxStageDisplayProps above. All number/Vector3/timestamp formatting happens
-- in DevMenuClient.lua; this screen only ever renders ready-made strings. Status is kept as the
-- real value (not pre-formatted) since the "Reports" tab's triage row needs to know which of the
-- three Open/Resolved/Dismissed buttons should render Selected.
export type BugReportRowDisplay = {
	Id: string,
	HeaderText: string,
	DescriptionText: string,
	ContextText: string,
	Status: "Open" | "Resolved" | "Dismissed",
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
	-- All four fire the row's UserId.
	KickPlayerRequested: RBXScriptSignal<number>,
	BanPlayerRequested: RBXScriptSignal<number>,
	ResetPlayerCombatStateRequested: RBXScriptSignal<number>,
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
	-- The fully self-contained content column Instance (tab strip + the 4 tab ScrollingFrames
	-- stacked, only one Visible at a time), sized and positioned by init.lua's own Body row layout.
	Root: Frame,

	-- "Self" or the resolved lock-on target's name -- mirrors DevMenuSystem.resolveActionTarget's
	-- own resolution exactly (see DevMenuClient.lua's watchTarget), so an admin always knows who
	-- Set Health/Godmode/Flight is about to hit before pressing it. Read by init.lua's own Header.
	TargetNameDisplay: Fusion.Value<string>,
	GodmodeActive: Fusion.Value<boolean>,
	FlightActive: Fusion.Value<boolean>,
	CollideActive: Fusion.Value<boolean>,
	SpawnDummyRequested: RBXScriptSignal,
	SpawnBotRequested: RBXScriptSignal<string>,
	SetHealthRequested: RBXScriptSignal<number>,
	SetGodmodeRequested: RBXScriptSignal<boolean>,
	SetFlightRequested: RBXScriptSignal<boolean>,
	SetFlightCollideRequested: RBXScriptSignal<boolean>,
	HitboxStageDisplay: Fusion.Value<HitboxStageDisplayProps?>,
	CycleHitboxStagePrevRequested: RBXScriptSignal,
	CycleHitboxStageNextRequested: RBXScriptSignal,
	AdjustHitboxTimingRequested: RBXScriptSignal<(string, number)>,
	ResetHitboxStageRequested: RBXScriptSignal,
	HitboxStandaloneDisplay: Fusion.Value<HitboxStandaloneDisplayProps?>,
	CycleHitboxStandalonePrevRequested: RBXScriptSignal,
	CycleHitboxStandaloneNextRequested: RBXScriptSignal,
	AdjustHitboxStandaloneRequested: RBXScriptSignal<(string, number)>,
	ResetHitboxStandaloneRequested: RBXScriptSignal,
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
	SpectatingActive: Fusion.Value<boolean>,
	SpectateLockedTargetRequested: RBXScriptSignal,
}

return {}
