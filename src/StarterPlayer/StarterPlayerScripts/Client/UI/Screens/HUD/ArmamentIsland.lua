--!strict
--[[
	HUD/ArmamentIsland.lua

	Owns: the armament readout BOLTED TO THE HOTBAR DOCK'S LEFT EDGE -- the plate, the joint, the
	entrance, and the four facts on it (which weapon the draw key acts on, whether it is in hand, how
	many others are behind it, and the two keys that move any of that).

	LIVES UNDER Screens/HUD/ RATHER THAN UNDER Screens/WeaponInventory/, AND THAT IS THE WHOLE POINT.
	This is not a panel that happens to sit near the dock; it is one half of a JOINT, and a joint has
	exactly one owner. Screens/HUD/init.lua owns the dock's plate, its chamfer, its bronze brackets
	and its violet edge -- so the surface that has to share an edge with it is written twenty lines
	away from those props rather than in another folder restating them from memory. The previous
	version lived beside the state that drives it and drifted: it kept its own full border and its own
	full chamfer on the shared side, was 52px tall against a 98px dock, and sat Tokens.Space.L away.
	Three panels' worth of chrome between two objects that were supposed to read as one.

	Screens/WeaponInventory/init.lua still owns the STATE (the Fusion Values and the SetInventory
	handle Client/Combat/WeaponInventoryClient.lua drives) and hands it here as an ArmamentState. That
	direction was already the documented one -- a content module must not depend on its own container
	-- and it survives intact: this file requires nothing from WeaponInventory, and WeaponInventory
	requires nothing from here.

	THE SEAM, WHICH IS THE ONLY REASON ANY OF THE GEOMETRY BELOW IS SHAPED THE WAY IT IS.

	  1. NEGATIVE GAP -- the island sinks SEAM_OVERLAP into the dock. This was a butt joint at gap
	     zero until 2026-08-25 and it was visibly wrong, for a reason that only shows up once BOTH
	     halves are chamfered: an island clipped flat at the seam ends its full ISLAND_HEIGHT tall,
	     while the dock's left edge exists only between its own two cut corners -- two chamfer depths
	     shorter. The dock's cut voids went unfilled, so the assembly's top and bottom edges each had
	     an eight-pixel triangular notch at the join. See SEAM_OVERLAP.
	  2. THE ISLAND DRAWS NO EDGE ON THAT SIDE. Its plate is built PLATE_WIDTH wide -- ISLAND_WIDTH
	     plus BLEED -- inside a slot exactly ISLAND_WIDTH wide that clips. Everything in the bleed is
	     cut off at the seam and never renders: the plate's right-hand stroke, its two right-hand
	     chamfer cuts, and its two right-hand corner brackets. Two panels each keeping their own
	     border at a join is exactly what makes it read as two panels touching, and no amount of
	     closing the gap fixes it. With rule 1's sink the two fills then MERGE and the dock's own left
	     stroke is covered, so Screens/HUD draws the shared rule at the island's clipped edge instead
	     of inheriting it -- exactly as the helm console does for the furnace plate.
	  3. ONE HEIGHT, SO THE EDGES ARE CONTINUOUS. ISLAND_HEIGHT is the dock's measured height, so the
	     two top edges form one unbroken line and the two bottom edges form another. This is the
	     single strongest "one object" cue available and the old panel had none of it.
	  4. THE SAME CONTENT BASELINE. The Y inset below is Tokens.Space.M -- the dock's own -- so both
	     surfaces' contents sit on the same interior line rather than merely inside boxes of the same
	     height.
	  5. BRONZE AT THE ASSEMBLY'S OUTER CORNERS ONLY. The island keeps the dock's bracket treatment
	     prop for prop, but only its LEFT pair ever renders (the right pair is in the bleed). So the
	     combined object has four bracketed corners, the way one panel does, and nothing marking the
	     interior. The dock's own left-hand elbows stop reading as that panel's corner and start
	     reading as the clamps holding this one in.
	The visible fastener -- one bronze bead straddling the seam -- belongs to the dock band rather
	than to this file, because half of it sits on the dock. See Screens/HUD/init.lua.

	THE ENTRANCE IS A DRAWER, NOT A WIPE. The slot's WIDTH springs (a laid-out or pinned child's
	Position is a property a layout owns, but nothing overwrites a Size), and the plate is anchored to
	the slot's LEFT edge -- so as the slot grows, the plate's leading edge travels outward and the
	plate translates with it. Anchoring it to the stationary right edge instead would keep the plate
	still and reveal it through a moving window, which reads as a wipe rather than as a thing being
	pushed out of the hotbar. The plate never reflows: its own Size is a fixed offset on both axes, so
	the name, the beads and the key row are laid out exactly once no matter how many frames the spring
	takes.

	BLEED IS COMPUTED, NOT TYPED, and the overshoot is why. Tokens.Motion.IslandSpring is the only
	under-damped spring in the HUD (see its own comment), so the slot passes ISLAND_WIDTH before
	settling -- which briefly shows MORE of the plate than its rest width. Empty plate is exactly what
	should be there; a half-clipped bronze bracket is not. So BLEED clears the bracket zone plus the
	spring's own analytic peak overshoot, and retuning the damping moves it automatically instead of
	silently exposing a corner treatment mid-flight.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)

