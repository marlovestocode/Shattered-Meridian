--!strict
--[[
	AbilitySlot.lua

	Owns: a single slot in the Ability System UI's hotbar row (docs/ui-ux-philosophy.md), rendering
	all four states that doc specifies -- Locked, Available, Cooldown, Active -- plus the optional
	icon/cooldown/resource props each state can carry. Every prop beyond Keybind/LayoutOrder is
	optional and State defaults to "Locked", so HUD/init.lua's five existing calls (which only ever
	pass Keybind/LayoutOrder) keep rendering byte-for-byte the same desaturated, minimal-attention
	appearance they did before this file grew states -- see that file's header for why: ArtSystem is
	still an empty Init(), and CombatSystem's first-pass melee foundation intentionally doesn't
	define an ability/art concept (see CombatSystem.lua's header), so there's still no real ability
	assigned to any hotbar slot.

	Does not own: what ability (if any) actually occupies a slot, its icon, its cooldown state, or
	its resource cost -- once ArtSystem exists and a real ability-loadout concept is designed, a
	caller drives State/IconAssetId/CooldownFraction/CooldownSeconds/ResourceLabel from real
	ClientState; this component only renders whatever it's given, it doesn't decide it.

	AccentColor tints the existing Available/Active border+glow treatment (see strokeColor/the
	UIGradient below) toward a per-ability hue once a real ability-loadout concept assigns one --
	falls back to the plain Tokens.Color.AccentPrimary every slot already used when omitted, so this
	is pure plumbing with no visible effect until a caller actually passes something. The live HUD's
	five calls never pass it (see HUD/init.lua's header) -- Screens/DevMenu's Tuning tab preview
	harness is the only current caller, verifying the tint renders correctly ahead of ArtSystem.

	Keybind numbers are a local input-affordance label, not gameplay state, so showing "1".."5" is
	not the kind of fabrication the rest of this file avoids -- it's just telling the player which
	key would activate whatever eventually lives here.

	Tile shape and "empty slot" chrome (2026-07-23 polish pass -- docs/ui-ux-philosophy.md's Ability
	System UI states were already all rendered; this pass answers a design review that the doc's own
	"minimal attention" Locked treatment was reading as "flat dead rectangle," not "restrained"):
	- The tile's own background/border now render via Client/UI/ChamferedSurface.lua's true cut-corner
	  silhouette when available (see that module's header), replacing UICorner+UIStroke -- falls back
	  to the prior sharp-rect treatment automatically when it isn't (ChamferedSurface.IsAvailable()).
	- A restrained centered reticle (four short gapped ticks, not a solid cross -- kept visually
	  distinct from VitalIcon.lua's CrossGlyph so it never reads as a vital) plus four small
	  Components/CornerBracket.lua accents (Panel.lua's own corner-bracket vocabulary, scaled down for
	  a 40px tile) give every slot -- including a fully "Locked" one -- some restrained structure
	  instead of a bare rectangle. Both track strokeColor/strokeTransparency below, the same
	  presence-by-state signal the border already carries, so this adds no new fabricated identity:
	  a Locked slot's reticle/ticks stay exactly as dim as its border already was.
	- Neither of these depends on ChamferedSurface -- they're plain Frame geometry, so they still
	  render even when the chamfered textures are unavailable and the tile falls back to a sharp rect.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Tokens = require(script.Parent.Parent.Tokens)
local ChamferedSurface = require(script.Parent.Parent.ChamferedSurface)
local CornerBracket = require(script.Parent.CornerBracket)
local Label = require(script.Parent.Label)

local Children = Fusion.Children

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>
type StrokeWeight = ChamferedSurface.StrokeWeight

export type AbilitySlotState = "Locked" | "Available" | "Cooldown" | "Active"

export type AbilitySlotProps = {
	Keybind: string,
	LayoutOrder: number?,
	-- Defaults to "Locked" -- see header. Reactive so a future caller can drive it straight from
	-- real ability/cooldown state once it exists.
	State: UsedAs<AbilitySlotState>?,
	-- A real uploaded texture (see VitalIcon.lua's header for why this repo doesn't guess at
	-- rbxassetids). Omit and the slot shows no icon -- unlike a vital, an ability has no fixed
	-- visual identity to fall back to procedurally, so there's no glyph substitute here.
	IconAssetId: string?,
	-- Remaining fraction of the cooldown, 1 (just used) down to 0 (ready). Meaningful only while
	-- State is "Cooldown" -- the caller is responsible for only supplying it then, the same way
	-- Bar.lua/VitalIcon.lua's CriticalBelow is only supplied by callers who want that behavior.
	CooldownFraction: UsedAs<number>?,
	-- Remaining time, for the on-icon countdown label. Meaningful only while State is "Cooldown".
	CooldownSeconds: UsedAs<number>?,
	-- e.g. "20 Qi" -- the resource cost/requirement docs/ui-ux-philosophy.md's Ability System UI
	-- section calls for. Rendered whenever provided, independent of State.
	ResourceLabel: UsedAs<string>?,
	-- Per-ability hue for the Available/Active border+glow (see this file's header). Omit for the
	-- plain Tokens.Color.AccentPrimary every slot already rendered before this prop existed.
	AccentColor: UsedAs<Color3>?,
}

local SLOT_SIZE = Tokens.Control.RowHeight

-- Decorative only -- eases the edge highlight in/out on a state change instead of snapping, per
-- ui-ux-philosophy.md's Animation Philosophy ("controlled... not excessive"). Every value the
-- spring wraps below is still read from the real, unsmoothed `state`. Values live in
-- Tokens.Motion.StateSpring now (see that table's header) -- kept as local aliases so every call
-- site below is unchanged.
local STATE_SPRING_SPEED = Tokens.Motion.StateSpring.Speed
local STATE_SPRING_DAMPING = Tokens.Motion.StateSpring.Damping

-- "Empty slot" reticle -- see this file's header. Four short gapped ticks rather than a solid cross
-- (VitalIcon.lua's CrossGlyph shape) so it never reads as a vital glyph accidentally wandering into
-- the ability row.
local RETICLE_TICK_LENGTH = 3
local RETICLE_THICKNESS = 1
local RETICLE_GAP = 3

-- Small corner-bracket accent, scaled well below Panel.lua's 12px-arm Hotbar-panel version -- see
-- this file's header and CornerBracket.lua's own header on why the constants differ per caller.
local TICK_ARM_LENGTH = 5
local TICK_ARM_THICKNESS = 1
local TICK_RIVET_SIZE = 2
local TICK_RIVET_INSET = 4

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

local function Reticle(scope: Scope, color: UsedAs<Color3>, transparency: UsedAs<number>): Frame
	local horizontalSize = UDim2.fromOffset(RETICLE_TICK_LENGTH, RETICLE_THICKNESS)
	local verticalSize = UDim2.fromOffset(RETICLE_THICKNESS, RETICLE_TICK_LENGTH)
	local offset = RETICLE_GAP + RETICLE_TICK_LENGTH / 2

	return scope:New "Frame" {
		Name = "Reticle",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(0, 0),
		BackgroundTransparency = 1,
		ZIndex = 1,

		[Children] = {
			reticleTick(scope, color, transparency, horizontalSize, UDim2.fromOffset(-offset, 0)),
			reticleTick(scope, color, transparency, horizontalSize, UDim2.fromOffset(offset, 0)),
			reticleTick(scope, color, transparency, verticalSize, UDim2.fromOffset(0, -offset)),
			reticleTick(scope, color, transparency, verticalSize, UDim2.fromOffset(0, offset)),
		},
	} :: Frame
end

local function AbilitySlot(scope: Scope, props: AbilitySlotProps): Frame
	local state: UsedAs<AbilitySlotState> = props.State or "Locked"
	local accentColor: UsedAs<Color3> = props.AccentColor or Tokens.Color.AccentPrimary
	local isChamfered = ChamferedSurface.IsAvailable()

	local backgroundColor = scope:Computed(function(use)
		return if use(state) == "Active" then Tokens.Color.SurfaceElevated else Tokens.Color.Background
	end)

	-- Locked stays visibly dimmer than every other state (doc: "minimal attention"); every other
	-- state reads as fully present.
	local backgroundTransparency = scope:Computed(function(use)
		return if use(state) == "Locked" then 0.2 else 0
	end)

	local strokeColor = scope:Computed(function(use)
		local current = use(state)
		if current == "Active" or current == "Available" then
			return use(accentColor)
		end
		return Tokens.Color.BorderSubtle
	end)

	local strokeThickness = scope:Computed(function(use)
		return if use(state) == "Active" then 2 else 1
	end)
	-- Chamfered-mode sibling of strokeThickness above -- ChamferedSurface's border is a baked-width
	-- image, not a live UIStroke.Thickness, so it swaps between two pre-baked widths instead (see
	-- that module's header). Same hard Computed switch as strokeThickness -- neither is sprung today.
	local strokeWeight: UsedAs<StrokeWeight> = scope:Computed(function(use)
		return if use(state) == "Active" then "Thick" else "Thin"
	end)

	local strokeTransparency = scope:Spring(
		scope:Computed(function(use)
			local current = use(state)
			if current == "Locked" then
				return 0.3
			elseif current == "Cooldown" then
				return 0.5
			end
			return 0.1
		end),
		STATE_SPRING_SPEED,
		STATE_SPRING_DAMPING
	)

	local keybindColor = scope:Computed(function(use)
		local current = use(state)
		if current == "Locked" then
			return Tokens.Color.TextDisabled
		elseif current == "Cooldown" then
			return Tokens.Color.TextSecondary
		end
		return Tokens.Color.TextPrimary
	end)

	-- Available/Active energy glow (doc: "slight energy glow" / "energy animation") -- the same
	-- top-to-bottom sheen technique VitalIcon.lua uses for its forged-metal highlight, recolored
	-- toward the accent hue instead of TextPrimary so it reads as *ability* energy specifically.
	local glowTransparency = scope:Spring(
		scope:Computed(function(use)
			local current = use(state)
			if current == "Active" then
				return 0.65
			elseif current == "Available" then
				return 0.85
			end
			return 1
		end),
		STATE_SPRING_SPEED,
		STATE_SPRING_DAMPING
	)

	-- Shared sheen gradient -- the accent-hued top-to-bottom highlight (doc: "slight energy glow" /
	-- "energy animation"), unchanged from before this pass except for where it's attached: it used to
	-- modify the root Frame's own BackgroundColor3 paint directly; now it recolors whichever fill
	-- surface (chamfered image or legacy Frame) actually paints the tile, since chamfered mode's root
	-- Frame has no background of its own to modify (see BackgroundTransparency below).
	local glowGradient = scope:New "UIGradient" {
		Color = scope:Computed(function(use)
			return ColorSequence.new({
				ColorSequenceKeypoint.new(0, use(accentColor)),
				ColorSequenceKeypoint.new(1, Tokens.Color.Background),
			})
		end),
		Transparency = scope:Computed(function(use)
			local top = use(glowTransparency)
			return NumberSequence.new({
				NumberSequenceKeypoint.new(0, top),
				NumberSequenceKeypoint.new(0.6, 1),
				NumberSequenceKeypoint.new(1, 1),
			})
		end),
		Rotation = 90,
	}

	local children: { Instance } = {}

	if isChamfered then
		local fill = ChamferedSurface.Fill(scope, {
			FillColor = backgroundColor,
			FillTransparency = backgroundTransparency,
			ZIndex = 0,
			Children = glowGradient,
		})
		local stroke = ChamferedSurface.Stroke(scope, {
			Color = strokeColor,
			Transparency = strokeTransparency,
			Weight = strokeWeight,
			ZIndex = 5,
		})
		if fill and stroke then
			table.insert(children, fill)
			table.insert(children, stroke)
		else
			-- ChamferedSurface.IsAvailable() said yes but a bake somehow came back nil anyway --
			-- treat it the same as unavailable rather than rendering a tile with no fill at all.
			isChamfered = false
		end
	end

	if not isChamfered then
		table.insert(
			children,
			scope:New "UICorner" {
				CornerRadius = Tokens.Radius.Sharp,
			}
		)
		table.insert(
			children,
			scope:New "UIStroke" {
				Color = strokeColor,
				Thickness = strokeThickness,
				Transparency = strokeTransparency,
			}
		)
		table.insert(children, glowGradient)
	end

	table.insert(children, Reticle(scope, strokeColor, strokeTransparency))
	local cornerTicks = CornerBracket.BuildAll(scope, {
		ArmLength = TICK_ARM_LENGTH,
		ArmThickness = TICK_ARM_THICKNESS,
		RivetSize = TICK_RIVET_SIZE,
		RivetInset = TICK_RIVET_INSET,
		Color = strokeColor,
		Transparency = strokeTransparency,
		ZIndex = 5,
	})
	for _, piece in ipairs(cornerTicks) do
		table.insert(children, piece)
	end

	-- ZIndex 6: above the ZIndex-5 corner ticks/stroke -- the keybind number and resource label both
	-- sit in a tile corner (top-left, bottom-right respectively) and must stay legible on top of the
	-- tick that occupies that same corner, not tucked underneath it.
	table.insert(
		children,
		Label(scope, {
			Text = props.Keybind,
			Scale = "Detail",
			Color = keybindColor,
			Position = UDim2.fromOffset(3, 1),
			Size = UDim2.fromOffset(14, 12),
			TextXAlignment = Enum.TextXAlignment.Left,
			ZIndex = 6,
		})
	)

	if props.IconAssetId ~= nil then
		local iconTransparency = scope:Computed(function(use)
			return if use(state) == "Cooldown" then 0.55 else 0
		end)

		table.insert(
			children,
			scope:New "ImageLabel" {
				Name = "Icon",
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromScale(0.7, 0.7),
				BackgroundTransparency = 1,
				Image = props.IconAssetId,
				ImageTransparency = iconTransparency,
				ScaleType = Enum.ScaleType.Fit,
				ZIndex = 2,
			} :: ImageLabel
		)
	end

	if props.CooldownFraction ~= nil then
		local cooldownFraction = props.CooldownFraction :: UsedAs<number>
		local cooldownSize = scope:Computed(function(use)
			return UDim2.fromScale(1, math.clamp(use(cooldownFraction), 0, 1))
		end)

		-- Same bottom-anchored fraction-fill technique VitalIcon.lua's Fill uses, but as a dark
		-- overlay that *recedes* as the cooldown completes rather than filling up -- doc: "vertical
		-- cooldown animation". Reuses the chamfered Fill mask when available so the overlay's own
		-- corners always match the tile's real silhouette instead of squaring off against it -- see
		-- VitalIcon.lua's header for the identical reasoning on its own fill gauge.
		local cooldownOverlay: GuiObject? = nil
		if isChamfered then
			cooldownOverlay = ChamferedSurface.Fill(scope, {
				FillColor = Tokens.Color.Background,
				FillTransparency = 0.35,
				AnchorPoint = Vector2.new(0, 1),
				Position = UDim2.fromScale(0, 1),
				Size = cooldownSize,
				ZIndex = 3,
			})
		end

		if not cooldownOverlay then
			cooldownOverlay = scope:New "Frame" {
				Name = "CooldownOverlay",
				AnchorPoint = Vector2.new(0, 1),
				Position = UDim2.fromScale(0, 1),
				Size = cooldownSize,
				BackgroundColor3 = Tokens.Color.Background,
				BackgroundTransparency = 0.35,
				BorderSizePixel = 0,
				ZIndex = 3,

				[Children] = scope:New "UICorner" {
					CornerRadius = Tokens.Radius.Sharp,
				},
			} :: Frame
		end

		table.insert(children, cooldownOverlay :: Instance)
	end

	if props.CooldownSeconds ~= nil then
		local cooldownSeconds = props.CooldownSeconds :: UsedAs<number>

		table.insert(
			children,
			Label(scope, {
				Text = scope:Computed(function(use)
					return string.format("%.1f", use(cooldownSeconds))
				end),
				Scale = "Detail",
				Color = Tokens.Color.TextPrimary,
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromOffset(SLOT_SIZE, 14),
				TextXAlignment = Enum.TextXAlignment.Center,
				ZIndex = 4,
			})
		)
	end

	if props.ResourceLabel ~= nil then
		table.insert(
			children,
			Label(scope, {
				Text = props.ResourceLabel :: UsedAs<string>,
				Scale = "Detail",
				Color = Tokens.Color.TextSecondary,
				AnchorPoint = Vector2.new(1, 1),
				Position = UDim2.new(1, -2, 1, -1),
				Size = UDim2.fromOffset(22, 10),
				TextXAlignment = Enum.TextXAlignment.Right,
				-- See the keybind Label's own comment above -- same bottom-right corner-tick overlap.
				ZIndex = 6,
			})
		)
	end

	return scope:New "Frame" {
		Name = "AbilitySlot" .. props.Keybind,
		LayoutOrder = props.LayoutOrder,
		Size = UDim2.fromOffset(SLOT_SIZE, SLOT_SIZE),
		BackgroundColor3 = backgroundColor,
		-- Chamfered mode paints its own fill via an ImageLabel child instead (see `children` above),
		-- so this root Frame's own background must stay fully transparent -- otherwise its plain
		-- rectangular corners would show through underneath the chamfered silhouette's cut corners.
		BackgroundTransparency = if isChamfered then 1 else backgroundTransparency,
		BorderSizePixel = 0,
		ClipsDescendants = true,

		[Children] = children,
	} :: Frame
end

return AbilitySlot
