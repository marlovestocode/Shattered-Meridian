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
local BloodlineConstants = require(ReplicatedStorage.Shared.Bloodline.BloodlineConstants)
local Tokens = require(script.Parent.Parent.Parent.Parent.Tokens)
local Panel = require(script.Parent.Parent.Parent.Parent.Components.Panel)
local Section = require(script.Parent.Parent.Parent.Parent.Components.Section)
local Label = require(script.Parent.Parent.Parent.Parent.Components.Label)
local Button = require(script.Parent.Parent.Parent.Parent.Components.Button)
local Tab = require(script.Parent.Parent.Parent.Parent.Components.Tab)
local TextField = require(script.Parent.Parent.Parent.Parent.Components.TextField)
local AbilitySlot = require(script.Parent.Parent.Parent.Parent.Components.AbilitySlot)
local ScrollArea = require(script.Parent.Parent.Parent.Parent.Components.ScrollArea)
local DevMenuTypes = require(script.Parent.Types)
local VehiclesTab = require(script.Parent.VehiclesTab)

local Children = Fusion.Children
local peek = Fusion.peek

type Scope = Fusion.Scope<typeof(Fusion)>
type DevMenuTabName = DevMenuTypes.DevMenuTabName
type FlightTuningDisplayProps = DevMenuTypes.FlightTuningDisplayProps
type BugReportRowDisplay = DevMenuTypes.BugReportRowDisplay
type ContentAreaHandle = DevMenuTypes.ContentAreaHandle
type AbilitySlotState = AbilitySlot.AbilitySlotState

local ContentArea = {}

-- One "0.080s [-0.1][-0.01][+0.01][+0.1]" row -- originally shared by the Hitbox Timing/Standalone
-- Attacks tuners' Windup/Active/Recovery fields too (both since moved out of DevMenu entirely, into
-- the Move Editor's "Default" moves section -- see Server/Combat/DefaultMoveRegistry.lua), now only
-- the Flight Tuning section below still uses this. `valueText` is UsedAs<string> (a Fusion Computed
-- bound to FlightTuningDisplay) so it re-renders whenever the selected field or its value changes;
-- `onAdjust(delta)` fires AdjustFlightTuningRequested for whichever field this row is for.
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

-- Longest a collapsed report's description preview renders before truncating with "..." -- Show
-- More/Show Less (below) reveals the rest. Purely a display cutoff, not a data limit: `display.
-- DescriptionText` itself is always the full filtered text DevMenuClient formatted it from.
local REPORT_DESCRIPTION_PREVIEW_LENGTH = 160

local REPORT_STATUS_OPTIONS = { "Open", "InProgress", "Resolved", "Dismissed" }
local REPORT_PRIORITY_OPTIONS = { "Low", "Normal", "High", "Urgent" }

-- Every callback a report row can fire, all keyed to this row's own display.Id by the caller (see
-- reportRows below) -- kept as one table instead of five positional closures now that the Reports
-- tab does more than the original single triage action.
export type ReportRowCallbacks = {
	OnSetStatus: (newStatus: string) -> (),
	OnSetPriority: (newPriority: string) -> (),
	OnAssign: (assign: boolean) -> (),
	OnJumpToReporter: () -> (),
	OnAddNote: (text: string) -> (),
}

-- Plain, hand-built TextLabel (not Components/Label.lua) specifically for report body text --
-- Label.lua's own header is explicit that it has "no fixed width, auto height mode" (Size given
-- means AutomaticSize.None entirely), which is exactly the combination free-form report
-- descriptions/notes need to both wrap within the row's width AND grow the row to fit however long
-- the admin's reply or a reporter's paragraph turns out to be. Native TextLabel supports fixed-width
-- + AutomaticSize.Y directly, so this stays a thin wrapper rather than a Label.lua change that would
-- ripple into every other caller's fixed-height assumption.
local function wrappedBodyText(
	scope: Scope,
	text: Fusion.UsedAs<string>,
	layoutOrder: number,
	color: Color3?
): TextLabel
	return scope:New "TextLabel" {
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		LayoutOrder = layoutOrder,
		FontFace = Tokens.Type.Body.Face,
		TextSize = Tokens.Type.Body.Size,
		TextColor3 = color or Tokens.Color.TextPrimary,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		TextWrapped = true,
		Text = text,
	} :: TextLabel
end