local Types = require(ReplicatedStorage.Shared.Types)
local WeaponRoster = require(ReplicatedStorage.Shared.Combat.WeaponRoster)

local Tokens = require(script.Parent.Parent.Parent.Tokens)
local ChamferedSurface = require(script.Parent.Parent.Parent.ChamferedSurface)
local Panel = require(script.Parent.Parent.Parent.Components.Panel)
local KeyCap = require(script.Parent.Parent.Parent.Components.KeyCap)
local Label = require(script.Parent.Parent.Parent.Components.Label)
local Stack = require(script.Parent.Parent.Parent.Components.Stack)
local Inset = require(script.Parent.Parent.Parent.Components.Inset)

local Children = Fusion.Children

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>

-- What the island needs from whoever owns the inventory, and nothing more. Declared here because
-- this file is the consumer; Screens/WeaponInventory/init.lua matches it structurally rather than
-- importing it, so neither module requires the other (Luau types are structural).
export type ArmamentState = {
	-- Every weapon id the player has picked up, in the server's own pickup order.
	Owned: UsedAs<{ string }>,
	-- Which of them the draw key acts on. nil only for an empty inventory.
	Selected: UsedAs<string?>,
	-- Whether Selected is in hand right now.
	Drawn: UsedAs<boolean>,
}

export type Island = {
	-- The pinned, clipping slot. Screens/HUD parents this into the dock band; it positions itself
	-- against that band's own box, which is the dock's.
	Content: GuiObject,
	-- The 0..1+ entrance spring, so the dock band can fade its seam bead in on the same value rather
	-- than running a second one that can disagree with this one about how far out the island is.
	Presence: UsedAs<number>,
}

-- THE DOCK'S MEASURED HEIGHT, and the one number in this file that describes a surface it does not
-- own. Not derivable: the dock's height is content-driven (its tallest module well plus its own Y
-- inset), and Roblox resolves that at layout time, in SCREEN pixels after the region host's UIScale
-- -- so reading it back would be the same pre/post-scale trap that made the previous version's mirror
-- spacer necessary. What makes a literal safe here is that Tests/UI/Hotbar.spec.lua asserts the
-- island and the dock measure the same height in a real layout pass: if a module in the dock grows,
-- the suite fails loudly instead of the seam quietly developing a step in it.
local ISLAND_HEIGHT = 98

-- 224, which is not a round number by accident. ViewportScale authors this UI against a 1366px
-- reference and never lets the effective local width fall below it above the MIN_SCALE floor, so the
-- dock (870, centred) leaves (1366 - 870) / 2 = 248px to its left. 224 lands the island's outer edge
-- exactly Tokens.Space.XL clear of the screen's own edge at the reference width, which is the same
-- margin Shell/Regions gives every other tile.
local ISLAND_WIDTH = 224

-- CornerBracket geometry, restated as the region of the plate a bracket can occupy: BracketInset in
-- from the corner, then BracketArmLength along the edge.
local BRACKET_ARM_LENGTH = 10
local BRACKET_INSET = ChamferedSurface.CHAMFER_PX
local BRACKET_ZONE = BRACKET_INSET + BRACKET_ARM_LENGTH

-- A second-order step response overshoots by exp(-pi*z / sqrt(1 - z^2)) -- the standard result, and
-- the same one Tokens.Motion.IslandSpring's own comment quotes to justify its damping. At z = 0.68
-- that is about 5.4%, so the slot peaks near 236px before settling to 224.
local DAMPING = Tokens.Motion.IslandSpring.Damping
local PEAK_OVERSHOOT = math.exp(-math.pi * DAMPING / math.sqrt(1 - DAMPING * DAMPING))

