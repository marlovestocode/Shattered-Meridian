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

	Keybind numbers are a local input-affordance label, not gameplay state, so showing "1".."5" is
	not the kind of fabrication the rest of this file avoids -- it's just telling the player which
	key would activate whatever eventually lives here.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Tokens = require(script.Parent.Parent.Tokens)
local Label = require(script.Parent.Label)

local Children = Fusion.Children

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>

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
}

local SLOT_SIZE = Tokens.Control.RowHeight

-- Decorative only -- eases the edge highlight in/out on a state change instead of snapping, per
-- ui-ux-philosophy.md's Animation Philosophy ("controlled... not excessive"). Every value the
-- spring wraps below is still read from the real, unsmoothed `state`. Values live in
-- Tokens.Motion.StateSpring now (see that table's header) -- kept as local aliases so every call
-- site below is unchanged.
local STATE_SPRING_SPEED = Tokens.Motion.StateSpring.Speed
local STATE_SPRING_DAMPING = Tokens.Motion.StateSpring.Damping

local function AbilitySlot(scope: Scope, props: AbilitySlotProps): Frame
	local state: UsedAs<AbilitySlotState> = props.State or "Locked"

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
			return Tokens.Color.BorderAccent
		end
		return Tokens.Color.BorderSubtle
	end)

	local strokeThickness = scope:Computed(function(use)
		return if use(state) == "Active" then 2 else 1
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

	local children: { Instance } = {
		scope:New "UICorner" {
			CornerRadius = Tokens.CornerRadius,
		},
		scope:New "UIStroke" {
			Color = strokeColor,
			Thickness = strokeThickness,
			Transparency = strokeTransparency,
		},
		scope:New "UIGradient" {
			Color = ColorSequence.new({
				ColorSequenceKeypoint.new(0, Tokens.Color.BorderAccent),
				ColorSequenceKeypoint.new(1, Tokens.Color.Background),
			}),
			Transparency = scope:Computed(function(use)
				local top = use(glowTransparency)
				return NumberSequence.new({
					NumberSequenceKeypoint.new(0, top),
					NumberSequenceKeypoint.new(0.6, 1),
					NumberSequenceKeypoint.new(1, 1),
				})
			end),
			Rotation = 90,
		},
		Label(scope, {
			Text = props.Keybind,
			Scale = "Caption",
			Color = keybindColor,
			Position = UDim2.fromOffset(3, 1),
			Size = UDim2.fromOffset(14, 12),
			TextXAlignment = Enum.TextXAlignment.Left,
			ZIndex = 4,
		}),
	}

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

		-- Same bottom-anchored fraction-fill technique VitalIcon.lua's Fill uses, but as a dark
		-- overlay that *recedes* as the cooldown completes rather than filling up -- doc: "vertical
		-- cooldown animation".
		table.insert(
			children,
			scope:New "Frame" {
				Name = "CooldownOverlay",
				AnchorPoint = Vector2.new(0, 1),
				Position = UDim2.fromScale(0, 1),
				Size = scope:Computed(function(use)
					return UDim2.fromScale(1, math.clamp(use(cooldownFraction), 0, 1))
				end),
				BackgroundColor3 = Tokens.Color.Background,
				BackgroundTransparency = 0.35,
				BorderSizePixel = 0,
				ZIndex = 3,

				[Children] = scope:New "UICorner" {
					CornerRadius = Tokens.CornerRadius,
				},
			} :: Frame
		)
	end

	if props.CooldownSeconds ~= nil then
		local cooldownSeconds = props.CooldownSeconds :: UsedAs<number>

		table.insert(
			children,
			Label(scope, {
				Text = scope:Computed(function(use)
					return string.format("%.1f", use(cooldownSeconds))
				end),
				Scale = "Caption",
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
				Scale = "Caption",
				Color = Tokens.Color.TextSecondary,
				AnchorPoint = Vector2.new(1, 1),
				Position = UDim2.new(1, -2, 1, -1),
				Size = UDim2.fromOffset(22, 10),
				TextXAlignment = Enum.TextXAlignment.Right,
				ZIndex = 4,
			})
		)
	end

	return scope:New "Frame" {
		Name = "AbilitySlot" .. props.Keybind,
		LayoutOrder = props.LayoutOrder,
		Size = UDim2.fromOffset(SLOT_SIZE, SLOT_SIZE),
		BackgroundColor3 = backgroundColor,
		BackgroundTransparency = backgroundTransparency,
		BorderSizePixel = 0,
		ClipsDescendants = true,

		[Children] = children,
	} :: Frame
end

return AbilitySlot
