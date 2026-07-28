--!strict
--[[
	DevMenu/ContentArea.lua

	Owns: every DevMenu tab (Spawn/Admin/Tuning/Reports). Phase 0 extracted this out of the pre-split
	DevMenu/init.lua as a pure file move (a "Players" tab still existed here, wrapping Sidebar.lua's
	roster); THIS PHASE (Phase 1) drops "Players" from the tab strip entirely -- the roster now lives
	permanently in Sidebar's own persistent column instead (see that module's own header), so this
	module no longer needs a Sidebar handle at all.

	Returns a single self-contained `Root: Frame` (tab strip + the 4 tab ScrollingFrames stacked, only
	one Visible at a time) sized to `(width, bodyHeight)` -- both explicit Mount parameters from
	init.lua's own top-level column-split budget (see that module's own ROOT_SIZE/CONTENT_WIDTH
	math). Everything below that split (tab strip height vs. scroll area) is this module's own budget,
	the same ownership boundary Sidebar.lua keeps for its own stats-header/roster-scroll split.

	Follows CombatFeedback.lua's "screen exposes state/signals, client module drives from outside"
	precedent, same as every other DevMenu section -- DevMenuClient.lua connects to every *Requested
	signal from outside, exactly as it did on the flat handle before either split.

	Does not own: authorization (DevMenuSystem.lua re-checks server-side regardless of what this
	screen renders), or the roster (Sidebar.lua, a persistent sibling column -- not a tab here anymore).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Fusion = require(ReplicatedStorage.Packages.Fusion)

local Constants = require(ReplicatedStorage.Shared.Constants)
local Tokens = require(script.Parent.Parent.Parent.Tokens)
local Panel = require(script.Parent.Parent.Parent.Components.Panel)
local Section = require(script.Parent.Parent.Parent.Components.Section)
local Label = require(script.Parent.Parent.Parent.Components.Label)
local Button = require(script.Parent.Parent.Parent.Components.Button)
local Tab = require(script.Parent.Parent.Parent.Components.Tab)
local TextField = require(script.Parent.Parent.Parent.Components.TextField)
local AbilitySlot = require(script.Parent.Parent.Parent.Components.AbilitySlot)
local DevMenuTypes = require(script.Parent.Types)

local Children = Fusion.Children
local peek = Fusion.peek

type Scope = Fusion.Scope<typeof(Fusion)>
type DevMenuTabName = DevMenuTypes.DevMenuTabName
type HitboxStageDisplayProps = DevMenuTypes.HitboxStageDisplayProps
type HitboxStandaloneDisplayProps = DevMenuTypes.HitboxStandaloneDisplayProps
type FlightTuningDisplayProps = DevMenuTypes.FlightTuningDisplayProps
type BugReportRowDisplay = DevMenuTypes.BugReportRowDisplay
type ContentAreaHandle = DevMenuTypes.ContentAreaHandle
type AbilitySlotState = AbilitySlot.AbilitySlotState