-- One bug report row (Reports tab) -- a Panel with header/badge/description text, an expand toggle
-- that reveals the full triage surface (status/priority/assign/jump-to-reporter/notes), same idiom
-- as hitboxTimingRow above (a small file-local builder, not a promoted Components/ primitive, since
-- it's specific to this screen's one call site).
--
-- `expanded`/`noteText` are created fresh each time this function runs, but the row Instance they're
-- bound into is only rebuilt when scope:ForPairs' own diff (see reportRows below) decides this row's
-- key actually needs rebuilding -- toggling Show More/Less or typing a note does NOT depend on
-- reportsDisplay changing, so these Fusion Values keep working as ordinary local UI state for as
-- long as the row Instance lives, the same way selectedTab/godmodeActive do at the Mount level.
local function reportRow(
	scope: Scope,
	display: BugReportRowDisplay,
	layoutOrder: number,
	callbacks: ReportRowCallbacks
): Frame
	local expanded = scope:Value(false)
	local noteText = scope:Value("")

	local expandButtonText = scope:Computed(function(use)
		return if use(expanded) then "Show Less" else "Show More"
	end)

	local previewText = scope:Computed(function(use)
		if use(expanded) or #display.DescriptionText <= REPORT_DESCRIPTION_PREVIEW_LENGTH then
			return display.DescriptionText
		end
		return string.sub(display.DescriptionText, 1, REPORT_DESCRIPTION_PREVIEW_LENGTH) .. "..."
	end)

	local badgeText = `{display.Status} | {display.PriorityText} | {display.AssignedText}`

	local function statusButton(status: string, order: number): TextButton
		return Tab(scope, {
			Text = status,
			Selected = display.Status == status,
			Size = UDim2.new(1 / #REPORT_STATUS_OPTIONS, -Tokens.Space.XS, 0, Tokens.Control.StepButtonSize),
			LayoutOrder = order,
			OnActivated = function()
				callbacks.OnSetStatus(status)
			end,
		})
	end

	local function priorityButton(priority: string, order: number): TextButton
		return Tab(scope, {
			Text = priority,
			Selected = display.Priority == priority,
			Size = UDim2.new(1 / #REPORT_PRIORITY_OPTIONS, -Tokens.Space.XS, 0, Tokens.Control.StepButtonSize),
			LayoutOrder = order,
			OnActivated = function()
				callbacks.OnSetPriority(priority)
			end,
		})
	end

	local statusButtons: { Instance } = {}
	for index, status in ipairs(REPORT_STATUS_OPTIONS) do
		statusButtons[index] = statusButton(status, index)
	end

	local priorityButtons: { Instance } = {}
	for index, priority in ipairs(REPORT_PRIORITY_OPTIONS) do
		priorityButtons[index] = priorityButton(priority, index)
	end

	local noteRows: { Instance } = {}
	if #display.Notes == 0 then
		noteRows[1] = Label(scope, {
			Text = "No notes yet.",
			Scale = "Detail",
			Color = Tokens.Color.TextSecondary,
			LayoutOrder = 1,
		})
	else
		for index, note in ipairs(display.Notes) do
			noteRows[index] = scope:New "Frame" {
				Name = "Note_" .. note.Id,
				Size = UDim2.fromScale(1, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				BackgroundTransparency = 1,
				LayoutOrder = index,

				[Children] = {
					scope:New "UIListLayout" {
						FillDirection = Enum.FillDirection.Vertical,
						Padding = UDim.new(0, 2),
						SortOrder = Enum.SortOrder.LayoutOrder,
					},
					Label(scope, {
						Text = `{note.AuthorName} -- {note.TimeText}`,
						Scale = "Detail",
						Color = Tokens.Color.TextSecondary,
						LayoutOrder = 1,
					}),
					wrappedBodyText(scope, note.Text, 2),
				},
			} :: Frame
		end
	end

	local assignButtonText = if display.IsAssignedToMe then "Release Claim" else "Claim Report"

	local detailFrame = scope:New "Frame" {
		Name = "Detail",
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		-- Non-visible children contribute no layout space to the parent UIListLayout (same trick
		-- tabContent's own Visible-only-selected-tab comment already documents), so collapsing a row
		-- costs nothing beyond flipping this one property.
		Visible = expanded,
		LayoutOrder = 5,

		[Children] = {
			scope:New "UIListLayout" {
				FillDirection = Enum.FillDirection.Vertical,
				HorizontalAlignment = Enum.HorizontalAlignment.Left,
				Padding = UDim.new(0, Tokens.Space.XS),
				SortOrder = Enum.SortOrder.LayoutOrder,
			},
			Label(scope, {
				Text = display.ContextText,
				Scale = "Detail",
				Color = Tokens.Color.TextSecondary,
				LayoutOrder = 1,
			}),
			Label(scope, { Text = "Status", Scale = "Detail", Color = Tokens.Color.TextSecondary, LayoutOrder = 2 }),
			scope:New "Frame" {
				Name = "StatusRow",
				Size = UDim2.new(1, 0, 0, Tokens.Control.StepButtonSize),
				BackgroundTransparency = 1,
				LayoutOrder = 3,
				[Children] = {
					scope:New "UIListLayout" {
						FillDirection = Enum.FillDirection.Horizontal,
						Padding = UDim.new(0, Tokens.Space.XS),
						SortOrder = Enum.SortOrder.LayoutOrder,
					},
					table.unpack(statusButtons),
				},
			},
			Label(scope, { Text = "Priority", Scale = "Detail", Color = Tokens.Color.TextSecondary, LayoutOrder = 4 }),
			scope:New "Frame" {
				Name = "PriorityRow",
				Size = UDim2.new(1, 0, 0, Tokens.Control.StepButtonSize),
				BackgroundTransparency = 1,
				LayoutOrder = 5,
				[Children] = {
					scope:New "UIListLayout" {
						FillDirection = Enum.FillDirection.Horizontal,
						Padding = UDim.new(0, Tokens.Space.XS),
						SortOrder = Enum.SortOrder.LayoutOrder,
					},
					table.unpack(priorityButtons),
				},
			},
			scope:New "Frame" {
				Name = "AssignRow",
				Size = UDim2.new(1, 0, 0, Tokens.Control.RowHeight),
				BackgroundTransparency = 1,
				LayoutOrder = 6,
				[Children] = {
					scope:New "UIListLayout" {
						FillDirection = Enum.FillDirection.Horizontal,
						Padding = UDim.new(0, Tokens.Space.S),
						SortOrder = Enum.SortOrder.LayoutOrder,
					},
					Button(scope, {
						Text = assignButtonText,
						Size = UDim2.new(0.5, -Tokens.Space.XS, 0, Tokens.Control.RowHeight),
						LayoutOrder = 1,
						OnActivated = function()
							callbacks.OnAssign(not display.IsAssignedToMe)
						end,
					}),
					Button(scope, {
						Text = "Jump to Reporter",
						Size = UDim2.new(0.5, -Tokens.Space.XS, 0, Tokens.Control.RowHeight),
						LayoutOrder = 2,
						OnActivated = function()
							callbacks.OnJumpToReporter()
						end,
					}),
				},
			},
			Label(scope, { Text = "Notes", Scale = "Detail", Color = Tokens.Color.TextSecondary, LayoutOrder = 7 }),
			scope:New "Frame" {
				Name = "NotesList",
				Size = UDim2.fromScale(1, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				BackgroundTransparency = 1,
				LayoutOrder = 8,
				[Children] = {
					scope:New "UIListLayout" {
						FillDirection = Enum.FillDirection.Vertical,
						Padding = UDim.new(0, Tokens.Space.XS),
						SortOrder = Enum.SortOrder.LayoutOrder,
					},
					table.unpack(noteRows),
				},
			},
			scope:New "Frame" {
				Name = "NoteInputRow",
				Size = UDim2.new(1, 0, 0, Tokens.Control.RowHeight),
				BackgroundTransparency = 1,
				LayoutOrder = 9,
				[Children] = {
					scope:New "UIListLayout" {
						FillDirection = Enum.FillDirection.Horizontal,
						Padding = UDim.new(0, Tokens.Space.XS),
						SortOrder = Enum.SortOrder.LayoutOrder,
					},
					TextField(scope, {
						Text = noteText,
						PlaceholderText = "Add an internal note...",
						MaxLength = Constants.BugReport.NoteMaxLength,
						Size = UDim2.new(0.75, -Tokens.Space.XS, 0, Tokens.Control.RowHeight),
						LayoutOrder = 1,
					}),
					Button(scope, {
						Text = "Add",
						Size = UDim2.new(0.25, -Tokens.Space.XS, 0, Tokens.Control.RowHeight),
						LayoutOrder = 2,
						OnActivated = function()
							local text = peek(noteText)
							if #text > 0 then
								callbacks.OnAddNote(text)
								noteText:set("")
							end
						end,
					}),
				},
			},
		},
	} :: Frame

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
			Label(scope, { Text = badgeText, Scale = "Detail", Color = Tokens.Color.TextSecondary, LayoutOrder = 2 }),
			wrappedBodyText(scope, previewText, 3),
			Button(scope, {
				Text = expandButtonText,
				Size = UDim2.fromOffset(120, Tokens.Control.StepButtonSize),
				LayoutOrder = 4,
				OnActivated = function()
					expanded:set(not peek(expanded))
				end,
			}),
			detailFrame,
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

	return ScrollArea(scope, {
		Name = tabName .. "Content",
		Size = scrollSize,
		-- All four tab contents share one LayoutOrder: they occupy the same slot below the tab strip
		-- (LayoutOrder 1) inside this module's own Root frame, and at most one is ever Visible at a
		-- time (UIListLayout skips non-Visible children entirely, so the other three contribute no
		-- layout space).
		LayoutOrder = 2,
		Visible = isVisible,

		Children = {
			-- Right padding keeps section panels clear of the scrollbar (ScrollArea's own
			-- ScrollBarThickness) instead of its right edge overlapping panel borders.
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
	})
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
	-- Swing-volume visualiser -- SERVER-WIDE (a real replicated Part, not a personal overlay), so
	-- this is seeded from DevMenu_GetHitboxDebug on open and refreshed from whatever
	-- DevMenu_SetHitboxDebug reports actually took effect, the same "never optimistic" shape every
	-- other server-authoritative toggle on this screen already follows.
	local hitboxDebugActive = scope:Value(false)
	local selectedTab: Fusion.Value<DevMenuTabName> = scope:Value("Spawn" :: DevMenuTabName)
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

	-- Filter/search state for the Reports tab -- all four are pure client-local view state, never
	-- sent to the server: they filter the already-fetched reportsDisplay cache in place (see
	-- filteredReportsDisplay below), the same "narrow what's already loaded" trade-off the DataStore
	-- pagination itself forces (ListReports pages chronologically, not by any of these fields, so a
	-- filter/search that wanted to reach UN-loaded reports would need server-side query support this
	-- module doesn't have). "All" is the not-filtering sentinel for both Status and Category.
	local reportsStatusFilter = scope:Value("All")
	local reportsCategoryFilter = scope:Value("All")
	local reportsMineOnly = scope:Value(false)
	local reportsSearchText = scope:Value("")

	local frozenActive = scope:Value(false)
	local invisibleActive = scope:Value(false)
	local speedMultiplierActive = scope:Value(1)
	local spectatingActive = scope:Value(false)
	-- Passive "a newer version has been published" banner -- see Types.lua's own VersionBannerText
	-- header. nil (nothing shown) until DevMenuClient's fetch resolves AND finds a newer version.
	local versionBannerText: Fusion.Value<string?> = scope:Value(nil :: string?)

	-- Debug dummy (Spawn tab) -- SERVER-WIDE guard toggle and an advisory active-count readout, same
	-- "seeded on open, refreshed from what the server reports actually took effect" contract as
	-- hitboxDebugActive above.
	local dummyGuardActive = scope:Value(false)
	local activeDummyCountDisplay = scope:Value(0)

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
	local rollRareEmoteRequestedEvent = Instance.new("BindableEvent")
	local grantBloodlineRerollsRequestedEvent = Instance.new("BindableEvent")
	local setGodmodeRequestedEvent = Instance.new("BindableEvent")
	local setFlightRequestedEvent = Instance.new("BindableEvent")
	local setFlightCollideRequestedEvent = Instance.new("BindableEvent")
	local setHitboxDebugRequestedEvent = Instance.new("BindableEvent")
	local cycleFlightTuningPrevRequestedEvent = Instance.new("BindableEvent")
	local cycleFlightTuningNextRequestedEvent = Instance.new("BindableEvent")
	local adjustFlightTuningRequestedEvent = Instance.new("BindableEvent")
	local resetFlightTuningRequestedEvent = Instance.new("BindableEvent")
	local loadFirstReportsRequestedEvent = Instance.new("BindableEvent")
	local loadMoreReportsRequestedEvent = Instance.new("BindableEvent")
	local updateReportStatusRequestedEvent = Instance.new("BindableEvent")
	local addReportNoteRequestedEvent = Instance.new("BindableEvent")
	local setReportPriorityRequestedEvent = Instance.new("BindableEvent")
	local assignReportRequestedEvent = Instance.new("BindableEvent")
	local jumpToReporterRequestedEvent = Instance.new("BindableEvent")
	local setFrozenRequestedEvent = Instance.new("BindableEvent")
	local setInvisibleRequestedEvent = Instance.new("BindableEvent")
	local setSpeedMultiplierRequestedEvent = Instance.new("BindableEvent")
	local teleportToTargetRequestedEvent = Instance.new("BindableEvent")
	local bringTargetRequestedEvent = Instance.new("BindableEvent")
	local teleportToCoordinatesRequestedEvent = Instance.new("BindableEvent")
	local forceRespawnTargetRequestedEvent = Instance.new("BindableEvent")
	local broadcastAnnouncementRequestedEvent = Instance.new("BindableEvent")
	local shutdownServerRequestedEvent = Instance.new("BindableEvent")
	local instantRestartServerRequestedEvent = Instance.new("BindableEvent")
	local spectateLockedTargetRequestedEvent = Instance.new("BindableEvent")
	local spawnDebugDummyRequestedEvent = Instance.new("BindableEvent")
	local despawnAllDebugDummiesRequestedEvent = Instance.new("BindableEvent")
	local setDummyGuardRequestedEvent = Instance.new("BindableEvent")
	local spawnCoalDepositRequestedEvent = Instance.new("BindableEvent")
	local spawnWaterSourceRequestedEvent = Instance.new("BindableEvent")
	local fillCarriedFuelRequestedEvent = Instance.new("BindableEvent")

	local godmodeButtonText = scope:Computed(function(use)
		return if use(godmodeActive) then "Godmode: On" else "Godmode: Off"
	end)
	local flightButtonText = scope:Computed(function(use)
		return if use(flightActive) then "Flight: On" else "Flight: Off"
	end)
	local collideButtonText = scope:Computed(function(use)
		return if use(collideActive) then "Collide: On" else "Collide: Off"
	end)
	local hitboxDebugButtonText = scope:Computed(function(use)
		return if use(hitboxDebugActive) then "Show Hitboxes: On" else "Show Hitboxes: Off"
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
	local dummyGuardButtonText = scope:Computed(function(use)
		return if use(dummyGuardActive) then "Guard: On" else "Guard: Off"
	end)
	local activeDummyCountText = scope:Computed(function(use)
		return `Active: {use(activeDummyCountDisplay)}`
	end)
	-- Empty string (renders nothing) rather than "Loading..." while versionBannerText is nil -- this
	-- banner is advisory chrome, not a value the admin is waiting on the way the flight tuner's
	-- fields below are, so silence is the right default for "not loaded yet" AND "no newer version."
	local versionBannerDisplayText = scope:Computed(function(use)
		return use(versionBannerText) or ""
	end)

	-- Same placeholder-until-loaded shape used by every DevMenuClient-fed section -- for the
	-- flight-feel tuner (the last of these tuning tools left in DevMenu; Hitbox Timing/Standalone
	-- Attacks moved to the Move Editor's "Default" moves section, see this module's own header).
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
	-- Every tab in the strip takes an equal share of its width, so this has to be kept in step with
	-- the tabButton calls below -- a strip built for four with five buttons in it silently overflows
	-- the content column rather than erroring.
	local TAB_COUNT = 5
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

	-- "Training Bot Presets" (the six bot-preset buttons) stays removed alongside the rest of the
	-- deleted combat system -- CombatSystem.SpawnTrainingBot no longer exists server-side, and nothing
	-- has rebuilt an AI-controlled sparring partner yet. "Training Dummy" is BACK, rebuilt from
	-- scratch against the current combat stack -- see Server/Systems/DebugDummySystem.lua's own
	-- header. Emotes is no longer this tab's only section.
	local spawnTab = tabContent(scope, "Spawn", selectedTab, scrollSize, {
		-- Emote System roll-path test trigger (Phase 2, radial emote wheel) -- exercises
		-- EmoteUnlockService.GrantEmote/RollEmote end to end from a human tester's own button press,
		-- since there is still no AchievementSystem/quest/live-ops caller to trigger it for real. See
		-- DevMenuSystem.handleRollEmote's own header for why this always rolls the "RareEmotes" pool
		-- specifically, for the calling admin themselves.
		Section(scope, "Emotes", 1, {
			Button(scope, {
				Text = "Roll Rare Emote",
				Size = UDim2.new(1, 0, 0, Tokens.Control.RowHeight),
				LayoutOrder = 1,
				OnActivated = function()
					rollRareEmoteRequestedEvent:Fire()
				end,
			}),
		}),
		-- THE ONLY WAY TO GET A BLOODLINE REROLL. A fresh profile gets
		-- BloodlineConstants.StartingRerolls and nothing in the game has ever granted one since, so
		-- the character menu's own reroll control went permanently dead the moment a player spent
		-- theirs -- including for whoever is trying to test the bloodline system. Sits beside Roll
		-- Rare Emote because it is the same kind of thing: a grant that exists only because the live
		-- path that would eventually do it for real (a shop, a quest, a tier-up) has not been
		-- designed yet.
		Section(scope, "Bloodline", 2, {
			Button(scope, {
				Text = `Grant {BloodlineConstants.DevGrantRerollAmount} Rerolls`,
				Size = UDim2.new(1, 0, 0, Tokens.Control.RowHeight),
				LayoutOrder = 1,
				OnActivated = function()
					grantBloodlineRerollsRequestedEvent:Fire()
				end,
			}),
		}),
		-- Debug Dummy -- a real, fully-registered combatant against the rebuilt HitboxEngine/
		-- DefenseSystem stack (see DebugDummySystem.lua's own header), spawned SpawnDistance studs in
		-- front of the requesting admin. Guard is a SERVER-WIDE toggle covering every currently-active
		-- (and every future) dummy at once -- there is no per-dummy target picker, the same "no
		-- player-select UI" posture every other action on this screen already takes.
		Section(scope, "Debug Dummy", 3, {
			scope:New "Frame" {
				Name = "SpawnRow",
				Size = UDim2.new(1, 0, 0, Tokens.Control.RowHeight),
				BackgroundTransparency = 1,
				LayoutOrder = 1,

				[Children] = {
					scope:New "UIListLayout" {
						FillDirection = Enum.FillDirection.Horizontal,
						Padding = UDim.new(0, Tokens.Space.S),
						SortOrder = Enum.SortOrder.LayoutOrder,
					},
					Button(scope, {
						Text = "Spawn Debug Dummy",
						Size = UDim2.new(0.5, -Tokens.Space.XS, 0, Tokens.Control.RowHeight),
						LayoutOrder = 1,
						OnActivated = function()
							spawnDebugDummyRequestedEvent:Fire()
						end,
					}),
					Button(scope, {
						Text = "Despawn All",
						Size = UDim2.new(0.5, -Tokens.Space.XS, 0, Tokens.Control.RowHeight),
						LayoutOrder = 2,
						OnActivated = function()
							despawnAllDebugDummiesRequestedEvent:Fire()
						end,
					}),
				},
			},
			scope:New "Frame" {
				Name = "GuardRow",
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
						Text = dummyGuardButtonText,
						Selected = dummyGuardActive,
						Size = UDim2.new(0.5, -Tokens.Space.XS, 0, Tokens.Control.RowHeight),
						LayoutOrder = 1,
						OnActivated = function()
							setDummyGuardRequestedEvent:Fire(not peek(dummyGuardActive))
						end,
					}),
					Label(scope, {
						Text = activeDummyCountText,
						Scale = "Body",
						Color = Tokens.Color.TextSecondary,
						Size = UDim2.new(0.5, -Tokens.Space.XS, 0, Tokens.Control.RowHeight),
						LayoutOrder = 2,
					}),
				},
			},
		}),
		-- Blimp Fuel System test nodes -- one tagged CoalDeposit/WaterSource Part spawned
		-- RESOURCE_NODE_SPAWN_DISTANCE studs in front of the requesting admin (Server/Systems/
		-- DevMenuSystem.handleSpawnCoalDeposit/handleSpawnWaterSource), so a tester can gather before a
		-- builder has placed any real world nodes. See Server/Systems/ResourceGatheringSystem.
		-- SpawnDebugNode's own header.
		Section(scope, "Blimp Fuel Nodes", 4, {
			scope:New "Frame" {
				Name = "SpawnResourceNodeRow",
				Size = UDim2.new(1, 0, 0, Tokens.Control.RowHeight),
				BackgroundTransparency = 1,
				LayoutOrder = 1,

				[Children] = {
					scope:New "UIListLayout" {
						FillDirection = Enum.FillDirection.Horizontal,
						Padding = UDim.new(0, Tokens.Space.S),
						SortOrder = Enum.SortOrder.LayoutOrder,
					},
					Button(scope, {
						Text = "Spawn Coal Deposit",
						Size = UDim2.new(0.5, -Tokens.Space.XS, 0, Tokens.Control.RowHeight),
						LayoutOrder = 1,
						OnActivated = function()
							spawnCoalDepositRequestedEvent:Fire()
						end,
					}),
					Button(scope, {
						Text = "Spawn Water Source",
						Size = UDim2.new(0.5, -Tokens.Space.XS, 0, Tokens.Control.RowHeight),
						LayoutOrder = 2,
						OnActivated = function()
							spawnWaterSourceRequestedEvent:Fire()
						end,
					}),
				},
			},
			-- Its own full-width row under the two node spawns, not a third button squeezed beside
			-- them: this is the shortcut PAST the pair above (fill the pockets instead of placing
			-- something to mine), so it reads better as the next step down than as a third of three.
			scope:New "Frame" {
				Name = "FillCarriedFuelRow",
				Size = UDim2.new(1, 0, 0, Tokens.Control.RowHeight),
				BackgroundTransparency = 1,
				LayoutOrder = 2,

				[Children] = {
					Button(scope, {
						Text = "Fill Carried Fuel",
						Size = UDim2.new(1, 0, 0, Tokens.Control.RowHeight),
						OnActivated = function()
							fillCarriedFuelRequestedEvent:Fire()
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

	-- "Health" section (Heal Full/Set HP to 1) was removed alongside the rest of the combat system --
	-- CombatSystem.SetPlayerHealth no longer exists server-side.
	local adminTab = tabContent(scope, "Admin", selectedTab, scrollSize, {
		Section(scope, "Godmode / Flight / Collide", 1, {
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
		Section(scope, "Frozen / Invisible / Speed", 2, {
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
		Section(scope, "Teleport", 3, {
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
		Section(scope, "Server Tools", 4, {
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
			-- Faster sibling to Shutdown Server above -- same two-press confirm, no countdown wait
			-- once confirmed. See Types.lua's InstantRestartServerRequested header.
			Button(scope, {
				Text = "Instant Restart Server",
				Size = UDim2.new(1, 0, 0, Tokens.Control.RowHeight),
				LayoutOrder = 6,
				OnActivated = function()
					instantRestartServerRequestedEvent:Fire()
				end,
			}),
			Label(scope, {
				Text = versionBannerDisplayText,
				Scale = "Detail",
				Color = Tokens.Color.Warning,
				LayoutOrder = 7,
			}),
		}),
		-- "Debug Visualization" (Show Hitboxes) is BACK, pointed at the rebuilt engine
		-- (HitboxEngine.SetDebugVolumesEnabled via DevMenu_GetHitboxDebug/SetHitboxDebug) -- see
		-- DevMenuSystem.lua's own header for why this is server-wide rather than a personal overlay.
		Section(scope, "Debug Visualization", 5, {
			Tab(scope, {
				Text = hitboxDebugButtonText,
				Selected = hitboxDebugActive,
				Size = UDim2.new(1, 0, 0, Tokens.Control.RowHeight),
				LayoutOrder = 1,
				OnActivated = function()
					setHitboxDebugRequestedEvent:Fire(not peek(hitboxDebugActive))
				end,
			}),
		}),
	})

	local tuningTab = tabContent(scope, "Tuning", selectedTab, scrollSize, {
		Section(scope, "Flight Tuning (Live Tune)", 1, {
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
			-- deviation from that row helper's original absolute-seconds shape.
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
		Section(scope, "Ability Slot Preview (Dev Only)", 2, {
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

	-- Status/Category filter tab rows, and the "Mine Only" toggle -- "All" always leads each option
	-- list as the not-filtering sentinel. Built as Tab strips (not Components/Toggle.lua) for the
	-- same reason the Ability Preview state buttons above are Tabs: a row of mutually-exclusive
	-- Selected chips reads consistently with every other selector already in this file, and
	-- Toggle.lua's own Label prop claims the full row width (built for a single standalone switch),
	-- which doesn't fit a strip of several options side by side.
	local REPORT_STATUS_FILTER_OPTIONS = { "All", "Open", "InProgress", "Resolved", "Dismissed" }
	local REPORT_CATEGORY_FILTER_OPTIONS = { "All", "Bug", "Exploit", "Suggestion", "Other" }

	local statusFilterButtons: { Instance } = {}
	for index, status in ipairs(REPORT_STATUS_FILTER_OPTIONS) do
		statusFilterButtons[index] = Tab(scope, {
			Text = status,
			Selected = scope:Computed(function(use)
				return use(reportsStatusFilter) == status
			end),
			Size = UDim2.new(1 / #REPORT_STATUS_FILTER_OPTIONS, -Tokens.Space.XS, 0, Tokens.Control.StepButtonSize),
			LayoutOrder = index,
			OnActivated = function()
				reportsStatusFilter:set(status)
			end,
		})
	end

	local categoryFilterButtons: { Instance } = {}
	for index, category in ipairs(REPORT_CATEGORY_FILTER_OPTIONS) do
		categoryFilterButtons[index] = Tab(scope, {
			Text = category,
			Selected = scope:Computed(function(use)
				return use(reportsCategoryFilter) == category
			end),
			Size = UDim2.new(1 / #REPORT_CATEGORY_FILTER_OPTIONS, -Tokens.Space.XS, 0, Tokens.Control.StepButtonSize),
			LayoutOrder = index,
			OnActivated = function()
				reportsCategoryFilter:set(category)
			end,
		})
	end

	-- Narrows the already-fetched reportsDisplay cache -- see reportsStatusFilter's own declaration
	-- above for why this is client-local narrowing rather than a server-side query. Recomputes
	-- whenever any filter input OR the underlying fetched list changes (every `use()` call below is
	-- a real dependency), so a fresh fetch or a status/priority patch from DevMenuClient
	-- automatically re-filters without this module having to know that happened.
	local filteredReportsDisplay = scope:Computed(function(use)
		local statusFilter = use(reportsStatusFilter)
		local categoryFilter = use(reportsCategoryFilter)
		local mineOnly = use(reportsMineOnly)
		local searchLower = string.lower(use(reportsSearchText))
		local all = use(reportsDisplay)

		local filtered: { BugReportRowDisplay } = {}
		for _, display in ipairs(all) do
			if statusFilter ~= "All" and display.Status ~= statusFilter then
				continue
			end
			if categoryFilter ~= "All" and display.Category ~= categoryFilter then
				continue
			end
			if mineOnly and not display.IsAssignedToMe then
				continue
			end
			if #searchLower > 0 then
				local haystack = string.lower(display.ReporterName .. " " .. display.DescriptionText)
				if not string.find(haystack, searchLower, 1, true) then
					continue
				end
			end
			table.insert(filtered, display)
		end
		return filtered
	end)

	-- Dynamic list rendering: scope:ForPairs, same primitive CombatFeedback/init.lua's damage-number
	-- list already uses (see that file's own comment on ForPairs vs. ForValues) -- keyed by
	-- display.Id (not the source array's own index) so a status-change re-render reuses/updates the
	-- same row Instance instead of tearing down and rebuilding every row whenever any one of them
	-- changes. Fed filteredReportsDisplay rather than the raw reportsDisplay cache -- rows for
	-- reports the current filter/search hides simply aren't built at all. Given admin report volume
	-- is low and pages are capped (Constants.BugReport.ListPageSize), no virtualization is needed.
	-- LayoutOrder is offset past the section's own title/toolbar rows below so rows always sort
	-- after them.
	local reportRows = scope:ForPairs(filteredReportsDisplay, function(_use, innerScope, index, display)
		return display.Id,
			reportRow(innerScope, display, 20 + index, {
				OnSetStatus = function(newStatus: string)
					updateReportStatusRequestedEvent:Fire(display.Id, newStatus)
				end,
				OnSetPriority = function(newPriority: string)
					setReportPriorityRequestedEvent:Fire(display.Id, newPriority)
				end,
				OnAssign = function(assign: boolean)
					assignReportRequestedEvent:Fire(display.Id, assign)
				end,
				OnJumpToReporter = function()
					jumpToReporterRequestedEvent:Fire(display.Id)
				end,
				OnAddNote = function(text: string)
					addReportNoteRequestedEvent:Fire(display.Id, text)
				end,
			})
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
				Name = "StatusFilterRow",
				Size = UDim2.new(1, 0, 0, Tokens.Control.StepButtonSize),
				BackgroundTransparency = 1,
				LayoutOrder = 2,
				[Children] = {
					scope:New "UIListLayout" {
						FillDirection = Enum.FillDirection.Horizontal,
						Padding = UDim.new(0, Tokens.Space.XS),
						SortOrder = Enum.SortOrder.LayoutOrder,
					},
					table.unpack(statusFilterButtons),
				},
			},
			scope:New "Frame" {
				Name = "CategoryFilterRow",
				Size = UDim2.new(1, 0, 0, Tokens.Control.StepButtonSize),
				BackgroundTransparency = 1,
				LayoutOrder = 3,
				[Children] = {
					scope:New "UIListLayout" {
						FillDirection = Enum.FillDirection.Horizontal,
						Padding = UDim.new(0, Tokens.Space.XS),
						SortOrder = Enum.SortOrder.LayoutOrder,
					},
					table.unpack(categoryFilterButtons),
				},
			},
			scope:New "Frame" {
				Name = "SearchAndMineRow",
				Size = UDim2.new(1, 0, 0, Tokens.Control.RowHeight),
				BackgroundTransparency = 1,
				LayoutOrder = 4,
				[Children] = {
					scope:New "UIListLayout" {
						FillDirection = Enum.FillDirection.Horizontal,
						VerticalAlignment = Enum.VerticalAlignment.Center,
						Padding = UDim.new(0, Tokens.Space.S),
						SortOrder = Enum.SortOrder.LayoutOrder,
					},
					TextField(scope, {
						Text = reportsSearchText,
						PlaceholderText = "Search reporter or description...",
						Size = UDim2.new(0.7, -Tokens.Space.XS, 0, Tokens.Control.RowHeight),
						LayoutOrder = 1,
					}),
					Tab(scope, {
						Text = "Mine Only",
						Selected = reportsMineOnly,
						Size = UDim2.new(0.3, -Tokens.Space.XS, 0, Tokens.Control.RowHeight),
						LayoutOrder = 2,
						OnActivated = function()
							reportsMineOnly:set(not peek(reportsMineOnly))
						end,
					}),
				},
			},
			scope:New "Frame" {
				Name = "ReportsToolbar",
				Size = UDim2.new(1, 0, 0, Tokens.Control.RowHeight),
				BackgroundTransparency = 1,
				LayoutOrder = 5,

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

	-- Built as its own module, unlike the four tabs above -- see VehiclesTab.lua's own header. It
	-- hands back the section Instances only; the ScrollingFrame, the visibility Computed and the tab
	-- strip entry below all stay this module's, exactly as they are for every other tab.
	local vehicles = VehiclesTab.Build(scope)
	local vehiclesTab = tabContent(scope, "Vehicles", selectedTab, scrollSize, vehicles.Children)

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
			tabButton("Vehicles", "Vehicles", 5),
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
			vehiclesTab,
		},
	} :: Frame

	return {
		Root = root,
		Vehicles = vehicles,
		TargetNameDisplay = targetNameDisplay,
		GodmodeActive = godmodeActive,
		FlightActive = flightActive,
		CollideActive = collideActive,
		RollRareEmoteRequested = rollRareEmoteRequestedEvent.Event,
		GrantBloodlineRerollsRequested = grantBloodlineRerollsRequestedEvent.Event,
		SetGodmodeRequested = setGodmodeRequestedEvent.Event,
		SetFlightRequested = setFlightRequestedEvent.Event,
		SetFlightCollideRequested = setFlightCollideRequestedEvent.Event,
		HitboxDebugActive = hitboxDebugActive,
		SetHitboxDebugRequested = setHitboxDebugRequestedEvent.Event,
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
		AddReportNoteRequested = addReportNoteRequestedEvent.Event,
		SetReportPriorityRequested = setReportPriorityRequestedEvent.Event,
		AssignReportRequested = assignReportRequestedEvent.Event,
		JumpToReporterRequested = jumpToReporterRequestedEvent.Event,
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
		InstantRestartServerRequested = instantRestartServerRequestedEvent.Event,
		VersionBannerText = versionBannerText,
		SpectatingActive = spectatingActive,
		SpectateLockedTargetRequested = spectateLockedTargetRequestedEvent.Event,
		DummyGuardActive = dummyGuardActive,
		ActiveDummyCountDisplay = activeDummyCountDisplay,
		SpawnDebugDummyRequested = spawnDebugDummyRequestedEvent.Event,
		DespawnAllDebugDummiesRequested = despawnAllDebugDummiesRequestedEvent.Event,
		SetDummyGuardRequested = setDummyGuardRequestedEvent.Event,
		SpawnCoalDepositRequested = spawnCoalDepositRequestedEvent.Event,
		SpawnWaterSourceRequested = spawnWaterSourceRequestedEvent.Event,
		FillCarriedFuelRequested = fillCarriedFuelRequestedEvent.Event,
	}
end

return ContentArea
