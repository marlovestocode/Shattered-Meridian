--!strict
--[[
	Shell/Layers.lua

	Owns: the client's z-order ladder, as named bands. Every ScreenGui's DisplayOrder is a Layers.*
	reference or a Layers.<Band> + n nudge within one, and never a literal.

	Does NOT own: which band any particular screen belongs to (that is the screen's own mount site),
	ordering WITHIN a band beyond providing the room for it, or anything about position, size or
	visibility. This file is data and two pure predicates. It has no state, no connections and
	nothing to tear down.

	THE BUG IT CLOSES. Four of seventeen surfaces set DisplayOrder at all -- EmoteWheel 10,
	Onboarding 10, Loading 20, StartMenu 30. The other thirteen, including the HUD, the combat
	feedback layer, the kill feed, the announcement banner and EVERY ModalScreen, sit at the default
	0 and stack by PlayerGui insertion order, which is mount order in UI/init.lua. Three consequences
	were live when this was written: ShiftLockCrosshair (mounted late) drew over every panel mounted
	before it; the announcement banner had no defined relationship to a modal; and EmoteWheel's 10
	collided exactly with Onboarding's 10, which is harmless only because the two are never
	simultaneously mounted -- a fact nothing enforces and nobody would notice breaking.

	WHY SPACED BY 100 AND NOT BY 1. Bands need headroom because ordering within one is a real
	requirement, not a hypothetical: two modals open at once is documented behaviour (see
	Constants.Attributes.UiModalOpen's own comment, and the fact that ModalScreen's openModalCount is
	module-scope rather than per-instance precisely because of it). If every modal took the same
	number they would z-fight and the winner would be PlayerGui insertion order -- which, for the
	Lazy-deferred screens, is FIRST-OPEN order, so it would vary between sessions depending on which
	panel the player happened to open first. 100 per band leaves room for a monotonic counter without
	any band ever being able to climb into the next one.

	The gaps are deliberately large enough that a nudge cannot silently reach the next band, and
	BandOf below is what makes that checkable rather than assumed.
]]

local Layers = {}

-- Spacing between band bases. Also the width of a band: an order belongs to a band if it is at or
-- above that band's base and less than base + Spacing.
Layers.Spacing = 100

-- World-anchored reticles and crosshairs. Below everything, because it is drawn ON the world rather
-- than on top of the UI -- ShiftLockCrosshair is the only current occupant.
Layers.World = 100

-- The single region host (Shell/Regions.lua) -- the HUD dock, the ambient corner tiles and the
-- feeds. ONE ScreenGui for all six regions, not one per region and not one per screen; see
-- Regions.lua's header for why that is what actually resolves the corner collisions rather than
-- merely making them deterministic.
Layers.Regions = 200

-- Transient things drawn over the HUD but under a panel the player opened deliberately:
-- CombatFeedback, the emote wheel, the death overlay, the posture-break banner.
Layers.Overlay = 300

-- Every ModalScreen / ScreenFrame. Takes Modal + n from ModalScreen's own monotonic open counter so
-- the last-opened panel renders on top, which is the only behaviour a player would predict.
Layers.Modal = 400

-- Developer surfaces: the Live Console (F5) and the parkour debug overlay (F6). Above modals on
-- purpose -- a debug overlay that a panel can cover is not a debug overlay.
Layers.Debug = 500

-- Boot and cinematic surfaces: Onboarding, Loading, StartMenu, BlackScreen, Intro. Above everything,
-- because while one of these is up it IS the screen.
Layers.Boot = 600

-- The band bases, in ascending order. Kept as a list beside the named fields rather than derived
-- from them, because deriving it would mean iterating the module table -- which also holds Spacing
-- and these functions, and would silently start treating a future non-band field as a band.
local BANDS: { { Name: string, Base: number } } = {
	{ Name = "World", Base = Layers.World },
	{ Name = "Regions", Base = Layers.Regions },
	{ Name = "Overlay", Base = Layers.Overlay },
	{ Name = "Modal", Base = Layers.Modal },
	{ Name = "Debug", Base = Layers.Debug },
	{ Name = "Boot", Base = Layers.Boot },
}

-- Whether `order` is exactly a band base -- i.e. an unnudged Layers.<Band>. Most surfaces are, and a
-- surface that is not should be able to say why.
function Layers.IsBand(order: number): boolean
	for _, band in BANDS do
		if band.Base == order then
			return true
		end
	end
	return false
end

-- The name of the band containing `order`, or nil if it falls outside every band. This is the check
-- worth making about a real DisplayOrder, because a legitimate one may be nudged (Layers.Boot + 20)
-- and IsBand would reject it. nil means either a raw literal that predates this ladder or a nudge
-- that has overrun its band -- both of which are the mistake this module exists to make findable.
function Layers.BandOf(order: number): string?
	for _, band in BANDS do
		if order >= band.Base and order < band.Base + Layers.Spacing then
			return band.Name
		end
	end
	return nil
end

return Layers