-- Everything past the seam. Wide enough that the plate's right-hand chrome stays outside the slot at
-- the spring's peak, with a Tokens.Space.M cushion so a small retune doesn't land exactly on the
-- boundary.
-- HOW FAR THE ISLAND SITS INTO THE DOCK. The chamfer depth, for the reason seam rule 1 above gives:
-- it is exactly the distance past which the dock's own two left cut corners have finished, so an
-- island clipped there covers both voids and the assembly's top and bottom edges run straight through
-- the join instead of notching at it.
--
-- Screens/BlimpHelm/FurnacePlate.lua reached this first, vertically, and this is the same fix rotated
-- (owner, 2026-08-25 -- "fix the connection inconsistency on the hotbar island"). The two joints in
-- this UI now keep one contract, which is the whole reason the second one was worth changing.
local SEAM_OVERLAP = ChamferedSurface.CHAMFER_PX

-- The slot's full travel, which is what the bleed has to clear at the spring's peak -- not
-- ISLAND_WIDTH, which is only where it comes to rest. Under-computing it by the sink is harmless at
-- the current damping and is exactly the sort of thing that stops being harmless after one retune.
local SLOT_TRAVEL = ISLAND_WIDTH + SEAM_OVERLAP

local BLEED = math.ceil(SLOT_TRAVEL * PEAK_OVERSHOOT) + BRACKET_ZONE + Tokens.Space.M
local PLATE_WIDTH = SLOT_TRAVEL + BLEED

-- The readout column's three rows. Named rather than inlined because the column is AutomaticSize.Y
-- and these are what it sums to -- 20 + 4 + 12 + 4 + 19 = 59 inside 74px of content height, so the
-- column has room to grow one more row before anything has to move.
local NAME_HEIGHT = 20
local BEAD_ROW_HEIGHT = 12
local KEYCAP_WIDTH = 21
local KEYCAP_HEIGHT = 19

-- The scabbard well: the dock's own module-group treatment (recessed wash, hairline stroke, 2px
-- radius) wrapped round the glyph, so the glyph reads as a MODULE of the same instrument rather than
-- as a loose icon parked beside some text. Sized from the glyph plus the dock's own well inset.
local WELL_INSET_X = Tokens.Space.S
local WELL_INSET_Y = Tokens.Space.S

-- THE RACK, AS BEADS RATHER THAN AS ROWS OF NAMES. The previous version listed the names of weapons
-- you are not holding, two at a time, under a "+N MORE" line -- between-fights information, rendered
-- permanently, on the surface with the least room in the game, and the direct cause of that panel
-- being unbounded in height (Workspace.Weapons is unbounded, so a builder adding models grew it).
-- What the cycle key actually needs answered is "how many, and which one am I on", and a strip of
-- beads answers exactly that at a FIXED height, in the mark this UI already uses for a point on a
-- line (Components/Divider.lua's flourish, Components/MeridianField.lua's threads). The names live
-- one keypress away in the character menu, which is the register they belong to.
local MAX_BEADS = 6
local BEAD_SELECTED_SIZE = 7
local BEAD_QUIET_SIZE = 5
local BEAD_QUIET_TRANSPARENCY = 0.45

-- Glyph geometry, in the local space of a GLYPH_WIDTH x GLYPH_HEIGHT box. Authored as centres rather
-- than as corners because every piece is anchored 0.5, 0.5 -- a sword is a symmetrical object, and
-- describing it from its spine is what keeps the pommel, grip, guard and blade on one axis instead
-- of on four independently-typed left edges.
local GLYPH_WIDTH = 22
local GLYPH_HEIGHT = 44
local GLYPH_AXIS = GLYPH_WIDTH / 2
local POMMEL_SIZE = 6
local POMMEL_CENTRE_Y = 7
local GRIP_CENTRE_Y = 12
local GUARD_CENTRE_Y = 18
local BLADE_WIDTH = 4
local BLADE_LENGTH = 20
local BLADE_CENTRE_Y = 30
local TIP_SIZE = 5
local TIP_CENTRE_Y = 41
-- Reaches from the blade's shoulder to the foot of the glyph, so a full sheath hides exactly the
-- blade and leaves the hilt standing proud -- which is what makes the silhouette readable at 22px
-- with no caption under it. Derived rather than typed so moving the blade moves the sheath with it.
local SCABBARD_WIDTH = 10
local SCABBARD_HEIGHT = GLYPH_HEIGHT - (BLADE_CENTRE_Y - BLADE_LENGTH / 2)
local SCABBARD_THROAT_HEIGHT = 2

