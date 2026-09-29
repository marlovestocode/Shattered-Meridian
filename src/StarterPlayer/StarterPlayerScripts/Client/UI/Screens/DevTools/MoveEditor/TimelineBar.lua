--!strict
--[[
	MoveEditor/TimelineBar.lua

	Owns: the readout's picture of a swing in time -- windup, active window and recovery as one bar at
	true proportion, with the cooldown, the clip's end and the clip's strike marker drawn on it, and the
	numbers beneath.

	IT DRAWS THE EFFECTIVE TIMELINE, NOT THE AUTHORED ONE. AttackCatalog rebuilds every swing against
	its clip (Shared/Attack/AttackWindows.lua): a strike marker replaces the windup, the clip's length
	decides the recovery, the weapon's speed and the string's tempo rescale both. That rebuilt timeline
	is what a player fights, and the old editor never showed it -- a move could read 0.30s windup in the
	editor and swing at 0.19s. The server sends the rebuilt timeline with every entry
	(MoveEditorTypes.EffectiveTiming); where a number differs from what was typed, the typed one is shown
	beside it in brackets, so the author can see which of their numbers the clip overrode.

	The entry lags an edit by one debounced round trip. That is deliberate: the effective timeline can
	only be computed where the clip data lives, and a client-side guess at it would be the old editor's
	mistake again.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local MoveEditorTypes = require(ReplicatedStorage.Shared.Authoring.MoveEditorTypes)
local MoveTypes = require(ReplicatedStorage.Shared.MoveTypes)

local Tokens = require(script.Parent.Parent.Parent.Parent.Tokens)
local StatRow = require(script.Parent.Parent.Parent.Parent.Components.StatRow)
local Stack = require(script.Parent.Parent.Parent.Parent.Components.Stack)

local Children = Fusion.Children

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>

export type TimelineBarProps = {
	Entry: UsedAs<MoveEditorTypes.MoveEntry?>,
	Draft: UsedAs<MoveTypes.MoveDefinition?>,
	LayoutOrder: number?,
}

local BAR_HEIGHT = 12
local MARKER_HEIGHT = BAR_HEIGHT + 8
local ROW_HEIGHT = 22

type Timeline = {
	Windup: number,
	Active: number,
	Recovery: number,
	Cooldown: number,
	Clip: number?,
	-- Where the clip's strike marker lands, in swing time (MoveEditorTypes.EffectiveTiming.StrikeSeconds).
	Strike: number?,
	Speed: number,
	-- Whether these are the server's effective numbers (false: the draft's authored ones, because the
	-- catalogue could not resolve the move).
	Effective: boolean,
}

local function timelineOf(entry: MoveEditorTypes.MoveEntry?, draft: MoveTypes.MoveDefinition?): Timeline?
	local effective = entry and entry.Effective
	if effective then
		return {
			Windup = effective.WindupSeconds,
			Active = effective.ActiveSeconds,
			Recovery = effective.RecoverySeconds,
			Cooldown = effective.Cooldown,
			Clip = effective.ClipSeconds,
			Strike = effective.StrikeSeconds,
			Speed = effective.PlaybackSpeed,
			Effective = true,
		}
	end
	if draft then
		return {
			Windup = draft.WindupSeconds,
			Active = draft.ActiveSeconds,
			Recovery = draft.RecoverySeconds,
			Cooldown = draft.Cooldown,
			Clip = nil,
			Strike = nil,
			Speed = 1,
			Effective = false,
		}
	end
	return nil
end

local function seconds(value: number): string
	return string.format("%.2fs", value)
end

-- "0.19s  (0.30)" when the effective number is not what was typed.
local function withAuthored(effective: number, authored: number?): string
	if authored and math.abs(effective - authored) > 0.005 then
		return `{seconds(effective)}  ({string.format("%.2f", authored)})`
	end
	return seconds(effective)
end

local function TimelineBar(scope: Scope, props: TimelineBarProps): Frame
	local timeline = scope:Computed(function(use)
		return timelineOf(use(props.Entry), use(props.Draft))
	end)

	-- Everything on the bar is a fraction of the longest thing drawn on it.
	local span = scope:Computed(function(use)
		local t = use(timeline)
		if not t then
			return 1
		end
		return math.max(t.Windup + t.Active + t.Recovery, t.Cooldown, t.Clip or 0, 1e-3)
	end)

	local function segment(
		name: string,
		order: number,
		color: Color3,
		transparency: number,
		pick: (Timeline) -> number
	): Frame
		return scope:New "Frame" {
			Name = name,
			LayoutOrder = order,
			BackgroundColor3 = color,
			BackgroundTransparency = transparency,
			BorderSizePixel = 0,
			Size = scope:Computed(function(use)
				local t = use(timeline)
				return UDim2.fromScale(if t then pick(t) / use(span) else 0, 1)
			end),
		} :: Frame
	end

	local function marker(name: string, color: Color3, pick: (Timeline) -> number?): Frame
		return scope:New "Frame" {
			Name = name,
			AnchorPoint = Vector2.new(0.5, 0.5),
			BackgroundColor3 = color,
			BorderSizePixel = 0,
			ZIndex = 2,
			Size = UDim2.fromOffset(2, MARKER_HEIGHT),
			Position = scope:Computed(function(use)
				local t = use(timeline)
				local at = if t then pick(t) else nil
				return UDim2.fromScale(if at then at / use(span) else 0, 0.5)
			end),
			Visible = scope:Computed(function(use)
				local t = use(timeline)
				return t ~= nil and pick(t) ~= nil
			end),
		} :: Frame
	end

	local function row(caption: string, order: number, value: (Timeline, MoveTypes.MoveDefinition?) -> string): Instance
		return StatRow(scope, {
			Caption = caption,
			Value = scope:Computed(function(use)
				local t = use(timeline)
				return if t then value(t, use(props.Draft)) else "-"
			end),
			Size = UDim2.new(1, 0, 0, ROW_HEIGHT),
			LayoutOrder = order,
		})
	end

	return Stack.New(scope, {
		Name = "Timeline",
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Gap = Tokens.Space.XS,
		LayoutOrder = props.LayoutOrder,
		Children = {
			scope:New "Frame" {
				Name = "Track",
				Size = UDim2.new(1, 0, 0, MARKER_HEIGHT),
				BackgroundTransparency = 1,
				LayoutOrder = 1,

				[Children] = {
					Stack.Row(scope, {
						Name = "Bar",
						AnchorPoint = Vector2.new(0, 0.5),
						Position = UDim2.fromScale(0, 0.5),
						Size = UDim2.new(1, 0, 0, BAR_HEIGHT),
						BackgroundColor3 = Tokens.Wash.TrackBase.Color,
						BackgroundTransparency = Tokens.Wash.TrackBase.Transparency,
						Children = {
							segment("Windup", 1, Tokens.Color.TextDisabled, 0.55, function(t)
								return t.Windup
							end),
							segment("Active", 2, Tokens.Color.Danger, 0, function(t)
								return t.Active
							end),
							segment("Recovery", 3, Tokens.Color.AccentPrimary, 0.6, function(t)
								return t.Recovery
							end),
						},
					}),
					marker("Cooldown", Tokens.Color.AccentSecondary, function(t)
						return t.Cooldown
					end),
					marker("ClipEnd", Tokens.Color.AccentPrimaryBright, function(t)
						return t.Clip
					end),
					marker("Strike", Tokens.Color.TextPrimary, function(t)
						return t.Strike
					end),
				},
			},
			row("Windup", 2, function(t, draft)
				return withAuthored(t.Windup, if t.Effective and draft then draft.WindupSeconds else nil)
			end),
			row("Active", 3, function(t)
				return seconds(t.Active)
			end),
			row("Recovery", 4, function(t, draft)
				return withAuthored(t.Recovery, if t.Effective and draft then draft.RecoverySeconds else nil)
			end),
			row("Cooldown  (bronze)", 5, function(t, draft)
				return withAuthored(t.Cooldown, if t.Effective and draft then draft.Cooldown else nil)
			end),
			row("Clip  (violet)", 6, function(t)
				if not t.Effective then
					return "not resolved"
				end
				if not t.Clip then
					return "unknown"
				end
				return `{seconds(t.Clip)} at {string.format("%.2f", t.Speed)}x`
			end),
			row("Strike marker  (white)", 7, function(t)
				if not t.Effective then
					return "not resolved"
				end
				return if t.Strike then seconds(t.Strike) else "none"
			end),
		},
	})
end

return TimelineBar
