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

	IT IS ALSO AN INPUT (2026-10-07), two ways:

	  * DRAG AN EDGE to retime. The three handles sit on the ends of windup, active and recovery; dragging
	    one sets that phase's AUTHORED length (the later phases ride along), snapped to 0.01s -- or to one
	    frame (1/60s) with Shift held. While a drag is on, and until the server answers it, the bar draws the
	    authored numbers it is setting rather than the effective ones it last heard, so the edge stays under
	    the cursor. Commits are throttled like NumericField's scrub, plus one on release, and they go through
	    the screen's one Edit -- so a drag previews, and undoes as one step, like any field. Where the clip's
	    strike marker decides the windup, dragging the windup changes only the typed number; the caption
	    under the bar says so.
	  * PRESS OR DRAG THE BAR ITSELF to scrub. That sets ScrubTime, which the client turns into your own
	    character held at that instant of the clip (Client/DevTools/MoveEditor/ClipScrubber.lua) -- so a
	    hand- or weapon-anchored hitbox drawn on you rides to exactly where it is at that moment. Play runs the
	    scrub forward at real speed and loops; Release lets the character go.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Constants = require(ReplicatedStorage.Shared.Constants)
local MoveEditorTypes = require(ReplicatedStorage.Shared.Authoring.MoveEditorTypes)
local MoveTypes = require(ReplicatedStorage.Shared.MoveTypes)

local Tokens = require(script.Parent.Parent.Parent.Parent.Tokens)
local Button = require(script.Parent.Parent.Parent.Parent.Components.Button)
local Label = require(script.Parent.Parent.Parent.Parent.Components.Label)
local StatRow = require(script.Parent.Parent.Parent.Parent.Components.StatRow)
local Stack = require(script.Parent.Parent.Parent.Parent.Components.Stack)

local Children = Fusion.Children
local OnEvent = Fusion.OnEvent
local peek = Fusion.peek

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>

