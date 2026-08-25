--!strict
--[[
	Shell/Regions.lua

	Owns: the six named screen regions, the single ScreenGui that hosts all of them, where each
	region sits relative to its screen edge, the order tiles stack in within one, and how the whole
	ambient layer steps back when something is asked of the screen.

	Does NOT own: what a tile contains, when a tile is visible for reasons of its own, or how a tile
	enters. A tile is handed in fully built; this file parents it and assigns its LayoutOrder, and
	that is all. It does not own the MODE either -- Shell/Chrome.lua decides what "a panel is open" or
	"the player is dead" means; this file only knows what a dim and a hidden corner look like.

	A REGION ALSO KEEPS OUT OF WHAT ITS NEIGHBOURS DRAW, and that is the second thing this file
	arbitrates after who-stacks-with-whom. Both bottom CORNERS start above the dock band rather than in
	the corner itself, because the dock is 870px wide and has a 224px weapon plate bolted to its left
	edge -- at this UI's own authoring resolution that plate lands 24px from the left screen edge,
	directly on top of the helm console. See DOCK_BAND_REACH. That is the same class of bug as the two
	byte-identical collisions below, arriving the same way (a panel grew into a strip another panel
	already occupied, and nothing was watching the strip), so it is closed in the same place.

	THE DOCK IS A TILE NOW TOO. BottomCentre was reserved for it through Phase 1 and holds it as of
	Phase 2 of docs/architecture/2026-08-25-hud-shell-plan.md -- Screens/HUD returns its band stack
	the way the other six screens return theirs. Two things went away with that: the dock's own
	ScreenGui, and the hand-scaled bottom margin it carried (a Computed multiplying Tokens.Space.L by
	the viewport scale, because the UIScale it had sat BELOW the thing being positioned). BottomCentre's
	ordinary edge inset is that margin now, and it scales because the host's UIScale is above it.

	THE BUG IT CLOSES, WHICH IS WORTH READING BEFORE EXTENDING THIS. Two pairs of panels were
	rendering at byte-identical coordinates, and each of the four files documented its own corner as
	free:

	    DeathFeed/init.lua:114        Position = UDim2.new(1, -Tokens.Space.L, 0, Tokens.Space.L)
	    BlimpFuel/init.lua:198        Position = UDim2.new(1, -Tokens.Space.L, 0, Tokens.Space.L)

	    BlimpHelm/init.lua:361        UDim2.new(0, Tokens.Space.L, 1, -Tokens.Space.L + ...)
	    WeaponInventory/init.lua:482  UDim2.new(0, Tokens.Space.L, 1, -Tokens.Space.L + ...)

	WeaponInventory carried "CarriedResources holds top-left and BlimpFuel top-right, so the three
	corner tiles never collide" -- not knowing BlimpHelm had taken bottom-left, or DeathFeed
	top-right. BlimpHelm carried "the hotbar owns bottom-centre and Screens/BlimpFuel owns top-right,
	so this is the corner a console-sized panel can grow downward-anchored in without ever colliding
	with either" -- not knowing about WeaponInventory. Both authors checked. Both checked against a
	prose list that nothing keeps current, and both were already wrong when written. Those two
	comments are deleted rather than corrected: a corrected comment rots the same way, and the point
	of this module is that the question stops being answerable by prose.

	REGIONS ARE STACKS, NOT SLOTS. The instinct is a Claim(region, screen) that errors on a second
	claimant. That is the wrong answer here, because both top-right claimants are legitimate and both
	mount unconditionally at boot -- an assert would only fail the boot it was meant to protect. So a
	region is one anchored Frame with a UIListLayout, and a second tile queues instead of overlapping.

	ONE HOST ScreenGui FOR ALL SIX REGIONS. This is the part that actually fixes the collisions
	rather than merely making them deterministic: if the kill feed and the fuel gauge lived in
	top-right regions belonging to two different ScreenGuis, they would still overlap and the z-order
	ladder would only decide which one won. One host, one top-right stack, and the two queue. It is
	also six fewer render layers.

	TWO CONTRACTS THIS FILE OWNS AND TILES MUST NOT SECOND-GUESS:

	  1. GROWTH DIRECTION IS THE REGION'S. A tile carries no AnchorPoint and no Position -- and could
	     not use one anyway, since a UIListLayout overwrites its children's Position on every layout
	     pass. That mechanical fact is worth stating because it is what retired the two hand-rolled
	     14px entrance offsets that used to live in BlimpHelm and WeaponInventory: they were not
	     removed as a style preference, they stopped being expressible. Reveal.lua (Phase 5) is where
	     an entrance offset comes back, for all five ambient tiles at once.

	  2. LOWER ORDER SITS NEARER THE REGION'S ANCHORED EDGE. For a top-anchored region that is
	     ordinary ascending layout. For a bottom-anchored one it is not: a UIListLayout always runs
	     top-to-bottom by ascending LayoutOrder, so order 10 would land ABOVE order 20 -- the opposite
	     of "nearest the anchored edge". Bottom regions therefore negate the order (see Add below).
	     Callers pass the same 10/20 either way and never have to know which end they are at.

	NOT MEMOIZED AT MODULE SCOPE, DELIBERATELY. The host and its six frames live on the value Mount
	returns, never in a module-level upvalue. UI/init.lua exposes its root Scope specifically so a
	future re-Mount (a Studio hot-reload) can :doCleanup() and build a fresh tree; a cached host would
	survive that cleanup as a reference to a destroyed Instance, and the second Mount would parent
	every tile into it. That failure is a blank screen with no error in the log, which is why it is
	called out here rather than left to be rediscovered.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)

local Tokens = require(script.Parent.Parent.Tokens)
local Layers = require(script.Parent.Layers)
local Surface = require(script.Parent.Surface)

local Children = Fusion.Children

type Scope = Fusion.Scope<typeof(Fusion)>

export type Region = "TopLeft" | "TopCentre" | "TopRight" | "BottomLeft" | "BottomCentre" | "BottomRight"

export type RegionHost = {
	-- Parents `tile` into `region` and gives it its place in that region's stack. Lower order sits
	-- nearer the region's anchored edge, whichever edge that is.
	Add: (self: RegionHost, region: Region, order: number, tile: GuiObject) -> (),
	-- The one host ScreenGui. Exposed for the specs -- not so callers can parent into it directly.
	Gui: ScreenGui,
}

-- HOW THE AMBIENT LAYER YIELDS, as two presentation values and nothing else. Shell/Chrome.lua's
-- handle satisfies this structurally, which is the whole reason it is spelled out here rather than
-- imported: this file has no opinion about what a "mode" is, only about what a dim and a hidden
-- corner look like, and Chrome has no opinion about which regions are corners. Neither requires the
-- other.
--
-- Optional at Mount. A spec that only asserts structure passes nothing and gets no scrim and no
-- Visible binding at all, which is one fewer moving part in the tests that are not about yielding.
export type RegionYield = {
	-- 0 = the ambient layer is at full strength; 1 = fully behind the scrim. Read as a GOAL, not as an
	-- animated value -- the tween that carries it lives here, at the pixels, so that Chrome stays
	-- pure logic and is testable without a render pass.
	Dim: Fusion.UsedAs<number>,
	-- Whether the four CORNER regions are on screen at all. The two centre regions ignore it -- see
	-- the Ambient flag on each spec below for which is which and why.
	AmbientVisible: Fusion.UsedAs<boolean>,
}

-- Tokens.IsTouch, not a second UserInputService.TouchEnabled read of this file's own. Tokens.lua
-- already reads it once at require time to floor small type sizes, and its comment there explains
-- why it is a constant rather than a Computed: which input methods this session's platform supports
-- is stable for the client's whole lifetime, unlike a window size a desktop player can actually
-- drag. A device does not grow a touchscreen mid-session -- and making it reactive would put a
-- connection in a module whose stated budget is zero idle cost.
local IS_TOUCH = Tokens.IsTouch

-- The margin every region keeps from its screen edges. Space.L is what all six migrated screens
-- already used, so desktop output is unchanged by the existence of this table.
local EDGE_INSET = Tokens.Space.L

-- Roblox's default mobile controls sit in the two bottom corners -- the movement thumbstick at
-- bottom-left, the jump button at bottom-right -- and the weapon rack and helm console have been
-- rendering underneath the thumbstick for as long as both have existed. Not a new bug and not one
-- this module introduced, but the region layer is the one place that can fix it for every tile at
-- once, which is why it is fixed here rather than left to each tile.
--
-- Sized off Tokens.Control.TouchTargetSize (the minimum square a finger has to hit) rather than off
-- a measured pixel count for Roblox's own controls: that number is theirs to change, and three
-- finger-widths of clearance stays right if they do.
--
-- THIS IS A CLEARANCE, NOT A MOBILE LAYOUT. A real mobile pass -- a reflowed dock, actual control-
-- zone layout -- is separate work and must not be grafted onto this constant. See the plan's §14.5,
-- which recorded that boundary as the reason this option was chosen over the alternatives.
local TOUCH_CONTROL_CLEARANCE = Tokens.Control.TouchTargetSize * 3

-- TopCentre starts BELOW the combat banner band, not at the ordinary edge inset. Two centred banners
-- are drawn above it by a DIFFERENT surface: Components/PostureBreakBanner.lua's StatusBanner sits at
-- Tokens.Space.XXL + YOffset and is 64px tall, and Screens/CombatFeedback mounts it twice -- posture
-- break at YOffset 0, disarmed at YOffset 72. The band therefore ends at 32 + 72 + 64 = 168, and the
-- announcement banner sits exactly one edge inset below it, at 184.
--
-- 184 IS FINALLY THE NUMBER IT CLAIMED TO BE, as of Phase 2. CombatFeedback has always been
-- IgnoreGuiInset = true and this host was not, so the two banners it clears were measured from the
-- true top of the screen while the announcement was measured from below Roblox's top bar -- 184
-- rendering at 220, a 36px gap that no line in either file mentioned. That is plan §2.3 in one
-- concrete pair of numbers ("the margins were authored to match and do not"). Both surfaces are in
-- one coordinate space now, so the announcement moves UP by the top bar's height and lands where it
-- was always written to land. It is the one tile this phase deliberately moves.
--
-- THE TWO NUMBERS BELOW ARE OWNED ELSEWHERE and are duplicated here rather than imported, because
-- Shell/ must not require Components/ -- the dependency runs the other way everywhere else in this
-- tree. This is the one constant in this file that can rot: if either banner's YOffset or its height
-- changes, this has to change with it, and nothing will tell you.
--
-- IT IS ALSO MEANT TO BE TEMPORARY. It exists only because CombatFeedback is still a separate surface
-- placing its own banners absolutely. The moment those two banners become TopCentre tiles, the stack
-- orders them against the announcement for free and this constant is deleted rather than adjusted.
local COMBAT_BANNER_BAND_BOTTOM = Tokens.Space.XXL + 72 + 64

-- Gap between two tiles stacked in the same region. Only ever paid when a region actually holds two
-- VISIBLE tiles: a UIListLayout excludes children whose Visible is false, so a hidden tile costs
-- neither its own height nor a helping of this padding.
local TILE_GAP = Tokens.Space.S

-- THE DOCK'S OWN REACH, MEASURED: how far above the BottomCentre tile's bottom edge the dock band's
-- TOP sits. 129 = the key legend band beneath the dock (31) plus the dock band itself (98), both read
-- off a real layout pass in this repo's own harness rather than added up from Screens/HUD's source.
--
-- WHY EITHER BOTTOM CORNER CARES ABOUT A CENTRED TILE. The dock is 870px wide and something is BOLTED
-- TO ITS LEFT EDGE: Screens/HUD/ArmamentIsland.lua pins a 224px weapon plate at x = -224 inside the
-- dock band, deliberately outside the BottomCentre tile's own bounds so the dock cannot be displaced
-- by it. At this UI's authoring resolution (1366x768, ViewportScale.REFERENCE_*, where the scale is
-- exactly 1.0) that puts the island's left edge at (1366 - 870) / 2 - 224 = 24px from the screen edge
-- -- straight through BottomLeft's 16..236 column, and straight through the helm console sitting in
-- it. Measured on 2026-08-25 from a screenshot and then reproduced from the numbers; it is not an
-- edge case, it is what the reference resolution renders.
--
-- SO THE BOTTOM CORNERS START ABOVE THE DOCK BAND, and that is the fix rather than moving the island
-- or narrowing the helm: the island cannot move (it is one half of a joint with the dock, see its own
-- header), and a region layer that lets a tile grow into a strip another tile already occupies is
-- exactly the arbitration this module exists to do. The same shape as COMBAT_BANNER_BAND_BOTTOM
-- above -- "another surface draws on this edge, so tiles on it start further in".
--
-- UNLIKE COMBAT_BANNER_BAND_BOTTOM, THIS ONE IS GUARDED. That constant's own note says "if either
-- banner's YOffset or its height changes, this has to change with it, and nothing will tell you."
-- Tests/UI/ShellRegions.spec.lua tells you about this one: it mounts the dock for real, measures the
-- reach off a live layout pass, and fails if BottomLeft no longer clears it. Retune the legend or the
-- dock's height and the spec fails naming the new number.
local DOCK_BAND_REACH = 129

