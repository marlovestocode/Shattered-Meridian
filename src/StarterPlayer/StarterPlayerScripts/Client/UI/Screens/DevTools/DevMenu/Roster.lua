--!strict
--[[
	DevMenu/Roster.lua

	Owns: the admin panel's left rail -- everyone in the server, live, and the selection that makes one
	of them the TARGET of the Player tab. It is the Move Editor browser's role: where you go to pick.

	A ROW SAYS WHAT IS GOING ON WITH A PLAYER WITHOUT OPENING THEM: display name and tier on the first
	line; on the second, the flags that matter (DEAD, COMBAT, FLAGGED, MUTED, GOD, FLY, FROZEN, ...) as
	words, or their @username when nothing is flagged; ping at the right; and a hairline along the
	bottom that is their health. Words, never colour alone (docs/ui-ux-philosophy.md).

	ROWS ARE KEYED BY UserId AND DO NOT REBUILD ON A POLL. The overview arrives every two seconds as a
	fresh array of fresh tables, and every ping in it moves. A ForPairs keyed on the entry itself would
	tear every row down and rebuild it on every poll -- losing hover, flickering, and churning a
	scope's worth of Instances for a list nobody touched. So the pairs are UserId -> sort position
	(stable across a poll unless someone joined, left or was renamed), and each row reads its live
	entry through a Computed lookup. A poll changes text; only a join or a leave changes rows.

	YOU ARE FIRST, then everyone else by display name -- the admin is the commonest target (testing
	on yourself) and should never have to be found.

	Does not own: what selecting does beyond setting the Value and announcing it (the driver
	re-inspects), or the data (the driver's poll).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local AdminFormat = require(ReplicatedStorage.Shared.Admin.AdminFormat)
local AdminTypes = require(ReplicatedStorage.Shared.Admin.AdminTypes)

local Tokens = require(script.Parent.Parent.Parent.Parent.Tokens)
local Inset = require(script.Parent.Parent.Parent.Parent.Components.Inset)
local Label = require(script.Parent.Parent.Parent.Parent.Components.Label)
local ScrollArea = require(script.Parent.Parent.Parent.Parent.Components.ScrollArea)
local Selection = require(script.Parent.Parent.Parent.Parent.Components.Selection)
local Stack = require(script.Parent.Parent.Parent.Parent.Components.Stack)
local TextField = require(script.Parent.Parent.Parent.Parent.Components.TextField)
local TrackedLabel = require(script.Parent.Parent.Parent.Parent.Components.TrackedLabel)

local Children = Fusion.Children
local OnEvent = Fusion.OnEvent

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>
type RosterEntry = AdminTypes.RosterEntry

export type RosterProps = {
	Width: number,
	LayoutOrder: number?,
	Roster: UsedAs<{ RosterEntry }>,
	Server: UsedAs<AdminTypes.ServerOverview?>,
	SelectedUserId: UsedAs<number?>,
	OnSelect: (userId: number) -> (),
}

local ROW_HEIGHT = 50
local ACCENT_WIDTH = 2
local HEALTH_RULE_HEIGHT = 2
local TIER_WIDTH = 44
local PING_WIDTH = 60

-- Pings past these read as a warning / a problem.
local PING_WARN_MS = 150
local PING_BAD_MS = 300

local function pingColor(ms: number): Color3
	if ms >= PING_BAD_MS then
		return Tokens.Color.DangerBright
	elseif ms >= PING_WARN_MS then
		return Tokens.Color.Warning
	end
	return Tokens.Color.TextDisabled
end

local function row(
	scope: Scope,
	userId: number,
	order: number,
	entries: UsedAs<{ [number]: RosterEntry }>,
	props: RosterProps
): Instance
	local selection = Selection.New(scope)
	local entry = scope:Computed(function(use): RosterEntry?
		return use(entries)[userId]
	end)
	local isSelected = scope:Computed(function(use)
		return use(props.SelectedUserId) == userId
	end)

	local nameText = scope:Computed(function(use)
		local current = use(entry)
		if not current then
			return ""
		end
		return if current.IsRequester then `{current.DisplayName}  · you` else current.DisplayName
	end)
	local flags = scope:Computed(function(use)
		local current = use(entry)
		return if current then AdminFormat.RosterFlags(current) else {}
	end)
	local detailText = scope:Computed(function(use)
		local current = use(entry)
		if not current then
			return ""
		end
		local flagList = use(flags)
		return if #flagList > 0 then table.concat(flagList, " · ") else `@{current.Name}`
	end)
	local detailColor = scope:Computed(function(use)
		local current = use(entry)
		if not current then
			return Tokens.Color.TextDisabled
		end
		if not current.Alive or current.Flagged then
			return Tokens.Color.DangerBright
		end
		return if #use(flags) > 0 then Tokens.Color.AccentSecondary else Tokens.Color.TextDisabled
	end)

	return scope:New "TextButton" {
		Name = `Player_{userId}`,
		Size = UDim2.new(1, 0, 0, ROW_HEIGHT),
		LayoutOrder = order,
		AutoButtonColor = false,
		Text = "",
		BackgroundColor3 = scope:Computed(function(use)
			return if use(isSelected) then Tokens.Wash.AccentFill.Color else Tokens.Wash.AccentBloom.Color
		end),
		BackgroundTransparency = scope:Computed(function(use)
			if use(isSelected) then
				return Tokens.Wash.AccentFill.Transparency
			end
			return if use(selection.Active) then Tokens.Wash.AccentBloom.Transparency else 1
		end),
		BorderSizePixel = 0,

		[OnEvent "Activated"] = function()
			props.OnSelect(userId)
		end,
		[OnEvent "MouseEnter"] = selection.OnPointerEnter,
		[OnEvent "MouseLeave"] = selection.OnPointerLeave,
		[OnEvent "SelectionGained"] = selection.OnSelectionGained,
		[OnEvent "SelectionLost"] = selection.OnSelectionLost,

		[Children] = {
			scope:New "Frame" {
				Name = "Accent",
				Size = UDim2.new(0, ACCENT_WIDTH, 1, 0),
				BackgroundColor3 = Tokens.Color.AccentPrimary,
				BackgroundTransparency = scope:Computed(function(use)
					return if use(isSelected) then 0 else 1
				end),
				BorderSizePixel = 0,
			},
			Label(scope, {
				Text = nameText,
				Scale = "Body",
				Color = scope:Computed(function(use)
					return if use(isSelected) then Tokens.Color.TextPrimary else Tokens.Color.TextSecondary
				end),
				Position = UDim2.fromOffset(Tokens.Space.M, 7),
				Size = UDim2.new(1, -(Tokens.Space.M + TIER_WIDTH + Tokens.Space.S), 0, Tokens.Type.Body.Size + 4),
				TextTruncate = Enum.TextTruncate.AtEnd,
			}),
			Label(scope, {
				Text = scope:Computed(function(use)
					local current = use(entry)
					return if current then `T{current.Tier}` else ""
				end),
				Scale = "NumeralSmall",
				Color = Tokens.Color.AccentSecondary,
				AnchorPoint = Vector2.new(1, 0),
				Position = UDim2.new(1, -Tokens.Space.S, 0, 8),
				Size = UDim2.fromOffset(TIER_WIDTH, Tokens.Type.Body.Size + 2),
				TextXAlignment = Enum.TextXAlignment.Right,
			}),
			Label(scope, {
				Text = detailText,
				Scale = "Detail",
				Color = detailColor,
				Position = UDim2.fromOffset(Tokens.Space.M, 27),
				Size = UDim2.new(1, -(Tokens.Space.M + PING_WIDTH + Tokens.Space.S), 0, Tokens.Type.Detail.Size + 4),
				TextTruncate = Enum.TextTruncate.AtEnd,
			}),
			Label(scope, {
				Text = scope:Computed(function(use)
					local current = use(entry)
					return if current then AdminFormat.Ping(current.PingMs) else ""
				end),
				Scale = "NumeralSmall",
				Color = scope:Computed(function(use)
					local current = use(entry)
					return if current then pingColor(current.PingMs) else Tokens.Color.TextDisabled
				end),
				AnchorPoint = Vector2.new(1, 0),
				Position = UDim2.new(1, -Tokens.Space.S, 0, 28),
				Size = UDim2.fromOffset(PING_WIDTH, Tokens.Type.Detail.Size + 2),
				TextXAlignment = Enum.TextXAlignment.Right,
			}),
			-- Health, as the row's own bottom edge: a track the width of the row, filled to the fraction.
			scope:New "Frame" {
				Name = "HealthTrack",
				AnchorPoint = Vector2.new(0, 1),
				Position = UDim2.new(0, Tokens.Space.M, 1, -3),
				Size = UDim2.new(1, -Tokens.Space.M * 2, 0, HEALTH_RULE_HEIGHT),
				BackgroundColor3 = Tokens.Wash.TrackBase.Color,
				BackgroundTransparency = Tokens.Wash.TrackBase.Transparency,
				BorderSizePixel = 0,
				[Children] = scope:New "Frame" {
					Name = "Fill",
					Size = scope:Computed(function(use)
						local current = use(entry)
						return UDim2.fromScale(if current then current.HealthFraction else 0, 1)
					end),
					BackgroundColor3 = scope:Computed(function(use)
						local current = use(entry)
						if current and current.HealthFraction <= 0.25 then
							return Tokens.Color.DangerBright
						end
						return Tokens.VitalColor.Health
					end),
					BorderSizePixel = 0,
				},
			},
		},
	}
end

local function Roster(scope: Scope, props: RosterProps): Frame
	local filterText = scope:Value("")

	local byUserId = scope:Computed(function(use)
		local map: { [number]: RosterEntry } = {}
		for _, entry in use(props.Roster) do
			map[entry.UserId] = entry
		end
		return map
	end)

	-- UserId -> sort position, for the entries the filter lets through. See the header on why the
	-- pairs are this shape rather than the entries themselves.
	local order = scope:Computed(function(use)
		local filter = use(filterText)
		local visible: { RosterEntry } = {}
		for _, entry in use(props.Roster) do
			if AdminFormat.RosterMatches(entry, filter) then
				table.insert(visible, entry)
			end
		end
		table.sort(visible, function(left: RosterEntry, right: RosterEntry): boolean
			if left.IsRequester ~= right.IsRequester then
				return left.IsRequester
			end
			return string.lower(left.DisplayName) < string.lower(right.DisplayName)
		end)
		local positions: { [number]: number } = {}
		for index, entry in visible do
			positions[entry.UserId] = index
		end
		return positions
	end)

	local rows = scope:ForPairs(order, function(_use, innerScope: Scope, userId: number, index: number)
		return userId, row(innerScope, userId, index, byUserId, props)
	end)

	local countText = scope:Computed(function(use)
		local server = use(props.Server)
		local count = #use(props.Roster)
		return if server then `{count} / {server.MaxPlayers}` else tostring(count)
	end)
	local isEmpty = scope:Computed(function(use)
		return next(use(order)) == nil
	end)

	-- The server's pulse, pinned under the list: the numbers an admin glances at without opening the
	-- Server tab.
	local pulseText = scope:Computed(function(use)
		local server = use(props.Server)
		if not server then
			return "Waiting for the server..."
		end
		local fps = if server.ServerFps then `{server.ServerFps} fps` else "-- fps"
		return `{fps} · {math.floor(server.MemoryMb + 0.5)} MB · up {AdminFormat.Duration(server.UptimeSeconds)}`
	end)
	local pulseColor = scope:Computed(function(use)
		local server = use(props.Server)
		if server and server.ServerFps and server.ServerFps < 45 then
			return Tokens.Color.Warning
		end
		return Tokens.Color.TextDisabled
	end)

	return Stack.New(scope, {
		Name = "Roster",
		Size = UDim2.new(0, props.Width, 1, 0),
		LayoutOrder = props.LayoutOrder,
		Gap = Tokens.Space.S,
		BackgroundColor3 = Tokens.Wash.RailScrim.Color,
		BackgroundTransparency = Tokens.Wash.RailScrim.Transparency,
		Children = {
			Inset(scope, { Top = Tokens.Space.M, Bottom = Tokens.Space.M, X = Tokens.Space.M }),
			Stack.Row(scope, {
				Name = "Header",
				Size = UDim2.new(1, 0, 0, Tokens.Control.StepButtonSize - 8),
				AlignY = Enum.VerticalAlignment.Center,
				Gap = Tokens.Space.S,
				LayoutOrder = 1,
				Children = {
					TrackedLabel(scope, {
						Text = "PLAYERS",
						Scale = "Eyebrow",
						Color = Tokens.Color.TextPrimary,
						LayoutOrder = 1,
					}),
					Stack.Fill(
						scope,
						Label(scope, {
							Text = countText,
							Scale = "NumeralSmall",
							Color = Tokens.Color.TextDisabled,
							Size = UDim2.fromScale(0, 1),
							TextXAlignment = Enum.TextXAlignment.Right,
							LayoutOrder = 2,
						})
					),
				},
			}),
			TextField(scope, {
				Text = filterText,
				PlaceholderText = "Filter by name or user id",
				MaxLength = 40,
				Size = UDim2.new(1, 0, 0, Tokens.Control.StepButtonSize),
				LayoutOrder = 2,
			}),
			Stack.Fill(
				scope,
				ScrollArea(scope, {
					Name = "Rows",
					Size = UDim2.fromScale(1, 0),
					LayoutOrder = 3,
					Children = {
						scope:New "UIListLayout" {
							FillDirection = Enum.FillDirection.Vertical,
							SortOrder = Enum.SortOrder.LayoutOrder,
						},
						Label(scope, {
							Text = "Nobody matches that filter.",
							Scale = "Detail",
							Color = Tokens.Color.TextDisabled,
							Size = UDim2.new(1, 0, 0, Tokens.Control.StepButtonSize),
							LayoutOrder = 0,
							Visible = scope:Computed(function(use)
								return use(isEmpty) and #use(props.Roster) > 0
							end),
						}),
						rows :: any,
					},
				})
			),
			Label(scope, {
				Text = pulseText,
				Scale = "NumeralSmall",
				Color = pulseColor,
				Size = UDim2.new(1, 0, 0, Tokens.Type.NumeralSmall.Size + Tokens.Space.XS),
				TextTruncate = Enum.TextTruncate.AtEnd,
				LayoutOrder = 4,
			}),
		},
	})
end

return Roster
