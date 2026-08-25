--!strict
--[[
	Shell/Regions.lua

	Owns: the six named screen regions, the single ScreenGui that hosts all of them, where each
	region sits relative to its screen edge, and the order tiles stack in within one.

	Does NOT own: what a tile contains, when a tile is visible, or how a tile enters. A tile is
	handed in fully built; this file parents it and assigns its LayoutOrder, and that is all.

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
	-- The one host ScreenGui. Exposed for Phase 3's yielding binding (the whole ambient layer steps
	-- back as a unit) and for the specs -- not so callers can parent into it directly.
	Gui: ScreenGui,
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
	},
	TopCentre = {
		AnchorPoint = Vector2.new(0.5, 0),
		AnchoredToBottom = false,
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		AnchorScale = Vector2.new(0.5, 0),
		ClearsTouchControls = false,
		EdgeInsetOverride = COMBAT_BANNER_BAND_BOTTOM + EDGE_INSET,
	},
	TopRight = {
		AnchorPoint = Vector2.new(1, 0),
		AnchoredToBottom = false,
		HorizontalAlignment = Enum.HorizontalAlignment.Right,
		AnchorScale = Vector2.new(1, 0),
		ClearsTouchControls = false,
	},
	BottomLeft = {
		AnchorPoint = Vector2.new(0, 1),
		AnchoredToBottom = true,
		HorizontalAlignment = Enum.HorizontalAlignment.Left,
		AnchorScale = Vector2.new(0, 1),
		ClearsTouchControls = true,
	},
	BottomCentre = {
		AnchorPoint = Vector2.new(0.5, 1),
		AnchoredToBottom = true,
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		AnchorScale = Vector2.new(0.5, 1),
		-- The dock sits BETWEEN the thumbstick and the jump button, not under either, so it takes the
		-- ordinary edge inset. Lifting it too would be a mobile layout decision, not a clearance.
		ClearsTouchControls = false,
	},
	BottomRight = {
		AnchorPoint = Vector2.new(1, 1),
		AnchoredToBottom = true,
		HorizontalAlignment = Enum.HorizontalAlignment.Right,
		AnchorScale = Vector2.new(1, 1),
		ClearsTouchControls = true,
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
function Regions.Mount(scope: Scope, playerGui: PlayerGui, scale: Fusion.UsedAs<number>): RegionHost
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
	local gui = Surface.New(scope, {
		Name = "Regions",
		Layer = Layers.Regions,
		Parent = playerGui,
		Scaled = true,
		Scale = scale,
		Children = frames,
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
