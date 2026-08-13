--!strict
--[[
	Graph.lua

	Owns: the two chart shapes this UI needs -- a time-series LINE plot (Graph.Line) and a labelled
	BAR chart (Graph.Bars) -- built the same asset-free, procedural way every other graphic in
	Components/ is (ActionIcon.lua, VitalIcon.lua, SectionIcon.lua, Bar.lua): plain Frames, tokens
	from Tokens.lua, no image uploads and nothing to re-export when a colour changes.

	Written for the Move Editor's statistics panel, which needs to answer "what does this move
	actually do" visually -- damage accumulating over the move's timeline, damage split per hit,
	where in the timeline hits can land -- and to keep answering it live while an admin test-fires
	the move. That "live" requirement is why both charts take REACTIVE data (UsedAs<{...}>) and
	fixed pixel dimensions: the number of Frames is allocated once at mount from a fixed ceiling and
	only their Size/Position/Visible change afterwards, so a chart that updates every time a test
	result lands never re-mounts a single instance.

	A line is drawn as a chain of rotated 1px-tall Frames, one per segment. That is genuinely how
	you draw a line in Roblox UI without an image: there is no polyline primitive, and the
	alternatives (a canvas image, a mesh) both mean an asset. MAX_SEGMENTS caps the allocation --
	series longer than that are decimated rather than truncated, so a long curve loses resolution
	instead of its tail.

	Does not own: what the numbers mean or where they come from (Shared/MoveStats.lua computes every
	series this renders), nor any layout beyond its own fixed Width/Height box -- the caller places
	it.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Tokens = require(script.Parent.Parent.Tokens)
local Label = require(script.Parent.Label)

local Children = Fusion.Children

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>

export type GraphPoint = {
	Time: number,
	Value: number,
}

export type GraphSeries = {
	Name: string,
	Color: Color3,
	Points: UsedAs<{ GraphPoint }>,
	-- Renders at reduced opacity -- for a reference/projected curve sitting behind a measured one,
	-- where both need to be readable but only one is the real answer.
	Muted: boolean?,
}

-- A labelled vertical rule at a point in time -- "the earliest a hit can land", "the follow-up".
export type GraphMarker = {
	Time: number,
	Label: string,
	Color: Color3,
}

export type LineGraphProps = {
	Title: string,
	Width: number,
	Height: number,
	-- Axis maxima. Reactive because both change as the author edits the move (a longer recovery
	-- stretches the x-axis; more damage raises the y-axis).
	XMax: UsedAs<number>,
	YMax: UsedAs<number>,
	XSuffix: string?,
	YSuffix: string?,
	Series: { GraphSeries },
	Markers: UsedAs<{ GraphMarker }>?,
	LayoutOrder: UsedAs<number>?,
	Visible: UsedAs<boolean>?,
}

export type GraphBar = {
	Label: string,
	Value: number,
	Color: Color3,
	-- Shown on the bar itself instead of the raw number -- for a value whose useful reading isn't
	-- its magnitude ("12 dmg" rather than "12").
	ValueText: string?,
}

export type BarGraphProps = {
	Title: string,
	Width: number,
	Height: number,
	Bars: UsedAs<{ GraphBar }>,
	LayoutOrder: UsedAs<number>?,
	Visible: UsedAs<boolean>?,
}

-- Segment/bar ceilings. Allocated up front and Visible-toggled rather than grown on demand, so a
-- chart bound to live test results never creates or destroys an instance while it updates.
-- 64 covers MoveStats' own 48-sample series with headroom; 12 covers every bar chart the stats
-- panel draws (its widest is one bar per damage event, of which a move can author three).
local MAX_SEGMENTS = 64
local MAX_BARS = 12
local MAX_MARKERS = 6
local LINE_THICKNESS = 2
local GRID_LINES = 4
local AXIS_LABEL_HEIGHT = 14
local TITLE_HEIGHT = 18
local LEGEND_HEIGHT = 14
local MUTED_TRANSPARENCY = 0.55

local Graph = {}

local function formatAxis(value: number, suffix: string): string
	if value >= 100 then
		return string.format("%d%s", math.floor(value + 0.5), suffix)
	end
	if value >= 10 then
		return string.format("%.1f%s", value, suffix)
	end
	return string.format("%.2f%s", value, suffix)
end

-- Reduces an arbitrarily long series to at most `limit` points by even stride, always keeping the
-- first and last. Decimation rather than truncation on purpose: the tail of a cumulative-damage
-- curve is its most important part (it's the total), so dropping it to fit would be worse than
-- losing resolution in the middle.
local function decimate(points: { GraphPoint }, limit: number): { GraphPoint }
	if #points <= limit then
		return points
	end
	local reduced: { GraphPoint } = {}
	local stride = (#points - 1) / (limit - 1)
	for index = 0, limit - 1 do
		table.insert(reduced, points[math.min(#points, math.floor(index * stride + 0.5) + 1)])
	end
	return reduced
end

-- A time-series plot. See this file's header for why a line is a chain of rotated Frames.
function Graph.Line(scope: Scope, props: LineGraphProps): Frame
	local plotHeight = props.Height - TITLE_HEIGHT - AXIS_LABEL_HEIGHT - LEGEND_HEIGHT - Tokens.Space.S * 2
	local plotWidth = props.Width

	local plotChildren: { Instance } = {
		scope:New "UIStroke" {
			Color = Tokens.Border.Standard.Color,
			Thickness = 1,
			Transparency = Tokens.Border.Standard.Transparency,
		},
	}

	-- Horizontal gridlines at even fractions of YMax. Fixed count, so they need no reactivity of
	-- their own -- only the axis LABELS change when YMax does.
	for index = 1, GRID_LINES do
		table.insert(
			plotChildren,
			scope:New "Frame" {
				Name = "Grid" .. index,
				Size = UDim2.new(1, 0, 0, 1),
				Position = UDim2.fromScale(0, index / (GRID_LINES + 1)),
				BackgroundColor3 = Tokens.Border.Hairline.Color,
				BackgroundTransparency = Tokens.Border.Hairline.Transparency,
				BorderSizePixel = 0,
			}
		)
	end

	-- Markers, allocated to a fixed ceiling and driven entirely by the reactive Markers list.
	local markers = props.Markers
	if markers then
		for index = 1, MAX_MARKERS do
			local marker = scope:Computed(function(use)
				return (use(markers) :: { GraphMarker })[index]
			end)
			local markerVisible = scope:Computed(function(use)
				return use(marker) ~= nil
			end)
			table.insert(
				plotChildren,
				scope:New "Frame" {
					Name = "Marker" .. index,
					Size = UDim2.new(0, 1, 1, 0),
					Position = scope:Computed(function(use)
						local entry = use(marker)
						if not entry then
							return UDim2.fromScale(0, 0)
						end
						return UDim2.fromScale(math.clamp(entry.Time / math.max(use(props.XMax), 1e-6), 0, 1), 0)
					end),
					BackgroundColor3 = scope:Computed(function(use)
						local entry = use(marker)
						return if entry then entry.Color else Tokens.Color.TextDisabled
					end),
					BackgroundTransparency = 0.4,
					BorderSizePixel = 0,
					Visible = markerVisible,

					[Children] = Label(scope, {
						Text = scope:Computed(function(use)
							local entry = use(marker)
							return if entry then entry.Label else ""
						end),
						Scale = "Detail",
						Color = Tokens.Color.TextSecondary,
						-- Anchored to the rule's top and extending to its right, so a marker near
						-- the right edge overflows outward rather than covering the plot.
						Position = UDim2.fromOffset(3, 0),
						Size = UDim2.fromOffset(70, AXIS_LABEL_HEIGHT),
					}),
				}
			)
		end
	end

	-- One chain of segment Frames per series.
	for seriesIndex, series in ipairs(props.Series) do
		local resolved = scope:Computed(function(use)
			return decimate(use(series.Points) :: { GraphPoint }, MAX_SEGMENTS + 1)
		end)
		for segment = 1, MAX_SEGMENTS do
			-- Each segment reads only its own two endpoints, so editing one field re-evaluates every
			-- segment's Computed but re-renders only the handful whose geometry actually moved.
			local geometry = scope:Computed(function(use)
				local points = use(resolved)
				local from, to = points[segment], points[segment + 1]
				if not from or not to then
					return nil
				end
				local xMax = math.max(use(props.XMax), 1e-6)
				local yMax = math.max(use(props.YMax), 1e-6)
				local x1 = math.clamp(from.Time / xMax, 0, 1) * plotWidth
				local y1 = plotHeight - math.clamp(from.Value / yMax, 0, 1) * plotHeight
				local x2 = math.clamp(to.Time / xMax, 0, 1) * plotWidth
				local y2 = plotHeight - math.clamp(to.Value / yMax, 0, 1) * plotHeight
				local deltaX, deltaY = x2 - x1, y2 - y1
				local length = math.sqrt(deltaX * deltaX + deltaY * deltaY)
				if length < 0.5 then
					return nil
				end
				return {
					Centre = Vector2.new((x1 + x2) / 2, (y1 + y2) / 2),
					Length = length,
					-- Screen Y grows downward and Roblox's Rotation is clockwise, so the raw atan2
					-- of the screen-space delta is already the correct rotation with no sign flip.
					Rotation = math.deg(math.atan2(deltaY, deltaX)),
				}
			end)

			table.insert(
				plotChildren,
				scope:New "Frame" {
					Name = "S" .. seriesIndex .. "Seg" .. segment,
					AnchorPoint = Vector2.new(0.5, 0.5),
					Position = scope:Computed(function(use)
						local resolvedGeometry = use(geometry)
						if not resolvedGeometry then
							return UDim2.fromOffset(0, 0)
						end
						return UDim2.fromOffset(resolvedGeometry.Centre.X, resolvedGeometry.Centre.Y)
					end),
					Size = scope:Computed(function(use)
						local resolvedGeometry = use(geometry)
						if not resolvedGeometry then
							return UDim2.fromOffset(0, 0)
						end
						return UDim2.fromOffset(resolvedGeometry.Length, LINE_THICKNESS)
					end),
					Rotation = scope:Computed(function(use)
						local resolvedGeometry = use(geometry)
						return if resolvedGeometry then resolvedGeometry.Rotation else 0
					end),
					BackgroundColor3 = series.Color,
					BackgroundTransparency = if series.Muted then MUTED_TRANSPARENCY else 0,
					BorderSizePixel = 0,
					Visible = scope:Computed(function(use)
						return use(geometry) ~= nil
					end),
				}
			)
		end
	end

	local legendChildren: { Instance } = {
		scope:New "UIListLayout" {
			FillDirection = Enum.FillDirection.Horizontal,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			Padding = UDim.new(0, Tokens.Space.S),
			SortOrder = Enum.SortOrder.LayoutOrder,
		},
	}
	for index, series in ipairs(props.Series) do
		table.insert(
			legendChildren,
			scope:New "Frame" {
				Name = "Legend" .. index,
				Size = UDim2.fromOffset(0, LEGEND_HEIGHT),
				AutomaticSize = Enum.AutomaticSize.X,
				BackgroundTransparency = 1,
				LayoutOrder = index,

				[Children] = {
					scope:New "UIListLayout" {
						FillDirection = Enum.FillDirection.Horizontal,
						VerticalAlignment = Enum.VerticalAlignment.Center,
						Padding = UDim.new(0, Tokens.Space.XS),
						SortOrder = Enum.SortOrder.LayoutOrder,
					},
					scope:New "Frame" {
						Name = "Swatch",
						Size = UDim2.fromOffset(8, 3),
						BackgroundColor3 = series.Color,
						BackgroundTransparency = if series.Muted then MUTED_TRANSPARENCY else 0,
						BorderSizePixel = 0,
						LayoutOrder = 1,
					},
					Label(scope, {
						Text = series.Name,
						Scale = "Detail",
						Color = Tokens.Color.TextSecondary,
						Size = UDim2.fromOffset(#series.Name * 6, LEGEND_HEIGHT),
						LayoutOrder = 2,
					}),
				},
			}
		)
	end

	return scope:New "Frame" {
		Name = "LineGraph",
		Size = UDim2.fromOffset(props.Width, props.Height),
		BackgroundTransparency = 1,
		LayoutOrder = props.LayoutOrder,
		Visible = if props.Visible == nil then true else props.Visible,

		[Children] = {
			scope:New "UIListLayout" {
				FillDirection = Enum.FillDirection.Vertical,
				Padding = UDim.new(0, Tokens.Space.XS),
				SortOrder = Enum.SortOrder.LayoutOrder,
			},
			scope:New "Frame" {
				Name = "TitleRow",
				Size = UDim2.new(1, 0, 0, TITLE_HEIGHT),
				BackgroundTransparency = 1,
				LayoutOrder = 1,

				[Children] = {
					Label(scope, {
						Text = props.Title,
						Scale = "Action",
						Color = Tokens.Color.TextPrimary,
						Size = UDim2.fromScale(1, 1),
					}),
					Label(scope, {
						Text = scope:Computed(function(use)
							return formatAxis(use(props.YMax), props.YSuffix or "")
						end),
						Scale = "Detail",
						Color = Tokens.Color.TextSecondary,
						Size = UDim2.fromScale(1, 1),
						TextXAlignment = Enum.TextXAlignment.Right,
					}),
				},
			},
			scope:New "Frame" {
				Name = "Plot",
				Size = UDim2.new(1, 0, 0, plotHeight),
				BackgroundColor3 = Tokens.Wash.Inset.Color,
				BackgroundTransparency = Tokens.Wash.Inset.Transparency,
				BorderSizePixel = 0,
				ClipsDescendants = true,
				LayoutOrder = 2,

				[Children] = plotChildren,
			},
			scope:New "Frame" {
				Name = "AxisRow",
				Size = UDim2.new(1, 0, 0, AXIS_LABEL_HEIGHT),
				BackgroundTransparency = 1,
				LayoutOrder = 3,

				[Children] = {
					Label(scope, {
						Text = "0" .. (props.XSuffix or ""),
						Scale = "Detail",
						Color = Tokens.Color.TextSecondary,
						Size = UDim2.fromScale(1, 1),
					}),
					Label(scope, {
						Text = scope:Computed(function(use)
							return formatAxis(use(props.XMax), props.XSuffix or "")
						end),
						Scale = "Detail",
						Color = Tokens.Color.TextSecondary,
						Size = UDim2.fromScale(1, 1),
						TextXAlignment = Enum.TextXAlignment.Right,
					}),
				},
			},
			scope:New "Frame" {
				Name = "Legend",
				Size = UDim2.new(1, 0, 0, LEGEND_HEIGHT),
				BackgroundTransparency = 1,
				LayoutOrder = 4,

				[Children] = legendChildren,
			},
		},
	} :: Frame
end

-- A labelled bar chart. Bars are scaled against the LARGEST value in the reactive list rather than
-- a caller-supplied maximum -- these compare magnitudes against each other ("which hit does most of
-- the damage"), and pinning them to an absolute scale would flatten every bar on a low-damage move
-- into an unreadable sliver.
function Graph.Bars(scope: Scope, props: BarGraphProps): Frame
	local plotHeight = props.Height - TITLE_HEIGHT - Tokens.Space.XS

	local peakValue = scope:Computed(function(use)
		local peak = 0
		for _, bar in ipairs(use(props.Bars) :: { GraphBar }) do
			if bar.Value > peak then
				peak = bar.Value
			end
		end
		return math.max(peak, 1e-6)
	end)

	local barChildren: { Instance } = {
		scope:New "UIListLayout" {
			FillDirection = Enum.FillDirection.Horizontal,
			VerticalAlignment = Enum.VerticalAlignment.Bottom,
			Padding = UDim.new(0, Tokens.Space.XS),
			SortOrder = Enum.SortOrder.LayoutOrder,
		},
	}

	for index = 1, MAX_BARS do
		local bar = scope:Computed(function(use)
			return (use(props.Bars) :: { GraphBar })[index]
		end)
		local barVisible = scope:Computed(function(use)
			return use(bar) ~= nil
		end)
		-- Every visible bar shares the row evenly, so the column width tracks how many there are.
		local columnWidth = scope:Computed(function(use)
			local count = #(use(props.Bars) :: { GraphBar })
			return UDim2.new(1 / math.max(count, 1), -Tokens.Space.XS, 1, 0)
		end)

		table.insert(
			barChildren,
			scope:New "Frame" {
				Name = "Bar" .. index,
				Size = columnWidth,
				BackgroundTransparency = 1,
				LayoutOrder = index,
				Visible = barVisible,

				[Children] = {
					scope:New "Frame" {
						Name = "Fill",
						AnchorPoint = Vector2.new(0.5, 1),
						-- Sits above the two label rows below it, hence the offset floor.
						Position = UDim2.new(0.5, 0, 1, -(AXIS_LABEL_HEIGHT * 2)),
						Size = scope:Computed(function(use)
							local entry = use(bar)
							if not entry then
								return UDim2.fromScale(0.7, 0)
							end
							local fraction = math.clamp(entry.Value / use(peakValue), 0, 1)
							return UDim2.new(0.7, 0, fraction, -(AXIS_LABEL_HEIGHT * 2) * fraction)
						end),
						BackgroundColor3 = scope:Computed(function(use)
							local entry = use(bar)
							return if entry then entry.Color else Tokens.Color.AccentPrimary
						end),
						BorderSizePixel = 0,
					},
					Label(scope, {
						Text = scope:Computed(function(use)
							local entry = use(bar)
							if not entry then
								return ""
							end
							return entry.ValueText or string.format("%.0f", entry.Value)
						end),
						Scale = "Detail",
						Color = Tokens.Color.AccentPrimaryBright,
						AnchorPoint = Vector2.new(0.5, 1),
						Position = UDim2.new(0.5, 0, 1, -AXIS_LABEL_HEIGHT),
						Size = UDim2.new(1, 0, 0, AXIS_LABEL_HEIGHT),
						TextXAlignment = Enum.TextXAlignment.Center,
					}),
					Label(scope, {
						Text = scope:Computed(function(use)
							local entry = use(bar)
							return if entry then entry.Label else ""
						end),
						Scale = "Detail",
						Color = Tokens.Color.TextSecondary,
						AnchorPoint = Vector2.new(0.5, 1),
						Position = UDim2.fromScale(0.5, 1),
						Size = UDim2.new(1, 0, 0, AXIS_LABEL_HEIGHT),
						TextXAlignment = Enum.TextXAlignment.Center,
					}),
				},
			}
		)
	end

	return scope:New "Frame" {
		Name = "BarGraph",
		Size = UDim2.fromOffset(props.Width, props.Height),
		BackgroundTransparency = 1,
		LayoutOrder = props.LayoutOrder,
		Visible = if props.Visible == nil then true else props.Visible,

		[Children] = {
			scope:New "UIListLayout" {
				FillDirection = Enum.FillDirection.Vertical,
				Padding = UDim.new(0, Tokens.Space.XS),
				SortOrder = Enum.SortOrder.LayoutOrder,
			},
			Label(scope, {
				Text = props.Title,
				Scale = "Action",
				Color = Tokens.Color.TextPrimary,
				Size = UDim2.new(1, 0, 0, TITLE_HEIGHT),
				LayoutOrder = 1,
			}),
			scope:New "Frame" {
				Name = "Plot",
				Size = UDim2.new(1, 0, 0, plotHeight),
				BackgroundColor3 = Tokens.Wash.Inset.Color,
				BackgroundTransparency = Tokens.Wash.Inset.Transparency,
				BorderSizePixel = 0,
				ClipsDescendants = true,
				LayoutOrder = 2,

				[Children] = barChildren,
			},
		},
	} :: Frame
end

return Graph