export type TimelineBarProps = {
	Entry: UsedAs<MoveEditorTypes.MoveEntry?>,
	Draft: UsedAs<MoveTypes.MoveDefinition?>,
	LayoutOrder: number?,
	-- The screen's edit path; without it the bar is read-only (no handles).
	Edit: ((mutate: (MoveTypes.MoveDefinition) -> ()) -> ())?,
	-- The clip scrub (see this file's header); without them the bar cannot be scrubbed.
	ScrubTime: Fusion.Value<number?>?,
	ScrubPlaying: Fusion.Value<boolean>?,
}

local BAR_HEIGHT = 12
local MARKER_HEIGHT = BAR_HEIGHT + 8
local TRACK_HEIGHT = MARKER_HEIGHT + 8
local ROW_HEIGHT = 22
local HANDLE_WIDTH = 10
local CONTROL_HEIGHT = 26
-- How often a drag commits (the readout paints every pointer move; the edit is the expensive half).
local COMMIT_INTERVAL = 1 / 20
local SNAP_SECONDS = 0.01
local FRAME_SECONDS = 1 / 60
local PHASE_LIMITS = Constants.MoveEditor.Limits.PhaseSeconds

type Edge = "Windup" | "Active" | "Recovery"

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

local function snap(value: number, frames: boolean): number
	local step = if frames then FRAME_SECONDS else SNAP_SECONDS
	return math.clamp(math.floor(value / step + 0.5) * step, PHASE_LIMITS.Min, PHASE_LIMITS.Max)
end

local function TimelineBar(scope: Scope, props: TimelineBarProps): Frame
	-- What is being dragged: an edge, the scrub, or nothing.
	local dragging = scope:Value(nil :: string?)
	-- True from a retime's first move until the server's next entry, so the bar shows what was set.
	local showAuthored = scope:Value(false)
	-- The bar's span is held still while a drag is on, so the edge under the cursor does not slide away.
	local heldSpan = scope:Value(nil :: number?)

	scope:Observer(props.Entry :: any):onChange(function()
		if peek(dragging) == nil then
			showAuthored:set(false)
		end
	end)

	local timeline = scope:Computed(function(use)
		if use(showAuthored) then
			return timelineOf(nil, use(props.Draft))
		end
		return timelineOf(use(props.Entry), use(props.Draft))
	end)

	-- Everything on the bar is a fraction of the longest thing drawn on it.
	local span = scope:Computed(function(use)
		local held = use(heldSpan)
		local t = use(timeline)
		if not t then
			return held or 1
		end
		local natural = math.max(t.Windup + t.Active + t.Recovery, t.Cooldown, t.Clip or 0, 1e-3)
		return if held then math.max(held, t.Windup + t.Active + t.Recovery) else natural
	end)

	local track: Frame? = nil
	-- The swing time under a screen x, against the track's live box.
	local function timeAt(x: number): number
		local frame = track
		if not frame then
			return 0
		end
		local width = math.max(frame.AbsoluteSize.X, 1)
		return math.clamp((x - frame.AbsolutePosition.X) / width, 0, 1) * peek(span)
	end

	-- Retime --------------------------------------------------------------------------------------------
	local lastCommit = 0
	local function retime(edge: Edge, at: number, final: boolean): ()
		local edit = props.Edit
		local move = peek(props.Draft)
		if not edit or not move then
			return
		end
		if not final and os.clock() - lastCommit < COMMIT_INTERVAL then
			return
		end
		lastCommit = os.clock()
		local frames = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift)
			or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
		local windup, active = move.WindupSeconds, move.ActiveSeconds
		local value = if edge == "Windup"
			then snap(at, frames)
			elseif edge == "Active" then snap(at - windup, frames)
			else snap(at - windup - active, frames)
		local field = if edge == "Windup"
			then "WindupSeconds"
			elseif edge == "Active" then "ActiveSeconds"
			else "RecoverySeconds"
		if math.abs((move :: any)[field] - value) < 1e-6 then
			return
		end
		edit(function(target)
			(target :: any)[field] = value
		end)
	end

	-- Scrub ---------------------------------------------------------------------------------------------
	local function scrubTo(at: number): ()
		local scrub = props.ScrubTime
		if scrub then
			scrub:set(at)
		end
	end

	local function beginDrag(kind: string, x: number): ()
		dragging:set(kind)
		heldSpan:set(peek(span))
		if kind == "Scrub" then
			if props.ScrubPlaying then
				props.ScrubPlaying:set(false)
			end
			scrubTo(timeAt(x))
		else
			showAuthored:set(true)
		end
	end
	local function moveDrag(x: number, final: boolean): ()
		local kind = peek(dragging)
		if kind == nil then
			return
		end
		if kind == "Scrub" then
			scrubTo(timeAt(x))
		else
			retime(kind :: Edge, timeAt(x), final)
		end
	end
	local function endDrag(x: number): ()
		if peek(dragging) == nil then
			return
		end
		moveDrag(x, true)
		dragging:set(nil)
		heldSpan:set(nil)
	end

	local function isPress(input: InputObject): boolean
		return input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch
	end
	table.insert(
		scope,
		UserInputService.InputChanged:Connect(function(input: InputObject)
			if
				input.UserInputType == Enum.UserInputType.MouseMovement
				or input.UserInputType == Enum.UserInputType.Touch
			then
				moveDrag(input.Position.X, false)
			end
		end)
	)
	table.insert(
		scope,
		UserInputService.InputEnded:Connect(function(input: InputObject)
			if isPress(input) then
				endDrag(input.Position.X)
			end
		end)
	)

	-- Where an edge sits, in swing time, on the bar as drawn.
	local function edgeAt(t: Timeline, edge: Edge): number
		if edge == "Windup" then
			return t.Windup
		elseif edge == "Active" then
			return t.Windup + t.Active
		end
		return t.Windup + t.Active + t.Recovery
	end

	local function handle(edge: Edge, order: number): Instance
		local hovering = scope:Value(false)
		return scope:New "TextButton" {
			Name = `{edge}Edge`,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Size = UDim2.fromOffset(HANDLE_WIDTH, TRACK_HEIGHT),
			Position = scope:Computed(function(use)
				local t = use(timeline)
				return UDim2.fromScale(if t then edgeAt(t, edge) / use(span) else 0, 0.5)
			end),
			BackgroundTransparency = 1,
			AutoButtonColor = false,
			Text = "",
			ZIndex = 4,
			LayoutOrder = order,
			[OnEvent "MouseEnter"] = function()
				hovering:set(true)
			end,
			[OnEvent "MouseLeave"] = function()
				hovering:set(false)
			end,
			[OnEvent "InputBegan"] = function(input: InputObject)
				if isPress(input) then
					beginDrag(edge, input.Position.X)
				end
			end,
			[Children] = scope:New "Frame" {
				Name = "Grip",
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = scope:Computed(function(use)
					local lit = use(hovering) or use(dragging) == edge
					return UDim2.fromOffset(if lit then 4 else 2, TRACK_HEIGHT - 4)
				end),
				BackgroundColor3 = Tokens.Color.TextPrimary,
				BackgroundTransparency = scope:Computed(function(use)
					return if use(hovering) or use(dragging) == edge then 0 else 0.45
				end),
				BorderSizePixel = 0,
			},
		}
	end

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

	local scrubbable = props.ScrubTime ~= nil
	local trackChildren: { Instance } = {}
	if props.Edit then
		table.insert(trackChildren, handle("Windup", 1))
		table.insert(trackChildren, handle("Active", 2))
		table.insert(trackChildren, handle("Recovery", 3))
	end
	if scrubbable then
		local scrub = props.ScrubTime :: Fusion.Value<number?>
		-- The scrub surface under everything else on the track.
		table.insert(
			trackChildren,
			scope:New "TextButton" {
				Name = "ScrubSurface",
				Size = UDim2.fromScale(1, 1),
				BackgroundTransparency = 1,
				AutoButtonColor = false,
				Text = "",
				ZIndex = 1,
				[OnEvent "InputBegan"] = function(input: InputObject)
					if isPress(input) then
						beginDrag("Scrub", input.Position.X)
					end
				end,
			}
		)
		table.insert(
			trackChildren,
			scope:New "Frame" {
				Name = "Playhead",
				AnchorPoint = Vector2.new(0.5, 0.5),
				Size = UDim2.fromOffset(2, TRACK_HEIGHT),
				BackgroundColor3 = Tokens.Color.Positive,
				BorderSizePixel = 0,
				ZIndex = 3,
				Position = scope:Computed(function(use)
					local at = use(scrub)
					return UDim2.fromScale(if at then math.clamp(at / use(span), 0, 1) else 0, 0.5)
				end),
				Visible = scope:Computed(function(use)
					return use(scrub) ~= nil
				end),
			}
		)
	end

	local controls: Instance? = nil
	if scrubbable then
		local scrub = props.ScrubTime :: Fusion.Value<number?>
		local playing = props.ScrubPlaying
		controls = Stack.Row(scope, {
			Name = "ScrubControls",
			Size = UDim2.new(1, 0, 0, CONTROL_HEIGHT),
			Gap = Tokens.Space.XS,
			AlignY = Enum.VerticalAlignment.Center,
			LayoutOrder = 2,
			Children = {
				Button(scope, {
					Text = if playing
						then scope:Computed(function(use)
							return if use(playing) then "Pause" else "Play clip"
						end)
						else "Play clip",
					Size = UDim2.fromOffset(84, CONTROL_HEIGHT),
					LayoutOrder = 1,
					OnActivated = function()
						if playing then
							local on = not peek(playing)
							if on and peek(scrub) == nil then
								scrub:set(0)
							end
							playing:set(on)
						end
					end,
				}),
				Button(scope, {
					Text = "Release",
					Size = UDim2.fromOffset(72, CONTROL_HEIGHT),
					LayoutOrder = 2,
					Disabled = scope:Computed(function(use)
						return use(scrub) == nil
					end),
					OnActivated = function()
						if playing then
							playing:set(false)
						end
						scrub:set(nil)
					end,
				}),
				Stack.Fill(
					scope,
					Label(scope, {
						Text = scope:Computed(function(use)
							local at = use(scrub)
							if at == nil then
								return "press or drag the bar to scrub"
							end
							return string.format("%.2fs  ·  frame %d", at, math.floor(at / FRAME_SECONDS + 0.5))
						end),
						Scale = "NumeralSmall",
						Color = Tokens.Color.TextSecondary,
						Size = UDim2.fromScale(0, 1),
						TextXAlignment = Enum.TextXAlignment.Right,
						TextTruncate = Enum.TextTruncate.AtEnd,
						LayoutOrder = 3,
					})
				),
			},
		})
	end

	-- Under the bar: what dragging an edge does, and the one case where the clip decides instead.
	local caption = if props.Edit
		then Label(scope, {
			Text = scope:Computed(function(use)
				local entry = use(props.Entry)
				local effective = entry and entry.Effective
				if effective and effective.StrikeSeconds ~= nil then
					return "Drag an edge to retime (Shift snaps to frames). The clip's strike marker sets the windup, so dragging it only changes the typed number."
				end
				return "Drag an edge to retime -- Shift snaps to frames."
			end),
			Scale = "Detail",
			Color = Tokens.Color.TextDisabled,
			Size = UDim2.fromScale(1, 0),
			AutoHeight = true,
			TextWrapped = true,
			LineHeight = Tokens.Leading.Prose,
			LayoutOrder = 3,
		})
		else nil

	local trackFrame = scope:New "Frame" {
		Name = "Track",
		Size = UDim2.new(1, 0, 0, TRACK_HEIGHT),
		BackgroundTransparency = 1,
		LayoutOrder = 1,

		[Children] = {
			trackChildren,
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
	} :: Frame
	track = trackFrame

	local head: { Instance } = { trackFrame }
	if controls then
		table.insert(head, controls)
	end
	if caption then
		table.insert(head, caption)
	end

	return Stack.New(scope, {
		Name = "Timeline",
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Gap = Tokens.Space.XS,
		LayoutOrder = props.LayoutOrder,
		Children = {
			head,
			row("Windup", 12, function(t, draft)
				return withAuthored(t.Windup, if t.Effective and draft then draft.WindupSeconds else nil)
			end),
			row("Active", 13, function(t)
				return seconds(t.Active)
			end),
			row("Recovery", 14, function(t, draft)
				return withAuthored(t.Recovery, if t.Effective and draft then draft.RecoverySeconds else nil)
			end),
			row("Cooldown  (bronze)", 15, function(t, draft)
				return withAuthored(t.Cooldown, if t.Effective and draft then draft.Cooldown else nil)
			end),
			row("Clip  (violet)", 16, function(t)
				if not t.Effective then
					return "not resolved"
				end
				if not t.Clip then
					return "unknown"
				end
				return `{seconds(t.Clip)} at {string.format("%.2f", t.Speed)}x`
			end),
			row("Strike marker  (white)", 17, function(t)
				if not t.Effective then
					return "not resolved"
				end
				return if t.Strike then seconds(t.Strike) else "none"
			end),
		},
	})
end

return TimelineBar