-- Where a bottom CORNER region's stack starts, measured from the bottom of the screen: BottomCentre's
-- own edge inset, plus the dock band's reach above that, plus one more edge inset of air so the two
-- read as separate surfaces rather than as a seam.
local DOCK_BAND_CLEARANCE = EDGE_INSET + DOCK_BAND_REACH + EDGE_INSET

-- How dark the ambient layer goes behind an open panel, at full dim. Not opaque, deliberately: the
-- point of Chrome's Menu mode is that the dock STEPS BACK rather than vanishing (plan 2.5), so the
-- player can still read their own vitals through it while a menu is up.
local SCRIM_TRANSPARENCY = 0.45

-- Above every tile in this host and nothing else. The tallest ZIndex any tile draws at is 6 (the
-- armament island's seam bolt, which has to clear everything Panel.lua builds), so this is chosen for
-- headroom rather than measured -- it only ever has to beat its siblings inside one ScreenGui.
local SCRIM_ZINDEX = 50

-- ROBLOX'S OWN TOP BAR, WHICH IS THIS FILE'S PROBLEM NOW. Phase 1 left the host without
-- IgnoreGuiInset specifically so the six migrated screens' margins stayed byte-identical; Phase 2
-- chose one coordinate space for every surface in the client (Shell/Surface.lua's header, plan 2.3)
-- and this host is full-bleed like the rest. So a top-anchored region's own edge inset no longer
-- starts below Roblox's chrome -- it starts at the true top of the screen, and has to clear the bar
-- itself.
--
-- EXACTLY THE SAME SHAPE AS TOUCH_CONTROL_CLEARANCE BELOW, and worth noticing that it is: both are
-- "Roblox draws its own controls on this edge, so tiles start further in", both are per-edge, and
-- both belong here rather than in a tile because this is the one layer that can apply them to every
-- tile at once. Read from GuiService via Surface rather than hardcoded to 36 -- see that function.
--
-- IT SCALES WITH EVERYTHING ELSE, and does not need compensating. The host's UIScale multiplies this
-- offset along with the edge inset, so the rendered clearance is (EDGE_INSET + bar) * scale. Over
-- ViewportScale's whole clamped range that never dips below the bar: at MIN_SCALE 0.8 a 16 + 36
-- inset still renders at 41.6px against a 36px bar. At scale 1.0 it renders at exactly the 52px
-- these four tiles have always sat at, so this migration moves none of them.
--
-- Read at Mount, not at require: Surface.TopBarInset's own comment has the reason (this module is
-- require()d on the server by the test place's client load-check, where GuiService reports zero).

type RegionSpec = {
	AnchorPoint: Vector2,
	-- Which screen edge the stack grows away from. Bottom-anchored regions negate LayoutOrder so
	-- that contract 2 above holds at both ends.
	AnchoredToBottom: boolean,
	HorizontalAlignment: Enum.HorizontalAlignment,
	-- X and Y as a fraction of the screen (0, 0.5 or 1); the inset is added in the right direction
	-- for the anchor by regionPosition below.
	AnchorScale: Vector2,
	-- Extra bottom clearance on touch, for the two regions that sit under Roblox's own controls.
	ClearsTouchControls: boolean,
	-- Whether this region holds AMBIENT tiles -- the corner readouts that describe the world around
	-- the player (carried resources, the fuel gauge, the helm console, the kill feed) rather than the
	-- player's own controls. The four corners are; the two centre regions are not, because the dock is
	-- the player and TopCentre is the announcement/notification channel, and neither should be taken
	-- away by a mode change. This is what Chrome's Dead mode drops -- see RegionYield below.
	Ambient: boolean,
	-- Replaces the ordinary edge inset on the anchored edge. Only TopCentre uses one -- see
	-- COMBAT_BANNER_BAND_BOTTOM above for the one thing it is clearing and why that is temporary.
	EdgeInsetOverride: number?,
}

local REGION_SPECS: { [Region]: RegionSpec } = {
	TopLeft = {
		AnchorPoint = Vector2.new(0, 0),
		AnchoredToBottom = false,
		HorizontalAlignment = Enum.HorizontalAlignment.Left,
		AnchorScale = Vector2.new(0, 0),
		ClearsTouchControls = false,
		Ambient = true,
	},
	TopCentre = {
		AnchorPoint = Vector2.new(0.5, 0),
		AnchoredToBottom = false,
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		AnchorScale = Vector2.new(0.5, 0),
		ClearsTouchControls = false,
		-- NOT ambient, and it is the one region that stays up in every mode. A server announcement --
		-- and, from Phase 6, a rank-up notification -- has to be able to reach a player who happens to
		-- have a panel open or to be waiting out a respawn. A channel a mode can swallow is not one.
		Ambient = false,
		EdgeInsetOverride = COMBAT_BANNER_BAND_BOTTOM + EDGE_INSET,
	},
	TopRight = {
		AnchorPoint = Vector2.new(1, 0),
		AnchoredToBottom = false,
		HorizontalAlignment = Enum.HorizontalAlignment.Right,
		AnchorScale = Vector2.new(1, 0),
		ClearsTouchControls = false,
		Ambient = true,
	},
	BottomLeft = {
		AnchorPoint = Vector2.new(0, 1),
		AnchoredToBottom = true,
		HorizontalAlignment = Enum.HorizontalAlignment.Left,
		AnchorScale = Vector2.new(0, 1),
		ClearsTouchControls = true,
		Ambient = true,
		-- Starts above the dock band rather than in the corner -- see DOCK_BAND_CLEARANCE. This is the
		-- region the armament island was rendering into.
		EdgeInsetOverride = DOCK_BAND_CLEARANCE,
	},
	BottomCentre = {
		AnchorPoint = Vector2.new(0.5, 1),
		AnchoredToBottom = true,
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		AnchorScale = Vector2.new(0.5, 1),
		-- The dock sits BETWEEN the thumbstick and the jump button, not under either, so it takes the
		-- ordinary edge inset. Lifting it too would be a mobile layout decision, not a clearance.
		ClearsTouchControls = false,
		-- The dock is the player's own controls, not a readout about the world, so it survives Dead --
		-- an empty health bar and a spent hotbar are things a dead player is meant to be looking at.
		Ambient = false,
	},
	BottomRight = {
		AnchorPoint = Vector2.new(1, 1),
		AnchoredToBottom = true,
		HorizontalAlignment = Enum.HorizontalAlignment.Right,
		AnchorScale = Vector2.new(1, 1),
		ClearsTouchControls = true,
		Ambient = true,
		-- Empty today, and it takes the clearance anyway. The dock's right edge is only 12px clear of
		-- this column at the reference resolution, so the FIRST tile to claim this corner would land
		-- in the dock's shadow the way the helm console landed in the island's -- and it would land
		-- there for the same reason, a region that never said anything about the strip it grows into.
		EdgeInsetOverride = DOCK_BAND_CLEARANCE,
	},
}

-- Declared as a list so the mount order of the six frames is fixed and readable. Within one
-- ScreenGui their order is irrelevant to rendering (they never overlap by construction), but a
-- stable order keeps the Explorer tree and any structural spec predictable.
local REGION_ORDER: { Region } = {
	"TopLeft",
	"TopCentre",
	"TopRight",
	"BottomLeft",
	"BottomCentre",
	"BottomRight",
}

local function regionPosition(spec: RegionSpec, topBarInset: number): UDim2
	local verticalInset = spec.EdgeInsetOverride or EDGE_INSET
	if spec.ClearsTouchControls and IS_TOUCH then
		verticalInset += TOUCH_CONTROL_CLEARANCE
	end
	-- Only where there is a bar to clear AND no override. An override is an absolute distance from
	-- the top of the screen chosen to clear something else entirely (TopCentre clears the combat
	-- banner band, which is 168px down), so adding the bar to it would push it past the thing it was
	-- measured against rather than clearing anything.
	if not spec.AnchoredToBottom and spec.EdgeInsetOverride == nil then
		verticalInset += topBarInset
	end

	-- The inset always points INWARD from whichever edge the anchor names: positive at scale 0,
	-- negative at scale 1, and zero at 0.5 where there is no edge to keep away from.
	local xOffset = if spec.AnchorScale.X == 0 then EDGE_INSET elseif spec.AnchorScale.X == 1 then -EDGE_INSET else 0
	local yOffset = if spec.AnchorScale.Y == 0 then verticalInset else -verticalInset

	return UDim2.new(spec.AnchorScale.X, xOffset, spec.AnchorScale.Y, yOffset)
end

local Regions = {}

-- Builds the host ScreenGui and its six region frames on the scope it is given. Takes the scope as
-- an argument and holds nothing globally -- see the memoization note in this file's header for the
-- specific failure that rules out doing it any other way.
function Regions.Mount(
	scope: Scope,
	playerGui: PlayerGui,
	scale: Fusion.UsedAs<number>,
	yield: RegionYield?
): RegionHost
	local frames: { [Region]: Frame } = {}
	local topBarInset = Surface.TopBarInset()

	for _, region in REGION_ORDER do
		local spec = REGION_SPECS[region]

		frames[region] = scope:New "Frame" {
			Name = region,
			AnchorPoint = spec.AnchorPoint,
			Position = regionPosition(spec, topBarInset),
			-- Sized by its tiles, never by a counted allowance. A region holding nothing measures
			-- 0x0 and costs nothing.
			Size = UDim2.fromOffset(0, 0),
			AutomaticSize = Enum.AutomaticSize.XY,
			BackgroundTransparency = 1,
			-- nil, not `true`, for a centre region or an unyielded host: Fusion leaves the property at
			-- its default rather than binding anything, so the two regions that must never be taken
			-- away have no binding that could take them away.
			Visible = if yield ~= nil and spec.Ambient then yield.AmbientVisible else nil,

			[Children] = scope:New "UIListLayout" {
				FillDirection = Enum.FillDirection.Vertical,
				HorizontalAlignment = spec.HorizontalAlignment,
				Padding = UDim.new(0, TILE_GAP),
				SortOrder = Enum.SortOrder.LayoutOrder,
			},
		} :: Frame
	end

	-- THE ONE PLACE THE AMBIENT LAYER GETS ITS SCALE, and the actual fix for plan §2.4. Every tile in
	-- this host -- the dock included, since BottomCentre is the dock's -- is authored in raw pixels,
	-- and before this they were the only surfaces on screen that did not grow with the viewport while
	-- the dock did. One UIScale on one host is what makes them agree. It is a value PASSED IN rather
	-- than computed here, for the reason Surface's header gives: a Compute per surface is a
	-- ViewportSize connection per surface.
	--
	-- The host is also where IgnoreGuiInset now comes from, rather than being omitted here as it was
	-- through Phase 1 -- see topBarInset above for what that costs the top-anchored regions and why
	-- it moves none of them at scale 1.0.
	-- THE SCRIM: how the ambient layer steps back behind an open panel, and the answer to plan 2.5.
	--
	-- A SHEET OVER THE LAYER, NOT A TRANSPARENCY ON IT, and that is forced rather than chosen. Roblox
	-- offers exactly one way to fade a subtree as a unit -- a CanvasGroup -- and a CanvasGroup CLIPS
	-- its descendants to its own bounds. BottomCentre's tile deliberately pins the armament island at
	-- x = -224, outside the region frame it lives in (Screens/HUD/init.lua's dock band note explains
	-- why the dock cannot be allowed to move for it), so a CanvasGroup region would clip the island
	-- away the moment it was introduced. A full-bleed sheet drawn over the whole host has no such
	-- constraint, costs one Frame, and dims the world along with the chrome -- which is what an
	-- elevated panel wants behind it anyway.
	--
	-- IT DOES NOT SWALLOW INPUT. A plain Frame is invisible to Roblox's hit-testing unless it is
	-- Active or a GuiButton (Components/ModalScreen.lua's header has the long version), so the dock's
	-- ability slots underneath stay clickable. They are gated by Constants.Attributes.UiModalOpen
	-- anyway while this is up; the point is that the scrim adds no second, quieter gate of its own.
	--
	-- THE TWEEN IS ON THE GOAL, NOT DOWNSTREAM OF IT. The Computed below runs on mode EDGES only and
	-- the tween carries its output straight into a property -- so there is no Computed recomputing
	-- per frame while it travels, which is plan 11 rule 5 (VitalIcon's "exactly 0 when nothing is
	-- happening" standard). EnterTween rather than a fourth spring, per the plan: this is a whole
	-- surface arriving, and it should move on the same curve as the panel arriving on top of it.
	local scrim = if yield ~= nil
		then scope:New "Frame" {
			Name = "Scrim",
			Size = UDim2.fromScale(1, 1),
			BackgroundColor3 = Tokens.Color.Background,
			BackgroundTransparency = scope:Tween(
				scope:Computed(function(use)
					return 1 - use(yield.Dim) * (1 - SCRIM_TRANSPARENCY)
				end),
				Tokens.Motion.EnterTween
			),
			BorderSizePixel = 0,
			ZIndex = SCRIM_ZINDEX,
		}
		else nil

	local gui = Surface.New(scope, {
		Name = "Regions",
		Layer = Layers.Regions,
		Parent = playerGui,
		Scaled = true,
		Scale = scale,
		Children = { frames, scrim },
	})

	local host = {} :: RegionHost
	host.Gui = gui

	function host.Add(_self: RegionHost, region: Region, order: number, tile: GuiObject): ()
		local frame = frames[region]
		if frame == nil then
			error(string.format("Regions: no such region %q", tostring(region)), 2)
		end

		-- See contract 2 in the header. A bottom-anchored region negates the order so that the
		-- caller's "10 is nearest the edge" means the same thing at both ends of the screen.
		tile.LayoutOrder = if REGION_SPECS[region].AnchoredToBottom then -order else order
		tile.Parent = frame
	end

	return host
end

return Regions
