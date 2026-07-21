--!strict
--[[
	DevMenu/init.lua

	Owns: the mounted whitelist-gated developer menu panel -- real actions only, no placeholder
	buttons for tools that don't exist yet: Spawn Training Dummy (a static punching bag) and six
	Spawn Training Bot presets (Attack-Only/Block-Only/Parry-Only/Full-Fight/Aggressor/Turtle --
	AI opponents that actually fight back, see TrainingBotSystem.lua). "Custom" weight
	configuration has full server-side support already (DevMenuSystem.lua/TrainingBotSystem.lua)
	but no slider UI yet -- not exposed here this pass, same backend-now-UI-later precedent this
	project already used for keybind rebinding.

	Fixed-size, tabbed layout (Spawn / Admin / Tuning), each its own ScrollingFrame -- replaces an
	earlier revision that stacked all ~23 controls in one AutomaticSize.XY panel with no scrolling
	anywhere in this UI framework, so the bottom section (hitbox tuner, reset) rendered off-screen
	on most viewports with no way to reach it. A fixed root Size + per-tab ScrollingFrame makes that
	structurally impossible regardless of how many controls any tab grows to later. This module
	always mounts (same as every other Screen); staying hidden until a dev opens it is just IsOpen
	defaulting false, the same pattern Menus.lua already uses. Local-only visibility (should this
	player even see the menu) is DevMenuClient.lua's job, not this module's.

	TargetNameDisplay/GodmodeActive/FlightActive are driven by DevMenuClient.lua from real server-
	replicated state (Combat_LockOnChanged's targetUserId, and the target Humanoid's Godmode/Flying
	Attributes) -- never a locally-guessed toggle. This is what makes the Admin tab's Godmode/Flight
	buttons an accurate reflection of whether the resolved target is actually protected/flying right
	now, not just "which button was clicked last."

	Follows CombatFeedback.lua's "screen exposes state/signals, client module drives from outside"
	precedent: DevMenuClient.lua doesn't exist yet at the moment this mounts (UI/init.lua mounts
	every Screen before Main.client.lua boots any client integration module), so a button can't
	take a callback prop directly -- each fires a BindableEvent instead, exposed on the handle as
	SpawnDummyRequested/SpawnBotRequested, which DevMenuClient.lua connects to after mount. The one
	exception is the close button: IsOpen is already a Fusion.Value owned by this same Mount call,
	so closing just sets it directly rather than round-tripping through a signal.

	Does not own: authorization (DevMenuSystem.lua re-checks server-side regardless of whether this
	screen is even visible), or deciding whether the local player should see this at all
	(DevMenuClient.lua's local whitelist read, itself never trusted as real authorization).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)

local Tokens = require(script.Parent.Parent.Tokens)
local Panel = require(script.Parent.Parent.Components.Panel)
local Label = require(script.Parent.Parent.Components.Label)
local Button = require(script.Parent.Parent.Components.Button)
local Tab = require(script.Parent.Parent.Components.Tab)

local Children = Fusion.Children
local peek = Fusion.peek

type Scope = Fusion.Scope<typeof(Fusion)>

-- What the hitbox-timing tuner section (below) renders for whichever stage DevMenuClient.lua
-- currently has selected -- pre-formatted strings, not raw numbers, per this screen's "already-
-- computed value in, presentation out" boundary (see file header) -- DevMenuClient.lua owns
-- number->string formatting, this module only ever displays what it's handed.
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

export type DevMenuTabName = "Spawn" | "Admin" | "Tuning" | "Reports"

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

export type DevMenuHandle = {
	IsOpen: Fusion.Value<boolean>,
	StatusText: Fusion.Value<string>,
	-- "Self" or the resolved lock-on target's name -- mirrors DevMenuSystem.resolveActionTarget's
	-- own resolution exactly (see DevMenuClient.lua's watchTarget), so an admin always knows who
	-- Set Health/Godmode/Flight is about to hit before pressing it.
	TargetNameDisplay: Fusion.Value<string>,
	-- Live state of the resolved target's Humanoid Godmode/Flying Attributes -- real replicated
	-- state, refreshed whenever the target or its character changes. Drives the Admin tab's toggle
	-- buttons' highlighted state.
	GodmodeActive: Fusion.Value<boolean>,
	FlightActive: Fusion.Value<boolean>,
	-- Live state of the resolved target's Humanoid "FlyCollide" Attribute -- whether Collide mode
	-- (Client/DevMenu/FlightPhysics.lua's physics-respecting flight) is active, independent of
	-- whether Flying itself is on. Same live-Attribute-driven shape as GodmodeActive/FlightActive.
	CollideActive: Fusion.Value<boolean>,
	SpawnDummyRequested: RBXScriptSignal,
	-- Fires with the preset name (e.g. "AttackOnly") a button was pressed for -- see
	-- Types.TrainingBotPresetName for the full set.
	SpawnBotRequested: RBXScriptSignal<string>,
	-- Admin actions -- all three apply to whichever player the requesting admin currently has
	-- locked on, or themselves if nothing's locked (DevMenuSystem.lua's resolveActionTarget) --
	-- there's no player-picker here, reusing the existing lock-on system instead. Godmode/Flight
	-- still fire the boolean to SET (not "toggle") -- the screen computes that boolean as the
	-- opposite of GodmodeActive/FlightActive's current value, so the request always asks for a
	-- real state flip rather than tracking its own separate toggle state.
	SetHealthRequested: RBXScriptSignal<number>,
	SetGodmodeRequested: RBXScriptSignal<boolean>,
	SetFlightRequested: RBXScriptSignal<boolean>,
	SetFlightCollideRequested: RBXScriptSignal<boolean>,
	-- Hitbox timing tuner: a Studio-only LIVE tuning tool (Server/Combat/HitboxTuning.lua) for the
	-- Windup/Active/RecoverySeconds that actually schedule a swing's hitbox -- lets an admin nudge a
	-- stage's real timing while playtesting and immediately feel the result, no restart needed. This
	-- section breaks from the rest of this screen's "stateless one-shot Button" pattern and instead
	-- follows CombatFeedback.lua's "screen exposes a Value, client module drives it from outside"
	-- shape, since it needs to DISPLAY live server state (the currently selected stage's timing),
	-- not just fire requests. nil until DevMenuClient.lua's initial ListHitboxStages response
	-- arrives -- the section renders a placeholder until then.
	HitboxStageDisplay: Fusion.Value<HitboxStageDisplayProps?>,
	CycleHitboxStagePrevRequested: RBXScriptSignal,
	CycleHitboxStageNextRequested: RBXScriptSignal,
	-- Fires with (field, delta) for whichever stage is currently selected -- field is one of
	-- "WindupSeconds"/"ActiveSeconds"/"RecoverySeconds" (matching Types.HitboxTimingField), delta
	-- the signed step (e.g. +-0.01/+-0.1).
	AdjustHitboxTimingRequested: RBXScriptSignal<(string, number)>,
	ResetHitboxStageRequested: RBXScriptSignal,
	-- Standalone-attack tuner: same live-tuning idea as the five HitboxStage* fields above, for
	-- DashPunch/DashHit (Server/Combat/HitboxTuning.lua's ListStandaloneAttacks/
	-- AdjustStandaloneField/ResetStandaloneAttack) -- these aren't a weapon combo stage, so they
	-- get their own selector/section rather than being folded into the one above. Also tunes
	-- OffsetForwardStuds, which the weapon-stage tool above deliberately doesn't (see
	-- Types.HitboxStandaloneInfo's own header).
	HitboxStandaloneDisplay: Fusion.Value<HitboxStandaloneDisplayProps?>,
	CycleHitboxStandalonePrevRequested: RBXScriptSignal,
	CycleHitboxStandaloneNextRequested: RBXScriptSignal,
	-- Fires with (field, delta) for whichever standalone attack is currently selected -- field is
	-- one of "WindupSeconds"/"ActiveSeconds"/"RecoverySeconds"/"OffsetForwardStuds" (matching
	-- Types.HitboxStandaloneField).
	AdjustHitboxStandaloneRequested: RBXScriptSignal<(string, number)>,
	ResetHitboxStandaloneRequested: RBXScriptSignal,
	-- Flight-feel live tuner: same fetch-once/cycle/adjust/reset shape as the two Hitbox tuners
	-- above, scoped to Constants.Flight's own curated field set (Server/DevMenu/FlightTuning.lua).
	-- AdjustFlightTuningRequested fires a FRACTIONAL delta (e.g. +-0.1 = +-10%), not an absolute
	-- seconds delta -- see that module's own header for why.
	FlightTuningDisplay: Fusion.Value<FlightTuningDisplayProps?>,
	CycleFlightTuningPrevRequested: RBXScriptSignal,
	CycleFlightTuningNextRequested: RBXScriptSignal,
	AdjustFlightTuningRequested: RBXScriptSignal<number>,
	ResetFlightTuningRequested: RBXScriptSignal,
	-- Bug report triage ("Reports" tab) -- same "screen exposes a Value, client module drives it
	-- from outside" shape as the three tuner sections above, since this needs to DISPLAY live
	-- server data (paginated reports), not just fire one-shot requests. ReportsDisplay starts empty
	-- and stays empty until DevMenuClient.lua's first ListBugReports response arrives.
	ReportsDisplay: Fusion.Value<{ BugReportRowDisplay }>,
	ReportsHasMore: Fusion.Value<boolean>,
	ReportsLoading: Fusion.Value<boolean>,
	LoadFirstReportsRequested: RBXScriptSignal,
	LoadMoreReportsRequested: RBXScriptSignal,
	-- Fires (reportId, newStatus) when an admin presses one of a report row's three triage buttons.
	UpdateReportStatusRequested: RBXScriptSignal<(string, string)>,
}

local DevMenu = {}

-- Root panel layout constants -- a fixed size (not AutomaticSize) is the structural fix for the
-- overflow bug described in the file header: every dimension below is a deliberate budget, not a
-- guess, so the math is spelled out rather than left implicit.
local ROOT_SIZE = UDim2.fromOffset(440, 600)
local HEADER_HEIGHT = 36
local TAB_STRIP_HEIGHT = 36
local FOOTER_HEIGHT = 24
-- Root (600) minus UIPadding.L top+bottom (16*2=32) minus header/tab-strip/footer (36+36+24=96)
-- minus the 3 UIListLayout gaps between those 4 rows (Space.M=12 * 3 = 36) leaves the scroll area.
local SCROLL_HEIGHT = 600 - 32 - 96 - 36
local SCROLL_SIZE = UDim2.fromOffset(440 - Tokens.Space.L * 2, SCROLL_HEIGHT)

-- One "0.080s [-0.1][-0.01][+0.01][+0.1]" row for the hitbox-timing tuner below -- shared by the
-- three timing fields (Windup/Active/Recovery) rather than writing the same row three times.
-- `valueText` is UsedAs<string> (a Fusion Computed bound to HitboxStageDisplay) so it re-renders
-- whenever the selected stage or its values change; `onAdjust(delta)` fires
-- AdjustHitboxTimingRequested for whichever field this particular row is for.
local function hitboxTimingRow(
	scope: Scope,
	layoutOrder: number,
	valueText: Fusion.UsedAs<string>,
	onAdjust: (delta: number) -> ()
): Frame
	local function stepButton(text: string, delta: number, order: number): TextButton
		return Button(scope, {
			Text = text,
			Size = UDim2.fromOffset(48, Tokens.Control.StepButtonSize),
			LayoutOrder = order,
			OnActivated = function()
				onAdjust(delta)
			end,
		})
	end

	return scope:New "Frame" {
		Name = "HitboxTimingRow",
		AutomaticSize = Enum.AutomaticSize.XY,
		BackgroundTransparency = 1,
		LayoutOrder = layoutOrder,

		[Children] = {
			scope:New "UIListLayout" {
				FillDirection = Enum.FillDirection.Horizontal,
				VerticalAlignment = Enum.VerticalAlignment.Center,
				Padding = UDim.new(0, Tokens.Space.XS),
				SortOrder = Enum.SortOrder.LayoutOrder,
			},
			Label(scope, {
				Text = valueText,
				Scale = "Body",
				Size = UDim2.fromOffset(100, Tokens.Control.StepButtonSize),
				LayoutOrder = 1,
			}),
			stepButton("-0.1", -0.1, 2),
			stepButton("-0.01", -0.01, 3),
			stepButton("+0.01", 0.01, 4),
			stepButton("+0.1", 0.1, 5),
		},
	} :: Frame
end

-- A full-width, auto-height grouping panel for related controls within a tab -- Panel.lua reused
-- as a plain sub-section container (point 5 of the dev-menu rework: real panel edges instead of
-- just a text heading to separate, e.g., Spawn's dummy button from its bot presets).
-- children's element type is `any`, not `Instance` -- every existing call site still passes plain
-- Instances, but the Reports tab (below) needs to splice in a scope:ForPairs(...) result (a Fusion
-- state-collection object, not an Instance) alongside plain Frames, the same way Children.luau
-- itself accepts either at any nesting depth (see that module's processChild).
local function section(scope: Scope, title: string, layoutOrder: number, children: { any }): Frame
	return Panel(scope, {
		Name = title,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = layoutOrder,

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
			Label(scope, {
				Text = title,
				Scale = "Subheading",
				LayoutOrder = 1,
			}),
			table.unpack(children),
		},
	}) :: Frame
end

-- One bug report row (Reports tab) -- a Panel with header/description/context text plus a 3-way
-- Open/Resolved/Dismissed Tab row for triage, same idiom as hitboxTimingRow above (a small
-- file-local builder, not a promoted Components/ primitive, since it's specific to this screen's
-- one call site). `onSetStatus` fires UpdateReportStatusRequested for this report's Id.
local function reportRow(
	scope: Scope,
	display: BugReportRowDisplay,
	layoutOrder: number,
	onSetStatus: (newStatus: string) -> ()
): Frame
	local function statusButton(text: string, status: string, order: number): TextButton
		return Tab(scope, {
			Text = text,
			Selected = display.Status == status,
			Size = UDim2.new(1 / 3, -Tokens.Space.XS, 0, Tokens.Control.StepButtonSize),
			LayoutOrder = order,
			OnActivated = function()
				onSetStatus(status)
			end,
		})
	end

	return Panel(scope, {
		Name = "Report_" .. display.Id,
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
			Label(scope, { Text = display.HeaderText, Scale = "Subheading", LayoutOrder = 1 }),
			Label(scope, { Text = display.DescriptionText, Scale = "Body", LayoutOrder = 2 }),
			Label(scope, {
				Text = display.ContextText,
				Scale = "Caption",
				Color = Tokens.Color.TextSecondary,
				LayoutOrder = 3,
			}),
			scope:New "Frame" {
				Name = "StatusRow",
				Size = UDim2.new(1, 0, 0, Tokens.Control.StepButtonSize),
				BackgroundTransparency = 1,
				LayoutOrder = 4,

				[Children] = {
					scope:New "UIListLayout" {
						FillDirection = Enum.FillDirection.Horizontal,
						Padding = UDim.new(0, Tokens.Space.XS),
						SortOrder = Enum.SortOrder.LayoutOrder,
					},
					statusButton("Open", "Open", 1),
					statusButton("Resolved", "Resolved", 2),
					statusButton("Dismissed", "Dismissed", 3),
				},
			},
		},
	}) :: Frame
end

-- One tab's scrollable content area -- only the selected tab's ScrollingFrame is Visible, so
-- switching tabs never re-mounts content, just hides it (the same trick Menus.lua/DevMenu's own
-- ScreenGui.Enabled already uses at the screen level, applied one level down per tab).
local function tabContent(
	scope: Scope,
	tabName: DevMenuTabName,
	selectedTab: Fusion.Value<DevMenuTabName>,
	children: { Instance }
): ScrollingFrame
	local isVisible = scope:Computed(function(use)
		return use(selectedTab) == tabName
	end)

	return scope:New "ScrollingFrame" {
		Name = tabName .. "Content",
		Size = SCROLL_SIZE,
		-- All three tab contents share one LayoutOrder: they occupy the same slot between the tab
		-- strip (2) and the footer (30), and at most one is ever Visible at a time (UIListLayout
		-- skips non-Visible children entirely, so the other two contribute no layout space).
		LayoutOrder = 3,
		Visible = isVisible,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.fromScale(0, 0),
		ScrollBarThickness = 6,
		ScrollBarImageColor3 = Tokens.Color.BorderAccent,

		[Children] = {
			-- Right padding keeps section panels clear of the scrollbar (ScrollBarThickness above)
			-- instead of its right edge overlapping panel borders.
			scope:New "UIPadding" {
				PaddingRight = UDim.new(0, Tokens.Space.XS),
			},
			scope:New "UIListLayout" {
				FillDirection = Enum.FillDirection.Vertical,
				HorizontalAlignment = Enum.HorizontalAlignment.Left,
				Padding = UDim.new(0, Tokens.Space.M),
				SortOrder = Enum.SortOrder.LayoutOrder,
			},
			table.unpack(children),
		},
	} :: ScrollingFrame
end

function DevMenu.Mount(scope: Scope, playerGui: PlayerGui): DevMenuHandle
	local isOpen = scope:Value(false)
	local statusText = scope:Value("")
	local targetNameDisplay = scope:Value("Self")
	local godmodeActive = scope:Value(false)
	local flightActive = scope:Value(false)
	local collideActive = scope:Value(false)
	local selectedTab: Fusion.Value<DevMenuTabName> = scope:Value("Spawn" :: DevMenuTabName)
	local hitboxStageDisplay: Fusion.Value<HitboxStageDisplayProps?> = scope:Value(nil :: HitboxStageDisplayProps?)
	local hitboxStandaloneDisplay: Fusion.Value<HitboxStandaloneDisplayProps?> =
		scope:Value(nil :: HitboxStandaloneDisplayProps?)
	local flightTuningDisplay: Fusion.Value<FlightTuningDisplayProps?> = scope:Value(nil :: FlightTuningDisplayProps?)
	local reportsDisplay: Fusion.Value<{ BugReportRowDisplay }> = scope:Value({} :: { BugReportRowDisplay })
	local reportsHasMore = scope:Value(false)
	local reportsLoading = scope:Value(false)

	-- Held alive by each Button's OnActivated closure below for as long as the mounted UI tree
	-- exists (which is the lifetime of this client) -- see file header for why a BindableEvent
	-- rather than a callback prop.
	local spawnDummyRequestedEvent = Instance.new("BindableEvent")
	local spawnBotRequestedEvent = Instance.new("BindableEvent")
	local setHealthRequestedEvent = Instance.new("BindableEvent")
	local setGodmodeRequestedEvent = Instance.new("BindableEvent")
	local setFlightRequestedEvent = Instance.new("BindableEvent")
	local setFlightCollideRequestedEvent = Instance.new("BindableEvent")
	local cycleHitboxStagePrevRequestedEvent = Instance.new("BindableEvent")
	local cycleHitboxStageNextRequestedEvent = Instance.new("BindableEvent")
	local adjustHitboxTimingRequestedEvent = Instance.new("BindableEvent")
	local resetHitboxStageRequestedEvent = Instance.new("BindableEvent")
	local cycleHitboxStandalonePrevRequestedEvent = Instance.new("BindableEvent")
	local cycleHitboxStandaloneNextRequestedEvent = Instance.new("BindableEvent")
	local adjustHitboxStandaloneRequestedEvent = Instance.new("BindableEvent")
	local resetHitboxStandaloneRequestedEvent = Instance.new("BindableEvent")
	local cycleFlightTuningPrevRequestedEvent = Instance.new("BindableEvent")
	local cycleFlightTuningNextRequestedEvent = Instance.new("BindableEvent")
	local adjustFlightTuningRequestedEvent = Instance.new("BindableEvent")
	local resetFlightTuningRequestedEvent = Instance.new("BindableEvent")
	local loadFirstReportsRequestedEvent = Instance.new("BindableEvent")
	local loadMoreReportsRequestedEvent = Instance.new("BindableEvent")
	local updateReportStatusRequestedEvent = Instance.new("BindableEvent")

	local targetLabelText = scope:Computed(function(use)
		return `Target: {use(targetNameDisplay)}`
	end)
	local godmodeButtonText = scope:Computed(function(use)
		return if use(godmodeActive) then "Godmode: On" else "Godmode: Off"
	end)
	local flightButtonText = scope:Computed(function(use)
		return if use(flightActive) then "Flight: On" else "Flight: Off"
	end)
	local collideButtonText = scope:Computed(function(use)
		return if use(collideActive) then "Collide: On" else "Collide: Off"
	end)

	-- Placeholder text shown before DevMenuClient.lua's initial ListHitboxStages response arrives,
	-- or if it ever fails -- Computed so every Label below stays bound even while nil.
	local hitboxTitleText = scope:Computed(function(use)
		local display = use(hitboxStageDisplay)
		return if display then display.TitleText else "Loading..."
	end)
	local hitboxWindupText = scope:Computed(function(use)
		local display = use(hitboxStageDisplay)
		return if display then display.WindupText else "Windup: --"
	end)
	local hitboxActiveText = scope:Computed(function(use)
		local display = use(hitboxStageDisplay)
		return if display then display.ActiveText else "Active: --"
	end)
	local hitboxRecoveryText = scope:Computed(function(use)
		local display = use(hitboxStageDisplay)
		return if display then display.RecoveryText else "Recovery: --"
	end)

	-- Same placeholder-until-loaded shape as the four hitboxX Computeds above, for the
	-- standalone-attack tuner (DashPunch/DashHit).
	local standaloneTitleText = scope:Computed(function(use)
		local display = use(hitboxStandaloneDisplay)
		return if display then display.TitleText else "Loading..."
	end)
	local standaloneWindupText = scope:Computed(function(use)
		local display = use(hitboxStandaloneDisplay)
		return if display then display.WindupText else "Windup: --"
	end)
	local standaloneActiveText = scope:Computed(function(use)
		local display = use(hitboxStandaloneDisplay)
		return if display then display.ActiveText else "Active: --"
	end)
	local standaloneRecoveryText = scope:Computed(function(use)
		local display = use(hitboxStandaloneDisplay)
		return if display then display.RecoveryText else "Recovery: --"
	end)
	local standaloneOffsetText = scope:Computed(function(use)
		local display = use(hitboxStandaloneDisplay)
		return if display then display.OffsetText else "Offset: --"
	end)

	-- Same placeholder-until-loaded shape as the Computeds above, for the flight-feel tuner.
	local flightTuningTitleText = scope:Computed(function(use)
		local display = use(flightTuningDisplay)
		return if display then display.TitleText else "Loading..."
	end)
	local flightTuningValueText = scope:Computed(function(use)
		local display = use(flightTuningDisplay)
		return if display then display.ValueText else "Value: --"
	end)

	-- Fractional (not a fixed offset) so TAB_COUNT tabs always sum to the tab strip's actual width
	-- regardless of ROOT_SIZE -- same 1/N-split idiom this file already uses for the Admin tab's
	-- Godmode/Flight/Collide row and the standalone-attack/hitbox selector rows. A fixed 128px-wide
	-- button (this function's previous shape, sized back when there were only 3 tabs) is what let a
	-- 4th tab ("Reports") overflow past the panel's right edge instead of sharing the strip's real
	-- width -- Frame has no ClipsDescendants here, so that overflow rendered as a fully disconnected
	-- floating button over the 3D viewport rather than being clipped or visibly cut off.
	local TAB_COUNT = 4
	local function tabButton(tabName: DevMenuTabName, text: string, layoutOrder: number): TextButton
		return Tab(scope, {
			Text = text,
			Size = UDim2.new(1 / TAB_COUNT, -Tokens.Space.XS, 0, Tokens.Control.StepButtonSize),
			LayoutOrder = layoutOrder,
			Selected = scope:Computed(function(use)
				return use(selectedTab) == tabName
			end),
			OnActivated = function()
				selectedTab:set(tabName)
			end,
		})
	end

	local spawnTab = tabContent(scope, "Spawn", selectedTab, {
		section(scope, "Training Dummy", 1, {
			Button(scope, {
				Text = "Spawn Training Dummy",
				Size = UDim2.new(1, 0, 0, Tokens.Control.RowHeight),
				LayoutOrder = 2,
				OnActivated = function()
					spawnDummyRequestedEvent:Fire()
				end,
			}),
		}),
		section(scope, "Training Bot Presets", 2, {
			scope:New "Frame" {
				Name = "BotPresetGrid",
				Size = UDim2.fromScale(1, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				BackgroundTransparency = 1,
				LayoutOrder = 2,

				[Children] = {
					scope:New "UIGridLayout" {
						CellSize = UDim2.fromOffset(174, 36),
						CellPadding = UDim2.fromOffset(Tokens.Space.S, Tokens.Space.S),
						SortOrder = Enum.SortOrder.LayoutOrder,
					},
					Button(scope, {
						Text = "Attack-Only",
						LayoutOrder = 1,
						OnActivated = function()
							spawnBotRequestedEvent:Fire("AttackOnly")
						end,
					}),
					Button(scope, {
						Text = "Block-Only",
						LayoutOrder = 2,
						OnActivated = function()
							spawnBotRequestedEvent:Fire("BlockOnly")
						end,
					}),
					Button(scope, {
						Text = "Parry-Only",
						LayoutOrder = 3,
						OnActivated = function()
							spawnBotRequestedEvent:Fire("ParryOnly")
						end,
					}),
					Button(scope, {
						Text = "Full-Fight",
						LayoutOrder = 4,
						OnActivated = function()
							spawnBotRequestedEvent:Fire("FullFight")
						end,
					}),
					Button(scope, {
						Text = "Aggressor",
						LayoutOrder = 5,
						OnActivated = function()
							spawnBotRequestedEvent:Fire("Aggressor")
						end,
					}),
					Button(scope, {
						Text = "Turtle",
						LayoutOrder = 6,
						OnActivated = function()
							spawnBotRequestedEvent:Fire("Turtle")
						end,
					}),
				},
			},
		}),
	})

	local adminTab = tabContent(scope, "Admin", selectedTab, {
		section(scope, "Health", 1, {
			scope:New "Frame" {
				Name = "HealthRow",
				Size = UDim2.new(1, 0, 0, Tokens.Control.RowHeight),
				BackgroundTransparency = 1,
				LayoutOrder = 2,

				[Children] = {
					scope:New "UIListLayout" {
						FillDirection = Enum.FillDirection.Horizontal,
						Padding = UDim.new(0, Tokens.Space.S),
						SortOrder = Enum.SortOrder.LayoutOrder,
					},
					Button(scope, {
						Text = "Heal Full",
						Size = UDim2.new(0.5, -Tokens.Space.XS, 0, Tokens.Control.RowHeight),
						LayoutOrder = 1,
						OnActivated = function()
							setHealthRequestedEvent:Fire(999999)
						end,
					}),
					Button(scope, {
						Text = "Set HP to 1",
						Size = UDim2.new(0.5, -Tokens.Space.XS, 0, Tokens.Control.RowHeight),
						LayoutOrder = 2,
						OnActivated = function()
							setHealthRequestedEvent:Fire(1)
						end,
					}),
				},
			},
		}),
		section(scope, "Godmode / Flight / Collide", 2, {
			scope:New "Frame" {
				Name = "ToggleRow",
				Size = UDim2.new(1, 0, 0, Tokens.Control.RowHeight),
				BackgroundTransparency = 1,
				LayoutOrder = 2,

				[Children] = {
					scope:New "UIListLayout" {
						FillDirection = Enum.FillDirection.Horizontal,
						Padding = UDim.new(0, Tokens.Space.S),
						SortOrder = Enum.SortOrder.LayoutOrder,
					},
					Tab(scope, {
						Text = godmodeButtonText,
						Selected = godmodeActive,
						Size = UDim2.new(1 / 3, -Tokens.Space.XS, 0, Tokens.Control.RowHeight),
						LayoutOrder = 1,
						OnActivated = function()
							setGodmodeRequestedEvent:Fire(not peek(godmodeActive))
						end,
					}),
					Tab(scope, {
						Text = flightButtonText,
						Selected = flightActive,
						Size = UDim2.new(1 / 3, -Tokens.Space.XS, 0, Tokens.Control.RowHeight),
						LayoutOrder = 2,
						OnActivated = function()
							setFlightRequestedEvent:Fire(not peek(flightActive))
						end,
					}),
					Tab(scope, {
						Text = collideButtonText,
						Selected = collideActive,
						Size = UDim2.new(1 / 3, -Tokens.Space.XS, 0, Tokens.Control.RowHeight),
						LayoutOrder = 3,
						OnActivated = function()
							setFlightCollideRequestedEvent:Fire(not peek(collideActive))
						end,
					}),
				},
			},
		}),
	})

	local tuningTab = tabContent(scope, "Tuning", selectedTab, {
		section(scope, "Hitbox Timing (Live Tune)", 1, {
			scope:New "Frame" {
				Name = "HitboxStageSelector",
				AutomaticSize = Enum.AutomaticSize.XY,
				BackgroundTransparency = 1,
				LayoutOrder = 2,

				[Children] = {
					scope:New "UIListLayout" {
						FillDirection = Enum.FillDirection.Horizontal,
						VerticalAlignment = Enum.VerticalAlignment.Center,
						Padding = UDim.new(0, Tokens.Space.XS),
						SortOrder = Enum.SortOrder.LayoutOrder,
					},
					Button(scope, {
						Text = "<",
						Size = UDim2.fromOffset(Tokens.Control.StepButtonSize, Tokens.Control.StepButtonSize),
						LayoutOrder = 1,
						OnActivated = function()
							cycleHitboxStagePrevRequestedEvent:Fire()
						end,
					}),
					Label(scope, {
						Text = hitboxTitleText,
						Scale = "Body",
						Size = UDim2.fromOffset(180, Tokens.Control.StepButtonSize),
						TextXAlignment = Enum.TextXAlignment.Center,
						LayoutOrder = 2,
					}),
					Button(scope, {
						Text = ">",
						Size = UDim2.fromOffset(Tokens.Control.StepButtonSize, Tokens.Control.StepButtonSize),
						LayoutOrder = 3,
						OnActivated = function()
							cycleHitboxStageNextRequestedEvent:Fire()
						end,
					}),
				},
			},
			hitboxTimingRow(scope, 3, hitboxWindupText, function(delta: number)
				adjustHitboxTimingRequestedEvent:Fire("WindupSeconds", delta)
			end),
			hitboxTimingRow(scope, 4, hitboxActiveText, function(delta: number)
				adjustHitboxTimingRequestedEvent:Fire("ActiveSeconds", delta)
			end),
			hitboxTimingRow(scope, 5, hitboxRecoveryText, function(delta: number)
				adjustHitboxTimingRequestedEvent:Fire("RecoverySeconds", delta)
			end),
			Button(scope, {
				Text = "Reset Stage to Default",
				Size = UDim2.new(1, 0, 0, Tokens.Control.RowHeight),
				LayoutOrder = 6,
				OnActivated = function()
					resetHitboxStageRequestedEvent:Fire()
				end,
			}),
		}),
		section(scope, "Standalone Attacks (Live Tune)", 2, {
			scope:New "Frame" {
				Name = "StandaloneAttackSelector",
				AutomaticSize = Enum.AutomaticSize.XY,
				BackgroundTransparency = 1,
				LayoutOrder = 2,

				[Children] = {
					scope:New "UIListLayout" {
						FillDirection = Enum.FillDirection.Horizontal,
						VerticalAlignment = Enum.VerticalAlignment.Center,
						Padding = UDim.new(0, Tokens.Space.XS),
						SortOrder = Enum.SortOrder.LayoutOrder,
					},
					Button(scope, {
						Text = "<",
						Size = UDim2.fromOffset(Tokens.Control.StepButtonSize, Tokens.Control.StepButtonSize),
						LayoutOrder = 1,
						OnActivated = function()
							cycleHitboxStandalonePrevRequestedEvent:Fire()
						end,
					}),
					Label(scope, {
						Text = standaloneTitleText,
						Scale = "Body",
						Size = UDim2.fromOffset(180, Tokens.Control.StepButtonSize),
						TextXAlignment = Enum.TextXAlignment.Center,
						LayoutOrder = 2,
					}),
					Button(scope, {
						Text = ">",
						Size = UDim2.fromOffset(Tokens.Control.StepButtonSize, Tokens.Control.StepButtonSize),
						LayoutOrder = 3,
						OnActivated = function()
							cycleHitboxStandaloneNextRequestedEvent:Fire()
						end,
					}),
				},
			},
			hitboxTimingRow(scope, 3, standaloneWindupText, function(delta: number)
				adjustHitboxStandaloneRequestedEvent:Fire("WindupSeconds", delta)
			end),
			hitboxTimingRow(scope, 4, standaloneActiveText, function(delta: number)
				adjustHitboxStandaloneRequestedEvent:Fire("ActiveSeconds", delta)
			end),
			hitboxTimingRow(scope, 5, standaloneRecoveryText, function(delta: number)
				adjustHitboxStandaloneRequestedEvent:Fire("RecoverySeconds", delta)
			end),
			-- Offset (studs, not seconds) -- the one field this tuner has that the weapon-stage one
			-- above doesn't (see Types.HitboxStandaloneInfo's own header). Reuses hitboxTimingRow's
			-- same +-0.01/+-0.1 step buttons -- coarser than ideal for stud increments, but keeps
			-- the row visually/behaviorally consistent with the three above; the 0.1 step alone is
			-- a reasonable single-click granularity for nudging a hitbox's reach.
			hitboxTimingRow(scope, 6, standaloneOffsetText, function(delta: number)
				adjustHitboxStandaloneRequestedEvent:Fire("OffsetForwardStuds", delta)
			end),
			Button(scope, {
				Text = "Reset Attack to Default",
				Size = UDim2.new(1, 0, 0, Tokens.Control.RowHeight),
				LayoutOrder = 7,
				OnActivated = function()
					resetHitboxStandaloneRequestedEvent:Fire()
				end,
			}),
		}),
		section(scope, "Flight Tuning (Live Tune)", 3, {
			scope:New "Frame" {
				Name = "FlightTuningSelector",
				AutomaticSize = Enum.AutomaticSize.XY,
				BackgroundTransparency = 1,
				LayoutOrder = 2,

				[Children] = {
					scope:New "UIListLayout" {
						FillDirection = Enum.FillDirection.Horizontal,
						VerticalAlignment = Enum.VerticalAlignment.Center,
						Padding = UDim.new(0, Tokens.Space.XS),
						SortOrder = Enum.SortOrder.LayoutOrder,
					},
					Button(scope, {
						Text = "<",
						Size = UDim2.fromOffset(Tokens.Control.StepButtonSize, Tokens.Control.StepButtonSize),
						LayoutOrder = 1,
						OnActivated = function()
							cycleFlightTuningPrevRequestedEvent:Fire()
						end,
					}),
					Label(scope, {
						Text = flightTuningTitleText,
						Scale = "Body",
						Size = UDim2.fromOffset(180, Tokens.Control.StepButtonSize),
						TextXAlignment = Enum.TextXAlignment.Center,
						LayoutOrder = 2,
					}),
					Button(scope, {
						Text = ">",
						Size = UDim2.fromOffset(Tokens.Control.StepButtonSize, Tokens.Control.StepButtonSize),
						LayoutOrder = 3,
						OnActivated = function()
							cycleFlightTuningNextRequestedEvent:Fire()
						end,
					}),
				},
			},
			-- Fraction-style steps (+-1%/+-10%) rather than hitboxTimingRow's usual absolute
			-- seconds deltas -- reused verbatim as a component (it's generic: valueText +
			-- onAdjust(delta)), just fed a different meaning for `delta` here. See
			-- Server/DevMenu/FlightTuning.lua's own header for why a fractional delta is the one
			-- deviation from the Hitbox tuners' shape.
			hitboxTimingRow(scope, 3, flightTuningValueText, function(delta: number)
				adjustFlightTuningRequestedEvent:Fire(delta)
			end),
			Button(scope, {
				Text = "Reset Field to Default",
				Size = UDim2.new(1, 0, 0, Tokens.Control.RowHeight),
				LayoutOrder = 4,
				OnActivated = function()
					resetFlightTuningRequestedEvent:Fire()
				end,
			}),
		}),
	})

	-- Dynamic list rendering: scope:ForPairs, same primitive CombatFeedback/init.lua's damage-number
	-- list already uses (see that file's own comment on ForPairs vs. ForValues) -- keyed by
	-- display.Id (not the source array's own index) so a status-change re-render reuses/updates the
	-- same row Instance instead of tearing down and rebuilding every row whenever any one of them
	-- changes. The first dynamic (data-driven) list in THIS screen; every other DevMenu section is
	-- fixed-at-mount. Given admin report volume is low and pages are capped
	-- (Constants.BugReport.ListPageSize), no virtualization is needed. LayoutOrder is offset past the
	-- section's own title (1) and toolbar (2) below so rows always sort after both.
	local reportRows = scope:ForPairs(reportsDisplay, function(use, innerScope, index, display)
		return display.Id,
			reportRow(innerScope, display, 10 + index, function(newStatus: string)
				updateReportStatusRequestedEvent:Fire(display.Id, newStatus)
			end)
	end)

	local loadMoreButtonText = scope:Computed(function(use)
		if use(reportsLoading) then
			return "Loading..."
		end
		return if use(reportsHasMore) then "Load More" else "No More Reports"
	end)

	local reportsTab = tabContent(scope, "Reports", selectedTab, {
		section(scope, "Bug Reports", 1, {
			scope:New "Frame" {
				Name = "ReportsToolbar",
				Size = UDim2.new(1, 0, 0, Tokens.Control.RowHeight),
				BackgroundTransparency = 1,
				LayoutOrder = 2,

				[Children] = {
					scope:New "UIListLayout" {
						FillDirection = Enum.FillDirection.Horizontal,
						Padding = UDim.new(0, Tokens.Space.S),
						SortOrder = Enum.SortOrder.LayoutOrder,
					},
					Button(scope, {
						Text = "Refresh",
						Size = UDim2.new(0.5, -Tokens.Space.XS, 0, Tokens.Control.RowHeight),
						LayoutOrder = 1,
						OnActivated = function()
							loadFirstReportsRequestedEvent:Fire()
						end,
					}),
					Button(scope, {
						Text = loadMoreButtonText,
						Size = UDim2.new(0.5, -Tokens.Space.XS, 0, Tokens.Control.RowHeight),
						LayoutOrder = 2,
						Disabled = scope:Computed(function(use)
							return use(reportsLoading) or not use(reportsHasMore)
						end),
						OnActivated = function()
							loadMoreReportsRequestedEvent:Fire()
						end,
					}),
				},
			},
			reportRows,
		}),
	})

	scope:New "ScreenGui" {
		Name = "DevMenu",
		ResetOnSpawn = false,
		Enabled = isOpen,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Parent = playerGui,

		[Children] = Panel(scope, {
			Name = "Root",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = ROOT_SIZE,
			Elevated = true,
			CornerAccent = true,

			Children = {
				scope:New "UIPadding" {
					PaddingTop = UDim.new(0, Tokens.Space.L),
					PaddingBottom = UDim.new(0, Tokens.Space.L),
					PaddingLeft = UDim.new(0, Tokens.Space.L),
					PaddingRight = UDim.new(0, Tokens.Space.L),
				},
				scope:New "UIListLayout" {
					FillDirection = Enum.FillDirection.Vertical,
					HorizontalAlignment = Enum.HorizontalAlignment.Left,
					Padding = UDim.new(0, Tokens.Space.M),
					SortOrder = Enum.SortOrder.LayoutOrder,
				},

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
							Scale = "Caption",
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

				-- Tab strip.
				scope:New "Frame" {
					Name = "TabStrip",
					Size = UDim2.new(1, 0, 0, TAB_STRIP_HEIGHT),
					BackgroundTransparency = 1,
					LayoutOrder = 2,

					[Children] = {
						scope:New "UIListLayout" {
							FillDirection = Enum.FillDirection.Horizontal,
							Padding = UDim.new(0, Tokens.Space.S),
							SortOrder = Enum.SortOrder.LayoutOrder,
						},
						tabButton("Spawn", "Spawn", 1),
						tabButton("Admin", "Admin", 2),
						tabButton("Tuning", "Tuning", 3),
						tabButton("Reports", "Reports", 4),
					},
				},

				spawnTab,
				adminTab,
				tuningTab,
				reportsTab,

				Label(scope, {
					Text = statusText,
					Scale = "Caption",
					Color = Tokens.Color.TextSecondary,
					Size = UDim2.new(1, 0, 0, FOOTER_HEIGHT),
					LayoutOrder = 30,
				}),
			},
		}),
	}

	return {
		IsOpen = isOpen,
		StatusText = statusText,
		TargetNameDisplay = targetNameDisplay,
		GodmodeActive = godmodeActive,
		FlightActive = flightActive,
		CollideActive = collideActive,
		SpawnDummyRequested = spawnDummyRequestedEvent.Event,
		SpawnBotRequested = spawnBotRequestedEvent.Event,
		SetHealthRequested = setHealthRequestedEvent.Event,
		SetGodmodeRequested = setGodmodeRequestedEvent.Event,
		SetFlightRequested = setFlightRequestedEvent.Event,
		SetFlightCollideRequested = setFlightCollideRequestedEvent.Event,
		HitboxStageDisplay = hitboxStageDisplay,
		CycleHitboxStagePrevRequested = cycleHitboxStagePrevRequestedEvent.Event,
		CycleHitboxStageNextRequested = cycleHitboxStageNextRequestedEvent.Event,
		AdjustHitboxTimingRequested = adjustHitboxTimingRequestedEvent.Event,
		ResetHitboxStageRequested = resetHitboxStageRequestedEvent.Event,
		HitboxStandaloneDisplay = hitboxStandaloneDisplay,
		CycleHitboxStandalonePrevRequested = cycleHitboxStandalonePrevRequestedEvent.Event,
		CycleHitboxStandaloneNextRequested = cycleHitboxStandaloneNextRequestedEvent.Event,
		AdjustHitboxStandaloneRequested = adjustHitboxStandaloneRequestedEvent.Event,
		ResetHitboxStandaloneRequested = resetHitboxStandaloneRequestedEvent.Event,
		FlightTuningDisplay = flightTuningDisplay,
		CycleFlightTuningPrevRequested = cycleFlightTuningPrevRequestedEvent.Event,
		CycleFlightTuningNextRequested = cycleFlightTuningNextRequestedEvent.Event,
		AdjustFlightTuningRequested = adjustFlightTuningRequestedEvent.Event,
		ResetFlightTuningRequested = resetFlightTuningRequestedEvent.Event,
		ReportsDisplay = reportsDisplay,
		ReportsHasMore = reportsHasMore,
		ReportsLoading = reportsLoading,
		LoadFirstReportsRequested = loadFirstReportsRequestedEvent.Event,
		LoadMoreReportsRequested = loadMoreReportsRequestedEvent.Event,
		UpdateReportStatusRequested = updateReportStatusRequestedEvent.Event,
	}
end

return DevMenu
