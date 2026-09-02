--!strict
--[[
	FurnacePrompt/init.lua

	Owns: the furnace's own interaction prompt -- the panel that replaces Roblox's default
	ProximityPrompt UI on a blimp's furnace, and nothing else. Two rows, one per action: load the
	furnace, and take the fuel back out.

	WHY A CUSTOM PROMPT AT ALL, when a stock one is free. The furnace is the only object in this game
	with TWO actions on ONE part (Shared/Blimp/BlimpConstants.Prompt.UnloadActionText has the argument
	for why they are two prompts rather than one), and Roblox's default UI has no concept of that: it
	draws each prompt as a separate floating pill, both anchored to the same point in space, with no
	relationship between them and nothing but a pixel offset keeping them from overlapping. A player
	walking up to a furnace should see ONE object with two things it can do, which is what this panel
	says and what two stacked pills cannot.

	It also fails docs/ui-ux-philosophy.md outright. The stock prompt is a soft rounded rectangle with
	a white fill and a system font -- "bubble UI... soft mobile-style cards" is the exact shape that
	document's Shape Language section names as the thing to avoid, and it is the only surface in the
	game the player meets that is not in this project's own visual language.

	THE HOTBAR'S REGISTER, DELIBERATELY -- the chamfered silhouette, bronze corner brackets, and the
	one width, prop for prop off Screens/HUD's own dock (owner's call, 2026-08-26: "designed like the
	hotbar"). docs/ui-ux-philosophy.md's Shape Language section names two registers and calls picking
	the wrong one a mistake rather than a taste, and the first draft of this file picked the menu one
	on the argument that a prompt is instructional chrome. That was wrong for a reason the doc itself
	supplies: the menu register is for surfaces the player READS -- panels, cards, tiles they sit in
	front of. This is a thing they walk up to and OPERATE, over live gameplay, at a distance, and the
	chamfer is what this project's own vocabulary says that is.

	So it wears the dock's exact recipe: Chamfered, plus CornerAccent inset by ChamferedSurface.
	CHAMFER_PX (which is what makes the two treatments legal together at all -- Panel.lua's header),
	un-rivetted, arms at 10. If ChamferedSurface is unavailable on this client, Panel falls back to a
	sharp rect with a stroke on its own and nothing here has to know.

	BRONZE IS THE FURNACE'S OWN COLOUR AND IT IS DOING REAL WORK HERE, not decoration. Tokens.Color.
	AccentSecondary is this palette's "committed / permanent" hue (Screens/HUD's own bolt comment) and
	it is also, literally, what a fire-box is made of -- so the brackets, the edge, the eyebrow and the
	hold fill are all bronze, and the violet that runs through every other surface in this UI is
	absent. That is the one thing on screen that says which object this panel belongs to before a
	single word is read. Nothing else in the HUD is bronze-edged.

	FIXED HEIGHT, NOT AutomaticSize, and it is the chamfer that forces it -- the two are incompatible
	(Panel.lua's header records the full-screen-height bug that proved it). PANEL_HEIGHT below is the
	literal sum of the children's own declared heights, the same shape Screens/Notifications' TILE_HEIGHT
	takes for the same reason. Every term in that sum is declared in THIS file and passed INTO the child
	it describes -- including the two rows' height, which is why Components/KeyHint.lua now takes a
	RowHeight prop. That is what stops this being the silently-invalidated allowance CLAUDE.md warns
	about: there is no second copy of any of these numbers to drift from.

	CAPS ARE THE "Quiet" REGISTER, not "Overlay", and that is a real distinction rather than a default:
	Overlay exists for a cap sat directly on the world carrying its own fill (Components/KeyCap.lua's
	own header), and every cap here has a filled panel behind it doing that job already.

	PURE PRESENTATION, DRIVEN FROM OUTSIDE, the same split every other Screens/<Name>/init.lua in this
	folder keeps: this file never touches ProximityPromptService, never reads the camera, and never
	decides when it is on screen. Client/Blimp/FurnacePromptClient.lua owns all of that and drives the
	handle below -- see its header for the prompt wiring and the world-to-screen projection.

	POSITION ARRIVES IN THIS SURFACE'S OWN COORDINATE SPACE, already divided by the viewport scale by
	the module that projects it. That division is FurnacePromptClient's because it is the half that
	knows the raw pixel it started from; this file simply writes what it is handed. A surface that
	converted on the way in would be doing arithmetic against a scale it does not own.

	THE HOLD BAR IS THE ONE THING HERE THAT MOVES, and it exists because unloading is the only hold
	prompt in the game (BlimpConstants.Prompt.UnloadHoldDuration -- a mis-press can strand a fuelled
	hull, so it is deliberately not a tap). A hold with no visible progress is indistinguishable from a
	press that did not register, which is the same silence Network.RemoteNames.FuelTransfer was added
	to end at the other end of the interaction. It occupies its 2px whether or not a hold is running,
	so the panel never changes height mid-press; what changes is its transparency and its fill.

	Does not own: which keys these rows name (BlimpConstants.Prompt -- handed in), what pressing them
	does (Server/Systems/BlimpSystem.lua's depositFuel/unloadFuel), or what the press turned out to
	have done (Client/Blimp/BlimpController.lua's onFuelTransfer, which answers on the notification
	channel rather than here -- an outcome is not a prompt).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)

local BlimpConstants = require(ReplicatedStorage.Shared.Blimp.BlimpConstants)
local Glyph = require(script.Parent.Parent.Parent.Input.Glyph)
local Tokens = require(script.Parent.Parent.Tokens)
local ChamferedSurface = require(script.Parent.Parent.ChamferedSurface)
local Layers = require(script.Parent.Parent.Shell.Layers)
local Surface = require(script.Parent.Parent.Shell.Surface)
local Panel = require(script.Parent.Parent.Components.Panel)
local Inset = require(script.Parent.Parent.Components.Inset)
local KeyHint = require(script.Parent.Parent.Components.KeyHint)
local Reveal = require(script.Parent.Parent.Components.Reveal)
local TrackedLabel = require(script.Parent.Parent.Components.TrackedLabel)

local Children = Fusion.Children

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>

export type FurnacePromptHandle = {
	-- Whether the player is in range of a furnace at all. Drives the whole panel's entrance/exit
	-- through Components/Reveal, so neither edge is ever a cut.
	SetVisible: (visible: boolean) -> (),
	-- Where the panel's bottom-centre should sit, in THIS surface's coordinate space -- see this
	-- file's header on why the division by the viewport scale happens before it gets here.
	SetPosition: (position: Vector2) -> (),
	-- 0..1 along the unload hold, or 0 for "not holding". The bar fades out at 0 rather than snapping
	-- to empty, so a released hold reads as abandoned rather than as never having happened.
	SetHoldProgress: (progress: number) -> (),
	-- NEITHER CAP'S GLYPH IS ON THIS HANDLE ANY MORE, and their absence is the point rather than a
	-- tidy-up. This used to carry SetKeys(loadKey, unloadKey) and then, briefly, SetUnloadKey alone --
	-- both of them a keyboard key NAME pushed in as a string, which is precisely how a panel ends up
	-- able to show only one device's keys. The load row resolves the live Interact bind itself from
	-- the action (Components/KeyCap.lua -> Client/Input/Glyph.lua), and the unload row resolves a
	-- per-device Binding built from the two constants the server made the prompt from. Both track the
	-- player's device, and the load row tracks a rebind, with nothing to push and nothing to go stale.
}

local FurnacePrompt = {}

-- Wide enough for the longer of the two verbs at the Chip step with the cap column in front of it,
-- and no wider: this floats over the world at a furnace a player is standing next to, and
-- docs/ui-ux-philosophy.md's HUD rule is "out of the player's way".
local PANEL_WIDTH = 186

-- The cap column both rows share, so the two verbs form one flush left edge -- KeyHint.lua's own
-- header calls that the whole point of its layout. Sized for one glyph; a longer bind ("SPACE")
-- grows its own cap past this, which is why KeyCap takes it as a minimum.
local KEY_COLUMN_WIDTH = 24

-- Pixels above the projected furnace point that the panel's bottom edge sits at. Lifts it clear of
-- the hull it is drawn against rather than centring it on a part whose origin is usually somewhere
-- inside the geometry.
local LIFT_PIXELS = 18

-- THE FIVE HEIGHTS THAT MAKE UP PANEL_HEIGHT, and the reason each is a named constant rather than a
-- literal at its use site: every one of them is passed into the child it describes AND summed below,
-- so the container and its contents cannot disagree. See this file's header.
local INSET_X = Tokens.Space.M
local INSET_Y = Tokens.Space.S
local ROW_GAP = Tokens.Space.XS
local EYEBROW_HEIGHT = 12
-- Components/KeyHint.lua's own default, restated here because this panel has to SUM it -- and passed
-- back into both rows as RowHeight so it is the value actually used, not a hopeful copy of one.
local HINT_ROW_HEIGHT = 17
local HOLD_BAR_HEIGHT = 2

-- Inset, eyebrow, gap, row, gap, row, gap, bar, inset. Written out in that order so it reads against
-- the Children list below rather than as an arithmetic result somebody has to reverse-engineer.
local PANEL_HEIGHT = INSET_Y
	+ EYEBROW_HEIGHT
	+ ROW_GAP
	+ HINT_ROW_HEIGHT
	+ ROW_GAP
	+ HINT_ROW_HEIGHT
	+ ROW_GAP
	+ HOLD_BAR_HEIGHT
	+ INSET_Y

-- The bronze edge, at the Lit weight rather than the Standard one. See this file's header on why the
-- whole panel is bronze; the WEIGHT is because this is a surface a player is being asked to act on,
-- which docs/ui-ux-philosophy.md's Borders section ("higher importance gets a brighter edge") puts a
-- step above an ambient tile's own edge.
local EDGE_TRANSPARENCY = 0.68

-- The dock's own bracket geometry (Screens/HUD/init.lua), matched rather than re-picked.
local BRACKET_ARM_LENGTH = 10

-- The unload prompt's own two buttons, one per device, as Client/Input/Glyph.lua reads them. Built
-- here from the two constants the SERVER built the prompt from, so the cap and the ProximityPrompt it
-- describes cannot drift -- neither is rebindable, which is what makes a constant the honest source
-- for both (see BlimpConstants.Prompt.UnloadKeyCode).
local UNLOAD_BINDING: Glyph.Binding = {
	Keyboard = BlimpConstants.Prompt.UnloadKeyCode,
	Gamepad = BlimpConstants.Prompt.UnloadGamepadKeyCode,
}

local function FurnacePromptPanel(
	scope: Scope,
	visible: UsedAs<boolean>,
	position: UsedAs<Vector2>,
	holdProgress: UsedAs<number>
): Frame
	local reveal = Reveal(scope, { Visible = visible })

	-- Bound rather than eased: this chases a hold the player is performing right now, and a spring
	-- would put the bar behind their own finger. The FADE is what is animated (see below) -- the fill
	-- itself is the raw truth.
	local fillWidth = scope:Computed(function(use): UDim2
		return UDim2.fromScale(math.clamp(use(holdProgress), 0, 1), 1)
	end)

	-- One spring over "is a hold running", so both the track and the fill arrive and leave together.
	-- Tokens.Motion.FillSpring is the preset for a value the player is driving, which is exactly this.
	local holdPresence = scope:Spring(
		scope:Computed(function(use): number
			return if use(holdProgress) > 0 then 1 else 0
		end),
		Tokens.Motion.FillSpring.Speed,
		Tokens.Motion.FillSpring.Damping
	)

	local holding = scope:Computed(function(use): boolean
		return use(holdProgress) > 0
	end)

	return Panel(scope, {
		Name = "FurnacePromptPanel",
		-- Both axes fixed -- see this file's header on why AutomaticSize is off the table here.
		Size = UDim2.fromOffset(PANEL_WIDTH, PANEL_HEIGHT),
		-- Bottom-centre on the projected point, so the panel stands ABOVE the furnace rather than
		-- covering it.
		AnchorPoint = Vector2.new(0.5, 1),
		Position = scope:Computed(function(use): UDim2
			local point = use(position)
			return UDim2.fromOffset(point.X, point.Y - LIFT_PIXELS)
		end),
		Visible = reveal.Mounted,

		-- THE DOCK'S RECIPE, prop for prop -- see this file's header. Elevated is false for the same
		-- reason it is on the dock: the chamfered fill IS the surface here, and lifting it toward
		-- SurfaceElevated makes a floating panel read as a card sat on something rather than as an
		-- object in its own right.
		Elevated = false,
		Chamfered = true,
		BorderColor3 = Tokens.Color.AccentSecondary,
		BorderTransparency = EDGE_TRANSPARENCY,
		CornerAccent = true,
		CornerAccentColor = Tokens.Color.AccentSecondary,
		CornerAccentRivets = false,
		BracketArmLength = BRACKET_ARM_LENGTH,
		-- What makes the chamfer and the brackets legal at once: an elbow inset by exactly the cut's
		-- own depth lands where the diagonal ends rather than floating over it. Panel.lua's header.
		BracketInset = ChamferedSurface.CHAMFER_PX,

		Children = {
			reveal.Scale,
			Inset(scope, { X = INSET_X, Y = INSET_Y }),
			scope:New "UIListLayout" {
				FillDirection = Enum.FillDirection.Vertical,
				Padding = UDim.new(0, ROW_GAP),
				SortOrder = Enum.SortOrder.LayoutOrder,
			},

			TrackedLabel(scope, {
				Text = "FURNACE",
				Scale = "Eyebrow",
				-- Bronze, not TextSecondary. The eyebrow is the only place the object NAMES itself,
				-- and naming it in the material it is made of is what ties the panel to the thing the
				-- player is standing in front of.
				Color = Tokens.Color.AccentSecondary,
				TextTransparency = reveal.Transparency,
				Size = UDim2.new(1, 0, 0, EYEBROW_HEIGHT),
				LayoutOrder = 1,
			}),

			KeyHint(scope, {
				-- NAMED BY ACTION, so this row draws the pad's own glyph for a controller player --
				-- including the L2+X chord, which is where Interact actually lives on a gamepad
				-- (Constants.Keybinds.GamepadChords). The unload row below stays raw-key, and the
				-- two sitting side by side is exactly the mixed case Components/KeyHint.lua's header
				-- describes: exclusivity is per row, not per panel.
				Actions = { "Interact" },
				Text = "Load fuel",
				KeyColumnWidth = KEY_COLUMN_WIDTH,
				RowHeight = HINT_ROW_HEIGHT,
				LayoutOrder = 2,
			}),

			KeyHint(scope, {
				-- NAMED BY BINDING, for the same reason the load row above is named by action: this cap
				-- used to be a keyboard KEY NAME pushed in as a string ("V"), which drew a keyboard key
				-- at a player holding a controller -- and the prompt this row describes has listened on
				-- a different button for that player all along (BlimpConstants.Prompt.
				-- UnloadGamepadKeyCode, ButtonY). A Binding rather than an Action because this key is
				-- deliberately NOT a Types.KeybindAction: see UnloadKeyCode's own header for why it is
				-- not Interact-shaped and never was.
				Bindings = { UNLOAD_BINDING },
				Text = "Unload fuel",
				KeyColumnWidth = KEY_COLUMN_WIDTH,
				RowHeight = HINT_ROW_HEIGHT,
				-- Lit for the whole hold, so the cap itself says "you are pressing this" alongside the
				-- bar saying "and this is how far in you are" -- docs/ui-ux-philosophy.md's Critical
				-- States rule is that a state must never be carried by one channel alone. The words
				-- change too, which is the third channel and the one that needs no colour at all.
				Active = holding,
				ActiveText = "Unloading...",
				LayoutOrder = 3,
			}),

			-- The hold track. A plain flow child rather than anything pinned, so it cannot be swept
			-- into the run the way a decoration in a UIListLayout would be (Components/Layer.lua's own
			-- header) -- it IS part of the run, deliberately, and holds its 2px whether or not a hold
			-- is under way so the panel never changes height mid-press.
			scope:New "Frame" {
				Name = "HoldTrack",
				LayoutOrder = 4,
				Size = UDim2.new(1, 0, 0, HOLD_BAR_HEIGHT),
				BackgroundColor3 = Tokens.Wash.TrackBase.Color,
				BackgroundTransparency = scope:Computed(function(use): number
					-- Its own resting transparency, lifted toward opaque only while a hold runs -- an
					-- empty track sitting under an idle prompt forever is the "does this make the
					-- player feel more connected" test's own answer to itself.
					return 1 - (1 - Tokens.Wash.TrackBase.Transparency) * use(holdPresence)
				end),
				BorderSizePixel = 0,

				[Children] = {
					scope:New "Frame" {
						Name = "HoldFill",
						Size = fillWidth,
						-- Bronze, like everything else on this panel that is not text -- and here it
						-- earns it twice: a fill creeping across a furnace's own plate in the colour
						-- of hot metal is the "energy buildup" docs/ui-ux-philosophy.md's Animation
						-- Philosophy names as a preferred motion, rather than a generic progress bar.
						BackgroundColor3 = Tokens.Color.AccentSecondary,
						BackgroundTransparency = scope:Computed(function(use): number
							return 1 - use(holdPresence)
						end),
						BorderSizePixel = 0,
					},
				},
			},
		},
	})
end

-- Builds this screen's own surface and returns the handle Client/Blimp/FurnacePromptClient.lua drives.
--
-- ITS OWN ScreenGui RATHER THAN A REGION TILE, unlike every ambient corner panel. Shell/Regions.lua
-- owns the six SCREEN corners; this panel is not in one. It tracks a point in the world, which is a
-- different kind of surface, and Layers.World is the band that already exists for exactly that (its
-- only other occupant is the shift-lock crosshair) -- below the HUD, because it is drawn on the world
-- rather than on top of the interface.
function FurnacePrompt.Mount(scope: Scope, playerGui: PlayerGui, scale: UsedAs<number>): FurnacePromptHandle
	local visible = scope:Value(false)
	local position = scope:Value(Vector2.zero)
	local holdProgress = scope:Value(0)

	Surface.New(scope, {
		Name = "FurnacePrompt",
		Layer = Layers.World + 1,
		Parent = playerGui,
		Scaled = true,
		Scale = scale,
		Children = {
			FurnacePromptPanel(scope, visible, position, holdProgress),
		},
	})

	return {
		SetVisible = function(newVisible: boolean)
			visible:set(newVisible)
		end,
		SetPosition = function(newPosition: Vector2)
			position:set(newPosition)
		end,
		SetHoldProgress = function(progress: number)
			holdProgress:set(progress)
		end,
	}
end

return FurnacePrompt
