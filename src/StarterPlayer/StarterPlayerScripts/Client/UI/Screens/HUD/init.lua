--!strict
--[[
	HUD.lua

	Owns: the always-visible combat HUD surface -- the central hotbar (docs/ui-ux-philosophy.md's
	"Player Status Display" and "Ability System UI" sections): a single horizontal bar --
	Health/Qi/Posture as icon-tile gauges (VitalIcon.lua) | one thin divider | a row of ability slots
	(AbilitySlot.lua) -- with a CombatStateBadge unfolding above it the moment
	CombatState.inCombatUntil goes live (see that component's own header) -- the first real consumer
	of that server signal. Renders directly from ClientState -- never computes or guesses at a value
	ClientState doesn't already hold, per that doc's HUD sync rule against optimistic HUD state.

	One row, not two: an earlier version stacked the vitals row over the ability row inside the same
	Panel. The Figma Make hotbar reference this was rebuilt against calls for a single unified bar --
	"no more stacked rows or connector lines" -- so the two groups now sit side by side, separated by
	one hairline Divider frame, and CombatStateBadge is the only thing still stacked above the bar
	(it has genuine open/closed state to unfold; the vitals/ability groups don't).

	The ability row is a real, styled mount point, not a placeholder comment -- but every slot
	still renders in the doc's "Locked" appearance: ArtSystem is still an empty Init(), and
	CombatSystem's first-pass melee foundation deliberately doesn't define an ability
	icon/cooldown/resource concept (no arts/abilities exist yet -- see CombatSystem.lua's header),
	so there's no real per-slot data to show. Health/Qi/Posture above, by contrast: Health and
	Posture ARE now live (CombatSystem exists and ClientState.Bootstrap() wires them to its
	Combat_VitalsUpdated remote); Qi stays render-only -- no System owns that resource yet.
	Damage numbers and lock-on UI are also now wired to CombatSystem, but live in the separate
	Screens/CombatFeedback surface, not this hotbar. Same "waits on the owning System" reasoning
	applies to Level, character information, and active effects (also named in the Player Status
	Display list but left out of this hotbar), and to notifications/menus, which still wait on
	RewardSystem/ProgressionSystem/FactionManager -- see docs/ui-ux-philosophy.md's "Current build
	status" for the full list and why.

	Mount() returns the bare ScreenGui, not a *Handle table -- this surface is always-on with no
	open/closed state to expose, one of the two documented Mount() return shapes (see
	docs/ui-ux-philosophy.md's Framework section, "Mount() return-value contract").

	2026-07-23 polish pass (design review against the actual in-game render): the Hotbar Panel now
	opts into Chamfered (Client/UI/ChamferedSurface.lua's true cut-corner silhouette) alongside its
	existing CornerAccent -- Panel.lua treats Chamfered as the preferred treatment and CornerAccent as
	its graceful-degradation fallback when the chamfered textures aren't available, see that file's
	header. The divider/ability-row gaps were also tightened and the divider recolored -- see Divider's
	own comment and the outer Row's call site below for the specific numbers and why.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)

local Tokens = require(script.Parent.Parent.Tokens)
local Panel = require(script.Parent.Parent.Components.Panel)
local VitalIcon = require(script.Parent.Parent.Components.VitalIcon)
local AbilitySlot = require(script.Parent.Parent.Components.AbilitySlot)
local CombatStateBadge = require(script.Parent.Parent.Components.CombatStateBadge)
local ClientStateModule = require(script.Parent.Parent.State.ClientState)

local Children = Fusion.Children

type Scope = Fusion.Scope<typeof(Fusion)>
type ClientState = ClientStateModule.ClientState

local HUD = {}

-- Keybinds are a local input affordance, not gameplay state -- see AbilitySlot.lua's header for
-- why showing these numbers isn't the kind of data fabrication this file otherwise avoids.
local ABILITY_KEYBINDS = { "1", "2", "3", "4", "5" }

-- A horizontal strip of children, auto-sized to its content on both axes so callers never need to
-- hand-compute a row's pixel width/height (and never need to duplicate a child component's own
-- size constants just to size the row around it).
local function Row(scope: Scope, layoutOrder: number, gap: number, children: { Instance }): Frame
	return scope:New "Frame" {
		LayoutOrder = layoutOrder,
		AutomaticSize = Enum.AutomaticSize.XY,
		Size = UDim2.fromOffset(0, 0),
		BackgroundTransparency = 1,

		[Children] = {
			scope:New "UIListLayout" {
				FillDirection = Enum.FillDirection.Horizontal,
				VerticalAlignment = Enum.VerticalAlignment.Center,
				Padding = UDim.new(0, gap),
				SortOrder = Enum.SortOrder.LayoutOrder,
			},
			children,
		},
	} :: Frame
end

-- The single hairline seam between the vitals group and the ability-slot group -- the reference
-- mockup's "one thin vertical divider" replacing the old two-stacked-rows layout (see this file's
-- header). Height comes from VitalIcon.TILE_SIZE, not a guessed number: the vitals tiles are the
-- taller of the two groups (52px vs. AbilitySlot's Tokens.Control.RowHeight, 40px), so sizing off
-- the real tile constant is what makes this genuinely span the bar's full inner height regardless
-- of either component's own size ever changing later.
--
-- Color is TextSecondary, not BorderSubtle -- BorderSubtle (RGB 45,55,68) sits too close to the
-- Hotbar panel's own Surface/SurfaceElevated background tones to read as a deliberate seam at a
-- glance (a 2026-07-23 design review against the actual in-game render flagged this specific
-- divider as looking like unstructured dead space). TextSecondary keeps the same cold blue-grey
-- register (no new hue introduced) while giving enough luminance contrast to actually register as
-- a line rather than a gap.
local function Divider(scope: Scope, layoutOrder: number): Frame
	return scope:New "Frame" {
		Name = "Divider",
		LayoutOrder = layoutOrder,
		Size = UDim2.fromOffset(Tokens.Control.DividerThickness, VitalIcon.TILE_SIZE),
		BackgroundColor3 = Tokens.Color.TextSecondary,
		BorderSizePixel = 0,
	} :: Frame
end

function HUD.Mount(scope: Scope, playerGui: PlayerGui, clientState: ClientState): ScreenGui
	local abilitySlots = {}
	for index, keybind in ipairs(ABILITY_KEYBINDS) do
		abilitySlots[index] = AbilitySlot(scope, {
			LayoutOrder = index,
			Keybind = keybind,
		})
	end

	return scope:New "ScreenGui" {
		Name = "HUD",
		IgnoreGuiInset = true,
		ResetOnSpawn = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Parent = playerGui,

		[Children] = Panel(scope, {
			Name = "Hotbar",
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.new(0.5, 0, 1, -Tokens.Space.L),
			AutomaticSize = Enum.AutomaticSize.XY,
			Elevated = true,
			CornerAccent = true,
			Chamfered = true,
			-- Explicit, not the Panel.lua default (Tokens.Color.BorderSubtle) -- same low-contrast
			-- token that made the vitals/ability divider and VitalIcon's own border nearly invisible
			-- against this panel's dark Surface/SurfaceElevated fill (2026-07-23 in-game screenshot
			-- review, same root cause both times). BorderAccent matches the corner brackets' own
			-- color, so the whole outer frame now reads as one coherent steel-blue edge instead of
			-- brackets floating over an invisible box. BorderTransparency softens it a step below
			-- full opacity (2026-07-24 review: fully opaque read as too harsh/glowing against the
			-- corner brackets' own already-bright accent) without going back to unreadable.
			BorderColor3 = Tokens.Color.AccentPrimary,
			BorderTransparency = 0.3,

			Children = {
				scope:New "UIPadding" {
					PaddingLeft = UDim.new(0, Tokens.Space.S),
					PaddingRight = UDim.new(0, Tokens.Space.S),
					PaddingTop = UDim.new(0, Tokens.Space.XS),
					PaddingBottom = UDim.new(0, Tokens.Space.XS),
				},
				-- Padding is 0, not Tokens.Space.XS -- a UIListLayout's Padding applies BETWEEN items
				-- regardless of either item's actual size, so a nonzero value here left a fixed
				-- sliver of dead space above the bar row even while CombatStateBadge was fully
				-- collapsed (Size.Y = 0), reading as "more open space at top than bottom"
				-- (2026-07-24 in-game screenshot review). CombatStateBadge.lua's own GAP_TO_NEXT now
				-- bakes that same gap into its own reactive height instead, so it collapses to true
				-- zero together with the badge rather than being layout-imposed on top of it.
				scope:New "UIListLayout" {
					FillDirection = Enum.FillDirection.Vertical,
					HorizontalAlignment = Enum.HorizontalAlignment.Center,
					Padding = UDim.new(0, 0),
					SortOrder = Enum.SortOrder.LayoutOrder,
				},
				CombatStateBadge(scope, {
					LayoutOrder = 0,
					InCombat = clientState.InCombat,
				}),
				-- The single unified bar (see this file's header): vitals group | Divider | ability
				-- group, one horizontal Row instead of the old two stacked rows. Gap is XS (not S)
				-- specifically around the Divider -- S on both sides read as an oversized, dead-looking
				-- gap against the actual in-game render (2026-07-23 design review); XS still gives the
				-- seam clearance on both sides without the panel reading as loosely padded, matching
				-- the reference direction's "no wasted padding... tight and compact."
				Row(scope, 1, Tokens.Space.XS, {
					Row(scope, 1, Tokens.Space.S, {
						VitalIcon.new(scope, {
							LayoutOrder = 1,
							Glyph = "Cross",
							Caption = "Health",
							Value = clientState.Health,
							Max = clientState.MaxHealth,
							FillColor = Tokens.VitalColor.Health,
							CriticalBelow = 0.25,
							-- Uploaded from docs/design/icons/health.svg's PNG export (see this
							-- prop's header on VitalIcon.lua) -- re-uploaded 2026-07-24 after the
							-- left-tilt + bolder-outline pass. Texture id (rbxassetid://108335358703553
							-- is the wrapping Decal, not usable here).
							IconAssetId = "rbxassetid://102020098775440",
						}),
						VitalIcon.new(scope, {
							LayoutOrder = 2,
							Glyph = "Spark",
							Caption = "Qi",
							Value = clientState.Qi,
							Max = clientState.MaxQi,
							FillColor = Tokens.VitalColor.Qi,
							CriticalBelow = 0.2,
							-- No System owns Qi yet (see this file's header) -- Value/MaxQi are
							-- permanent placeholders, never real data. Muted renders the doc's
							-- "not live yet" treatment instead of a full-looking gauge.
							Muted = true,
							-- Uploaded from docs/design/icons/qi.svg's PNG export -- Texture id
							-- (rbxassetid://125861176852006 is the wrapping Decal, not usable here).
							IconAssetId = "rbxassetid://139165261554498",
						}),
						VitalIcon.new(scope, {
							LayoutOrder = 3,
							Glyph = "Diamond",
							Caption = "Posture",
							Value = clientState.Posture,
							Max = clientState.MaxPosture,
							FillColor = Tokens.VitalColor.Posture,
							CriticalBelow = 0.15,
							-- Uploaded from docs/design/icons/posture.svg's PNG export -- Texture id
							-- (rbxassetid://71612968745315 is the wrapping Decal, not usable here).
							IconAssetId = "rbxassetid://137723815865371",
						}),
					}),
					Divider(scope, 2),
					Row(scope, 3, Tokens.Space.XS, abilitySlots),
				}),
			},
		}) :: Frame,
	} :: ScreenGui
end

return HUD
