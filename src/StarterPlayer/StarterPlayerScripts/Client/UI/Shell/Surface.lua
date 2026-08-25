--!strict
--[[
	Shell/Surface.lua

	Owns: every ScreenGui this client creates that is NOT a region tile -- its band on the ladder, the
	coordinate space it draws in, and whether it grows with the player's screen. One factory, so those
	three questions are answered once instead of once per surface.

	Does NOT own: what a surface contains, when it is Enabled (the caller passes its own state), where
	inside itself anything sits, or the six ambient corner tiles -- those have no ScreenGui at all and
	belong to Shell/Regions.lua, which is itself one caller of this file.

	THE TWO BUGS IT CLOSES, both of the same shape: a question every surface was answering
	independently, and answering differently.

	  1. COORDINATE SPACE (plan 2.3). IgnoreGuiInset was true on exactly three surfaces -- HUD,
	     CombatFeedback and StartMenu -- and absent on the other six always-on panels. So
	     Tokens.Space.L "from the top" meant 16px for the dock and 16px plus Roblox's own 36px top bar
	     for the kill feed. The margins were authored to match and did not, and nothing in the source
	     of either file said so: the difference lived in a property one of them set and the other
	     omitted. Every surface built here is full-bleed, so a surface's (0, 0) is the screen's (0, 0)
	     and a margin means the same number of pixels wherever it is written.

	  2. AUTOSCALE (plan 2.4). UI/ViewportScale.lua had exactly two callers -- Components/
	     ModalScreen.lua and Screens/HUD/init.lua -- and every ambient panel was raw pixels with no
	     UIScale at all. At 2560x1440 the dock scaled to 1.5 and the fuel gauge, weapon rack, helm
	     console and carried-resources tile sitting next to it did not. ViewportScale's own header
	     names this as the thing it exists to prevent ("a second hand-rolled copy would let a modal
	     and the HUD disagree about how big the same player's screen is, which is visible") -- and the
	     ambient panels were that disagreement by OMISSION rather than by a second copy, which is why
	     that header did not stop it.

	CLEARING ROBLOX'S OWN TOP BAR IS NOW A LAYOUT PROBLEM, NOT A PROPERTY. That is the whole trade
	IgnoreGuiInset = true makes, and it is worth stating plainly rather than discovering: a surface
	that draws at the top edge is now responsible for the ~36px of chrome Roblox draws there, because
	nothing insets it any more. TopBarInset below is that number, read from GuiService rather than
	hardcoded, and there are exactly two readers -- Shell/Regions.lua's top-anchored regions and
	Client/Parkour/ParkourDebug.lua, whose readout previously hid its two most important lines under
	the top bar the one time it tried IgnoreGuiInset = true. Everything else here is either centred,
	full-bleed, or anchored to an edge Roblox does not decorate.

	NO SINGLETON, AND THE SCOPE IS AN ARGUMENT, because five callers run before UI.Mount() exists.
	Main.client.lua calls LoadingClient.Run() and then IntroClient.Run() -- which blocks through the
	entire cinematic and character creator -- and only then reaches UI.Mount(). Screens/Onboarding
	mounts on its OWN temporary Fusion scope, torn down before the root scope is ever created, and
	Client/Parkour/ParkourDebug.lua builds and tears down a scope of its own at runtime. So Loading,
	Onboarding, StartMenu, BlackScreen and the intro greeting all build surfaces in a window where
	there is no root scope, no region host and no Chrome to register with. Reading anything global
	here would make those five a special case; taking the scope as an argument makes them ordinary.

	SCALED IS REQUIRED AND DEFAULTS TO NOTHING, and so is Layer. Both are questions with no safe
	default: a band that defaulted would be a surface silently at the bottom of the ladder, and a
	Scale that defaulted to "compute my own" would be a second ViewportSize connection per surface,
	which is exactly the idle cost plan 11 rule 2 forbids. Passing Scaled = true without a Scale is an
	error rather than a fallback for that reason -- the value has to come from the ONE Compute the
	root scope made.

	THE PLAN SPECCED Scaled AS DEFAULTING TO TRUE. It does not, and the reason is that Phase 1 landed
	first: six of the surfaces that default was written for no longer exist, having collapsed into the
	single region host. Of what is left, most is either full-bleed (where a scale is meaningless), a
	reticle drawn at a world-space aim point, a debug readout that wants literal pixels, or a modal
	whose own AutoScale prop has owned this since before this file did. Scaled = true is now the
	minority answer, and a default that is wrong more often than it is right is worse than no default.
	The rule that replaces it: A SURFACE IS SCALED IF IT DRAWS CHROME ALONGSIDE THE DOCK. That is what
	2.4 is actually about -- two things visible at once disagreeing about how big the screen is.
]]

local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)

local Layers = require(script.Parent.Layers)

local Children = Fusion.Children

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>

