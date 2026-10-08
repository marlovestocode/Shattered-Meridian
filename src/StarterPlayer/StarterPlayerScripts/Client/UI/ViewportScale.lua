--!strict
--[[
	ViewportScale.lua

	Owns: the single answer to "how big should this surface be on THIS player's screen" -- a reactive
	0..1.5 multiplier derived from the live viewport, handed to a UIScale.

	WHY A MULTIPLIER AND NOT SCALE-BASED SIZING. Every surface in this UI is authored in pixels, and
	that is deliberate rather than lazy: a 1px hairline, a 48px vital tile and a 12px type step are
	all sized against each other, and expressing any of them as a fraction of the screen breaks that
	relationship the moment the aspect ratio changes. So the layout stays in pixels and the WHOLE
	thing is scaled once at the root -- which keeps every internal proportion exact and turns
	"support 4K" into one multiplier instead of a scale/offset audit of several hundred numbers.

	EXTRACTED from Components/ModalScreen.lua, which authored this and was its only caller until the
	hotbar dock needed the same curve (2026-08-25). Two callers is the bar this codebase already used
	for Components/CornerBracket.lua coming out of Panel.lua, and the reason it matters more than
	usual here: a second hand-rolled copy would not merely duplicate code, it would let a modal and
	the HUD disagree about how big the same player's screen is, which is visible.

	Lives beside Tokens.lua rather than in Components/ because it renders nothing -- it is layout
	math, the same shelf as Geometry.lua and Meter.lua.

	Reactive, unlike Tokens.lua's IS_TOUCH: a desktop player can resize their window mid-session, so
	this is a live value rather than a per-session fact -- the same call Screens/Onboarding/
	Attributes.lua's PipRail makes, and the same nil-camera guard.
]]

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)

type Scope = Fusion.Scope<typeof(Fusion)>

local ViewportScale = {}

-- The resolution these surfaces were authored against -- scale 1.0 renders them at their literal
-- authored pixel size. Not a "supported minimum": MIN_SCALE below is what handles a smaller screen.
local REFERENCE_WIDTH = 1366
local REFERENCE_HEIGHT = 768
-- Below 1.0 a surface is being shrunk to fit a screen smaller than the reference; the floor is where
-- shrinking stops buying anything and starts making the text worse than the overflow would have been.
local MIN_SCALE = 0.8
-- Above this the chrome stops reading as a game panel and starts reading as a poster. A 1px hairline
-- at 1.5 is still a hairline; at 2.5 it is a border.
local MAX_SCALE = 1.5

ViewportScale.REFERENCE_WIDTH = REFERENCE_WIDTH
ViewportScale.REFERENCE_HEIGHT = REFERENCE_HEIGHT
ViewportScale.MIN_SCALE = MIN_SCALE
ViewportScale.MAX_SCALE = MAX_SCALE

-- The live viewport multiplier. Connect once per scope and read it from as many places as you like;
-- the connection is registered on the scope, so teardown is the caller's existing doCleanup.
function ViewportScale.Compute(scope: Scope): Fusion.Computed<number>
	local camera = Workspace.CurrentCamera
	local viewport = scope:Value(if camera then camera.ViewportSize else Vector2.new(REFERENCE_WIDTH, REFERENCE_HEIGHT))
	if camera then
		table.insert(
			scope,
			camera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
				viewport:set(camera.ViewportSize)
			end)
		)
	end
	return scope:Computed(function(use)
		local size = use(viewport)
		-- The SMALLER of the two ratios, so a surface scaled to fit a wide-but-short window is
		-- bounded by the height it actually has rather than by the width it does not need.
		local raw = math.min(size.X / REFERENCE_WIDTH, size.Y / REFERENCE_HEIGHT)
		return math.clamp(raw, MIN_SCALE, MAX_SCALE)
	end)
end

-- Room kept clear around a fitted panel, and the top bar's band (the Roblox chrome a ScreenGui that respects
-- the GUI inset loses).
local FIT_MARGIN = 16
local TOP_INSET = 58
-- Below this a fitted panel's text stops being worth reading; past it the panel is allowed to overflow.
local FIT_MIN_SCALE = 0.6

-- Compute's multiplier, lowered as far as it must go for a `size`-pixel panel to fit the live viewport (down
-- to FIT_MIN_SCALE). For a panel too large for the reference resolution itself, which Compute alone would
-- clip at exactly the screen it calls 1.0 (a 780-tall panel on a 768-tall laptop).
function ViewportScale.Fit(scope: Scope, size: Vector2): Fusion.Computed<number>
	local curve = ViewportScale.Compute(scope)
	local camera = Workspace.CurrentCamera
	local viewport = scope:Value(if camera then camera.ViewportSize else Vector2.new(REFERENCE_WIDTH, REFERENCE_HEIGHT))
	if camera then
		table.insert(
			scope,
			camera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
				viewport:set(camera.ViewportSize)
			end)
		)
	end
	return scope:Computed(function(use)
		local screen = use(viewport)
		local fit = math.min(
			(screen.X - FIT_MARGIN * 2) / math.max(size.X, 1),
			(screen.Y - TOP_INSET - FIT_MARGIN * 2) / math.max(size.Y, 1)
		)
		return math.max(math.min(use(curve), fit), FIT_MIN_SCALE)
	end)
end

return ViewportScale