-- The two keys this island names are passed to keyHint below as ACTIONS, not as strings, so there is
-- nothing to resolve at this level any more.
--
-- WHAT USED TO BE HERE was a defaultKeyLabel helper reading Constants.Keybinds.Defaults directly,
-- with a comment explaining that it showed the DEFAULT bind rather than the live one because
-- KeybindManager "exposes no changed-signal a Screen is allowed to reach for". That signal exists
-- now (KeybindManager.OnChanged), and Components/KeyCap.lua's Action prop consumes it for the caller
-- along with the device question -- so these captions now follow a rebind AND redraw as pad glyphs,
-- neither of which a Defaults lookup could ever do.

-- A sword in a scabbard, built from plain Frames -- no ImageLabel, because this repo does not guess
-- at an rbxassetid (Components/VitalIcon.lua's header is the long version of why) and there is no
-- upload pipeline to put a real one behind. Same procedural-glyph technique VitalIcon and
-- Components/BountyMarkedBadge.lua both use, and deliberately a DIFFERENT silhouette from either, so
-- an armament tile is never mistaken for a vital or for the bounty crosshair.
--
-- MOVED HERE UNCHANGED from Screens/WeaponInventory/init.lua, which is where it was authored. It is
-- the equip indicator -- docs/ui-ux-philosophy.md's Critical States rule ("never the only signal")
-- applies as hard to drawn/sheathed as to a low vital, and this answers it two ways at once:
--   1. the scabbard retracts, uncovering the blade;
--   2. the blade warms from the disabled grey to the accent's text weight.
-- `drawn` is the shared 0..1 progress, so the scabbard's height, its stroke and its throat band move
-- together as one object rather than as three pieces that happen to animate at the same time, and a
-- third cue later is one more Computed off the same value.
local function weaponGlyph(scope: Scope, drawn: UsedAs<number>): Frame
	local progress = scope:Computed(function(use)
		return math.clamp(use(drawn), 0, 1)
	end)

	-- Cue 2. TextDisabled is this palette's "unavailable" weight and AccentPrimaryBright is its
	-- text-on-dark accent, so the blade travels exactly the distance a disabled control travels when
	-- it becomes live -- which is the claim being made.
	local bladeColor = scope:Computed(function(use)
		return Tokens.Color.TextDisabled:Lerp(Tokens.Color.AccentPrimaryBright, use(progress))
	end)
	local scabbardSize = scope:Computed(function(use)
		return UDim2.fromOffset(SCABBARD_WIDTH, math.round(SCABBARD_HEIGHT * (1 - use(progress))))
	end)
	-- Faded rather than left to the height alone: a UIStroke belongs to the frame, not to its
	-- descendants, so a zero-height scabbard would still draw its own outline as a hairline sitting
	-- at the glyph's foot. The throat band below IS a descendant, and is clipped away instead.
	local scabbardStroke = scope:Computed(function(use)
		local resting = Tokens.Border.Standard.Transparency
		return resting + (1 - resting) * use(progress)
	end)

	-- Bronze hilt, accent blade, and the split is the palette's own: AccentSecondary is "committed /
	-- permanent" (a hilt never changes state) while the primary accent is "live / interactive" (the
	-- blade is the half that comes out).
	local function hiltPiece(name: string, size: UDim2, centreY: number, rotation: number?): Frame
		return scope:New "Frame" {
			Name = name,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromOffset(GLYPH_AXIS, centreY),
			Size = size,
			Rotation = rotation,
			BackgroundColor3 = Tokens.Color.AccentSecondary,
			BorderSizePixel = 0,
			ZIndex = 1,
		} :: Frame
	end

	local function bladePiece(name: string, size: UDim2, centreY: number, rotation: number?): Frame
		return scope:New "Frame" {
			Name = name,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromOffset(GLYPH_AXIS, centreY),
			Size = size,
			Rotation = rotation,
			BackgroundColor3 = bladeColor,
			BorderSizePixel = 0,
			ZIndex = 1,
		} :: Frame
	end

	return scope:New "Frame" {
		Name = "WeaponGlyph",
		LayoutOrder = 1,
		Size = UDim2.fromOffset(GLYPH_WIDTH, GLYPH_HEIGHT),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,

		[Children] = {
			hiltPiece("Pommel", UDim2.fromOffset(POMMEL_SIZE, POMMEL_SIZE), POMMEL_CENTRE_Y, 45),
			hiltPiece("Grip", UDim2.fromOffset(3, 9), GRIP_CENTRE_Y),
			hiltPiece("Guard", UDim2.fromOffset(15, 3), GUARD_CENTRE_Y),
			bladePiece("Blade", UDim2.fromOffset(BLADE_WIDTH, BLADE_LENGTH), BLADE_CENTRE_Y),
			bladePiece("Tip", UDim2.fromOffset(TIP_SIZE, TIP_SIZE), TIP_CENTRE_Y, 45),

			scope:New "Frame" {
				Name = "Scabbard",
				AnchorPoint = Vector2.new(0.5, 1),
				Position = UDim2.new(0, GLYPH_AXIS, 1, 0),
				Size = scabbardSize,
				-- The base Surface, not the plate's own fill: a sheath has to read as a recess cut
				-- into the well, and matching the well exactly would leave only the outline to carry
				-- the shape.
				BackgroundColor3 = Tokens.Color.Surface,
				BorderSizePixel = 0,
				-- So the throat band collapses with the sheath instead of hanging in the air once
				-- the frame it belongs to has retracted past it.
				ClipsDescendants = true,
				ZIndex = 2,

				[Children] = {
					scope:New "UICorner" {
						CornerRadius = Tokens.Radius.Hairline,
					},
					scope:New "UIStroke" {
						Color = Tokens.Border.Standard.Color,
						Transparency = scabbardStroke,
						Thickness = 1,
					},
					scope:New "Frame" {
						Name = "Throat",
						AnchorPoint = Vector2.new(0.5, 0),
						Position = UDim2.fromScale(0.5, 0),
						Size = UDim2.new(1, 0, 0, SCABBARD_THROAT_HEIGHT),
						BackgroundColor3 = Tokens.Color.AccentSecondary,
						BorderSizePixel = 0,
						ZIndex = 3,
					},
				},
			},
		},
	} :: Frame
