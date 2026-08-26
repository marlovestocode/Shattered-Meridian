--!strict
--[[
	EmoteWheel/init.lua

	Owns: the radial emote wheel's pure presentation, and the LAYOUT RADII every other file in this
	folder is drawn against. Four pieces compose here and nowhere else -- WheelDial.lua (the disc,
	graduation and needle), one WheelSegment.lua per loadout slot, WheelHub.lua (the centre readout),
	and a key legend under the whole assembly -- plus the vignette that separates all of it from the
	gameplay behind. Mirrors this codebase's existing Screens/<Name>/init.lua shape (DevMenu/init.lua,
	Menus/init.lua): Mount(scope, playerGui, clientState, scale) returns a *Handle table that
	Client/Emotes/EmoteWheelClient.lua drives from outside -- the same "screen exposes state/signals,
	client module drives from outside" boundary CombatFeedback/DevMenu already establish. This module
	does NO input handling and NO networking beyond reading ClientState: it never touches
	UserInputService or NetworkBridge, and never calls EmoteController itself -- see
	EmoteWheelClient.lua for all of that. (It does read KeybindManager, for the legend's letters only,
	exactly as Screens/HUD/init.lua does for its own.)

	THE GEOMETRY LIVES HERE, AND THAT IS WHY THE HANDLE CARRIES A RADIUS. HUB_RADIUS is two things at
	once: the circle WheelHub draws, and the distance inside which EmoteWheelClient refuses to resolve
	a selection at all (WheelSelection.GetSelectedIndex's dead zone). Those must be the same number or
	the wheel draws one affordance and obeys another, so the screen -- which owns its own layout --
	publishes it on the handle instead of the client module hardcoding a second copy. It is published
	ALREADY MULTIPLIED BY THE VIEWPORT SCALE, because the client compares it against a raw mouse
	position in screen pixels while everything in here is authored in unscaled pixels under
	Shell/Surface.lua's root UIScale. That multiplication is the entire reason this is a Computed on
	the handle rather than a module constant the client could have required directly.

	Segment count is read from #peek(clientState.EmoteLoadout) at every render, never hardcoded to
	EmoteConstants.LoadoutSize (8) -- see that constant's own header. Segments are built via
	scope:ForPairs keyed by loadout INDEX (not emoteId), the same "keyed by a stable identity, not by
	value" reasoning Sidebar.lua's own playerRosterRow ForPairs already documents: a wheel POSITION is
	the stable thing here, and RequestSetLoadoutSlot can freely change which EmoteId occupies a given
	index without the segment at that position being torn down and rebuilt -- only its own props
	recompute. Only the one segment whose own Selected boolean actually flips re-tweens (see
	WheelSegment.lua's own header on why a Computed feeding a Spring is what buys this for free).

	Open/close transition: a single scope:Spring (0 while closed, springs to 1 while open, and back
	down on close) drives a CanvasGroup.GroupTransparency fade, a UIScale scale-in, the graduation's
	entrance sweep (WheelDial) and each tile's staggered radial bloom (WheelSegment) -- one animating
	value, four things reading it, no timers anywhere. Per this feature's own design brief the close
	must be a comparably snappy reverse rather than a different curve, so the spring is tuned snappier
	than Tokens.Motion.FadeSpring (the closest existing preset, used for a one-shot entrance that
	never needs to reverse quickly): this has to disappear the instant a player releases mid-fight,
	not linger.

	ScreenGui.Enabled deliberately does NOT bind directly to IsOpen the way Menus.lua/DevMenu/init.lua
	bind theirs -- those two screens have no animated close of their own (an instant Enabled toggle is
	correct for them), but binding Enabled straight to IsOpen here would cut the close reverse-tween
	off before a single frame of it rendered, since Roblox stops presenting everything under a disabled
	ScreenGui instantly. A local scope:Observer(isOpen) instead keeps the ScreenGui enabled for exactly
	CLOSE_ANIMATION_SECONDS after IsOpen goes false, so the close animation this file's own header
	promises is actually visible -- this is a screen-owned presentation timing detail, not new input
	handling, and never reaches outside this module (EmoteWheelClient.lua only ever reads/writes the
	Values on the returned handle, unaffected by this internal delay).

	CanvasGroup risk (unverified, matches Screens/Onboarding/init.lua's own caveat for the identical
	technique): a live Studio pass hasn't confirmed UIStroke renders correctly on the chamfered
	segments' own borders while composited inside a CanvasGroup. Accepted here for the same reason
	Onboarding accepts it -- abandoning CanvasGroup would mean abandoning the fade+scale entrance this
	feature explicitly asks for.

	Does not own: which emote plays or which loadout slot gets written (Client/Emotes/
	EmoteController.lua, called only from EmoteWheelClient.lua), or deciding when the wheel opens/
	closes/confirms/cancels (EmoteWheelClient.lua, driving the handle's Values from outside).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Types = require(ReplicatedStorage.Shared.Types)
local EmoteRegistry = require(ReplicatedStorage.Shared.Emotes.EmoteRegistry)

local Tokens = require(script.Parent.Parent.Tokens)
local Layers = require(script.Parent.Parent.Shell.Layers)
local Surface = require(script.Parent.Parent.Shell.Surface)
local KeyLegend = require(script.Parent.Parent.Components.KeyLegend)
local KeybindManager = require(script.Parent.Parent.Parent.Input.KeybindManager)
local ClientStateModule = require(script.Parent.Parent.State.ClientState)
local WheelSelection = require(script.WheelSelection)
local WheelSegment = require(script.WheelSegment)
local WheelDial = require(script.WheelDial)
local WheelHub = require(script.WheelHub)

local Children = Fusion.Children
local peek = Fusion.peek

type Scope = Fusion.Scope<typeof(Fusion)>
type ClientState = ClientStateModule.ClientState

export type EmoteWheelHandle = {
	IsOpen: Fusion.Value<boolean>,
	SelectedIndex: Fusion.Value<number?>,
	-- Radians, clockwise from "up", written by EmoteWheelClient.lua and ALREADY unwrapped by it
	-- (WheelSelection.UnwrapAngle) so the dial's needle spring never sweeps the long way round the
	-- circle. Drives presentation only -- nothing selects off this.
	CursorAngle: Fusion.Value<number>,
	-- The dead-zone radius in RAW SCREEN PIXELS -- see this file's header on why the screen publishes
	-- it rather than the client owning a second copy.
	DeadZoneRadius: Fusion.UsedAs<number>,
}

local EmoteWheel = {}

-- THE FOUR RADII, from the centre out. Every other file in this folder is drawn against these and
-- none of them holds its own copy: WheelHub gets HUB_RADIUS, WheelDial gets HUB_RADIUS and
-- RIM_RADIUS, each WheelSegment gets an offset of length SEGMENT_RADIUS. Authored in unscaled pixels
-- like every surface in this UI (see UI/ViewportScale.lua's header on why the layout stays in pixels
-- and the whole thing is scaled once at the root).
--
-- The tiles sit clear of both: a 104px tile centred at 172 spans 120..224, which leaves 28px of gap
-- outside the hub boundary and 18px inside the graduation. Changing one of these four without
-- re-checking that arithmetic is how a tile ends up overlapping the marks it is supposed to point at.
local HUB_RADIUS = 92
local SEGMENT_RADIUS = 172
local RIM_RADIUS = 242
local SEGMENT_SIZE = UDim2.fromOffset(104, 104)

-- Clearance from the rim down to the key legend.
local LEGEND_DROP = RIM_RADIUS + 44

-- Snappier than Tokens.Motion.FadeSpring (14, 0.7) -- see file header on why this needs to settle
-- faster than that one-shot-entrance preset in BOTH directions.
local OPEN_SPRING_SPEED = 20
local OPEN_SPRING_DAMPING = 1

-- How long the ScreenGui stays enabled after IsOpen goes false, so the close reverse-tween the
-- spring above produces actually gets to render before this screen stops presenting entirely.
-- Comfortably covers OPEN_SPRING_SPEED/OPEN_SPRING_DAMPING's own settle time (critically damped
-- springs settle to within ~5% by roughly 3/Speed seconds -- 3/20 = 0.15s) with margin for a slow
-- frame.
local CLOSE_ANIMATION_SECONDS = 0.25

local SCALE_FLOOR = 0.85

-- A flat wash plus two crossed gradients. The flat layer alone is what this screen used to have, and
-- over a bright daylit field it dimmed the grass at the edges exactly as much as it dimmed the space
-- behind the readout -- so the wheel had no ground of its own and the description text sat on
-- whatever happened to be behind it. Roblox has no radial gradient, so the vignette is the standard
-- two-axis approximation: darkest at all four edges, clear through the middle where the dial's own
-- disc takes over. Two Frames, no assets, no per-frame work.
local BASE_SCRIM_TRANSPARENCY = 0.72
local VIGNETTE_VERTICAL = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 0.32),
	NumberSequenceKeypoint.new(0.5, 0.94),
	NumberSequenceKeypoint.new(1, 0.32),
})
local VIGNETTE_HORIZONTAL = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 0.42),
	NumberSequenceKeypoint.new(0.5, 1),
	NumberSequenceKeypoint.new(1, 0.42),
})

