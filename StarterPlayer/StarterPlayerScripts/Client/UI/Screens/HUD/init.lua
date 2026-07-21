--!strict
--[[
	HUD.lua

	Owns: the always-visible combat HUD surface -- the central hotbar (docs/ui-ux-philosophy.md's
	"Player Status Display" and "Ability System UI" sections): Health/Qi/Posture as
	icon-tile gauges (VitalIcon.lua) stacked over a row of ability slots (AbilitySlot.lua), with a
	CombatStateBadge unfolding above them the moment CombatState.inCombatUntil goes live (see that
	component's own header) -- the first real consumer of that server signal. Renders directly from
	ClientState -- never computes or guesses at a value ClientState doesn't already hold, per that
	doc's HUD sync rule against optimistic HUD state.

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

			Children = {
				scope:New "UIPadding" {
					PaddingLeft = UDim.new(0, Tokens.Space.S),
					PaddingRight = UDim.new(0, Tokens.Space.S),
					PaddingTop = UDim.new(0, Tokens.Space.XS),
					PaddingBottom = UDim.new(0, Tokens.Space.XS),
				},
				scope:New "UIListLayout" {
					FillDirection = Enum.FillDirection.Vertical,
					HorizontalAlignment = Enum.HorizontalAlignment.Center,
					Padding = UDim.new(0, Tokens.Space.XS),
					SortOrder = Enum.SortOrder.LayoutOrder,
				},
				CombatStateBadge(scope, {
					LayoutOrder = 0,
					InCombat = clientState.InCombat,
				}),
				Row(scope, 1, Tokens.Space.S, {
					VitalIcon.new(scope, {
						LayoutOrder = 1,
						Glyph = "Cross",
						Caption = "Health",
						Value = clientState.Health,
						Max = clientState.MaxHealth,
						FillColor = Tokens.Color.Health,
						CriticalBelow = 0.25,
					}),
					VitalIcon.new(scope, {
						LayoutOrder = 2,
						Glyph = "Spark",
						Caption = "Qi",
						Value = clientState.Qi,
						Max = clientState.MaxQi,
						FillColor = Tokens.Color.Qi,
						CriticalBelow = 0.2,
						-- No System owns Qi yet (see this file's header) -- Value/MaxQi are
						-- permanent placeholders, never real data. Muted renders the doc's
						-- "not live yet" treatment instead of a full-looking gauge.
						Muted = true,
					}),
					VitalIcon.new(scope, {
						LayoutOrder = 3,
						Glyph = "Diamond",
						Caption = "Posture",
						Value = clientState.Posture,
						Max = clientState.MaxPosture,
						FillColor = Tokens.Color.Posture,
						CriticalBelow = 0.15,
					}),
				}),
				Row(scope, 2, Tokens.Space.XS, abilitySlots),
			},
		}) :: Frame,
	} :: ScreenGui
end

return HUD