end

-- One rack bead. FIXED SET OF MAX_BEADS INSTANCES, each reactive, rather than a Fusion For over the
-- live rack: the count is bounded by construction, so a For here would buy dynamic sizing this strip
-- can never need while adding an Instance-lifetime problem (see Screens/DevTools/MoveEditor/
-- Browser.lua on why a plain Computed returning Instances leaks). Every bead's visibility, size and weight is one
-- Computed off the same two facts.
local function rackBead(scope: Scope, index: number, shown: UsedAs<number>, selectedSlot: UsedAs<number>): Frame
	local isSelected = scope:Computed(function(use)
		return use(selectedSlot) == index
	end)

	return scope:New "Frame" {
		Name = `Bead{index}`,
		LayoutOrder = index,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Visible = scope:Computed(function(use)
			return index <= use(shown)
		end),
		Size = scope:Computed(function(use)
			local edge = if use(isSelected) then BEAD_SELECTED_SIZE else BEAD_QUIET_SIZE
			return UDim2.fromOffset(edge, edge)
		end),
		-- The same rotated bead Components/MeridianField.lua threads along its meridians and
		-- Divider.Flourish puts at its centre -- this UI's own mark for "a point on a line", reused
		-- rather than a bullet character that would render as whatever the body face happens to draw
		-- for it.
		Rotation = 45,
		BackgroundColor3 = Tokens.Color.AccentSecondary,
		BackgroundTransparency = scope:Computed(function(use)
			return if use(isSelected) then 0 else BEAD_QUIET_TRANSPARENCY
		end),
		BorderSizePixel = 0,
	} :: Frame
end

-- A key the player is being told to press, plus what it does. The LIT register throughout: every cap
-- on this island sits beside a verb the player is being asked to act on, which is the distinction
-- Components/KeyCap.lua's Tone prop exists to keep (the quiet register is for a legend that merely
-- lists bindings, like the one under the dock).
local function keyHint(
	scope: Scope,
	layoutOrder: number,
	action: Types.KeybindAction,
	caption: UsedAs<string>,
	visible: UsedAs<boolean>?
): Frame
	return Stack.Row(scope, {
		-- Named by the ACTION, which is fixed, rather than by the glyph, which is not -- see
		-- Components/KeyCap.lua's note on why an Instance must never be named by a reactive binding.
		Name = `KeyHint_{action}`,
		LayoutOrder = layoutOrder,
		Visible = visible,
		Size = UDim2.fromOffset(0, KEYCAP_HEIGHT),
		AutomaticSize = Enum.AutomaticSize.X,
		Gap = Tokens.Space.XS,
		AlignY = Enum.VerticalAlignment.Center,

		Children = {
			KeyCap(scope, {
				Name = `Keycap_{action}`,
				Action = action,
				Tone = "Lit",
				LayoutOrder = 1,
				MinWidth = KEYCAP_WIDTH,
				Height = KEYCAP_HEIGHT,
			}),
			Label(scope, {
				Text = caption,
				Scale = "Detail",
				Color = Tokens.Color.TextSecondary,
				LayoutOrder = 2,
				-- AutoWidth, not a bare Label: an omitted Size gives AutomaticSize.XY from a
				-- scale-1 WIDTH base, and inside this AutomaticSize.X row that is the feedback loop
				-- Components/Label.lua's header documents (parent grows, child grows, repeat).
				AutoWidth = true,
			}),
		},
	})