local function vignetteLayer(scope: Scope, name: string, rotation: number, ramp: NumberSequence): Frame
	return scope:New "Frame" {
		Name = name,
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Tokens.Wash.RailScrim.Color,
		BackgroundTransparency = 0,
		BorderSizePixel = 0,
		ZIndex = 0,

		[Children] = scope:New "UIGradient" {
			Rotation = rotation,
			Transparency = ramp,
		},
	} :: Frame
end

function EmoteWheel.Mount(
	scope: Scope,
	playerGui: PlayerGui,
	clientState: ClientState,
	scale: Fusion.UsedAs<number>
): EmoteWheelHandle
	local isOpen = scope:Value(false)
	local selectedIndex: Fusion.Value<number?> = scope:Value(nil :: number?)
	local cursorAngle = scope:Value(0)

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
		return SCALE_FLOOR + use(openProgress) * (1 - SCALE_FLOOR)
	end)

	local segmentCount = scope:Computed(function(use)
		return #use(clientState.EmoteLoadout)
	end)

	local deadZoneRadius = scope:Computed(function(use)
		return HUB_RADIUS * use(scale)
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

		local baseOffset = innerScope:Computed(function(use)
			return WheelSelection.GetSegmentPosition(index, use(segmentCount), SEGMENT_RADIUS)
		end)
		local selected = innerScope:Computed(function(use)
			return use(selectedIndex) == index
		end)

		-- Peeked, not used(): the entrance stagger is cosmetic timing, and reading segmentCount
		-- reactively here would make EVERY tile a dependent of the loadout's length, tearing all of
		-- them down and rebuilding them whenever a slot is added -- the exact rebuild this ForPairs
		-- is keyed by index to avoid. A tile built while the loadout was 8 long keeps staggering as
		-- one of 8; nothing about that is wrong to look at.
		local entranceCount = math.max(#peek(clientState.EmoteLoadout), 1)

		return index,
			WheelSegment(innerScope, {
				Emote = definition :: Types.EmoteDefinition,
				SlotIndex = index,
				Selected = selected,
				Size = SEGMENT_SIZE,
				BaseOffset = baseOffset,
				OpenProgress = openProgress,
				EntranceOrder = index,
				EntranceCount = entranceCount,
				ZIndex = 3,
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

	-- Live from KeybindManager exactly as Screens/HUD/init.lua's own legend is, so rebinding the
	-- wheel re-letters the cap in place. The unsubscribe goes on the scope rather than being dropped:
	-- UI/init.lua's Studio hot-reload teardown path is a real caller of this scope's cleanup.
	local emoteKey = scope:Value(KeybindManager.Describe(KeybindManager.Get("EmoteWheel")))
	table.insert(
		scope,
		KeybindManager.OnChanged(function()
			emoteKey:set(KeybindManager.Describe(KeybindManager.Get("EmoteWheel")))
		end)
	)

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

				scope:New "Frame" {
					Name = "Scrim",
					Size = UDim2.fromScale(1, 1),
					BackgroundColor3 = Tokens.Wash.RailScrim.Color,
					BackgroundTransparency = BASE_SCRIM_TRANSPARENCY,
					BorderSizePixel = 0,
					ZIndex = 0,
				},
				vignetteLayer(scope, "VignetteVertical", 90, VIGNETTE_VERTICAL),
				vignetteLayer(scope, "VignetteHorizontal", 0, VIGNETTE_HORIZONTAL),

				scope:New "Frame" {
					Name = "Wheel",
					AnchorPoint = Vector2.new(0.5, 0.5),
					Position = UDim2.fromScale(0.5, 0.5),
					Size = UDim2.fromOffset(0, 0),
					BackgroundTransparency = 1,
					ZIndex = 1,

					[Children] = {
						WheelDial(scope, {
							SegmentCount = segmentCount,
							SelectedIndex = selectedIndex,
							CursorAngle = cursorAngle,
							OpenProgress = openProgress,
							RimRadius = RIM_RADIUS,
							HubRadius = HUB_RADIUS,
							ZIndex = 1,
						}),

						segments,

						WheelHub(scope, {
							Emote = centerEmote,
							Radius = HUB_RADIUS,
							ZIndex = 5,
						}),

						-- AutomaticSize.XY around KeyLegend's own AutomaticSize.X row, so the run
						-- centres on the wheel's axis at whatever width its captions happen to need.
						-- Safe against the AutomaticSize trap Components/MeridianField.lua's header
						-- records -- nothing in this subtree is Scale-sized.
						scope:New "Frame" {
							Name = "LegendBand",
							AnchorPoint = Vector2.new(0.5, 0.5),
							Position = UDim2.fromScale(0.5, 0.5) + UDim2.fromOffset(0, LEGEND_DROP),
							Size = UDim2.fromOffset(0, 0),
							AutomaticSize = Enum.AutomaticSize.XY,
							BackgroundTransparency = 1,
							ZIndex = 6,

							[Children] = KeyLegend(scope, {
								Entries = {
									{ Key = emoteKey, Text = "PERFORM" },
									{ Key = "RMB", Text = "CANCEL" },
								},
								Gap = Tokens.Space.XL,
							}),
						},
					},
				},
			},
		},
	})

	return {
		IsOpen = isOpen,
		SelectedIndex = selectedIndex,
		CursorAngle = cursorAngle,
		DeadZoneRadius = deadZoneRadius,
	}
end

return EmoteWheel
