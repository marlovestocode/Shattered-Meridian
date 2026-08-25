--!strict
--[[
	WeaponInventory/init.lua

	Owns: the corner readout of the weapons a player has picked up -- which one the draw key acts
	on, whether it is in hand right now, what else is on the rack behind it, and which two keys move
	any of that. The "so I can see what I have" surface the weapon pickup loop was missing: before
	this existed, picking a sword up produced a prompt that vanished and nothing else, and the only
	way to check whether it had worked was to press T and see if anything appeared.

	Client/Combat/WeaponInventoryClient.lua drives this screen's handle on every
	Weapon_InventoryChanged push -- this file itself sends and receives nothing, the same "screen
	exposes state, client module drives it" split Screens/CarriedResources/init.lua and
	Screens/BlimpFuel/init.lua both follow.

	REBUILT 2026-08-20 INTO THE CHARACTER MENU'S REGISTER (user: the panel was "a very outdated
	design"). What it was: four identical rows of Detail text, the selected one marked with a `> `
	string prefix, a right-aligned DRAWN/SHEATHED word at the same size and weight as everything
	around it, and a `"T: Draw   Y: Next"` run-on line spaced with literal double spaces. Every fact
	was present and none of them was RANKED -- the one question a HUD tile gets to answer at a
	glance ("is my sword out?") was drawn the same size as the least important thing on the panel.
	It also predated every layout primitive in Components/, so its rows positioned their two halves
	at UDim2.fromScale(0.58)/(0.42), and its panel wore the old rivet-and-violet CornerAccent that
	docs/ui-ux-philosophy.md's redesign notes replaced with unornamented bronze brackets.

	THE STATE IS ANSWERED TWO WAYS, NEITHER OF WHICH IS COLOUR ALONE. docs/ui-ux-philosophy.md's
	Critical States rule ("never the only signal") applies just as hard to drawn/sheathed as it does
	to a low vital, because this is the fact the whole panel exists for and it has to survive a
	glance taken in peripheral vision mid-fight:
	  1. the scabbard on the weapon glyph retracts, uncovering the blade;
	  2. the blade itself warms from the disabled grey to the accent's text weight.
	Both ride ONE scope:Spring (Tokens.Motion.StateSpring -- "an edge highlight easing in/out on a
	state change", which is exactly what this is), so they can never disagree about how far through
	the transition they are, and a third cue later is one more Computed off the same value.
	A THIRD CUE -- the panel's own leading-edge rail -- existed briefly during the SHRUNK pass below
	and was cut again the same day (user: "remove the thing on the left that comes in when you equip
	it"). It read, on an actual playtest, as an unexplained bar rather than as a state indicator; the
	glyph alone carries the claim now, the same way it always was going to once the DRAWN/SHEATHED
	word left.

	THE RACK IS CAPPED AND THE HERO IS NOT. Owned weapons are unbounded -- WeaponRoster reads
	Workspace.Weapons, so a builder adding models grows this list with no code change -- and the
	previous version rendered every one of them, which is a panel that eventually runs off the top
	of the screen. The selected weapon gets the hero row; the rest get MAX_RACK_ROWS compact rows
	and then a "+N MORE" line. Kept in the server's own pickup order rather than rotated into cycle
	order: rotating would re-order the list under the player's eyes on every press of the cycle key,
	and "what does that key do" is already answered in the footer without moving anything.

	SHRUNK 2026-08-20 (user: the panel "stretches way too far from the bottom to the top" and needed
	"its own specialized tiny spot" that doesn't fight the camera for screen space). Cue 4 above --
	the DRAWN/SHEATHED word -- is gone outright: the user's own framing was that the glyph animation
	IS the equip indicator ("that is what the sword animation in the thing is for"), so a redundant
	text badge repeating what the scabbard and blade already show was pure height with no signal of
	its own. The "Armament" eyebrow heading, its "N HELD" note, and the rule under it are gone too --
	same reasoning as CarriedResources/init.lua staying casing-and-rows with no heading band, and the
	held count was already legible from the rack itself. What used to be a bare list of rack rows
	under a hairline divider is now wrapped in one bordered, washed sub-container (Tokens.Wash.Inset
	fill, Tokens.Border.Standard stroke) instead -- the user's own invitation to "add more contrast,
	more containering, more bordering" to how the weapons are held, without touching the palette or
	the panel's own chrome. MAX_RACK_ROWS dropped from 3 to 2 so that container stays a small chip
	rather than a second panel's worth of rows.

	Does not own: the inventory itself (Server/Combat/Weapon/WeaponInventorySystem.lua is the
	authority; this only ever renders what it is told), the keys that change it (Client/Combat/
	AttackInputClient.lua owns both binds), or the pickup prompt.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)

local Constants = require(ReplicatedStorage.Shared.Constants)
local Types = require(ReplicatedStorage.Shared.Types)
local WeaponConstants = require(ReplicatedStorage.Shared.Combat.WeaponConstants)

local Tokens = require(script.Parent.Parent.Tokens)
local Panel = require(script.Parent.Parent.Components.Panel)
local KeyCap = require(script.Parent.Parent.Components.KeyCap)
local Label = require(script.Parent.Parent.Components.Label)
local Stack = require(script.Parent.Parent.Components.Stack)
local Inset = require(script.Parent.Parent.Components.Inset)

local Children = Fusion.Children

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>

export type WeaponInventoryHandle = {
	SetInventory: (payload: WeaponConstants.InventoryPayload) -> (),
}

local WeaponInventory = {}

-- Wider than the 190 it replaced, and the extra 22px all goes to the hero row: a weapon id is a
-- Workspace model's Name, so it is as long as whoever built the sword felt like typing, and the one
-- string on this panel that must never truncate is the name of the thing in your hand.
local PANEL_WIDTH = 212
-- Matches GLYPH_HEIGHT exactly now that the hero row is glyph-plus-name-only (no second line for a
-- state badge under the name) -- see the file header's SHRUNK note.
local HERO_HEIGHT = 44
local NAME_HEIGHT = 20
local GLYPH_WIDTH = 22
local GLYPH_HEIGHT = 44
local RACK_ROW_HEIGHT = 18
local RACK_TICK_COLUMN = 8
local RACK_TICK_SIZE = 4
local OVERFLOW_HEIGHT = 16
local KEYCAP_WIDTH = 21
local KEYCAP_HEIGHT = 19

-- Two, plus the "+N MORE" line -- see file header's SHRUNK note. Sized so the tallest this tile can
-- ever get (both rows filled, the container's own padding, and the overflow line showing) still
-- reads as one small corner chip; a third row buys one more name for a permanent 18px plus whatever
-- the bordered container's own chrome adds on top of it.
local MAX_RACK_ROWS = 2

-- Glyph geometry, in the local space of a GLYPH_WIDTH x GLYPH_HEIGHT box. Authored as centres
-- rather than as corners because every piece is anchored 0.5, 0.5 -- a sword is a symmetrical
-- object, and describing it from its spine is what keeps the pommel, grip, guard and blade on one
-- axis instead of on four independently-typed left edges.
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

-- The two keys, read off Constants rather than typed as literals. This is the DEFAULT bind, not the
-- live one: Client/Input/KeybindManager.lua owns rebinds and exposes no changed-signal to subscribe
-- to, and a Screen here never reaches into it directly anyway (Screens/Settings/KeybindsTab.lua's
-- own header holds the same line). Screens/HUD/init.lua's ability row hardcodes "1".."5" for the
-- same reason; going through Constants at least means a retuned default moves this label with it.
local function defaultKeyLabel(action: Types.KeybindAction): string
	local keyCode = Constants.Keybinds.Defaults[action].KeyCode
	return if keyCode then keyCode.Name else "--"
end

local DRAW_KEY = defaultKeyLabel("ToggleWeapon")
local CYCLE_KEY = defaultKeyLabel("SelectNextWeapon")

-- A sword in a scabbard, built from plain Frames -- no ImageLabel, because this repo does not guess
-- at an rbxassetid (Components/VitalIcon.lua's header is the long version of why) and there is no
-- upload pipeline to put a real one behind. Same procedural-glyph technique VitalIcon and
-- Components/BountyMarkedBadge.lua both use, and deliberately a DIFFERENT silhouette from either,
-- so an armament tile is never mistaken for a vital or for the bounty crosshair.
--
-- `drawn` is the shared 0..1 progress (see file header). It moves the scabbard's height, its stroke
-- and its throat band together, so the sheath retracts as one object rather than as three pieces
-- that happen to be animating at the same time.
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
				-- The base Surface, not the panel's own SurfaceElevated: a sheath has to read as a
				-- recess cut into the tile, and matching the tile exactly would leave only the
				-- outline to carry the shape.
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

local function keyHint(
	scope: Scope,
	layoutOrder: number,
	key: string,
	caption: UsedAs<string>,
	visible: UsedAs<boolean>?
): Frame
	return Stack.Row(scope, {
		Name = `KeyHint_{key}`,
		LayoutOrder = layoutOrder,
		Visible = visible,
		Size = UDim2.fromOffset(0, KEYCAP_HEIGHT),
		AutomaticSize = Enum.AutomaticSize.X,
		Gap = Tokens.Space.XS,
		AlignY = Enum.VerticalAlignment.Center,

		Children = {
			KeyCap(scope, {
				Name = `Keycap_{key}`,
				Key = key,
				-- The LIT register: this cap sits beside the one verb on the tile the player is being asked
				-- to act on, so it takes the 32% emphasis edge rather than the legend's quiet 18% one --
				-- see KeyCap.lua's own Tone prop, which exists to keep exactly this distinction.
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
			}),
		},
	})
end

-- One line per weapon you own but are not holding. Deliberately quiet: this half of the panel
-- answers "what else is on the rack", a question asked between fights, and giving it the hero row's
-- weight would flatten the hierarchy the rebuild exists to create.
local function rackRow(scope: Scope, layoutOrder: number, weaponId: string): Frame
	return Stack.Row(scope, {
		Name = `Rack_{weaponId}`,
		LayoutOrder = layoutOrder,
		Size = UDim2.new(1, 0, 0, RACK_ROW_HEIGHT),
		Gap = Tokens.Space.S,
		AlignY = Enum.VerticalAlignment.Center,

		Children = {
			scope:New "Frame" {
				Name = "Tick",
				LayoutOrder = 1,
				Size = UDim2.fromOffset(RACK_TICK_COLUMN, RACK_ROW_HEIGHT),
				BackgroundTransparency = 1,

				[Children] = scope:New "Frame" {
					Name = "Node",
					AnchorPoint = Vector2.new(0.5, 0.5),
					Position = UDim2.fromScale(0.5, 0.5),
					Size = UDim2.fromOffset(RACK_TICK_SIZE, RACK_TICK_SIZE),
					-- The same rotated bead Components/MeridianField.lua threads along its meridians
					-- and Divider.Flourish puts at its centre -- this UI's own mark for "a point on a
					-- line", reused rather than a bullet character that would render as whatever the
					-- body face happens to draw for it.
					Rotation = 45,
					BackgroundColor3 = Tokens.Color.AccentSecondary,
					BackgroundTransparency = 0.35,
					BorderSizePixel = 0,
				},
			},
			Stack.Fill(
				scope,
				Label(scope, {
					Text = weaponId,
					Scale = "Detail",
					Color = Tokens.Color.TextSecondary,
					LayoutOrder = 2,
					Size = UDim2.new(1, 0, 0, RACK_ROW_HEIGHT),
				})
			),
		},
	})
end

-- Returns its handle AND its tile, unparented -- UI/init.lua hands it to Shell/Regions.lua's
-- BottomLeft at order 10, so it keeps the corner it has always had and the helm console stacks
-- ABOVE it rather than on top of it. The two used to share a coordinate; see Regions.lua's header.
function WeaponInventory.Mount(scope: Scope): (WeaponInventoryHandle, Frame)
	local owned: Fusion.Value<{ string }> = scope:Value({})
	local selected: Fusion.Value<string?> = scope:Value(nil)
	local drawn = scope:Value(false)

	-- VISIBLE ONLY ONCE SOMETHING HAS BEEN PICKED UP, matching CarriedResources' own rule and for
	-- the same reason: a player who has never touched a weapon rack should not carry an empty tile
	-- on their screen for the whole session. It appears on the first pickup and stays, because
	-- unlike carried coal an inventory never empties back out (there is no drop yet).
	local visible = scope:Computed(function(use)
		return #use(owned) > 0
	end)

	-- THE 14px ENTRANCE RISE IS GONE FOR NOW, and it was not removed as a preference. It was a spring
	-- driving this panel's Position, and a region tile's Position is overwritten by its region's
	-- UIListLayout on every layout pass -- so the spring would have been computed and then discarded
	-- every frame it ran. Components/Reveal.lua (Phase 5 of the HUD shell plan) is where an entrance
	-- comes back, expressed as something a laid-out tile can actually animate, for this panel and the
	-- four other ambient tiles at once. Until then this tile appears without a slide.

	-- The one value behind both drawn/sheathed cues -- see this file's header.
	local drawnTarget = scope:Computed(function(use)
		return if use(drawn) then 1 else 0
	end)
	local drawnProgress = scope:Spring(drawnTarget, Tokens.Motion.StateSpring.Speed, Tokens.Motion.StateSpring.Damping)

	local selectedName = scope:Computed(function(use)
		-- Selected is nil only for an empty inventory (WeaponConstants.InventoryPayload's own
		-- contract), which is the one case this panel is not on screen for -- so the dash is a
		-- backstop against a payload that disagreed with itself, not a state a player can reach.
		return use(selected) or "--"
	end)
	local drawCaption = scope:Computed(function(use)
		return if use(drawn) then "Sheathe" else "Draw"
	end)

	-- Everything owned except what the hero row is already showing, capped -- as a MAP keyed by
	-- weapon id whose value is that weapon's PICKUP INDEX. Both halves of that shape are load-bearing
	-- for the ForPairs below, and neither is obvious:
	--   * keyed by id, not by position, because Fusion's For reuses a sub-object when its own input
	--     KEY is still present in the new table. An array reindexes on every selection change (the
	--     weapon at [1] becomes a different weapon), so every row is guaranteed to be invalidated;
	--     with ids, only the rows whose weapon actually entered or left the rack are.
	--   * valued at the pickup index rather than at 1..MAX_RACK_ROWS, because Fusion re-runs the
	--     processor when EITHER half of a pair changes -- a rack renumbered 1..3 would hand every
	--     surviving row a new value and rebuild it anyway. A pickup index never moves, and since a
	--     UIListLayout SORTS rather than counts, LayoutOrders of {2, 4, 5} lay out exactly as
	--     {1, 2, 3} would.
	-- Reuse is a best effort, not a guarantee, and the comment above is careful not to promise more:
	-- when a key does disappear, For hands that orphaned sub-object some other pending pair, and it
	-- picks which one by iterating an unordered set -- so a departing row can take a surviving row's
	-- pair and rebuild it. Nothing here depends on identity surviving; this is about how much work a
	-- push costs, not about correctness.
	local rackOrder = scope:Computed(function(use)
		local current = use(selected)
		local order: { [string]: number } = {}
		local listed = 0
		for index, weaponId in ipairs(use(owned)) do
			if weaponId ~= current then
				order[weaponId] = index
				listed += 1
				if listed >= MAX_RACK_ROWS then
					break
				end
			end
		end
		return order
	end)
	-- A map has no length operator, and this is read three times below.
	local rackCount = scope:Computed(function(use)
		local count = 0
		for _ in pairs(use(rackOrder)) do
			count += 1
		end
		return count
	end)
	local hasRack = scope:Computed(function(use)
		return use(rackCount) > 0
	end)
	local hasMultiple = scope:Computed(function(use)
		return #use(owned) > 1
	end)
	-- Owned, less the one in the hero row, less the ones the rack actually listed. Derived off the
	-- real count rather than off MAX_RACK_ROWS so it stays honest if the cap ever moves.
	local overflowCount = scope:Computed(function(use)
		return math.max(math.max(#use(owned) - 1, 0) - use(rackCount), 0)
	end)
	local overflowText = scope:Computed(function(use)
		return `+{use(overflowCount)} MORE`
	end)
	local hasOverflow = scope:Computed(function(use)
		return use(overflowCount) > 0
	end)

	-- ForPairs, this codebase's only dynamic-list primitive (see MoveEditor/MoveList.lua's own
	-- comment on why not ForValues). Building Instances inside a plain Computed would leak them:
	-- Fusion has no destructor for what a Computed returns, so every inventory push would strand the
	-- previous set of rows.
	--
	-- The pickup index is threaded through as an explicit LayoutOrder for the same reason MoveList
	-- does it: once rows are keyed by id rather than by position, the UIListLayout can no longer
	-- rely on child insertion order to reflect the order the server holds them in.
	local rows = scope:ForPairs(rackOrder, function(_use, innerScope: Scope, weaponId: string, order: number)
		return weaponId, rackRow(innerScope, order, weaponId)
	end)

	local function setInventory(payload: WeaponConstants.InventoryPayload): ()
		owned:set(payload.Owned)
		selected:set(payload.Selected)
		drawn:set(payload.Drawn)
	end

	local tile = Panel(scope, {
		Name = "WeaponInventoryPanel",
		Size = UDim2.fromOffset(PANEL_WIDTH, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Visible = visible,
		-- SurfaceElevated, unlike Components/ScreenFrame.lua's own body (which sits on the base
		-- Surface so its bands can be the elevated ones). A modal has a scrim behind it to
		-- separate it from the world; a HUD tile has the running game back there and has to lift
		-- off it on its own.
		Elevated = true,
		-- NOT SurfaceTexture. This is the actual bug behind the file header's SHRUNK note, found by
		-- measuring rather than guessing: MeridianField.lua's root Frame is Size = Scale(1, 1), and
		-- Panel.lua parents it as a DIRECT sibling of Content inside the SAME Frame this panel sets
		-- AutomaticSize.Y on -- a Scale(1) child of the frame that is simultaneously trying to size
		-- itself FROM its children. Content survives the exact same shape one level down (a plain
		-- Scale(1)-height sibling of Body, sitting inside Content, resolved correctly in the same
		-- test) but the outer shell does not: measured in a real run-in-roblox session, a bare
		-- AutomaticSize.Y panel
		-- with SurfaceTexture = true and 40px of real content resolved to Y = 852 -- roughly the
		-- viewport height, not the content height -- reproducible with CornerAccent on or off, so
		-- CornerAccent's own AccentOverlay (the same Scale(1,1)-sibling shape) is not what triggers
		-- it. ScreenFrame.lua's own SurfaceTexture panel never hits this because ModalScreen hands it
		-- a fixed Size, never AutomaticSize -- this panel is the only SurfaceTexture caller that is
		-- also AutomaticSize, which is exactly why nothing else in this codebase surfaced it. The
		-- grain was always subtle at this panel's width (0.55 intensity, see the removed comment
		-- this replaced) and losing it costs nothing next to shipping a panel that silently covers a
		-- third of the screen. Fixing MeridianField/Panel.lua's general AutomaticSize interaction is
		-- real follow-up work; this call site just stops opting into the broken combination.
		-- The redesign's unornamented 16px bronze brackets -- the exact set the character menu
		-- wears (Components/ScreenFrame.lua), replacing this panel's old 12px violet-with-rivets
		-- default. See Panel.lua's own prop comments on why each is an explicit opt-in.
		CornerAccent = true,
		BracketArmLength = 16,
		CornerAccentColor = Tokens.Color.AccentSecondary,
		CornerAccentRivets = false,

		Children = {
			Stack.New(scope, {
				Name = "Body",
				Size = UDim2.fromScale(1, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				-- 0, not a Tokens.Space step. Body now has only two children -- the hero row
				-- (Selected, which owns the title/button spacing internally, see its own comment
				-- below) and Rack -- and Rack's own bordered/washed chrome is what separates it
				-- from the hero rather than a gap here doing it.
				Gap = 0,

				Children = {
					Inset(scope, { X = Tokens.Space.M, Y = Tokens.Space.XS }),

					-- The hero, and the whole panel now: glyph on the left, then a TIGHT
					-- title-over-button column on the right (user: "move the T and Draw text
					-- higher" -- putting Keys outside this row as a separate sibling below never
					-- closed that gap, no matter how the outer Gap or LayoutOrder were tuned,
					-- because the space between title and button was really the dead air below
					-- a short title CENTRED inside the tall GLYPH_HEIGHT row -- Keys started
					-- exactly at that row's bottom edge either way. Nesting the button under the
					-- title in its OWN short column, sized to its own content instead of to the
					-- glyph, is what actually closes it: the two are now Tokens.Space.XS apart no
					-- matter how tall the glyph is). No state badge under the name -- the glyph's
					-- own scabbard-retract-and-blade-warm animation (weaponGlyph above) IS the "is
					-- it out" answer now, not a caption under the name repeating it in words. See
					-- the file header's SHRUNK note.
					Stack.Row(scope, {
						Name = "Selected",
						LayoutOrder = 1,
						Size = UDim2.new(1, 0, 0, HERO_HEIGHT),
						Gap = Tokens.Space.S,
						AlignY = Enum.VerticalAlignment.Center,

						Children = {
							weaponGlyph(scope, drawnProgress),
							Stack.Fill(
								scope,
								Stack.New(scope, {
									Name = "TitleAndKeys",
									Size = UDim2.fromScale(1, 0),
									AutomaticSize = Enum.AutomaticSize.Y,
									Gap = Tokens.Space.XS,

									Children = {
										Label(scope, {
											Text = selectedName,
											Scale = "CardTitle",
											LayoutOrder = 1,
											Size = UDim2.new(1, 0, 0, NAME_HEIGHT),
										}),
										Stack.Row(scope, {
											Name = "Keys",
											LayoutOrder = 2,
											Size = UDim2.new(1, 0, 0, KEYCAP_HEIGHT),
											Gap = Tokens.Space.M,
											AlignY = Enum.VerticalAlignment.Center,

											Children = {
												keyHint(scope, 1, DRAW_KEY, drawCaption),
												-- Hidden while there is nothing to cycle to,
												-- rather than shown disabled: a key hint is an
												-- instruction, and an instruction that does
												-- nothing is worse than no instruction at all.
												-- (The character menu's reroll button makes the
												-- opposite call for the opposite reason -- it has
												-- a visible count beside it explaining why it is
												-- dead.)
												keyHint(scope, 2, CYCLE_KEY, "Next", hasMultiple),
											},
										}),
									},
								})
							),
						},
					}),

					-- LayoutOrder 2, the only sibling Selected has left: Keys moved INSIDE Selected
					-- above (see that block's own comment), so this no longer sits between the hero
					-- row and the button -- it is simply what comes after the whole hero cluster.
					--
					-- Collapses to nothing when there is only one weapon: a UIListLayout skips
					-- non-visible children, so a player who has picked up exactly one sword pays
					-- no vertical space for an empty rack. What renders when it isn't empty is one
					-- bordered, washed sub-container (Tokens.Wash.Inset fill, Tokens.Border.Standard
					-- stroke) rather than a bare list under a hairline rule -- the user's own
					-- invitation to give the weapons a more contained, more bordered look, and it
					-- replaces the divider the list used to sit under (the container's own edge is
					-- the separation now).
					Stack.New(scope, {
						Name = "Rack",
						LayoutOrder = 2,
						Visible = hasRack,
						Size = UDim2.fromScale(1, 0),
						AutomaticSize = Enum.AutomaticSize.Y,
						BackgroundColor3 = Tokens.Wash.Inset.Color,
						BackgroundTransparency = Tokens.Wash.Inset.Transparency,
						Gap = Tokens.Space.XS,

						Children = {
							scope:New "UICorner" {
								CornerRadius = Tokens.Radius.Hairline,
							},
							scope:New "UIStroke" {
								Color = Tokens.Border.Standard.Color,
								Transparency = Tokens.Border.Standard.Transparency,
								Thickness = 1,
							},
							Inset(scope, Tokens.Space.XS),
							Stack.New(scope, {
								Name = "RackRows",
								LayoutOrder = 1,
								Size = UDim2.fromScale(1, 0),
								AutomaticSize = Enum.AutomaticSize.Y,
								Children = rows,
							}),
							Label(scope, {
								Text = overflowText,
								Scale = "Detail",
								Color = Tokens.Color.TextDisabled,
								LayoutOrder = 2,
								Visible = hasOverflow,
								Size = UDim2.new(1, 0, 0, OVERFLOW_HEIGHT),
							}),
						},
					}),
				},
			}),
		},
	})

	return {
		SetInventory = setInventory,
	}, tile
end

return WeaponInventory
