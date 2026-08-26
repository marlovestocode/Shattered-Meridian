--!strict
--[[
	AbilitySlot.lua

	Owns: a single slot in the Ability System UI's hotbar row (docs/ui-ux-philosophy.md), rendering
	all four states that doc specifies -- Locked, Available, Cooldown, Active -- plus the optional
	icon/cooldown/resource props each state can carry. Every prop beyond Keybind/LayoutOrder is
	optional and State defaults to "Locked", so a caller that only passes Keybind/LayoutOrder still
	gets the doc's restrained, minimal-attention Locked appearance.

	Does not own: what ability (if any) actually occupies a slot, its icon, its cooldown state, or its
	resource cost. Once ArtSystem defines a real ability-loadout concept, a caller drives
	State/IconAssetId/CooldownFraction/CooldownSeconds/ResourceLabel from real ClientState; this
	component only renders whatever it is given, it does not decide it.

	The root instance is a TextButton, not a Frame -- the live HUD's slots need a real click affordance
	now that a move can be bound to one (Client/Combat/HotbarBindings.lua) and fired by clicking, the
	same "button does the same thing as its keybind" contract the keybind number in the corner already
	implies. OnActivated is optional and nil-safe, so a preview harness with nothing to activate
	renders and behaves exactly as a Frame would.

	AccentColor tints the Available/Active border, wash and edge bar toward a per-ability hue once a
	real loadout concept assigns one -- falls back to plain Tokens.Color.AccentPrimary when omitted.

	Keybind numbers are a local input-affordance label, not gameplay state, so showing "1".."5" is not
	the kind of fabrication the rest of this file avoids -- it is just telling the player which key
	would activate whatever eventually lives here.

	2026-08-25 hotbar rebuild. What changed and why:

	* THE TILE IS 56px, NOT Tokens.Control.RowHeight (40). RowHeight is the "one action per row" token
	  for a menu control; an ability tile is not a row, and borrowing that token was how the hotbar's
	  most-looked-at element ended up the smallest thing on the dock. It now carries its own constant,
	  private on purpose: nothing outside needs it, because every container around a row of these
	  auto-sizes to its contents rather than hand-summing tile widths (Components/Stack.lua).

	* THE ROOT NO LONGER CLIPS; THE TILE INSIDE IT DOES. The hover lift needs somewhere to lift TO, and
	  a UIListLayout owns the Position of every child it arranges -- so the button cannot move itself.
	  Splitting the two lets the fixed-size root keep its place in the row (and keep a STATIONARY hit
	  rect, so a hovering cursor can never be shrugged off by the thing it is hovering) while the tile
	  inside it rises. Clipping moved down with the visuals, since the cooldown wipe is what needed it.

	* THE GLOW IS A PLATE, NOT A REBUILT GRADIENT. The Available/Active energy wash used to be a
	  UIGradient whose Transparency NumberSequence was rebuilt by a Computed on every frame of the
	  state spring -- three keypoint objects plus a NumberSequence allocated per slot per frame, for
	  the whole settle, every time any slot changed state. It is now a flat plate whose single
	  ImageTransparency/BackgroundTransparency float the spring drives directly. Same look, no garbage.
	  The material sheen that remains is static and built once, because it describes the tile's
	  surface rather than its state.

	* THE READY FLASH IS FREE, and is the one genuinely new cue. It is not a timer and not a new prop:
	  the edge bar's brightness is driven by the SAME state spring the border already used, and a
	  Cooldown -> Available transition is exactly when that spring travels its full range. So the bar
	  swells as the ability comes back and settles to its resting glow on its own. Nothing schedules
	  it, nothing has to clear it, and it cannot fire for a state change that did not happen.
	  (Deliberately NOT the reference design's "affordable / resource ready" pulse dot -- this codebase
	  has no resource-cost model for an ability yet, and a prop with no caller is exactly the
	  speculative surface Bar.lua's header refuses. Add it when a cost exists to read.)

	IDENTITY, AND WHY THE RETICLE IS CONDITIONAL (2026-08-25). The reticle below is EMPTY-slot chrome,
	but nothing ever turned it off: HUD/init.lua had no name, no icon and no cost to pass, because
	Art_StateUpdated only ever carried slot -> ArtId and an ArtId is a move-registry key the client
	cannot resolve. So an equipped art rendered the "nothing here" mark, and the only thing separating
	a slot holding a form from a slot holding nothing was how brightly its border glowed. The payload
	carries DisplayName and QiCost now (Types.ArtStatePayload.EquippedInfo), the tile draws a monogram
	of the name where an icon would go, and the reticle appears only when there is genuinely nothing
	to draw there.

	The monogram is a real abbreviation of real data, not a fabricated icon -- the same line
	VitalIcon.lua's procedural glyphs walk. When an art finally has an uploaded texture, IconAssetId
	takes precedence over it and neither the caller nor this file's layout has to change.

	"Empty slot" chrome -- a restrained centered reticle (four short gapped ticks, deliberately not a
	solid cross, so it is never mistaken for VitalIcon.lua's health glyph) plus four small
	Components/CornerBracket.lua accents -- gives every slot, including a fully Locked one, some
	structure instead of a bare rectangle. Both track the border's own state colour, so this adds no
	fabricated identity: a Locked slot's reticle stays exactly as dim as its border already was.
	Neither depends on ChamferedSurface -- they are plain Frame geometry, so they still render when the
	tile falls back to a sharp rect.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Tokens = require(script.Parent.Parent.Tokens)
local ChamferedSurface = require(script.Parent.Parent.ChamferedSurface)
local CornerBracket = require(script.Parent.CornerBracket)
local Label = require(script.Parent.Label)

local Children = Fusion.Children
local OnEvent = Fusion.OnEvent

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>
type StrokeWeight = ChamferedSurface.StrokeWeight

export type AbilitySlotState = "Locked" | "Available" | "Cooldown" | "Active"

export type AbilitySlotProps = {
	Keybind: string,
	LayoutOrder: number?,
	-- Defaults to "Locked". Reactive so a caller can drive it straight from real ability/cooldown
	-- state.
	State: UsedAs<AbilitySlotState>?,
	-- A real uploaded texture (see VitalIcon.lua's header for why this repo does not guess at
	-- rbxassetids). Omit and the tile falls back to AbilityName's monogram below, which is what every
	-- live slot renders today -- no art in this game has an uploaded icon yet.
	IconAssetId: string?,
	-- The equipped ability's own DisplayName, straight from the server (Types.ArtStatePayload's
	-- EquippedInfo). The tile renders a MONOGRAM of it, not the name itself -- see monogram() below
	-- on why the abbreviation is decided here rather than by the caller.
	--
	-- This is also what tells a filled slot apart from an empty one: supplying a non-empty name
	-- replaces the empty-slot reticle. Reactive, because a slot's occupant changes under the player
	-- without the tile being rebuilt.
	AbilityName: UsedAs<string>?,
	-- Remaining fraction of the cooldown, 1 (just used) down to 0 (ready). Meaningful only while State
	-- is "Cooldown" -- the caller is responsible for only supplying it then, the same way
	-- Bar.lua/VitalIcon.lua's CriticalBelow is only supplied by callers who want that behavior.
	CooldownFraction: UsedAs<number>?,
	-- Remaining time, for the on-tile countdown. Meaningful only while State is "Cooldown".
	CooldownSeconds: UsedAs<number>?,
	-- e.g. "20 Qi" -- the resource cost docs/ui-ux-philosophy.md's Ability System UI section calls
	-- for. Rendered whenever provided, independent of State.
	ResourceLabel: UsedAs<string>?,
	-- Per-ability hue for the Available/Active border, wash and edge bar. Omit for the plain
	-- Tokens.Color.AccentPrimary every slot renders without it.
	AccentColor: UsedAs<Color3>?,
	-- Fires on a completed click/tap, TextButton's own native Activated semantics -- same optional,
	-- caller-decides-what-it-means contract as Button.lua/Tab.lua's own OnActivated. This component
	-- never decides what activating a slot DOES, only that it can be activated.
	OnActivated: (() -> ())?,
}

-- See this file's header on why this is its own constant rather than Tokens.Control.RowHeight.
local SLOT_SIZE = 56
-- How far the tile rises under the cursor. The reference design's `hover:-translate-y-1`.
local HOVER_LIFT = 4
-- How far it sinks on press. A press that only changes colour reads as a hover on a touchscreen,
-- where there is no hover to distinguish it from.
local PRESS_SCALE = 0.94
-- The monogram's own line box. Tall enough for Tokens.Type.Heading's 22px face without clipping its
-- descenders, and short enough that the mark stays clear of the keybind numeral above it and the Qi
-- cost below it -- the icon well is the band between those two corners, not the whole tile.
local SIGIL_HEIGHT = 26
-- The lit edge under an Available/Active tile -- the reference design's `h-1` accent rule, and the
-- surface the ready flash plays on (see header).
local EDGE_BAR_HEIGHT = 2

-- Eases the edge highlight in and out on a state change instead of snapping, per
-- docs/ui-ux-philosophy.md's Animation Philosophy ("controlled... not excessive"). Every value the
-- spring wraps is still read from the real, unsmoothed `state`.
local STATE_SPRING_SPEED = Tokens.Motion.StateSpring.Speed
local STATE_SPRING_DAMPING = Tokens.Motion.StateSpring.Damping
-- The hover/press springs are deliberately faster than the state spring: a state change is the game
-- telling the player something, and a hover is the player's own hand -- input feedback that lags is
-- input feedback that feels broken.
local INPUT_SPRING_SPEED = 34
local INPUT_SPRING_DAMPING = 1

-- "Empty slot" reticle. Four short gapped ticks rather than a solid cross (VitalIcon.lua's CrossGlyph
-- shape) so it never reads as a vital glyph that wandered into the ability row.
local RETICLE_TICK_LENGTH = 4
local RETICLE_THICKNESS = 1
local RETICLE_GAP = 4

-- Small corner-bracket accent, scaled well below Panel.lua's 12px-arm panel version -- see
-- CornerBracket.lua's own header on why the constants differ per caller.
local TICK_ARM_LENGTH = 6
local TICK_ARM_THICKNESS = 1
local TICK_RIVET_SIZE = 2
local TICK_RIVET_INSET = 5

-- ZIndex bands within the tile. Named because there are now seven of them and an off-by-one puts the
-- cooldown scrim over the countdown that is supposed to be read through it.
local Z_FILL = 0
local Z_WASH = 1
local Z_ICON = 2
local Z_COOLDOWN_FILL = 3
local Z_SCRIM = 4
local Z_COUNTDOWN = 5
local Z_CHROME = 6
local Z_CORNER_TEXT = 7

-- The first CHARACTER of `text`, not its first byte. utf8-aware because an art's DisplayName is
-- typed by hand in the Move Editor: string.sub(word, 1, 1) on a multi-byte character yields half of
-- one, which Roblox renders as a replacement box rather than a letter.
local function firstGlyph(text: string): string
	local nextOffset = utf8.offset(text, 2)
	return if nextOffset then string.sub(text, 1, nextOffset - 1) else text
end

-- An ability's name, abbreviated to the two characters a 56px tile can actually hold: the initials
-- of its first two words ("Ascendant Palm" -> "AP"), or the first two letters of a single-word name
-- ("Thunderclap" -> "Th"). Empty in, empty out, which is what the caller passes for an empty slot.
--
-- DECIDED HERE, NOT BY THE CALLER, and that is not a contradiction of this file's "renders what it is
-- given" rule. How many characters fit is a fact about this tile's size and type scale, both of which
-- are private to this file -- a caller doing the abbreviation would be guessing at both, and would
-- have to be revisited every time either changed. WHAT the ability is called stays the caller's fact;
-- only how much of it fits is ours.
local function monogram(name: string): string
	local words: { string } = {}
	for word in string.gmatch(name, "%S+") do
		table.insert(words, word)
		if #words == 2 then
			break
		end
	end

	if #words == 0 then
		return ""
	end
	if #words >= 2 then
		return string.upper(firstGlyph(words[1])) .. string.upper(firstGlyph(words[2]))
	end

	local word = words[1]
	local first = firstGlyph(word)
	-- Title case rather than two capitals: "Th" reads as an abbreviation of one word, "TH" reads as
	-- two initials and would claim a second word that isn't there.
	return string.upper(first) .. string.lower(firstGlyph(string.sub(word, #first + 1)))
end

local function reticleTick(
	scope: Scope,
	color: UsedAs<Color3>,
	transparency: UsedAs<number>,
	size: UDim2,
	position: UDim2
): Frame
	return scope:New "Frame" {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = position,
		Size = size,
		BackgroundColor3 = color,
		BackgroundTransparency = transparency,
		BorderSizePixel = 0,
	} :: Frame
end

local function Reticle(
	scope: Scope,
	color: UsedAs<Color3>,
	transparency: UsedAs<number>,
	visible: UsedAs<boolean>
): Frame
	local horizontalSize = UDim2.fromOffset(RETICLE_TICK_LENGTH, RETICLE_THICKNESS)
	local verticalSize = UDim2.fromOffset(RETICLE_THICKNESS, RETICLE_TICK_LENGTH)
	local offset = RETICLE_GAP + RETICLE_TICK_LENGTH / 2

	return scope:New "Frame" {
		Name = "Reticle",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(0, 0),
		BackgroundTransparency = 1,
		-- Hidden on the CONTAINER, so all four ticks go together and neither the caller nor the ticks
		-- themselves need to know why. Visible = false on a parent hides its descendants regardless of
		-- their own Visible, which is the whole reason the ticks live under a wrapper frame.
		Visible = visible,
		ZIndex = Z_ICON,

		[Children] = {
			reticleTick(scope, color, transparency, horizontalSize, UDim2.fromOffset(-offset, 0)),
			reticleTick(scope, color, transparency, horizontalSize, UDim2.fromOffset(offset, 0)),
			reticleTick(scope, color, transparency, verticalSize, UDim2.fromOffset(0, -offset)),
			reticleTick(scope, color, transparency, verticalSize, UDim2.fromOffset(0, offset)),
		},
	} :: Frame
end

local function AbilitySlot(scope: Scope, props: AbilitySlotProps): TextButton
	local state: UsedAs<AbilitySlotState> = props.State or "Locked"
	local accentColor: UsedAs<Color3> = props.AccentColor or Tokens.Color.AccentPrimary
	local isChamfered = ChamferedSurface.IsAvailable()

	-- Input state. Two plain booleans the springs below smooth -- the only mutable state this
	-- component owns, and neither is gameplay-relevant.
	local hovered: Fusion.Value<boolean> = scope:Value(false)
	local pressed: Fusion.Value<boolean> = scope:Value(false)

	-- 0 while dim (Locked/Cooldown), 1 while lit (Available/Active). Sprung ONCE and reused by every
	-- lit-state visual below, so the border, the wash, the edge bar and the ready flash cannot drift
	-- out of phase with each other -- and so one state change costs one spring, not four.
	local litness = scope:Spring(
		scope:Computed(function(use)
			local current = use(state)
			if current == "Active" then
				return 1
			elseif current == "Available" then
				return 0.72
			end
			return 0
		end),
		STATE_SPRING_SPEED,
		STATE_SPRING_DAMPING
	)

	local hoverLift = scope:Spring(
		scope:Computed(function(use)
			-- A Locked slot does not rise: there is nothing there to pick up, and a tile that
			-- animates under the cursor is promising an interaction it cannot honour.
			if use(state) == "Locked" then
				return 0
			end
			return if use(hovered) then 1 else 0
		end),
		INPUT_SPRING_SPEED,
		INPUT_SPRING_DAMPING
	)
	local pressScale = scope:Spring(
		scope:Computed(function(use)
			return if use(pressed) then PRESS_SCALE else 1
		end),
		INPUT_SPRING_SPEED,
		INPUT_SPRING_DAMPING
	)

	local backgroundColor = scope:Computed(function(use)
		return if use(state) == "Active" then Tokens.Color.SurfaceElevated else Tokens.Color.Background
	end)

	-- Locked stays visibly dimmer than every other state (doc: "minimal attention"); every other state
	-- reads as fully present.
	local backgroundTransparency = scope:Computed(function(use)
		return if use(state) == "Locked" then 0.2 else 0
	end)

	local strokeColor = scope:Computed(function(use)
		return Tokens.Border.Standard.Color:Lerp(use(accentColor), use(litness))
	end)

	local strokeThickness = scope:Computed(function(use)
		return if use(state) == "Active" then 2 else 1
	end)
	-- Chamfered-mode sibling of strokeThickness: ChamferedSurface's border is a baked-width image, not
	-- a live UIStroke.Thickness, so it swaps between two pre-baked widths instead.
	local strokeWeight: UsedAs<StrokeWeight> = scope:Computed(function(use)
		return if use(state) == "Active" then "Thick" else "Thin"
	end)

	-- Hover brightens the edge on top of whatever the state already made it -- docs/ui-ux-philosophy.
	-- md's Borders section, "higher importance: brighter edge highlight".
	local strokeTransparency = scope:Computed(function(use)
		local lit = use(litness)
		local resting = Tokens.Border.Standard.Transparency
		local base = resting + (0.1 - resting) * lit
		return base * (1 - 0.6 * use(hoverLift))
	end)

	local keybindColor = scope:Computed(function(use)
		local current = use(state)
		if current == "Locked" then
			return Tokens.Color.TextDisabled
		elseif current == "Cooldown" then
			return Tokens.Color.TextSecondary
		end
		return Tokens.Color.AccentSecondary
	end)

	-- The Available/Active energy wash (doc: "slight energy glow" / "energy animation"). A flat plate,
	-- not a rebuilt gradient -- see this file's header on why that mattered.
	local washTransparency = scope:Computed(function(use)
		return 1 - 0.06 * use(litness)
	end)

	-- The lit edge under the tile, and the ready flash. Both are this one number: `litness` is at 0
	-- through a whole cooldown and travels its full range the instant the slot comes back, so the bar
	-- swells and settles with no timer -- see header.
	local edgeTransparency = scope:Computed(function(use)
		local lit = use(litness)
		if lit <= 0 then
			return 1
		end
		return 1 - lit * 0.75
	end)

	-- Static material sheen -- describes the tile's surface, not its state, so it is built once and
	-- never touched again. The state-driven glow is the wash plate above.
	local sheenGradient = scope:New "UIGradient" {
		Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Tokens.Color.TextPrimary),
			ColorSequenceKeypoint.new(1, Tokens.Color.Background),
		}),
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.9),
			NumberSequenceKeypoint.new(0.55, 1),
			NumberSequenceKeypoint.new(1, 1),
		}),
		Rotation = 90,
	}

	local tileChildren: { Instance } = {}

	if isChamfered then
		local fill = ChamferedSurface.Fill(scope, {
			FillColor = backgroundColor,
			FillTransparency = backgroundTransparency,
			ZIndex = Z_FILL,
			Children = sheenGradient,
		})
		local wash = ChamferedSurface.Fill(scope, {
			FillColor = accentColor,
			FillTransparency = washTransparency,
			ZIndex = Z_WASH,
		})
		local stroke = ChamferedSurface.Stroke(scope, {
			Color = strokeColor,
			Transparency = strokeTransparency,
			Weight = strokeWeight,
			ZIndex = Z_CHROME,
		})
		if fill and wash and stroke then
			table.insert(tileChildren, fill)
			table.insert(tileChildren, wash)
			table.insert(tileChildren, stroke)
		else
			-- ChamferedSurface.IsAvailable() said yes but a bake came back nil anyway -- treat it the
			-- same as unavailable rather than rendering a tile with no fill at all.
			isChamfered = false
		end
	end

	if not isChamfered then
		table.insert(
			tileChildren,
			scope:New "UICorner" {
				CornerRadius = Tokens.Radius.Sharp,
			}
		)
		table.insert(
			tileChildren,
			scope:New "UIStroke" {
				Color = strokeColor,
				Thickness = strokeThickness,
				Transparency = strokeTransparency,
			}
		)
		table.insert(tileChildren, sheenGradient)
		table.insert(
			tileChildren,
			scope:New "Frame" {
				Name = "Wash",
				Size = UDim2.fromScale(1, 1),
				BackgroundColor3 = accentColor,
				BackgroundTransparency = washTransparency,
				BorderSizePixel = 0,
				ZIndex = Z_WASH,
			} :: Frame
		)
	end

	-- The tile's identity mark: a real icon if one was uploaded, otherwise the ability's monogram.
	-- Nil for a slot with neither, which is the case the reticle exists for.
	local sigilText: UsedAs<string>? = nil
	if props.AbilityName ~= nil and props.IconAssetId == nil then
		local abilityName = props.AbilityName :: UsedAs<string>
		sigilText = scope:Computed(function(use)
			return monogram(use(abilityName))
		end)
	end

	-- The empty-slot mark, shown only when there is genuinely nothing in the slot -- see this file's
	-- header. A name that abbreviates to nothing (whitespace, or a slot the caller is clearing) counts
	-- as empty, so an art whose DisplayName never arrived falls back to the empty tile rather than to
	-- a blank one with no mark at all.
	local reticleVisible: UsedAs<boolean>
	if props.IconAssetId ~= nil then
		reticleVisible = false
	elseif sigilText ~= nil then
		local sigil = sigilText :: UsedAs<string>
		reticleVisible = scope:Computed(function(use)
			return use(sigil) == ""
		end)
	else
		reticleVisible = true
	end

	-- Dims whatever occupies the icon well, so a cooling or locked ability recedes exactly as far as
	-- docs/ui-ux-philosophy.md's state table asks ("darkened icon" / "desaturated, disabled"). Shared
	-- by the icon and the monogram rather than written twice: they are the same well, and two copies
	-- of this curve would be free to drift the day one of them is retuned.
	local iconTransparency = scope:Computed(function(use)
		local current = use(state)
		if current == "Cooldown" then
			return 0.55
		elseif current == "Locked" then
			return 0.4
		end
		return 0
	end)

	table.insert(tileChildren, Reticle(scope, strokeColor, strokeTransparency, reticleVisible))

	local cornerTicks = CornerBracket.BuildAll(scope, {
		ArmLength = TICK_ARM_LENGTH,
		ArmThickness = TICK_ARM_THICKNESS,
		RivetSize = TICK_RIVET_SIZE,
		RivetInset = TICK_RIVET_INSET,
		Color = strokeColor,
		Transparency = strokeTransparency,
		ZIndex = Z_CHROME,
	})
	for _, piece in ipairs(cornerTicks) do
		table.insert(tileChildren, piece)
	end

	-- The lit rule along the tile's bottom edge. Inside the clipping tile, so it follows the
	-- chamfered silhouette's own bottom edge rather than overhanging the cut corners.
	table.insert(
		tileChildren,
		scope:New "Frame" {
			Name = "EdgeBar",
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.fromScale(0.5, 1),
			Size = UDim2.new(1, 0, 0, EDGE_BAR_HEIGHT),
			BackgroundColor3 = accentColor,
			BackgroundTransparency = edgeTransparency,
			BorderSizePixel = 0,
			ZIndex = Z_CHROME,
		} :: Frame
	)

	if props.IconAssetId ~= nil then
		table.insert(
			tileChildren,
			scope:New "ImageLabel" {
				Name = "Icon",
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromScale(0.62, 0.62),
				BackgroundTransparency = 1,
				Image = props.IconAssetId,
				ImageTransparency = iconTransparency,
				ScaleType = Enum.ScaleType.Fit,
				ZIndex = Z_ICON,
			} :: ImageLabel
		)
	elseif sigilText ~= nil then
		-- SERIF, not the mono the keybind numeral and the countdown use, and that is the point: this
		-- is a proper noun (Tokens.Type's own division of the three registers), and it has to be
		-- instantly distinguishable from the two numbers sharing the tile with it. Sized to the tile
		-- so the mark stays centred in the icon well whatever it abbreviates to.
		table.insert(
			tileChildren,
			Label(scope, {
				Text = sigilText :: UsedAs<string>,
				Scale = "Heading",
				Color = Tokens.Color.TextPrimary,
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromOffset(SLOT_SIZE, SIGIL_HEIGHT),
				TextXAlignment = Enum.TextXAlignment.Center,
				TextTransparency = iconTransparency,
				ZIndex = Z_ICON,
			})
		)
	end

	if props.CooldownFraction ~= nil then
		local cooldownFraction = props.CooldownFraction :: UsedAs<number>
		local cooldownSize = scope:Computed(function(use)
			return UDim2.fromScale(1, math.clamp(use(cooldownFraction), 0, 1))
		end)
		-- The scrim is tied to the cooldown's own fraction rather than to State, so it fades out with
		-- the wipe instead of vanishing on a separate edge -- one event, one animation.
		local scrimTransparency = scope:Computed(function(use)
			local remaining = math.clamp(use(cooldownFraction), 0, 1)
			return if remaining <= 0 then 1 else 0.45
		end)

		-- The bottom-anchored fraction fill, as a dark overlay that RECEDES as the cooldown completes
		-- rather than filling up -- doc: "vertical cooldown animation". Reuses the chamfered Fill mask
		-- when available so the overlay's corners always match the tile's real silhouette instead of
		-- squaring off against it.
		local cooldownFill: GuiObject? = nil
		local cooldownScrim: GuiObject? = nil
		if isChamfered then
			cooldownFill = ChamferedSurface.Fill(scope, {
				FillColor = accentColor,
				FillTransparency = 0.8,
				AnchorPoint = Vector2.new(0, 1),
				Position = UDim2.fromScale(0, 1),
				Size = cooldownSize,
				ZIndex = Z_COOLDOWN_FILL,
			})
			cooldownScrim = ChamferedSurface.Fill(scope, {
				FillColor = Tokens.Color.Background,
				FillTransparency = scrimTransparency,
				ZIndex = Z_SCRIM,
			})
		end

		if not cooldownFill then
			cooldownFill = scope:New "Frame" {
				Name = "CooldownFill",
				AnchorPoint = Vector2.new(0, 1),
				Position = UDim2.fromScale(0, 1),
				Size = cooldownSize,
				BackgroundColor3 = accentColor,
				BackgroundTransparency = 0.8,
				BorderSizePixel = 0,
				ZIndex = Z_COOLDOWN_FILL,
			} :: Frame
		end
		if not cooldownScrim then
			cooldownScrim = scope:New "Frame" {
				Name = "CooldownScrim",
				Size = UDim2.fromScale(1, 1),
				BackgroundColor3 = Tokens.Color.Background,
				BackgroundTransparency = scrimTransparency,
				BorderSizePixel = 0,
				ZIndex = Z_SCRIM,
			} :: Frame
		end

		table.insert(tileChildren, cooldownFill :: Instance)
		table.insert(tileChildren, cooldownScrim :: Instance)
	end

	if props.CooldownSeconds ~= nil then
		local cooldownSeconds = props.CooldownSeconds :: UsedAs<number>

		table.insert(
			tileChildren,
			Label(scope, {
				Text = scope:Computed(function(use)
					return string.format("%.1fs", use(cooldownSeconds))
				end),
				Scale = "Numeral",
				Color = Tokens.Color.TextPrimary,
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromOffset(SLOT_SIZE, 16),
				TextXAlignment = Enum.TextXAlignment.Center,
				-- Hidden rather than left reading "0.0s" over a ready tile. The caller zeroes this on
				-- expiry, and a countdown that lingers at zero is worse than no countdown.
				Visible = scope:Computed(function(use)
					return use(cooldownSeconds) > 0
				end),
				ZIndex = Z_COUNTDOWN,
			})
		)
	end

	-- The keybind number and the resource label both sit in a tile corner (top-left and bottom-right),
	-- above the corner tick that occupies that same corner rather than tucked underneath it.
	table.insert(
		tileChildren,
		Label(scope, {
			Text = props.Keybind,
			Scale = "NumeralSmall",
			Color = keybindColor,
			Position = UDim2.fromOffset(5, 3),
			Size = UDim2.fromOffset(14, 12),
			TextXAlignment = Enum.TextXAlignment.Left,
			ZIndex = Z_CORNER_TEXT,
		})
	)

	if props.ResourceLabel ~= nil then
		table.insert(
			tileChildren,
			Label(scope, {
				Text = props.ResourceLabel :: UsedAs<string>,
				Scale = "NumeralSmall",
				Color = Tokens.Color.TextSecondary,
				AnchorPoint = Vector2.new(1, 1),
				Position = UDim2.new(1, -4, 1, -3),
				Size = UDim2.fromOffset(26, 11),
				TextXAlignment = Enum.TextXAlignment.Right,
				ZIndex = Z_CORNER_TEXT,
			})
		)
	end

	-- Everything visible lives on this inner frame so the hover lift and press scale have something to
	-- move that is not the button's own hit rect -- see this file's header.
	local tile = scope:New "Frame" {
		Name = "Tile",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = scope:Computed(function(use)
			return UDim2.new(0.5, 0, 0.5, -HOVER_LIFT * use(hoverLift))
		end),
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = backgroundColor,
		-- Chamfered mode paints its own fill via an ImageLabel child instead, so this frame's own
		-- background must stay fully transparent -- otherwise its plain rectangular corners would show
		-- through underneath the chamfered silhouette's cut corners.
		BackgroundTransparency = if isChamfered then 1 else backgroundTransparency,
		BorderSizePixel = 0,
		ClipsDescendants = true,

		[Children] = {
			scope:New "UIScale" { Scale = pressScale },
			tileChildren,
		},
	} :: Frame

	return scope:New "TextButton" {
		Name = "AbilitySlot" .. props.Keybind,
		LayoutOrder = props.LayoutOrder,
		Size = UDim2.fromOffset(SLOT_SIZE, SLOT_SIZE),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		-- Deliberately NOT clipping: the tile inside rises out of this rect on hover, and clipping here
		-- would shave the top off it as it did.
		AutoButtonColor = false,
		-- Blank, same reasoning as Tab.lua/Sidebar.lua's navItem -- every visible glyph on this tile is
		-- already a purpose-built child, and a native Text here would just be an invisible, unstyled
		-- second label sitting behind them.
		Text = "",

		[OnEvent "Activated"] = function()
			if props.OnActivated then
				props.OnActivated()
			end
		end,
		[OnEvent "MouseEnter"] = function()
			hovered:set(true)
		end,
		[OnEvent "MouseLeave"] = function()
			hovered:set(false)
			-- A drag that leaves the tile never fires InputEnded on it, so the press would latch
			-- forever. Clearing here is what keeps a released-elsewhere click from leaving the tile
			-- permanently sunk.
			pressed:set(false)
		end,
		[OnEvent "MouseButton1Down"] = function()
			pressed:set(true)
		end,
		[OnEvent "MouseButton1Up"] = function()
			pressed:set(false)
		end,

		[Children] = tile,
	} :: TextButton
end

return AbilitySlot