end

--[[
	Builds the island. Returns the pinned slot for Screens/HUD to parent into its dock band, plus the
	entrance spring so the band can fade its seam bead on the same value.
]]
local ArmamentIsland = {}

-- Exposed because Screens/HUD draws the shared rule and the bead at exactly this depth -- half of
-- each sits on the dock, so both belong to it, and neither can be placed without knowing how far the
-- island sinks. Same arrangement Screens/BlimpHelm/FurnacePlate has with the helm console.
ArmamentIsland.SEAM_OVERLAP = SEAM_OVERLAP

function ArmamentIsland.Build(scope: Scope, state: ArmamentState): Island
	local owned = state.Owned
	local selected = state.Selected
	local drawn = state.Drawn

	local ownedCount = scope:Computed(function(use)
		return #use(owned)
	end)
	local hasMultiple = scope:Computed(function(use)
		return use(ownedCount) > 1
	end)

	-- VISIBLE ONLY ONCE SOMETHING HAS BEEN PICKED UP, matching Screens/CarriedResources' rule and for
	-- the same reason: a player who never touches a weapon rack should not carry an empty surface on
	-- their screen for the whole session. It arrives on the first pickup and stays, because unlike
	-- carried coal an inventory never empties back out (there is no drop yet).
	local present = scope:Computed(function(use)
		return use(ownedCount) > 0
	end)

	-- THE ENTRANCE. What springs is the slot's WIDTH: a pinned child's Position is a property this
	-- island's own container sets, and an earlier version that sprang a Position had it recomputed
	-- and discarded every frame by the layout it was sitting in.
	local presence = scope:Spring(
		scope:Computed(function(use)
			return if use(present) then 1 else 0
		end),
		Tokens.Motion.IslandSpring.Speed,
		Tokens.Motion.IslandSpring.Damping
	)

	-- Kept in the tree through the whole exit so the spring has something to animate, the same guard
	-- Screens/BlimpHelm's console uses. Unreachable today (see `present` above) and cheap enough to
	-- be correct anyway.
	local alive = scope:Computed(function(use)
		return use(present) or use(presence) > 0.01
	end)

	-- The sink is part of the travel, not an offset applied after it: the slot has to reach
	-- ISLAND_WIDTH + SEAM_OVERLAP for the island's outer edge to land where it always did, and
	-- springing the whole distance keeps the drawer's leading edge moving at one rate.
	local slotWidth = scope:Computed(function(use)
		return math.max(0, math.round(use(presence) * SLOT_TRAVEL))
	end)

	-- The one value behind both drawn/sheathed cues -- see weaponGlyph above.
	local drawnProgress = scope:Spring(
		scope:Computed(function(use)
			return if use(drawn) then 1 else 0
		end),
		Tokens.Motion.StateSpring.Speed,
		Tokens.Motion.StateSpring.Damping
	)

	local selectedName = scope:Computed(function(use)
		-- Selected is nil only for an empty inventory (WeaponConstants.InventoryPayload's own
		-- contract), which is the one case this island is not on screen for -- so the dash is a
		-- backstop against a payload that disagreed with itself, not a state a player can reach.
		return use(selected) or "--"
	end)
	local drawCaption = scope:Computed(function(use)
		return if use(drawn) then "Sheathe" else "Draw"
	end)
	-- NO DRAW/SHEATHE FOR FISTS: they are always in hand when nothing else is drawn and cannot be put away
	-- (WeaponInventorySystem's header, FISTS ARE ALWAYS IN HAND), so the key does nothing with them selected
	-- -- and a key hint for a key that does nothing is worse than none (the Next hint's own rule below).
	local canSheathe = scope:Computed(function(use)
		local selectedId = use(selected)
		return selectedId ~= nil and selectedId ~= WeaponRoster.FISTS_ID
	end)

	-- THE STRIP WINDOWS ONTO THE SELECTED WEAPON rather than always showing the first MAX_BEADS. A
	-- fixed window would leave nothing lit the moment a player's selection walked past the sixth
	-- weapon, which is the one thing this strip exists to say. The window slides only as far as it
	-- has to, so for any inventory that fits it is the plain 1..n strip.
	local windowStart = scope:Computed(function(use)
		local count = use(ownedCount)
		if count <= MAX_BEADS then
			return 1
		end
		local selectedId = use(selected)
		local selectedIndex = 1
		for index, weaponId in ipairs(use(owned)) do
			if weaponId == selectedId then
				selectedIndex = index
				break
			end
		end
		return math.clamp(selectedIndex - MAX_BEADS + 1, 1, count - MAX_BEADS + 1)
	end)
	local shownBeads = scope:Computed(function(use)
		return math.min(use(ownedCount), MAX_BEADS)
	end)
	-- Which BEAD (1..MAX_BEADS), not which weapon -- the strip's own coordinate, so each bead's
	-- Computed is a single integer comparison rather than a table walk.
	local selectedSlot = scope:Computed(function(use)
		local selectedId = use(selected)
		local first = use(windowStart)
		for index, weaponId in ipairs(use(owned)) do
			if weaponId == selectedId then
				return index - first + 1
			end
		end
		return 0
	end)
	local hiddenCount = scope:Computed(function(use)
		return use(ownedCount) - use(shownBeads)
	end)
	local hasOverflow = scope:Computed(function(use)
		return use(hiddenCount) > 0
	end)
	local overflowText = scope:Computed(function(use)
		return `+{use(hiddenCount)}`
	end)

	local beads: { Instance } = {}
	for index = 1, MAX_BEADS do
		beads[index] = rackBead(scope, index, shownBeads, selectedSlot)
	end

	local plate = Panel(scope, {
		Name = "ArmamentPlate",
		-- Fixed on BOTH axes. The width carries the bleed past the seam (see this file's header); the
		-- height is the dock's, so the two plates' top and bottom edges are one line each. Nothing
		-- here is AutomaticSize and nothing here is Scale-sized, which is what keeps the springing
		-- slot from ever reflowing the contents -- and what keeps this out of the AutomaticSize
		-- inflation trap Components/Panel.lua's SurfaceTexture note measures.
		Size = UDim2.fromOffset(PLATE_WIDTH, ISLAND_HEIGHT),
		-- THE DOCK'S MATERIAL, PROP FOR PROP -- Screens/HUD/init.lua's HotbarDock. Not a family
		-- resemblance: at a shared seam, any difference in silhouette, bracket colour, arm length or
		-- edge opacity reads as two mismatched objects bolted together rather than as one instrument
		-- and its outrigger.
		--
		-- Chamfered, and Elevated = false with it. docs/ui-ux-philosophy.md's Shape Language puts the
		-- cut corner on COMBAT surfaces and the sharp rect on MENU surfaces, and this is a combat
		-- surface by exactly the argument the dock is. SurfaceElevated is the "sits above the panel
		-- behind it" step, and beside the dock there is no panel behind either of them.
		Elevated = false,
		Chamfered = true,
		-- NOT SurfaceTexture, for two independent reasons and either alone settles it: that grain is
		-- the menu register's, and Components/MeridianField.lua cannot be mounted where it would have
		-- to be here anyway. See Panel.lua's own prop note.
		CornerAccent = true,
		BracketArmLength = BRACKET_ARM_LENGTH,
		-- What makes brackets legal on a chamfered panel at all -- each elbow lands where the cut
		-- ends and the straight edge begins, so the arms brace the chamfer instead of floating over
		-- its void. The dock's value, not the character menu's 16px flush one: a 16px arm beside the
		-- dock's 10px one is the kind of near-miss that reads as a mistake rather than a variation.
		BracketInset = BRACKET_INSET,
		CornerAccentColor = Tokens.Color.AccentSecondary,
		CornerAccentRivets = false,
		-- The dock's own violet edge at the dock's own softened opacity. Only the LEFT half of it
		-- ever renders; the rest is in the bleed.
		BorderColor3 = Tokens.Color.AccentPrimary,
		BorderTransparency = 0.3,

		Children = {
			-- Y is the dock's own inset, so both surfaces' contents share one interior line -- seam
			-- point 4 in this file's header. Right carries the bleed so the content box is exactly
			-- ISLAND_WIDTH minus its two real insets, however wide the plate itself has to be.
			Inset(scope, {
				Left = Tokens.Space.L,
				Right = Tokens.Space.M + BLEED,
				Y = Tokens.Space.M,
			}),

			Stack.Row(scope, {
				Name = "Readout",
				Gap = Tokens.Space.M,
				AlignY = Enum.VerticalAlignment.Center,

				Children = {
					-- The scabbard well.
					Stack.New(scope, {
						Name = "ScabbardWell",
						LayoutOrder = 1,
						Size = UDim2.fromOffset(0, 0),
						AutomaticSize = Enum.AutomaticSize.XY,
						AlignX = Enum.HorizontalAlignment.Center,
						BackgroundColor3 = Tokens.Wash.RailScrim.Color,
						BackgroundTransparency = Tokens.Wash.RailScrim.Transparency,

						Children = {
							-- Safe among a Stack's Children precisely because none of them is a
							-- GuiObject: a UIListLayout arranges GuiObject children only, which is
							-- the distinction Components/Layer.lua's header is about.
							scope:New "UICorner" {
								CornerRadius = Tokens.Radius.Hairline,
							},
							scope:New "UIStroke" {
								Color = Tokens.Border.Hairline.Color,
								Transparency = Tokens.Border.Hairline.Transparency,
								Thickness = 1,
							},
							Inset(scope, { X = WELL_INSET_X, Y = WELL_INSET_Y }),
							weaponGlyph(scope, drawnProgress),
						},
					}),

					Stack.Fill(
						scope,
						Stack.New(scope, {
							Name = "Column",
							Size = UDim2.fromScale(1, 0),
							AutomaticSize = Enum.AutomaticSize.Y,
							Gap = Tokens.Space.XS,

							Children = {
								Label(scope, {
									Text = selectedName,
									Scale = "CardTitle",
									LayoutOrder = 1,
									-- A weapon id is a Workspace model's Name, so it is as long as
									-- whoever built the sword felt like typing. A real Size is what
									-- gets it truncated at the edge of the column (Label's own
									-- default) instead of overhanging the seam.
									Size = UDim2.new(1, 0, 0, NAME_HEIGHT),
								}),

								-- Collapses entirely with a single weapon held: a UIListLayout skips
								-- a non-visible child, so nothing on this island costs vertical
								-- space for a fact it does not have yet.
								Stack.Row(scope, {
									Name = "RackStrip",
									LayoutOrder = 2,
									Visible = hasMultiple,
									Size = UDim2.new(1, 0, 0, BEAD_ROW_HEIGHT),
									Gap = Tokens.Space.XS,
									AlignY = Enum.VerticalAlignment.Center,

									Children = {
										beads,
										Label(scope, {
											Text = overflowText,
											Scale = "Detail",
											Color = Tokens.Color.TextDisabled,
											LayoutOrder = MAX_BEADS + 1,
											Visible = hasOverflow,
											AutoWidth = true,
										}),
									},
								}),

								Stack.Row(scope, {
									Name = "Keys",
									LayoutOrder = 3,
									Size = UDim2.new(1, 0, 0, KEYCAP_HEIGHT),
									Gap = Tokens.Space.S,
									AlignY = Enum.VerticalAlignment.Center,

									Children = {
										keyHint(scope, 1, "ToggleWeapon", drawCaption, canSheathe),
										-- Hidden while there is nothing to cycle to, rather than
										-- shown disabled: a key hint is an instruction, and an
										-- instruction that does nothing is worse than none.
										keyHint(scope, 2, "SelectNextWeapon", "Next", hasMultiple),
									},
								}),
							},
						})
					),
				},
			}),
		},
	})

	-- THE SLOT: a plain clipping frame whose only jobs are to be the width the spring says and to cut
	-- the plate's right-hand chrome off at the seam. Deliberately NOT a Panel -- it has no chrome of
	-- its own; the plate inside carries all of it, and a second bordered surface here would draw a
	-- box around a box.
	--
	-- PINNED, NOT LAID OUT, and that is what makes the dock's position safe rather than merely
	-- correct. AnchorPoint (1, 0.5) with Position (0, 0, 0.5, 0) puts its right edge exactly on the
	-- band's left edge -- which is the dock's, since the dock is the only thing sizing that band --
	-- and its centre on the dock's. Because nothing lays it out, there is no arithmetic anywhere that
	-- could move the dock as this width changes: the previous version reserved space in a centred row
	-- and cancelled it with a mirror spacer, which worked but had to be kept in agreement to the
	-- pixel, in the pre-UIScale coordinate space, on every frame of the spring.
	local slot = scope:New "Frame" {
		Name = "ArmamentIsland",
		AnchorPoint = Vector2.new(1, 0.5),
		-- SEAM_OVERLAP into the dock, not flush against its edge -- see that constant for the two
		-- triangular notches this removes from the assembly's silhouette.
		Position = UDim2.new(0, SEAM_OVERLAP, 0.5, 0),
		Size = scope:Computed(function(use)
			return UDim2.fromOffset(use(slotWidth), ISLAND_HEIGHT)
		end),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ClipsDescendants = true,
		Visible = alive,

		[Children] = plate,
	} :: Frame

	return {
		Content = slot,
		Presence = presence,
	}
end

return ArmamentIsland
