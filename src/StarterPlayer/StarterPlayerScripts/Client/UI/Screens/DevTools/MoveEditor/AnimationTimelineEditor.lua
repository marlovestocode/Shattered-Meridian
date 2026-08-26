--!strict
--[[
	AnimationTimelineEditor.lua

	Owns: the Move Editor's Animation section content -- authoring a move's ordered clip list
	(Shared/AnimationTimeline.lua) rather than the single AnimationId field this section used to be.

	Three stacked pieces, top to bottom:

	  1. A TIMELINE STRIP. Every enabled clip drawn as a bar across the move's own duration, with the
	     windup/active/recovery phase bands behind it. This is the thing that makes a multi-clip move
	     authorable at all -- the numbers alone ("starts at 0.2, stops at phase end, queued behind
	     clip 1") do not tell you whether two clips overlap, and overlapping is the whole question.
	     Drawn from AnimationTimeline.Resolve, the SAME resolution the runtime plays and the preview
	     replays, so the strip cannot show a sequence that won't happen.
	  2. A CLIP LIST. One compact row per clip: order, name, enabled state, reorder and delete. One
	     row is selected at a time.
	  3. A DETAIL FORM for whichever clip is selected: every per-clip control the schema has.

	The list/detail split is deliberate rather than eight expanded forms stacked vertically. Each
	clip has ~15 controls; mounting eight full copies would be well over a thousand instances in a
	panel that re-renders on every keystroke, and the author only ever edits one clip at a time
	anyway. The rows are still all mounted up front and Visible-toggled (the idiom used across this
	screen) -- it's only the FORM that is shared, rebound to whichever row is selected.

	Does not own: playback (Client/FX/CombatAnimator.lua at runtime, PreviewViewport.lua in the
	editor), the schedule rules themselves (AnimationTimeline.Resolve), or validation
	(MoveRegistryManager.Validate re-clamps every clip server-side against the same
	AnimationTimeline.Limits these fields are built from).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local AnimationTimeline = require(ReplicatedStorage.Shared.AnimationTimeline)
local MoveTypes = require(ReplicatedStorage.Shared.MoveTypes)
local Tokens = require(script.Parent.Parent.Parent.Parent.Tokens)
local EditorTokens = require(script.Parent.EditorTokens)
local Label = require(script.Parent.Parent.Parent.Parent.Components.Label)
local Button = require(script.Parent.Parent.Parent.Parent.Components.Button)
local Toggle = require(script.Parent.Parent.Parent.Parent.Components.Toggle)
local TextField = require(script.Parent.Parent.Parent.Parent.Components.TextField)
local Dropdown = require(script.Parent.Parent.Parent.Parent.Components.Dropdown)
local NumericField = require(script.Parent.Parent.Parent.Parent.Components.NumericField)
local DraftBinding = require(script.Parent.DraftBinding)
local Copy = require(script.Parent.Copy)

local Children = Fusion.Children
local OnEvent = Fusion.OnEvent
local peek = Fusion.peek

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>
type MoveDefinition = MoveTypes.MoveDefinition
type Clip = MoveTypes.MoveAnimationClip
type DraftContext = DraftBinding.DraftContext

local Limits = AnimationTimeline.Limits

local STRIP_HEIGHT = 96
local PHASE_BAND_HEIGHT = 14
local CLIP_BAR_HEIGHT = 12
local CLIP_ROW_HEIGHT = 28
local ROW_INDEX_WIDTH = 22
local ROW_BUTTON_WIDTH = 26

local AnimationTimelineEditorModule = {}

-- The three phases and their colours, in timeline order. Exported (rather than left file-local, as
-- it was) because PropertyEditor.lua's own Timing phase bar draws the SAME three bands from the SAME
-- AnimationTimeline.PhaseStart/PhaseEnd helpers -- two widgets in one editor showing a move's phases
-- in different colours would read as two different things. Promoted here rather than into Tokens.lua
-- on this codebase's own "promote on the second consumer, to the module that already owns it" rule:
-- these are existing accents applied to a timeline concept, not a new palette entry.
AnimationTimelineEditorModule.Phases = {
	-- Violet/crimson/blue, from EditorTokens.Phase rather than picked here: the Figma Make reference
	-- gives each phase a fixed hue and reuses it on every surface that shows a phase (this editor's
	-- bands, the frame timeline's segments, the preview's phase tabs, the stat cards' left borders).
	-- These were grey/violet/bronze when this file was the only such surface.
	{ Name = "Windup", Color = EditorTokens.Phase.Windup },
	{ Name = "Active", Color = EditorTokens.Phase.Active },
	{ Name = "Recovery", Color = EditorTokens.Phase.Recovery },
} :: { { Name: string, Color: Color3 } }

-- Wraps rather than clamps, so a clip past the end of the palette restarts at colour 1 instead of
-- silently sharing the last one with everything after it. The palette itself is EditorTokens' --
-- three of its entries were byte-identical to StatsPanel.lua's own literals before it moved there.
local function clipColor(index: number): Color3
	local palette = EditorTokens.ClipPalette
	return palette[(index - 1) % #palette + 1]
end

local function timingsOf(draft: MoveDefinition): AnimationTimeline.PhaseTimings
	return {
		WindupSeconds = draft.WindupSeconds,
		ActiveSeconds = draft.ActiveSeconds,
		RecoverySeconds = draft.RecoverySeconds,
	}
end

-- Every clip mutation funnels through here: clone the array AND the one clip being changed before
-- touching either. See DraftBinding.Apply's own header for what mutating them in place corrupts --
-- a clip table is exactly the kind of nested reference that stays shared with the previous draft.
local function applyToClip(context: DraftContext, index: number, mutate: (Clip) -> ()): ()
	DraftBinding.Apply(context, function(draft)
		local clips = table.clone(draft.Animations)
		local clip = clips[index]
		if not clip then
			return
		end
		local updated = table.clone(clip)
		mutate(updated)
		clips[index] = updated
		draft.Animations = clips
	end)
end

local function applyToClips(context: DraftContext, mutate: (clips: { Clip }) -> ()): ()
	DraftBinding.Apply(context, function(draft)
		local clips = table.clone(draft.Animations)
		mutate(clips)
		draft.Animations = clips
	end)
end

-- A TextField two-way bound to one string field of the SELECTED clip. Re-seeded whenever the draft
-- or the selection changes, so switching clips shows the new clip's text rather than the previous
-- one's -- the reason this can't just be a Computed (TextField owns a real Fusion.Value it writes
-- into as the author types).
local function clipTextRow(
	scope: Scope,
	context: DraftContext,
	selectedIndex: Fusion.Value<number>,
	labelText: string,
	placeholder: string,
	layoutOrder: number,
	getter: (Clip) -> string,
	setter: (Clip, string) -> ()
): Frame
	local localText = scope:Value("")

	local function reseed(): ()
		local draft = peek(context.Draft)
		local clip = if draft then draft.Animations[peek(selectedIndex)] else nil
		localText:set(if clip then getter(clip) else "")
	end

	scope:Observer(context.Draft):onChange(reseed)
	scope:Observer(selectedIndex):onChange(reseed)
	reseed()

	return scope:New "Frame" {
		Name = labelText,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		LayoutOrder = layoutOrder,

		[Children] = {
			scope:New "UIListLayout" {
				FillDirection = Enum.FillDirection.Vertical,
				Padding = UDim.new(0, Tokens.Space.XS),
				SortOrder = Enum.SortOrder.LayoutOrder,
			},
			Label(scope, { Text = labelText, Scale = "Body", Color = Tokens.Color.TextPrimary, LayoutOrder = 1 }),
			scope:New "Frame" {
				Name = "FieldSlot",
				Size = UDim2.fromScale(1, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				BackgroundTransparency = 1,
				LayoutOrder = 2,

				[Children] = TextField(scope, {
					Text = localText,
					PlaceholderText = placeholder,
					OnFocusLost = function(newText: string)
						applyToClip(context, peek(selectedIndex), function(clip)
							setter(clip, newText)
						end)
					end,
				}),
			},
		},
	} :: Frame
end

-- The visual schedule -- see this file's header for why it exists. Phase bands sit behind the clip
-- bars so an author can read "this clip covers all of windup and half of active" directly off the
-- strip instead of comparing four numbers.
local function timelineStrip(scope: Scope, context: DraftContext, selectedIndex: Fusion.Value<number>): Frame
	local schedule = scope:Computed(function(use)
		local draft = use(context.Draft)
		if not draft then
			return {} :: { AnimationTimeline.ScheduledClip }
		end
		return AnimationTimeline.Resolve(draft.Animations, timingsOf(draft))
	end)

	local totalSeconds = scope:Computed(function(use)
		local draft = use(context.Draft)
		if not draft then
			return 1
		end
		return math.max(AnimationTimeline.TotalDuration(timingsOf(draft)), 1e-3)
	end)

	local stripChildren: { Instance } = {
		scope:New "UIStroke" {
			Color = Tokens.Border.Standard.Color,
			Thickness = 1,
			Transparency = Tokens.Border.Standard.Transparency,
		},
	}

	-- Phase bands. Three fixed frames whose widths track the move's own timing.
	local phases = AnimationTimelineEditorModule.Phases
	for index, phase in ipairs(phases) do
		local phaseName = phase.Name :: AnimationTimeline.MovePhase
		table.insert(
			stripChildren,
			scope:New "Frame" {
				Name = phase.Name .. "Band",
				Size = scope:Computed(function(use)
					local draft = use(context.Draft)
					if not draft then
						return UDim2.fromScale(0, 0)
					end
					local timings = timingsOf(draft)
					local span = AnimationTimeline.PhaseEnd(timings, phaseName)
						- AnimationTimeline.PhaseStart(timings, phaseName)
					return UDim2.new(span / use(totalSeconds), 0, 0, PHASE_BAND_HEIGHT)
				end),
				Position = scope:Computed(function(use)
					local draft = use(context.Draft)
					if not draft then
						return UDim2.fromScale(0, 0)
					end
					local start = AnimationTimeline.PhaseStart(timingsOf(draft), phaseName)
					return UDim2.fromScale(start / use(totalSeconds), 0)
				end),
				BackgroundColor3 = phase.Color,
				BackgroundTransparency = 0.75,
				BorderSizePixel = 0,
				LayoutOrder = index,

				[Children] = Label(scope, {
					Text = phase.Name,
					Scale = "Detail",
					Color = Tokens.Color.TextSecondary,
					Size = UDim2.fromScale(1, 1),
					TextXAlignment = Enum.TextXAlignment.Center,
				}),
			}
		)
	end

	-- One bar per possible clip, positioned from the resolved schedule. The schedule is ordered by
	-- play order, not by array index, so bar N is "the Nth clip to play" -- which is what the author
	-- is reading the strip for.
	for slot = 1, Limits.MaxClips do
		local entry = scope:Computed(function(use)
			return (use(schedule) :: { AnimationTimeline.ScheduledClip })[slot]
		end)
		table.insert(
			stripChildren,
			scope:New "TextButton" {
				Name = "ClipBar" .. slot,
				Size = scope:Computed(function(use)
					local scheduled = use(entry)
					if not scheduled then
						return UDim2.fromScale(0, 0)
					end
					-- Floored at a hairline so a clip squeezed to zero duration (its window was cut
					-- short by an Exclusive clip, or the move's timing shrank under it) still shows
					-- as a mark the author can see and click rather than vanishing silently.
					local width = math.max(scheduled.DurationSeconds / use(totalSeconds), 0.004)
					return UDim2.new(width, 0, 0, CLIP_BAR_HEIGHT)
				end),
				Position = scope:Computed(function(use)
					local scheduled = use(entry)
					if not scheduled then
						return UDim2.fromScale(0, 0)
					end
					return UDim2.new(
						scheduled.StartSeconds / use(totalSeconds),
						0,
						0,
						PHASE_BAND_HEIGHT + Tokens.Space.XS + (slot - 1) * (CLIP_BAR_HEIGHT + 2)
					)
				end),
				BackgroundColor3 = clipColor(slot),
				-- A clip another clip cut short is dimmed, so "my clip is being truncated" is visible
				-- on the strip and not only in the detail form's readout.
				BackgroundTransparency = scope:Computed(function(use)
					local scheduled = use(entry)
					return if scheduled and scheduled.StoppedBy == "Exclusive" then 0.5 else 0.1
				end),
				BorderSizePixel = 0,
				AutoButtonColor = false,
				Text = "",
				Visible = scope:Computed(function(use)
					return use(entry) ~= nil
				end),

				-- Clicking a bar selects that clip below -- the strip doubles as navigation, which is
				-- the natural gesture once you've spotted the overlap you wanted to fix.
				[OnEvent "Activated"] = function()
					local scheduled = peek(entry)
					local draft = peek(context.Draft)
					if not scheduled or not draft then
						return
					end
					for index, clip in ipairs(draft.Animations) do
						if clip.ClipId == scheduled.Clip.ClipId then
							selectedIndex:set(index)
							return
						end
					end
				end,
			}
		)
	end

	return scope:New "Frame" {
		Name = "TimelineStrip",
		Size = UDim2.new(1, 0, 0, STRIP_HEIGHT),
		BackgroundColor3 = Tokens.Wash.Inset.Color,
		BackgroundTransparency = Tokens.Wash.Inset.Transparency,
		BorderSizePixel = 0,
		ClipsDescendants = true,
		LayoutOrder = 3,

		[Children] = stripChildren,
	} :: Frame
end

-- One compact row in the clip list. Selection, enable/disable, reorder and delete only -- every
-- other control lives in the shared detail form below.
local function clipRow(scope: Scope, context: DraftContext, selectedIndex: Fusion.Value<number>, slot: number): Frame
	local clip = scope:Computed(function(use)
		local draft = use(context.Draft)
		return if draft then draft.Animations[slot] else nil
	end)
	local exists = scope:Computed(function(use)
		return use(clip) ~= nil
	end)
	local isSelected = scope:Computed(function(use)
		return use(selectedIndex) == slot
	end)

	-- Reorder rewrites the two clips' Order fields rather than moving array entries -- Order is what
	-- AnimationTimeline.Resolve actually sorts on, and leaving the array alone keeps every clip's
	-- position (and so its ClipId, and so this row's binding) stable while it moves in the schedule.
	local function swapOrderWith(otherSlot: number): ()
		applyToClips(context, function(clips)
			local first, second = clips[slot], clips[otherSlot]
			if not first or not second then
				return
			end
			local updatedFirst = table.clone(first)
			local updatedSecond = table.clone(second)
			updatedFirst.Order, updatedSecond.Order = second.Order, first.Order
			clips[slot] = updatedFirst
			clips[otherSlot] = updatedSecond
		end)
	end

	return scope:New "TextButton" {
		Name = "ClipRow" .. slot,
		Size = UDim2.new(1, 0, 0, CLIP_ROW_HEIGHT),
		BackgroundColor3 = Tokens.Wash.AccentFill.Color,
		BackgroundTransparency = scope:Computed(function(use)
			return if use(isSelected) then Tokens.Wash.AccentFill.Transparency else 1
		end),
		BorderSizePixel = 0,
		AutoButtonColor = false,
		Text = "",
		LayoutOrder = slot,
		Visible = exists,

		[OnEvent "Activated"] = function()
			selectedIndex:set(slot)
		end,

		[Children] = {
			scope:New "UIListLayout" {
				FillDirection = Enum.FillDirection.Horizontal,
				VerticalAlignment = Enum.VerticalAlignment.Center,
				Padding = UDim.new(0, Tokens.Space.XS),
				SortOrder = Enum.SortOrder.LayoutOrder,
			},
			scope:New "Frame" {
				Name = "Swatch",
				Size = UDim2.fromOffset(4, CLIP_ROW_HEIGHT),
				BackgroundColor3 = clipColor(slot),
				BorderSizePixel = 0,
				LayoutOrder = 1,
			},
			Label(scope, {
				Text = scope:Computed(function(use)
					local entry = use(clip)
					return if entry then tostring(entry.Order) else ""
				end),
				Scale = "Detail",
				Color = Tokens.Color.TextSecondary,
				Size = UDim2.fromOffset(ROW_INDEX_WIDTH, CLIP_ROW_HEIGHT),
				TextXAlignment = Enum.TextXAlignment.Center,
				LayoutOrder = 2,
			}),
			Label(scope, {
				Text = scope:Computed(function(use)
					local entry = use(clip)
					if not entry then
						return ""
					end
					-- A clip with no asset yet, or one switched off, says so here rather than only in
					-- the detail form -- both are states where the clip silently does nothing at
					-- runtime, which is exactly the thing an author needs surfaced in the list.
					if not entry.Enabled then
						return entry.Name .. "  (off)"
					end
					if entry.AnimationId == "" then
						return entry.Name .. "  (no asset)"
					end
					return entry.Name
				end),
				Scale = "Body",
				Color = scope:Computed(function(use)
					local entry = use(clip)
					if entry and (not entry.Enabled or entry.AnimationId == "") then
						return Tokens.Color.TextDisabled
					end
					return if use(isSelected) then Tokens.Color.TextPrimary else Tokens.Color.TextSecondary
				end),
				Size = UDim2.new(1, -(ROW_INDEX_WIDTH + ROW_BUTTON_WIDTH * 3 + Tokens.Space.XS * 6 + 4), 1, 0),
				LayoutOrder = 3,
			}),
			Button(scope, {
				Text = "^",
				Size = UDim2.fromOffset(ROW_BUTTON_WIDTH, CLIP_ROW_HEIGHT - 4),
				LayoutOrder = 4,
				OnActivated = function()
					swapOrderWith(slot - 1)
				end,
			}),
			Button(scope, {
				Text = "v",
				Size = UDim2.fromOffset(ROW_BUTTON_WIDTH, CLIP_ROW_HEIGHT - 4),
				LayoutOrder = 5,
				OnActivated = function()
					swapOrderWith(slot + 1)
				end,
			}),
			Button(scope, {
				Text = "X",
				Size = UDim2.fromOffset(ROW_BUTTON_WIDTH, CLIP_ROW_HEIGHT - 4),
				LayoutOrder = 6,
				OnActivated = function()
					applyToClips(context, function(clips)
						table.remove(clips, slot)
					end)
					-- Keep the selection on a row that still exists.
					if peek(selectedIndex) > slot then
						selectedIndex:set(peek(selectedIndex) - 1)
					end
					selectedIndex:set(math.max(1, math.min(peek(selectedIndex), slot)))
				end,
			}),
		},
	} :: Frame
end

-- Every per-clip control, bound to whichever clip is selected. Mounted once -- see this file's
-- header for why there is one shared form rather than one per clip.
local function detailForm(scope: Scope, context: DraftContext, selectedIndex: Fusion.Value<number>): Frame
	local selectedClip = scope:Computed(function(use)
		local draft = use(context.Draft)
		return if draft then draft.Animations[use(selectedIndex)] else nil
	end)
	local hasClip = scope:Computed(function(use)
		return use(selectedClip) ~= nil
	end)

	-- Reads one field off the selected clip, defaulting while nothing is selected -- the clip-scoped
	-- counterpart of DraftBinding.Field, which reads off the draft itself.
	local function clipField<T>(getter: (Clip) -> T, default: T): Fusion.Computed<T>
		return scope:Computed(function(use)
			local clip = use(selectedClip)
			return if clip then getter(clip) else default
		end)
	end

	local function numberField(
		labelText: string,
		unit: string,
		layoutOrder: number,
		minimum: number,
		maximum: number,
		steps: { number },
		decimals: number,
		getter: (Clip) -> number,
		setter: (Clip, number) -> (),
		visible: UsedAs<boolean>?
	)
		return NumericField.Mount(scope, {
			Label = labelText,
			Unit = unit,
			Value = clipField(getter, minimum),
			Min = minimum,
			Max = maximum,
			Steps = steps,
			Decimals = decimals,
			LayoutOrder = layoutOrder,
			Visible = visible,
			OnChanged = function(value: number)
				applyToClip(context, peek(selectedIndex), function(clip)
					setter(clip, value)
				end)
			end,
		})
	end

	local function dropdown(
		labelText: string,
		layoutOrder: number,
		options: { string },
		getter: (Clip) -> string,
		setter: (Clip, string) -> ()
	)
		local built: { { Value: string, Text: string } } = {}
		for _, option in ipairs(options) do
			table.insert(built, { Value = option, Text = option })
		end
		return Dropdown.Mount(scope, {
			Label = labelText,
			Options = built,
			Value = clipField(getter, options[1]),
			LayoutOrder = layoutOrder,
			OnChanged = function(value: string)
				applyToClip(context, peek(selectedIndex), function(clip)
					setter(clip, value)
				end)
			end,
		})
	end

	local startsByTime = clipField(function(clip)
		return clip.StartMode == "Time"
	end, true)
	local startsByPhase = clipField(function(clip)
		return clip.StartMode == "Phase"
	end, false)
	local stopsByDuration = clipField(function(clip)
		return clip.StopMode == "Duration"
	end, false)

	-- The resolved window for this clip, in words. Reading a clip's authored StartMode/StopMode and
	-- working out what they produce is exactly the arithmetic the author should not have to do --
	-- and it's the only place Queue delays and Exclusive truncations are stated outright.
	local resolvedSummary = scope:Computed(function(use)
		local draft = use(context.Draft)
		local clip = use(selectedClip)
		if not draft or not clip then
			return ""
		end
		for _, scheduled in ipairs(AnimationTimeline.Resolve(draft.Animations, timingsOf(draft))) do
			if scheduled.Clip.ClipId ~= clip.ClipId then
				continue
			end
			local text = string.format(
				"Plays %.2fs -> %.2fs (%.2fs)",
				scheduled.StartSeconds,
				scheduled.StopSeconds,
				scheduled.DurationSeconds
			)
			if scheduled.DelayedByQueue then
				text ..= "  -- start pushed back by Queue"
			end
			if scheduled.StoppedBy == "Exclusive" then
				text ..= "  -- cut short by a later Exclusive clip"
			elseif scheduled.LetPlayOut then
				text ..= "  -- ends on its own"
			end
			return text
		end
		if not clip.Enabled then
			return "Disabled -- this clip never plays."
		end
		if clip.AnimationId == "" then
			return "No animation id -- this clip never plays."
		end
		return ""
	end)

	return scope:New "Frame" {
		Name = "ClipDetail",
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		LayoutOrder = 6,
		Visible = hasClip,

		[Children] = {
			scope:New "UIListLayout" {
				FillDirection = Enum.FillDirection.Vertical,
				Padding = UDim.new(0, Tokens.Space.S),
				SortOrder = Enum.SortOrder.LayoutOrder,
			},

			Label(scope, {
				Text = resolvedSummary,
				Scale = "Detail",
				Color = Tokens.Color.AccentPrimaryBright,
				TextWrapped = true,
				LineHeight = Tokens.Leading.Prose,
				-- Fixed height, deliberately -- see HitboxEditor.lua's identical note. `resolvedSummary`
				-- is a live Computed that recomputes as the author drags a timing field, so putting it
				-- on Label.lua's AutoHeight mode would re-measure this ScrollingFrame's canvas mid-drag.
				-- The three static prose labels further down this same file DID move to AutoHeight.
				Size = UDim2.new(1, 0, 0, 30),
				LayoutOrder = 1,
			}),

			clipTextRow(scope, context, selectedIndex, "Clip Name", "Slash", 2, function(clip)
				return clip.Name
			end, function(clip, value)
				clip.Name = value
			end),
			clipTextRow(
				scope,
				context,
				selectedIndex,
				"Animation Id (rbxassetid://...)",
				"rbxassetid://0",
				3,
				function(clip)
					return clip.AnimationId
				end,
				function(clip, value)
					clip.AnimationId = value
				end
			),

			scope:New "Frame" {
				Name = "EnabledRow",
				Size = UDim2.fromScale(1, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				BackgroundTransparency = 1,
				LayoutOrder = 4,

				[Children] = Toggle(scope, {
					Label = "Enabled",
					Value = clipField(function(clip)
						return clip.Enabled
					end, false),
					OnChanged = function(enabled: boolean)
						applyToClip(context, peek(selectedIndex), function(clip)
							clip.Enabled = enabled
						end)
					end,
				}),
			},

			dropdown("Start", 5, AnimationTimeline.StartModeOrder :: { string }, function(clip)
				return clip.StartMode
			end, function(clip, value)
				clip.StartMode = value :: AnimationTimeline.ClipStartMode
			end),
			numberField(
				"Start Time",
				"seconds",
				6,
				Limits.MinStartTime,
				Limits.MaxStartTime,
				{ 0.01, 0.1 },
				2,
				function(clip)
					return clip.StartTime
				end,
				function(clip, value)
					clip.StartTime = value
				end,
				startsByTime
			),
			-- Dropdown.lua has no Visible prop of its own, so the one control that only applies under
			-- a specific StartMode is wrapped -- the same idiom used for every conditionally-shown
			-- Toggle on this screen. Start Time above gets the mirror treatment through
			-- NumericField's own Visible prop.
			scope:New "Frame" {
				Name = "StartPhaseSlot",
				Size = UDim2.fromScale(1, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				BackgroundTransparency = 1,
				LayoutOrder = 7,
				Visible = startsByPhase,

				[Children] = dropdown("Start Phase", 1, AnimationTimeline.PhaseOrder :: { string }, function(clip)
					return clip.StartPhase
				end, function(clip, value)
					clip.StartPhase = value :: AnimationTimeline.MovePhase
				end),
			},
			numberField(
				"Start Delay",
				"seconds",
				8,
				Limits.MinStartDelay,
				Limits.MaxStartDelay,
				{ 0.01, 0.1 },
				2,
				function(clip)
					return clip.StartDelay
				end,
				function(clip, value)
					clip.StartDelay = value
				end
			),

			dropdown("Stop", 9, AnimationTimeline.StopModeOrder :: { string }, function(clip)
				return clip.StopMode
			end, function(clip, value)
				clip.StopMode = value :: AnimationTimeline.ClipStopMode
			end),
			numberField(
				"Duration",
				"seconds",
				10,
				Limits.MinDuration,
				Limits.MaxDuration,
				{ 0.01, 0.1 },
				2,
				function(clip)
					return clip.DurationSeconds
				end,
				function(clip, value)
					clip.DurationSeconds = value
				end,
				stopsByDuration
			),

			DraftBinding.Row(scope, 11, 2, {
				numberField("Speed", "x", 1, Limits.MinSpeed, Limits.MaxSpeed, { 0.05, 0.25 }, 2, function(clip)
					return clip.Speed
				end, function(clip, value)
					clip.Speed = value
				end),
				numberField("Weight", "", 2, Limits.MinWeight, Limits.MaxWeight, { 0.05, 0.5 }, 2, function(clip)
					return clip.Weight
				end, function(clip, value)
					clip.Weight = value
				end),
			}),
			DraftBinding.Row(scope, 12, 2, {
				numberField("Fade In", "seconds", 1, Limits.MinFade, Limits.MaxFade, { 0.01, 0.1 }, 2, function(clip)
					return clip.FadeInSeconds
				end, function(clip, value)
					clip.FadeInSeconds = value
				end),
				numberField("Fade Out", "seconds", 2, Limits.MinFade, Limits.MaxFade, { 0.01, 0.1 }, 2, function(clip)
					return clip.FadeOutSeconds
				end, function(clip, value)
					clip.FadeOutSeconds = value
				end),
			}),

			scope:New "Frame" {
				Name = "LoopedRow",
				Size = UDim2.fromScale(1, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				BackgroundTransparency = 1,
				LayoutOrder = 13,

				[Children] = Toggle(scope, {
					Label = "Loop until stopped",
					Value = clipField(function(clip)
						return clip.Looped
					end, false),
					OnChanged = function(looped: boolean)
						applyToClip(context, peek(selectedIndex), function(clip)
							clip.Looped = looped
						end)
					end,
				}),
			},

			dropdown("When another clip starts", 14, AnimationTimeline.BlendOrder :: { string }, function(clip)
				return clip.Blend
			end, function(clip, value)
				clip.Blend = value :: AnimationTimeline.ClipBlend
			end),
			Label(scope, {
				Text = "Overlap: ignore the others. Exclusive: cut short whatever is still playing when this starts. "
					.. "Queue: never start before the previous clip has finished.",
				Scale = "Detail",
				Color = Tokens.Color.TextSecondary,
				AutoHeight = true,
				LineHeight = Tokens.Leading.Prose,
				Size = UDim2.fromScale(1, 0),
				LayoutOrder = 15,
			}),

			dropdown("If the move is interrupted", 16, AnimationTimeline.InterruptOrder :: { string }, function(clip)
				return clip.OnInterrupt
			end, function(clip, value)
				clip.OnInterrupt = value :: AnimationTimeline.ClipInterrupt
			end),
			Label(scope, {
				Text = "Stop: end immediately. Freeze: hold the current pose. PlayThrough: let it finish anyway.",
				Scale = "Detail",
				Color = Tokens.Color.TextSecondary,
				AutoHeight = true,
				LineHeight = Tokens.Leading.Prose,
				Size = UDim2.fromScale(1, 0),
				LayoutOrder = 17,
			}),

			-- LAST, and the least often touched: Action is right for essentially every clip authored
			-- here, and the only reason to move it is a specific problem (a clip that should sit under
			-- locomotion, or one being hidden by it). PreviewViewport applies this to the real
			-- AnimationTrack, so the effect is visible in the preview rather than only at test-fire.
			dropdown("Animation layer", 18, AnimationTimeline.PriorityOrder :: { string }, function(clip)
				return clip.Priority
			end, function(clip, value)
				clip.Priority = value :: AnimationTimeline.ClipPriority
			end),
			Label(scope, {
				Text = Copy.Field("Animation.Priority").Hint,
				Scale = "Detail",
				Color = Tokens.Color.TextSecondary,
				AutoHeight = true,
				LineHeight = Tokens.Leading.Prose,
				Size = UDim2.fromScale(1, 0),
				LayoutOrder = 19,
			}),
		},
	} :: Frame
end

-- Returns the section's content children -- PropertyEditor.lua's own sectionContent supplies the
-- card chrome, same as every other section.
function AnimationTimelineEditorModule.Build(scope: Scope, context: DraftContext): { Instance }
	local selectedIndex = scope:Value(1)

	local clipCount = scope:Computed(function(use)
		local draft = use(context.Draft)
		return if draft then #draft.Animations else 0
	end)

	local rows: { Instance } = {
		scope:New "UIListLayout" {
			FillDirection = Enum.FillDirection.Vertical,
			Padding = UDim.new(0, 2),
			SortOrder = Enum.SortOrder.LayoutOrder,
		},
	}
	for slot = 1, Limits.MaxClips do
		table.insert(rows, clipRow(scope, context, selectedIndex, slot))
	end

	return {
		Label(scope, {
			Text = "Clips play on the move's own timeline. Add as many as you need, set when each starts and stops, "
				.. "and use the strip below to see how they overlap.",
			Scale = "Detail",
			Color = Tokens.Color.TextSecondary,
			AutoHeight = true,
			LineHeight = Tokens.Leading.Prose,
			Size = UDim2.fromScale(1, 0),
			LayoutOrder = 2,
		}),

		timelineStrip(scope, context, selectedIndex),

		scope:New "Frame" {
			Name = "ClipList",
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			LayoutOrder = 4,

			[Children] = rows,
		},

		scope:New "Frame" {
			Name = "AddClipRow",
			Size = UDim2.new(1, 0, 0, Tokens.Control.RowHeight),
			BackgroundTransparency = 1,
			LayoutOrder = 5,

			[Children] = {
				scope:New "UIListLayout" {
					FillDirection = Enum.FillDirection.Horizontal,
					VerticalAlignment = Enum.VerticalAlignment.Center,
					Padding = UDim.new(0, Tokens.Space.S),
					SortOrder = Enum.SortOrder.LayoutOrder,
				},
				Button(scope, {
					Text = "+ Add Clip",
					Size = UDim2.fromOffset(120, Tokens.Control.RowHeight - 6),
					LayoutOrder = 1,
					Disabled = scope:Computed(function(use)
						return use(clipCount) >= Limits.MaxClips
					end),
					OnActivated = function()
						local draft = peek(context.Draft)
						if not draft or #draft.Animations >= Limits.MaxClips then
							return
						end
						local newIndex = #draft.Animations + 1
						applyToClips(context, function(clips)
							-- Ordered after every existing clip and, when there is a previous one,
							-- chained off it -- so repeatedly pressing Add builds a sequence rather
							-- than a pile of clips all starting at zero, which is what an author
							-- adding a second clip almost always means.
							local clip = AnimationTimeline.DefaultClip(AnimationTimeline.NextClipId(clips), newIndex)
							if newIndex > 1 then
								clip.StartMode = "AfterPrevious"
							end
							table.insert(clips, clip)
						end)
						selectedIndex:set(newIndex)
					end,
				}),
				Label(scope, {
					Text = scope:Computed(function(use)
						return string.format("%d / %d clips", use(clipCount), Limits.MaxClips)
					end),
					Scale = "Detail",
					Color = Tokens.Color.TextSecondary,
					Size = UDim2.fromOffset(90, Tokens.Control.RowHeight),
					LayoutOrder = 2,
				}),
			},
		},

		detailForm(scope, context, selectedIndex),
	}
end

return AnimationTimelineEditorModule