local ContentArea = {}

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
			-- An inline row label (this bug report's own header line), not a section title --
			-- BodyLarge (sans), where the deprecated Subheading alias already pointed (docs/design/
			-- intro-redesign-handoff.md Phase F's Subheading sweep).
			Label(scope, { Text = display.HeaderText, Scale = "BodyLarge", LayoutOrder = 1 }),
			Label(scope, { Text = display.DescriptionText, Scale = "Body", LayoutOrder = 2 }),
			Label(scope, {
				Text = display.ContextText,
				Scale = "Detail",
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
	scrollSize: UDim2,
	children: { Instance }
): ScrollingFrame
	local isVisible = scope:Computed(function(use)
		return use(selectedTab) == tabName
	end)

	return scope:New "ScrollingFrame" {
		Name = tabName .. "Content",
		Size = scrollSize,
		-- All four tab contents share one LayoutOrder: they occupy the same slot below the tab strip
		-- (LayoutOrder 1) inside this module's own Root frame, and at most one is ever Visible at a
		-- time (UIListLayout skips non-Visible children entirely, so the other three contribute no
		-- layout space).
		LayoutOrder = 2,
		Visible = isVisible,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.fromScale(0, 0),
		-- 3px, no track (docs/design/intro-redesign-figma-spec.md section 7's Scrollbar note), the
		-- Border.Standard tint instead of a flat accent -- matches CreatorFrame.lua's own scrollbar.
		ScrollBarThickness = 3,
		ScrollBarImageColor3 = Tokens.Border.Standard.Color,
		ScrollBarImageTransparency = Tokens.Border.Standard.Transparency,

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

-- Tab-strip row height -- a ContentArea-internal layout decision (unlike `width`/`bodyHeight` below,
-- which come from init.lua's own top-level column split), the same way Sidebar.lua owns its own
-- STATS_HEIGHT rather than having init.lua dictate it.
local TAB_STRIP_HEIGHT = 36

-- Demo accent colors for the Ability Slot Preview harness (Tuning tab) -- five of AbilitySlot's new
-- AccentColor prop, one per preview slot, so the tint is visibly demonstrated across a full 5-slot
-- row the same way the real hotbar is shaped. Reuses existing named tokens rather than inventing
-- arbitrary Color3 literals for a purely illustrative palette -- these are NOT a claim about which
-- ability/bloodline will eventually own which hue, just five already-distinct colors this file
-- already has a name for.
--
-- Updated for the violet/bronze redesign (docs/design/intro-redesign-handoff.md Phase F) -- swaps
-- the two faction colors for AccentPrimary/AccentSecondary, the redesign's own two new accents and
-- the ones an admin is most likely to actually want to see this harness demonstrate; the three
-- vitals stay since they're still useful, still-distinct contrast references.
local ABILITY_PREVIEW_ACCENT_COLORS = {
	Tokens.VitalColor.Health,
	Tokens.VitalColor.Qi,
	Tokens.VitalColor.Posture,
	Tokens.Color.AccentPrimary,
	Tokens.Color.AccentSecondary,
}

-- `width`/`bodyHeight` are init.lua's explicit top-level column-split budget (see that module's own
-- ROOT_SIZE/CONTENT_WIDTH math) -- this module never guesses its own placement inside the Root
-- panel. Everything below that split (tab strip vs. scroll area) is this module's own budget.
function ContentArea.Mount(scope: Scope, width: number, bodyHeight: number): ContentAreaHandle
	-- Root (bodyHeight) minus the tab strip minus the one UIListLayout gap between the strip and the
	-- scroll area leaves each tab's own scrollable height.
	local scrollHeight = bodyHeight - TAB_STRIP_HEIGHT - Tokens.Space.M
	local scrollSize = UDim2.fromOffset(width, scrollHeight)

	local targetNameDisplay = scope:Value("Self")
	local godmodeActive = scope:Value(false)
	local flightActive = scope:Value(false)
	local collideActive = scope:Value(false)
	local selectedTab: Fusion.Value<DevMenuTabName> = scope:Value("Spawn" :: DevMenuTabName)
	local hitboxStageDisplay: Fusion.Value<HitboxStageDisplayProps?> = scope:Value(nil :: HitboxStageDisplayProps?)
	local hitboxStandaloneDisplay: Fusion.Value<HitboxStandaloneDisplayProps?> =
		scope:Value(nil :: HitboxStandaloneDisplayProps?)
	local flightTuningDisplay: Fusion.Value<FlightTuningDisplayProps?> = scope:Value(nil :: FlightTuningDisplayProps?)

	-- Ability Slot Preview (Tuning tab, see the Section built below) -- entirely local/fake state,
	-- never sent to or read from the server: this harness exists purely to make AbilitySlot's
	-- Available/Cooldown/Active/AccentColor rendering visible and verifiable ahead of ArtSystem (see
	-- that component's header). No BindableEvent pair needed since nothing here is a request the
	-- server needs to authorize -- unlike every other Tuning tool above, which mutates real
	-- server-authoritative tuning data.
	local abilityPreviewState: Fusion.Value<AbilitySlotState> = scope:Value("Locked" :: AbilitySlotState)
	local abilityPreviewCooldownFraction = scope:Value(0)
	local abilityPreviewCooldownSeconds = scope:Value(0)

	local reportsDisplay: Fusion.Value<{ BugReportRowDisplay }> = scope:Value({} :: { BugReportRowDisplay })
	local reportsHasMore = scope:Value(false)
	local reportsLoading = scope:Value(false)

	local frozenActive = scope:Value(false)
	local invisibleActive = scope:Value(false)
	local speedMultiplierActive = scope:Value(1)
	local spectatingActive = scope:Value(false)

	-- Local-only raw input state for Teleport-To-Coordinates/Broadcast-Announcement -- neither is
	-- exposed on the handle itself (same "screen owns its own raw input, fires already-validated
	-- values" boundary the Reports tab's triage buttons and BugReport/init.lua's description field
	-- already keep).
	local teleportXText = scope:Value("0")
	local teleportYText = scope:Value("0")
	local teleportZText = scope:Value("0")
	local announcementMessageText = scope:Value("")

	-- Held alive by each Button's OnActivated closure below for as long as the mounted UI tree
	-- exists (which is the lifetime of this client) -- see DevMenu/init.lua's own header for why a
	-- BindableEvent rather than a callback prop.
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
	local setFrozenRequestedEvent = Instance.new("BindableEvent")
	local setInvisibleRequestedEvent = Instance.new("BindableEvent")
	local setSpeedMultiplierRequestedEvent = Instance.new("BindableEvent")
	local teleportToTargetRequestedEvent = Instance.new("BindableEvent")
	local bringTargetRequestedEvent = Instance.new("BindableEvent")
	local teleportToCoordinatesRequestedEvent = Instance.new("BindableEvent")
	local forceRespawnTargetRequestedEvent = Instance.new("BindableEvent")
	local broadcastAnnouncementRequestedEvent = Instance.new("BindableEvent")
	local shutdownServerRequestedEvent = Instance.new("BindableEvent")
	local spectateLockedTargetRequestedEvent = Instance.new("BindableEvent")

	local godmodeButtonText = scope:Computed(function(use)
		return if use(godmodeActive) then "Godmode: On" else "Godmode: Off"
	end)
	local flightButtonText = scope:Computed(function(use)
		return if use(flightActive) then "Flight: On" else "Flight: Off"
	end)
	local collideButtonText = scope:Computed(function(use)
		return if use(collideActive) then "Collide: On" else "Collide: Off"
	end)
	local frozenButtonText = scope:Computed(function(use)
		return if use(frozenActive) then "Frozen: On" else "Frozen: Off"
	end)
	local invisibleButtonText = scope:Computed(function(use)
		return if use(invisibleActive) then "Invisible: On" else "Invisible: Off"
	end)
	local speedMultiplierText = scope:Computed(function(use)
		return `Speed: {use(speedMultiplierActive)}x`
	end)
	local spectateButtonText = scope:Computed(function(use)
		return if use(spectatingActive) then "Spectating: On" else "Spectate Locked Target"
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

	-- Ability Slot Preview harness (see abilityPreviewState's own declaration above). Held in this
	-- closure (not a module-local) since it's scoped to one Mount call's lifetime, the same
	-- "disconnect-before-reconnect" idiom FlightController.lua's heartbeatConnection already uses for
	-- its own start/stop toggle.
	local abilityPreviewCooldownConnection: RBXScriptConnection? = nil

	local function stopAbilityPreviewCooldownDemo()
		if abilityPreviewCooldownConnection then
			abilityPreviewCooldownConnection:Disconnect()
			abilityPreviewCooldownConnection = nil
		end
	end

	-- Backs the four Locked/Available/Cooldown/Active preview buttons below. Selecting "Cooldown"
	-- directly (without pressing "Run Cooldown Demo") snapshots a representative half-drained frame
	-- so the overlay/timer are visible immediately, not just mid-animation.
	local function setAbilityPreviewState(targetState: AbilitySlotState)
		stopAbilityPreviewCooldownDemo()
		abilityPreviewState:set(targetState)
		if targetState == "Cooldown" then
			abilityPreviewCooldownFraction:set(0.5)
			abilityPreviewCooldownSeconds:set(Constants.Debug.DevMenu.AbilityPreviewCooldownDemoSeconds / 2)
		else
			abilityPreviewCooldownFraction:set(0)
			abilityPreviewCooldownSeconds:set(0)
		end
	end

	-- Animates the preview row through a full Cooldown drain (1 -> 0 over
	-- AbilityPreviewCooldownDemoSeconds), then hands off to Available -- the one thing a static
	-- setAbilityPreviewState("Cooldown") snapshot can't demonstrate on its own: the vertical overlay
	-- actually receding and the timer actually counting down.
	local function runAbilityPreviewCooldownDemo()
		stopAbilityPreviewCooldownDemo()
		abilityPreviewState:set("Cooldown")
		local totalSeconds = Constants.Debug.DevMenu.AbilityPreviewCooldownDemoSeconds
		local remaining = totalSeconds
		abilityPreviewCooldownFraction:set(1)
		abilityPreviewCooldownSeconds:set(remaining)
		abilityPreviewCooldownConnection = RunService.Heartbeat:Connect(function(deltaTime: number)
			remaining -= deltaTime
			if remaining <= 0 then
				stopAbilityPreviewCooldownDemo()
				abilityPreviewCooldownFraction:set(0)
				abilityPreviewCooldownSeconds:set(0)
				abilityPreviewState:set("Available")
				return
			end
			abilityPreviewCooldownFraction:set(remaining / totalSeconds)
			abilityPreviewCooldownSeconds:set(remaining)
		end)
	end

	local abilityPreviewSlots: { Instance } = {}
	for index = 1, 5 do
		abilityPreviewSlots[index] = AbilitySlot(scope, {
			Keybind = tostring(index),
			LayoutOrder = index,
			State = abilityPreviewState,
			AccentColor = ABILITY_PREVIEW_ACCENT_COLORS[index],
			CooldownFraction = abilityPreviewCooldownFraction,
			CooldownSeconds = abilityPreviewCooldownSeconds,
		})
	end

	local function abilityPreviewStateButton(
		text: string,
		targetState: AbilitySlotState,
		layoutOrder: number
	): TextButton
		return Tab(scope, {
			Text = text,
			Selected = scope:Computed(function(use)
				return use(abilityPreviewState) == targetState
			end),
			Size = UDim2.new(1 / 4, -Tokens.Space.XS, 0, Tokens.Control.StepButtonSize),
			LayoutOrder = layoutOrder,
			OnActivated = function()
				setAbilityPreviewState(targetState)
			end,
		})
	end

	-- Fractional (not a fixed offset) so TAB_COUNT tabs always sum to the tab strip's actual width
	-- regardless of the root panel's own width -- same 1/N-split idiom this file already uses for
	-- the Admin tab's Godmode/Flight/Collide row and the standalone-attack/hitbox selector rows.
	-- 4, not 5 -- "Players" was dropped from the tab strip in Phase 1 (see this module's own header).
	local TAB_COUNT = 4
	local function tabButton(tabName: DevMenuTabName, text: string, layoutOrder: number): TextButton
		return Tab(scope, {
			Text = text,
			Size = UDim2.new(1 / TAB_COUNT, -Tokens.Space.XS, 0, Tokens.Control.StepButtonSize),
			LayoutOrder = layoutOrder,
			Selected = scope:Computed(function(use)
				return use(selectedTab) == tabName
			end),
			-- The real tab strip -- static names, safe for Tab.lua's TrackedCaps (see that file's own
			-- header for why every OTHER Tab call site in this file leaves it off).
			TrackedCaps = true,
			OnActivated = function()
				selectedTab:set(tabName)
			end,
		})
	end

	local spawnTab = tabContent(scope, "Spawn", selectedTab, scrollSize, {
		Section(scope, "Training Dummy", 1, {
			Button(scope, {
				Text = "Spawn Training Dummy",
				Size = UDim2.new(1, 0, 0, Tokens.Control.RowHeight),
				LayoutOrder = 2,
				OnActivated = function()
					spawnDummyRequestedEvent:Fire()
				end,
			}),
		}),
		Section(scope, "Training Bot Presets", 2, {
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

	-- Speed Multiplier preset buttons -- built as a named local array (same idiom BugReport/init.lua's
	-- categoryButtons already uses) rather than inline, since a plain `for` loop reads more clearly
	-- here than an IIFE would inside the section's own Children table below.
	local speedPresetButtons: { Instance } = {}
	for index, preset in ipairs(Constants.Debug.DevMenu.SpeedMultiplierPresets) do
		speedPresetButtons[index] = Tab(scope, {
			Text = `{preset}x`,
			Selected = scope:Computed(function(use)
				return use(speedMultiplierActive) == preset
			end),
			Size = UDim2.new(1 / 5, -Tokens.Space.XS, 0, Tokens.Control.RowHeight),
			LayoutOrder = index,
			OnActivated = function()
				setSpeedMultiplierRequestedEvent:Fire(preset)
			end,
		})
	end

	local adminTab = tabContent(scope, "Admin", selectedTab, scrollSize, {
		Section(scope, "Health", 1, {
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
		Section(scope, "Godmode / Flight / Collide", 2, {
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
		Section(scope, "Frozen / Invisible / Speed", 3, {
			scope:New "Frame" {
				Name = "FrozenInvisibleRow",
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
						Text = frozenButtonText,
						Selected = frozenActive,
						Size = UDim2.new(0.5, -Tokens.Space.XS, 0, Tokens.Control.RowHeight),
						LayoutOrder = 1,
						OnActivated = function()
							setFrozenRequestedEvent:Fire(not peek(frozenActive))
						end,
					}),
					Tab(scope, {
						Text = invisibleButtonText,
						Selected = invisibleActive,
						Size = UDim2.new(0.5, -Tokens.Space.XS, 0, Tokens.Control.RowHeight),
						LayoutOrder = 2,
						OnActivated = function()
							setInvisibleRequestedEvent:Fire(not peek(invisibleActive))
						end,
					}),
				},
			},
			Label(scope, { Text = speedMultiplierText, Scale = "Body", LayoutOrder = 3 }),
			scope:New "Frame" {
				Name = "SpeedMultiplierRow",
				Size = UDim2.new(1, 0, 0, Tokens.Control.RowHeight),
				BackgroundTransparency = 1,
				LayoutOrder = 4,

				[Children] = {
					scope:New "UIListLayout" {
						FillDirection = Enum.FillDirection.Horizontal,
						Padding = UDim.new(0, Tokens.Space.XS),
						SortOrder = Enum.SortOrder.LayoutOrder,
					},
					table.unpack(speedPresetButtons),
				},
			},
		}),
		Section(scope, "Teleport", 4, {
			scope:New "Frame" {
				Name = "TeleportRow",
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
						Text = "Teleport To Target",
						Size = UDim2.new(0.5, -Tokens.Space.XS, 0, Tokens.Control.RowHeight),
						LayoutOrder = 1,
						OnActivated = function()
							teleportToTargetRequestedEvent:Fire()
						end,
					}),
					Button(scope, {
						Text = "Bring Target",
						Size = UDim2.new(0.5, -Tokens.Space.XS, 0, Tokens.Control.RowHeight),
						LayoutOrder = 2,
						OnActivated = function()
							bringTargetRequestedEvent:Fire()
						end,
					}),
				},
			},
			Label(scope, {
				Text = "Teleport To Coordinates",
				Scale = "Detail",
				Color = Tokens.Color.TextSecondary,
				LayoutOrder = 3,
			}),
			scope:New "Frame" {
				Name = "CoordinateRow",
				Size = UDim2.new(1, 0, 0, Tokens.Control.RowHeight),
				BackgroundTransparency = 1,
				LayoutOrder = 4,

				[Children] = {
					scope:New "UIListLayout" {
						FillDirection = Enum.FillDirection.Horizontal,
						Padding = UDim.new(0, Tokens.Space.XS),
						SortOrder = Enum.SortOrder.LayoutOrder,
					},
					TextField(scope, {
						Text = teleportXText,
						PlaceholderText = "X",
						Size = UDim2.new(1 / 4, -Tokens.Space.XS, 0, Tokens.Control.RowHeight),
						LayoutOrder = 1,
					}),
					TextField(scope, {
						Text = teleportYText,
						PlaceholderText = "Y",
						Size = UDim2.new(1 / 4, -Tokens.Space.XS, 0, Tokens.Control.RowHeight),
						LayoutOrder = 2,
					}),
					TextField(scope, {
						Text = teleportZText,
						PlaceholderText = "Z",
						Size = UDim2.new(1 / 4, -Tokens.Space.XS, 0, Tokens.Control.RowHeight),
						LayoutOrder = 3,
					}),
					Button(scope, {
						Text = "Go",
						Size = UDim2.new(1 / 4, -Tokens.Space.XS, 0, Tokens.Control.RowHeight),
						LayoutOrder = 4,
						OnActivated = function()
							local x = tonumber(peek(teleportXText))
							local y = tonumber(peek(teleportYText))
							local z = tonumber(peek(teleportZText))
							if x and y and z then
								teleportToCoordinatesRequestedEvent:Fire(x, y, z)
							end
						end,
					}),
				},
			},
			Button(scope, {
				Text = "Force Respawn Target",
				Size = UDim2.new(1, 0, 0, Tokens.Control.RowHeight),
				LayoutOrder = 5,
				OnActivated = function()
					forceRespawnTargetRequestedEvent:Fire()
				end,
			}),
		}),
		Section(scope, "Server Tools", 5, {
			TextField(scope, {
				Text = announcementMessageText,
				PlaceholderText = "Announcement message...",
				MaxLength = Constants.Debug.DevMenu.AnnouncementMaxLength,
				Size = UDim2.new(1, 0, 0, Tokens.Control.RowHeight),
				LayoutOrder = 2,
			}),
			Button(scope, {
				Text = "Broadcast Announcement",
				Size = UDim2.new(1, 0, 0, Tokens.Control.RowHeight),
				LayoutOrder = 3,
				OnActivated = function()
					local message = peek(announcementMessageText)
					if #message > 0 then
						broadcastAnnouncementRequestedEvent:Fire(message)
						announcementMessageText:set("")
					end
				end,
			}),
			Tab(scope, {
				Text = spectateButtonText,
				Selected = spectatingActive,
				Size = UDim2.new(1, 0, 0, Tokens.Control.RowHeight),
				LayoutOrder = 4,
				OnActivated = function()
					spectateLockedTargetRequestedEvent:Fire()
				end,
			}),
			Button(scope, {
				Text = "Shutdown Server",
				Size = UDim2.new(1, 0, 0, Tokens.Control.RowHeight),
				LayoutOrder = 5,
				OnActivated = function()
					shutdownServerRequestedEvent:Fire()
				end,
			}),
		}),
	})

	local tuningTab = tabContent(scope, "Tuning", selectedTab, scrollSize, {
		Section(scope, "Hitbox Timing (Live Tune)", 1, {
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
		Section(scope, "Standalone Attacks (Live Tune)", 2, {
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
		Section(scope, "Flight Tuning (Live Tune)", 3, {
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
		Section(scope, "Ability Slot Preview (Dev Only)", 4, {
			Label(scope, {
				Text = "Local preview only -- verifies AbilitySlot's state/cooldown/accent-color "
					.. "rendering ahead of ArtSystem. Not wired to real ability data or the live HUD.",
				Scale = "Detail",
				Color = Tokens.Color.TextSecondary,
				LayoutOrder = 2,
				TextWrapped = true,
			}),
			scope:New "Frame" {
				Name = "AbilityPreviewRow",
				AutomaticSize = Enum.AutomaticSize.XY,
				BackgroundTransparency = 1,
				LayoutOrder = 3,

				[Children] = {
					scope:New "UIListLayout" {
						FillDirection = Enum.FillDirection.Horizontal,
						VerticalAlignment = Enum.VerticalAlignment.Center,
						Padding = UDim.new(0, Tokens.Space.XS),
						SortOrder = Enum.SortOrder.LayoutOrder,
					},
					table.unpack(abilityPreviewSlots),
				},
			},
			scope:New "Frame" {
				Name = "AbilityPreviewStateRow",
				Size = UDim2.new(1, 0, 0, Tokens.Control.StepButtonSize),
				BackgroundTransparency = 1,
				LayoutOrder = 4,

				[Children] = {
					scope:New "UIListLayout" {
						FillDirection = Enum.FillDirection.Horizontal,
						Padding = UDim.new(0, Tokens.Space.XS),
						SortOrder = Enum.SortOrder.LayoutOrder,
					},
					abilityPreviewStateButton("Locked", "Locked", 1),
					abilityPreviewStateButton("Available", "Available", 2),
					abilityPreviewStateButton("Cooldown", "Cooldown", 3),
					abilityPreviewStateButton("Active", "Active", 4),
				},
			},
			Button(scope, {
				Text = "Run Cooldown Demo",
				Size = UDim2.new(1, 0, 0, Tokens.Control.RowHeight),
				LayoutOrder = 5,
				OnActivated = function()
					runAbilityPreviewCooldownDemo()
				end,
			}),
		}),
	})

	-- Dynamic list rendering: scope:ForPairs, same primitive CombatFeedback/init.lua's damage-number
	-- list already uses (see that file's own comment on ForPairs vs. ForValues) -- keyed by
	-- display.Id (not the source array's own index) so a status-change re-render reuses/updates the
	-- same row Instance instead of tearing down and rebuilding every row whenever any one of them
	-- changes. Given admin report volume is low and pages are capped
	-- (Constants.BugReport.ListPageSize), no virtualization is needed. LayoutOrder is offset past the
	-- section's own title (1) and toolbar (2) below so rows always sort after both.
	local reportRows = scope:ForPairs(reportsDisplay, function(_use, innerScope, index, display)
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

	local reportsTab = tabContent(scope, "Reports", selectedTab, scrollSize, {
		Section(scope, "Bug Reports", 1, {
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

	local tabStrip = scope:New "Frame" {
		Name = "TabStrip",
		Size = UDim2.new(1, 0, 0, TAB_STRIP_HEIGHT),
		BackgroundTransparency = 1,
		LayoutOrder = 1,

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
	} :: Frame

	local root = scope:New "Frame" {
		Name = "ContentArea",
		Size = UDim2.fromOffset(width, bodyHeight),
		BackgroundTransparency = 1,

		[Children] = {
			scope:New "UIListLayout" {
				FillDirection = Enum.FillDirection.Vertical,
				HorizontalAlignment = Enum.HorizontalAlignment.Left,
				Padding = UDim.new(0, Tokens.Space.M),
				SortOrder = Enum.SortOrder.LayoutOrder,
			},
			tabStrip,
			spawnTab,
			adminTab,
			tuningTab,
			reportsTab,
		},
	} :: Frame

	return {
		Root = root,
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
		FrozenActive = frozenActive,
		InvisibleActive = invisibleActive,
		SpeedMultiplierActive = speedMultiplierActive,
		SetFrozenRequested = setFrozenRequestedEvent.Event,
		SetInvisibleRequested = setInvisibleRequestedEvent.Event,
		SetSpeedMultiplierRequested = setSpeedMultiplierRequestedEvent.Event,
		TeleportToTargetRequested = teleportToTargetRequestedEvent.Event,
		BringTargetRequested = bringTargetRequestedEvent.Event,
		TeleportToCoordinatesRequested = teleportToCoordinatesRequestedEvent.Event,
		ForceRespawnTargetRequested = forceRespawnTargetRequestedEvent.Event,
		BroadcastAnnouncementRequested = broadcastAnnouncementRequestedEvent.Event,
		ShutdownServerRequested = shutdownServerRequestedEvent.Event,
		SpectatingActive = spectatingActive,
		SpectateLockedTargetRequested = spectateLockedTargetRequestedEvent.Event,
	}
end

return ContentArea
