--!strict
--[[
	StatsPanel.lua

	Owns: the Move Editor's Stats section content -- what a move actually does, in numbers and
	charts, so an author can stop working it out on paper.

	Two halves on one set of axes:

	  * PROJECTED, recomputed from the draft on every edit (Shared/MoveStats.Project). Damage per
	    hit, total across the target cap, burst and sustained DPS, reach, covered volume, the phase
	    split, when the first and last hit can land, and every damage event an object stun or
	    follow-up adds.
	  * OBSERVED, accumulated live while the admin test-fires the move (MoveStats.SummarizeSamples
	    over the real Combat_FeedbackEvent results MoveEditorClient records). Drawn as a second line
	    against the projection, on the same axes, so "did it do what I intended" is a look rather
	    than a calculation.

	The projected line is deliberately the MUTED one: when both are present, the measured result is
	the answer and the projection is the reference behind it.

	Does not own: any of the arithmetic (Shared/MoveStats.lua), the drawing
	(Components/Graph.lua), or recording the test results (Client/DevTools/MoveEditor/MoveEditorClient.lua
	fills the TestSamples value this reads).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local MoveStats = require(ReplicatedStorage.Shared.MoveStats)
local MoveTypes = require(ReplicatedStorage.Shared.MoveTypes)
local Tokens = require(script.Parent.Parent.Parent.Parent.Tokens)
local Label = require(script.Parent.Parent.Parent.Parent.Components.Label)
local Button = require(script.Parent.Parent.Parent.Parent.Components.Button)
local TrackedLabel = require(script.Parent.Parent.Parent.Parent.Components.TrackedLabel)
local Graph = require(script.Parent.Parent.Parent.Parent.Components.Graph)
local DraftBinding = require(script.Parent.DraftBinding)
local EditorTokens = require(script.Parent.EditorTokens)

local Children = Fusion.Children

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>
type MoveDefinition = MoveTypes.MoveDefinition
type DraftContext = DraftBinding.DraftContext

export type StatsPanelProps = {
	Context: DraftContext,
	-- Real results recorded from the last test fire, newest run only -- see this file's header.
	TestSamples: Fusion.Value<{ MoveStats.TestSample }>,
	-- Width available inside the section card, so the charts can be sized in real pixels (a chart
	-- needs a concrete plot rectangle to place points in -- see Components/Graph.lua).
	ContentWidth: number,
}

local TILE_HEIGHT = 46
local TILE_COLUMNS = 3
local GRAPH_HEIGHT = 150

-- Series identity comes from EditorTokens, not from literals here: Primary was byte-identical to
-- PROJECTED_COLOR one line above it and to AnimationTimelineEditor.lua's own first clip colour, in
-- three separate places, with nothing saying they were meant to be the same colour.
local PROJECTED_COLOR = EditorTokens.StatsSeries.Projected
local MEASURED_COLOR = EditorTokens.StatsSeries.Measured
local SOURCE_COLORS: { [string]: Color3 } = {
	Primary = EditorTokens.StatsSeries.Primary,
	ObjectStun = EditorTokens.StatsSeries.ObjectStun,
	FollowUp = EditorTokens.StatsSeries.FollowUp,
}

local StatsPanelModule = {}

-- One label-over-value readout. Enough of them that they're worth a helper: hand-writing the same
-- two-Label frame twelve times is exactly the duplication Tokens.lua's own header warns about.
local function statTile(scope: Scope, caption: string, value: UsedAs<string>, layoutOrder: number, width: number): Frame
	return scope:New "Frame" {
		Name = caption,
		Size = UDim2.fromOffset(width, TILE_HEIGHT),
		BackgroundColor3 = Tokens.Wash.Inset.Color,
		BackgroundTransparency = Tokens.Wash.Inset.Transparency,
		BorderSizePixel = 0,
		LayoutOrder = layoutOrder,

		[Children] = {
			scope:New "UIStroke" {
				Color = Tokens.Border.Standard.Color,
				Thickness = 1,
				Transparency = Tokens.Border.Standard.Transparency,
			},
			scope:New "UIPadding" {
				PaddingLeft = UDim.new(0, Tokens.Space.S),
				PaddingRight = UDim.new(0, Tokens.Space.XS),
				PaddingTop = UDim.new(0, Tokens.Space.XS),
			},
			Label(scope, {
				Text = caption,
				Scale = "Detail",
				Color = Tokens.Color.TextSecondary,
				Size = UDim2.new(1, 0, 0, 12),
			}),
			Label(scope, {
				Text = value,
				Scale = "Body",
				Color = Tokens.Color.AccentPrimaryBright,
				Position = UDim2.fromOffset(0, 14),
				Size = UDim2.new(1, 0, 0, 18),
			}),
		},
	} :: Frame
end

function StatsPanelModule.Build(scope: Scope, props: StatsPanelProps): { Instance }
	local context = props.Context

	-- The whole panel hangs off this one Computed: every tile and both charts read fields of it, so
	-- an edit anywhere in the move recomputes the projection exactly once per frame rather than once
	-- per readout.
	local report = scope:Computed(function(use)
		local draft = use(context.Draft)
		if not draft then
			return nil
		end
		return MoveStats.Project(draft)
	end)

	local measured = scope:Computed(function(use)
		local current = use(report)
		return MoveStats.SummarizeSamples(
			use(props.TestSamples) :: { MoveStats.TestSample },
			if current then current.TimelineSeconds else 1
		)
	end)

	local function readout(format: (MoveStats.MoveStatsReport) -> string): Fusion.Computed<string>
		return scope:Computed(function(use)
			local current = use(report)
			return if current then format(current) else "--"
		end)
	end

	local tileWidth = math.floor((props.ContentWidth - Tokens.Space.XS * (TILE_COLUMNS - 1)) / TILE_COLUMNS)

	local tiles: { Instance } = {
		scope:New "UIGridLayout" {
			CellSize = UDim2.fromOffset(tileWidth, TILE_HEIGHT),
			CellPadding = UDim2.fromOffset(Tokens.Space.XS, Tokens.Space.XS),
			SortOrder = Enum.SortOrder.LayoutOrder,
		},
		statTile(
			scope,
			"DAMAGE / HIT",
			readout(function(current)
				return string.format("%.0f", current.DamagePerHit)
			end),
			1,
			tileWidth
		),
		statTile(
			scope,
			"POSTURE / HIT",
			readout(function(current)
				return string.format("%.0f", current.PosturePerHit)
			end),
			2,
			tileWidth
		),
		statTile(
			scope,
			"MAX HITS",
			readout(function(current)
				return string.format("%d", current.MaxHits)
			end),
			3,
			tileWidth
		),
		statTile(
			scope,
			"ONE TARGET TOTAL",
			readout(function(current)
				return string.format("%.0f dmg", current.SingleTargetDamage)
			end),
			4,
			tileWidth
		),
		statTile(
			scope,
			"ALL TARGETS TOTAL",
			readout(function(current)
				return string.format("%.0f dmg", current.MaxTotalDamage)
			end),
			5,
			tileWidth
		),
		statTile(
			scope,
			"POSTURE TOTAL",
			readout(function(current)
				return string.format("%.0f", current.SingleTargetPosture)
			end),
			6,
			tileWidth
		),
		statTile(
			scope,
			"BURST DPS",
			readout(function(current)
				return string.format("%.1f", current.BurstDamagePerSecond)
			end),
			7,
			tileWidth
		),
		statTile(
			scope,
			"SUSTAINED DPS",
			readout(function(current)
				return string.format("%.1f", current.SustainedDamagePerSecond)
			end),
			8,
			tileWidth
		),
		statTile(
			scope,
			"POSTURE / SEC",
			readout(function(current)
				return string.format("%.1f", current.SustainedPosturePerSecond)
			end),
			9,
			tileWidth
		),
		statTile(
			scope,
			"HIT WINDOW",
			readout(function(current)
				return string.format("%.2f - %.2fs", current.FirstHitSeconds, current.LastHitSeconds)
			end),
			10,
			tileWidth
		),
		statTile(
			scope,
			"TOTAL / COOLDOWN",
			readout(function(current)
				return string.format("%.2f / %.2fs", current.TotalDurationSeconds, current.CooldownSeconds)
			end),
			11,
			tileWidth
		),
		statTile(
			scope,
			"REACH / VOLUME",
			readout(function(current)
				return string.format("%.1f / %.0f", current.ReachStuds, current.VolumeStuds3)
			end),
			12,
			tileWidth
		),
	}

	local damageOverTime = Graph.Line(scope, {
		Title = "DAMAGE OVER TIME (one target)",
		Width = props.ContentWidth,
		Height = GRAPH_HEIGHT,
		XSuffix = "s",
		YSuffix = " dmg",
		XMax = scope:Computed(function(use)
			local current = use(report)
			return if current then current.TimelineSeconds else 1
		end),
		YMax = scope:Computed(function(use)
			local current = use(report)
			local projectedTotal = if current then current.SingleTargetDamage else 0
			-- The axis has to fit BOTH lines, or a test that out-damaged the projection (multiple
			-- targets on one dummy, a follow-up that landed twice) would be silently clipped at the
			-- top of the plot rather than visibly exceeding it.
			return math.max(projectedTotal, (use(measured) :: MoveStats.TestSummary).TotalDamage, 1)
		end),
		Series = {
			{
				Name = "Projected",
				Color = PROJECTED_COLOR,
				Muted = true,
				Points = scope:Computed(function(use)
					local current = use(report)
					return if current then current.CumulativeSeries else {}
				end),
			},
			{
				Name = "Measured",
				Color = MEASURED_COLOR,
				Points = scope:Computed(function(use)
					return (use(measured) :: MoveStats.TestSummary).CumulativeSeries
				end),
			},
		},
		Markers = scope:Computed(function(use)
			local current = use(report)
			if not current then
				return {}
			end
			return {
				{ Time = current.FirstHitSeconds, Label = "first hit", Color = Tokens.Color.AccentPrimary },
				{ Time = current.ActiveWindowEnd, Label = "active ends", Color = Tokens.Color.AccentSecondary },
			}
		end),
		LayoutOrder = 20,
	})

	local damagePerEvent = Graph.Bars(scope, {
		Title = "DAMAGE PER HIT",
		Width = props.ContentWidth,
		Height = GRAPH_HEIGHT,
		Bars = scope:Computed(function(use)
			local current = use(report)
			if not current then
				return {}
			end
			local bars: { Graph.GraphBar } = {}
			for _, event in ipairs(current.Events) do
				table.insert(bars, {
					Label = event.Label,
					Value = event.Damage,
					Color = SOURCE_COLORS[event.Source] or PROJECTED_COLOR,
					ValueText = string.format("%.0f @ %.2fs", event.Damage, event.TimeSeconds),
				})
			end
			return bars
		end),
		LayoutOrder = 21,
	})

	local phaseSplit = Graph.Bars(scope, {
		Title = "PHASE SPLIT",
		Width = props.ContentWidth,
		Height = GRAPH_HEIGHT,
		Bars = scope:Computed(function(use)
			local current = use(report)
			if not current then
				return {}
			end
			-- EditorTokens.Phase, like every other surface in this editor that shows a phase. These
			-- three were still grey/violet/bronze -- the pre-reference palette AnimationTimelineEditor
			-- moved off when EditorTokens.Phase was introduced -- which left the same three phases
			-- reading as two different colour schemes depending on which panel you were looking at.
			local colors: { [string]: Color3 } = {
				Windup = EditorTokens.Phase.Windup,
				Active = EditorTokens.Phase.Active,
				Recovery = EditorTokens.Phase.Recovery,
			}
			local bars: { Graph.GraphBar } = {}
			for _, slice in ipairs(current.PhaseBreakdown) do
				table.insert(bars, {
					Label = slice.Phase,
					Value = slice.Seconds,
					Color = colors[slice.Phase] or PROJECTED_COLOR,
					ValueText = string.format("%.2fs (%.0f%%)", slice.Seconds, slice.Fraction * 100),
				})
			end
			return bars
		end),
		LayoutOrder = 22,
	})

	return {
		Label(scope, {
			Text = "Projected from the move's own numbers, updated as you edit. Test the move on a dummy and the "
				.. "measured line fills in against it.",
			Scale = "Detail",
			Color = Tokens.Color.TextSecondary,
			AutoHeight = true,
			LineHeight = Tokens.Leading.Prose,
			Size = UDim2.fromScale(1, 0),
			LayoutOrder = 2,
		}),

		scope:New "Frame" {
			Name = "Tiles",
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			LayoutOrder = 3,

			[Children] = tiles,
		},

		scope:New "Frame" {
			Name = "TestResultRow",
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
				TrackedLabel(scope, {
					Text = "MEASURED",
					Scale = "Action",
					Color = Tokens.Color.TextPrimary,
					LayoutOrder = 1,
				}),
				Label(scope, {
					Text = scope:Computed(function(use)
						local summary = use(measured) :: MoveStats.TestSummary
						if summary.HitCount == 0 then
							return "no test results yet"
						end
						return string.format(
							"%d hits, %.0f damage, %.0f posture, peak %.0f, %.2fs - %.2fs",
							summary.HitCount,
							summary.TotalDamage,
							summary.TotalPosture,
							summary.PeakDamage,
							summary.FirstHitSeconds,
							summary.LastHitSeconds
						)
					end),
					Scale = "Body",
					Color = Tokens.Color.TextSecondary,
					Size = UDim2.new(1, -220, 1, 0),
					LayoutOrder = 2,
				}),
				Button(scope, {
					Text = "Clear",
					Size = UDim2.fromOffset(70, Tokens.Control.RowHeight - 8),
					LayoutOrder = 3,
					OnActivated = function()
						props.TestSamples:set({})
					end,
				}),
			},
		},

		damageOverTime,
		damagePerEvent,
		phaseSplit,
	}
end

return StatsPanelModule
