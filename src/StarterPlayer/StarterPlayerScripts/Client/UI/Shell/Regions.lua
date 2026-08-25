--!strict
--[[
	Shell/Regions.lua

	Owns: the six named screen regions, the single ScreenGui that hosts all of them, where each
	region sits relative to its screen edge, and the order tiles stack in within one.

	Does NOT own: what a tile contains, when a tile is visible, or how a tile enters. A tile is
	handed in fully built; this file parents it and assigns its LayoutOrder, and that is all. It also
	does not own the HUD dock -- BottomCentre is reserved for it and the dock adopts this in Phase 2
	of docs/architecture/2026-08-25-hud-shell-plan.md, not here.

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
-- announcement banner has always sat exactly one edge inset below it, at 184.
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

local function regionPosition(spec: RegionSpec): UDim2
	local verticalInset = spec.EdgeInsetOverride or EDGE_INSET
	if spec.ClearsTouchControls and IS_TOUCH then
		verticalInset += TOUCH_CONTROL_CLEARANCE
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
function Regions.Mount(scope: Scope, playerGui: PlayerGui): RegionHost
	local frames: { [Region]: Frame } = {}

	for _, region in REGION_ORDER do
		local spec = REGION_SPECS[region]

		frames[region] = scope:New "Frame" {
			Name = region,
			AnchorPoint = spec.AnchorPoint,
			Position = regionPosition(spec),
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

	local gui = scope:New "ScreenGui" {
		Name = "Regions",
		DisplayOrder = Layers.Regions,
		ResetOnSpawn = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		-- NOT IgnoreGuiInset, deliberately, and only for now. None of the six screens this host
		-- adopts set it either, so leaving it off is what keeps their margins byte-identical through
		-- this migration. Choosing ONE coordinate space for every surface is Phase 2's job (§2.3),
		-- and doing it here would silently move six panels by the top bar's height while claiming to
		-- be a pure position refactor.
		Parent = playerGui,

		[Children] = frames,
	} :: ScreenGui

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
