--!strict
--[[
	EmoteWheel/init.lua

	Owns: the radial emote wheel's pure presentation -- a ScreenGui with one WheelSegment.lua tile per
	loadout slot, arranged in a circle via WheelSelection's placement math, plus a center readout
	showing whichever segment is currently selected. Mirrors this codebase's existing Screens/<Name>/
	init.lua shape (DevMenu/init.lua, Menus/init.lua): Mount(scope, playerGui, clientState) returns a
	*Handle table (IsOpen/SelectedIndex, both plain Fusion.Values) that Client/Emotes/
	EmoteWheelClient.lua drives from outside -- the same "screen exposes state/signals, client module
	drives from outside" boundary CombatFeedback/DevMenu already establish. This module does NO input
	handling and NO networking: it never touches UserInputService, KeybindManager, or NetworkBridge,
	and never calls EmoteController itself -- see EmoteWheelClient.lua for all of that.

	Segment count is read from #peek(clientState.EmoteLoadout) at every render, never hardcoded to
	EmoteConstants.LoadoutSize (8) -- see that constant's own header. Segments are built via
	scope:ForPairs keyed by loadout INDEX (not emoteId), the same "keyed by a stable identity, not by
	value" reasoning Sidebar.lua's own playerRosterRow ForPairs already documents: a wheel POSITION is
	the stable thing here, and RequestSetLoadoutSlot can freely change which EmoteId occupies a given
	index without the segment at that position being torn down and rebuilt -- only its own props
	recompute. Only the one segment whose own Selected boolean actually flips re-tweens (see
	WheelSegment.lua's own header on why a Computed feeding a Spring is what buys this for free).

	Open/close transition: a single scope:Spring (0 while closed, springs to 1 while open, and back
	down on close) drives both a CanvasGroup.GroupTransparency fade and a UIScale scale-in, targeting
	roughly the same feel as Tokens.Motion.EnterTween ("a whole screen entering") in both directions --
	this is a hold-to-open/release-to-close gesture, not a one-way entrance, so "for open... a
	comparably snappy reverse for close" (this feature's own design brief) means symmetric timing, not
	two different curves. Per that brief's own explicit requirement, this must not read as slow: the
	spring is tuned snappier than Tokens.Motion.FadeSpring (the closest existing preset, used for a
	one-shot entrance that never needs to reverse quickly) since this needs to disappear the instant a
	player releases mid-fight, not linger.

	ScreenGui.Enabled deliberately does NOT bind directly to IsOpen the way Menus.lua/DevMenu/init.lua
	bind theirs -- those two screens have no animated close of their own (an instant Enabled toggle is
	correct for them), but binding Enabled straight to IsOpen here would cut the close reverse-tween
	off before a single frame of it rendered, since Roblox stops presenting everything under a disabled
	ScreenGui instantly. A local scope:Observer(isOpen) instead keeps the ScreenGui enabled for exactly
	CLOSE_ANIMATION_SECONDS after IsOpen goes false, so the close animation this file's own header
	promises is actually visible -- this is a screen-owned presentation timing detail, not new input
	handling, and never reaches outside this module (EmoteWheelClient.lua only ever reads/writes the
	two Values on the returned handle, unaffected by this internal delay).

	CanvasGroup risk (unverified, matches Screens/Onboarding/init.lua's own caveat for the identical
	technique): a live Studio pass hasn't confirmed UIStroke renders correctly on the chamfered
	segments' own borders while composited inside a CanvasGroup. Accepted here for the same reason
	Onboarding accepts it -- abandoning CanvasGroup would mean abandoning the fade+scale entrance this
	feature explicitly asks for.

	Does not own: which emote plays or which loadout slot gets written (Client/Emotes/
	EmoteController.lua, called only from EmoteWheelClient.lua), or deciding when the wheel opens/
	closes/confirms/cancels (EmoteWheelClient.lua, driving IsOpen/SelectedIndex from outside).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Types = require(ReplicatedStorage.Shared.Types)
local EmoteRegistry = require(ReplicatedStorage.Shared.Emotes.EmoteRegistry)

local Tokens = require(script.Parent.Parent.Tokens)
local Layers = require(script.Parent.Parent.Shell.Layers)
local Surface = require(script.Parent.Parent.Shell.Surface)
local Label = require(script.Parent.Parent.Components.Label)
local ClientStateModule = require(script.Parent.Parent.State.ClientState)
local WheelSelection = require(script.WheelSelection)
local WheelSegment = require(script.WheelSegment)

local Children = Fusion.Children
local peek = Fusion.peek

type Scope = Fusion.Scope<typeof(Fusion)>
type ClientState = ClientStateModule.ClientState

export type EmoteWheelHandle = {
	IsOpen: Fusion.Value<boolean>,
	SelectedIndex: Fusion.Value<number?>,
}

local EmoteWheel = {}

-- Distance from the wheel's own center to each segment's center point.
local WHEEL_RADIUS = 130
local SEGMENT_SIZE = UDim2.fromOffset(92, 92)
local CENTER_READOUT_SIZE = UDim2.fromOffset(220, 90)

-- Snappier than Tokens.Motion.FadeSpring (14, 0.7) -- see file header on why this needs to settle
-- faster than that one-shot-entrance preset in BOTH directions.
local OPEN_SPRING_SPEED = 20
local OPEN_SPRING_DAMPING = 1

-- How long the ScreenGui stays enabled after IsOpen goes false, so the close reverse-tween the
-- spring above produces actually gets to render before this screen stops presenting entirely. Comfortably
-- covers OPEN_SPRING_SPEED/OPEN_SPRING_DAMPING's own settle time (critically damped springs settle
-- to within ~5% by roughly 3/Speed seconds -- 3/20 = 0.15s) with margin for a slow frame.
local CLOSE_ANIMATION_SECONDS = 0.25

local function centerOffsetPosition(offset: Vector2): UDim2
	return UDim2.fromScale(0.5, 0.5) + UDim2.fromOffset(offset.X, offset.Y)
end

function EmoteWheel.Mount(
	scope: Scope,
	playerGui: PlayerGui,
	clientState: ClientState,
	scale: Fusion.UsedAs<number>
): EmoteWheelHandle
	local isOpen = scope:Value(false)
	local selectedIndex: Fusion.Value<number?> = scope:Value(nil :: number?)

	-- See file header's "ScreenGui.Enabled deliberately does NOT bind directly to IsOpen" section.
	local screenEnabled = scope:Value(false)
	local closeGeneration = 0
	scope:Observer(isOpen):onChange(function()
		closeGeneration += 1
		if peek(isOpen) then
			screenEnabled:set(true)
			return
		end
		local generation = closeGeneration
		task.delay(CLOSE_ANIMATION_SECONDS, function()
			if generation == closeGeneration then
				screenEnabled:set(false)
			end
		end)
	end)

	local openProgress = scope:Spring(
		scope:Computed(function(use)
			return if use(isOpen) then 1 else 0
		end),
		OPEN_SPRING_SPEED,
		OPEN_SPRING_DAMPING
	)

	local groupTransparency = scope:Computed(function(use)
		return 1 - use(openProgress)
	end)

	local scaleMultiplier = scope:Computed(function(use)
		return 0.85 + use(openProgress) * 0.15
	end)

	local segmentCount = scope:Computed(function(use)
		return #use(clientState.EmoteLoadout)
	end)

	local segments = scope:ForPairs(clientState.EmoteLoadout, function(_use, innerScope, index, emoteId)
		local definition = EmoteRegistry.Get(emoteId)
		if not definition then
			-- Defensive only -- a loadout slot naming a since-retired/unknown EmoteId should never
			-- crash the wheel; it simply renders no tile at that position rather than guessing at
			-- placeholder content (this codebase's own "never fabricate" reflex, see EmoteDefinitions.
			-- lua's own header).
			return index, nil
		end

		local position = innerScope:Computed(function(use)
			return centerOffsetPosition(WheelSelection.GetSegmentPosition(index, use(segmentCount), WHEEL_RADIUS))
		end)
		local selected = innerScope:Computed(function(use)
			return use(selectedIndex) == index
		end)

		return index,
			WheelSegment(innerScope, {
				Emote = definition :: Types.EmoteDefinition,
				Selected = selected,
				Size = SEGMENT_SIZE,
				Position = position,
				AnchorPoint = Vector2.new(0.5, 0.5),
			})
	end)

	local centerEmote = scope:Computed(function(use)
		local index = use(selectedIndex)
		if not index then
			return nil
		end
		local loadout = use(clientState.EmoteLoadout)
		local emoteId = loadout[index]
		if not emoteId then
			return nil
		end
		return EmoteRegistry.Get(emoteId)
	end)

	local centerNameText = scope:Computed(function(use)
		local definition = use(centerEmote)
		return if definition then definition.DisplayName else ""
	end)
	local centerDescriptionText = scope:Computed(function(use)
		local definition = use(centerEmote)
		return if definition and definition.Description then definition.Description else ""
	end)
	local centerVisible = scope:Computed(function(use)
		return use(centerEmote) ~= nil
	end)

	-- Layers.Overlay, replacing a bare DisplayOrder = 10 that collided EXACTLY with the number
	-- Screens/Onboarding used to carry. That was harmless only because the two are never simultaneously
	-- mounted -- a fact nothing enforced and nobody would have noticed breaking. See Shell/Layers.lua.
	--
	-- Scaled, and the scale it takes is NOT the one already inside this screen: the UIScale on the
	-- CanvasGroup below runs 0.85 -> 1.0 off openProgress and is the wheel's entrance, nothing to do
	-- with the size of the player's monitor. The two multiply, which is what should happen.
	Surface.New(scope, {
		Name = "EmoteWheel",
		Layer = Layers.Overlay,
		Parent = playerGui,
		Scaled = true,
		Scale = scale,
		Enabled = screenEnabled,

		Children = scope:New "CanvasGroup" {
			Name = "Root",
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			GroupTransparency = groupTransparency,

			[Children] = {
				scope:New "UIScale" {
					Scale = scaleMultiplier,
				},

				-- Dims the gameplay behind the wheel so text-only segments stay legible over any
				-- background -- a plain full-screen wash, not a themed Panel (nothing here is a
				-- bordered surface).
				scope:New "Frame" {
					Name = "Scrim",
					Size = UDim2.fromScale(1, 1),
					BackgroundColor3 = Tokens.Wash.RailScrim.Color,
					BackgroundTransparency = Tokens.Wash.RailScrim.Transparency,
					BorderSizePixel = 0,
					ZIndex = 0,
				},

				scope:New "Frame" {
					Name = "Wheel",
					AnchorPoint = Vector2.new(0.5, 0.5),
					Position = UDim2.fromScale(0.5, 0.5),
					Size = UDim2.fromOffset(0, 0),
					BackgroundTransparency = 1,
					ZIndex = 1,

					[Children] = {
						segments,

						scope:New "Frame" {
							Name = "CenterReadout",
							AnchorPoint = Vector2.new(0.5, 0.5),
							Position = UDim2.fromScale(0.5, 0.5),
							Size = CENTER_READOUT_SIZE,
							BackgroundTransparency = 1,
							Visible = centerVisible,
							ZIndex = 2,

							[Children] = {
								Label(scope, {
									Text = centerNameText,
									Scale = "CardTitle",
									Color = Tokens.Color.AccentPrimaryBright,
									AnchorPoint = Vector2.new(0.5, 0.5),
									Position = UDim2.fromScale(0.5, 0.35),
									Size = UDim2.fromScale(1, 0.4),
									TextXAlignment = Enum.TextXAlignment.Center,
								}),
								Label(scope, {
									Text = centerDescriptionText,
									Scale = "Detail",
									Color = Tokens.Color.TextSecondary,
									AnchorPoint = Vector2.new(0.5, 0.5),
									Position = UDim2.fromScale(0.5, 0.68),
									Size = UDim2.fromScale(1, 0.4),
									TextXAlignment = Enum.TextXAlignment.Center,
									TextWrapped = true,
								}),
							},
						},
					},
				},
			},
		},
	})

	return {
		IsOpen = isOpen,
		SelectedIndex = selectedIndex,
	}
end

return EmoteWheel