export type SurfaceProps = {
	Name: string,
	-- REQUIRED, with no default: a Layers.<Band>, or a Layers.<Band> + n nudge within one. Checked
	-- against Layers.BandOf below, so a raw literal (the 0/10/20/30 thirteen surfaces used to carry)
	-- errors at mount rather than rendering somewhere unpredictable.
	Layer: number,
	Parent: PlayerGui,
	-- REQUIRED, with no default -- see this file's header. true means the surface grows with the
	-- player's screen and MUST be given the Scale below.
	Scaled: boolean,
	-- The ONE viewport multiplier, computed once on the root scope (UI/init.lua) and passed to every
	-- scaled surface. Never call ViewportScale.Compute here: each call opens its own ViewportSize
	-- connection, and one per surface is the exact cost this file exists to avoid.
	Scale: UsedAs<number>?,
	-- Defaults to true. Passed straight through, so a caller driving a panel from a Fusion Value keeps
	-- doing that -- Components/ModalScreen.lua in particular reads this property back off the built
	-- Instance as the rendered truth behind its modal count.
	Enabled: UsedAs<boolean>?,
	Children: any?,
}

local Surface = {}

-- The height of Roblox's own top bar, in the coordinate space this file establishes. Read rather
-- than hardcoded to 36, because it is Roblox's number to change and a stale constant here would put
-- a panel under their chrome with nothing to explain why.
--
-- A FUNCTION, NOT A MODULE CONSTANT, and deliberately not memoized -- the same reasoning
-- Shell/Regions.lua's header gives for its host. This module is required on the server by
-- scripts/run-tests.lua's client load-check, where GuiService reports (0, 0); resolving it at require
-- time would bake a headless zero into a value only the client ever uses. Callers read it once at
-- their own mount, on the client, which is both correct and cheap.
function Surface.TopBarInset(): number
	local ok, inset = pcall(function()
		return (GuiService:GetGuiInset())
	end)
	if not ok or typeof(inset) ~= "Vector2" then
		return 0
	end
	return inset.Y
end

-- Builds one full-bleed ScreenGui on the scope it is given and returns it. The Instance is returned
-- rather than a handle because two callers need it afterward for reasons this file has no business
-- knowing about: ModalScreen watches its Enabled edge, and Intro/BlackScreen hands it to the
-- cinematic that fades it.
function Surface.New(scope: Scope, props: SurfaceProps): ScreenGui
	if props.Layer == nil then
		error(string.format("Surface %q: Layer is required -- pass a Shell/Layers band.", props.Name), 2)
	end
	if Layers.BandOf(props.Layer) == nil then
		error(
			string.format(
				"Surface %q: DisplayOrder %d is not inside any Shell/Layers band. Pass Layers.<Band> "
					.. "or Layers.<Band> + n, never a literal.",
				props.Name,
				props.Layer
			),
			2
		)
	end
	if props.Scaled == nil then
		error(
			string.format(
				"Surface %q: Scaled is required -- true if this surface draws chrome alongside the "
					.. "dock, false if it is full-bleed, a world-space reticle or a literal-pixel readout.",
				props.Name
			),
			2
		)
	end
	if props.Scaled and props.Scale == nil then
		error(
			string.format(
				"Surface %q: Scaled = true needs the Scale the root scope computed. Do not call "
					.. "ViewportScale.Compute here -- that is a second ViewportSize connection.",
				props.Name
			),
			2
		)
	end

	-- Parented to the ScreenGui itself rather than wrapped around the caller's content, and that
	-- distinction is load-bearing: MEASURED 2026-08-25 against a real render pass, a UIScale under a
	-- ScreenGui multiplies its descendants' OFFSETS (both size and position) while leaving a
	-- Size = UDim2.fromScale(1, 1) child at exactly the viewport. The same UIScale one level lower,
	-- inside a full-bleed Frame, inflates that Frame to 1.5x the screen instead. So this is the one
	-- placement where "scale the chrome" and "full-bleed stays full-bleed" are both true, which is
	-- what lets a single flag serve a corner panel and a cinematic backdrop.
	--
	-- It also means an edge margin written as an offset scales for free. Screens/HUD/init.lua used to
	-- multiply Tokens.Space.L by the scale by hand, with a comment explaining that a UIScale does not
	-- touch Position -- true of ITS UIScale, which sat on the band stack, but not of one up here.
	local scaleChild = if props.Scaled then scope:New "UIScale" { Scale = props.Scale } else nil

	return scope:New "ScreenGui" {
		Name = props.Name,
		DisplayOrder = props.Layer,
		-- The 2.3 decision, in one place. See this file's header for what it costs and who pays it.
		IgnoreGuiInset = true,
		ResetOnSpawn = false,
		Enabled = if props.Enabled == nil then true else props.Enabled,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Parent = props.Parent,

		[Children] = { props.Children, scaleChild },
	} :: ScreenGui
end

return Surface
