--!strict
--[[
	HUD.lua

	Owns: the always-visible HUD surface -- the central hotbar (docs/ui-ux-philosophy.md's "Player
	Status Display" and "Ability System UI" sections): a single horizontal bar -- the tier readout
	(TierBadge.lua) | a thin divider | Health/Qi/Posture as icon-tile gauges (VitalIcon.lua) | a thin
	divider | a row of ability slots (AbilitySlot.lua). Renders directly from ClientState -- never
	computes or guesses at a value ClientState doesn't already hold, per that doc's HUD sync rule
	against optimistic HUD state.

	One row, not two: an earlier version stacked the vitals row over the ability row inside the same
	Panel. The Figma Make hotbar reference this was rebuilt against calls for a single unified bar --
	"no more stacked rows or connector lines" -- so the two groups now sit side by side, separated by
	one hairline Divider frame.

	Combat system rebuilt: CombatStateBadge (an "in combat" pill) stays gone -- the rebuilt stack has
	no notion of "in combat" to feed it. Everything else on this bar is live again. Health and Posture
	update from their new sources (the local Humanoid, and Defense_StateChanged's guard pool -- see
	ClientState.lua's own header for why neither goes through a vitals remote anymore), Qi (QiSystem.
	lua, Progression_QiUpdated) is untouched, and the five ability slots are clickable again: each one
	still reflects Client/Combat/HotbarBindings.lua's admin-local slot->MoveId binding, and activating
	one now routes through Client/Combat/AttackInputClient.PressHotbarSlot -- the same function the
	number keys go through, so "the button does the same thing as its keybind" is one code path rather
	than two that can drift.

	Slot state is three-way now rather than two: Locked when nothing is bound, Cooldown while the
	server's own CooldownSeconds for that slot is still running (AttackInputClient mirrors it back
	through OnSlotCooldown), and Available otherwise. The cooldown is the server's number echoed, not
	a locally-run timer of this screen's own -- the same "render what you were told" rule the rest of
	this file keeps.

	The ability row is a real, styled mount point, not a placeholder comment -- but every slot still
	renders in the doc's "Locked" appearance by default: ArtSystem is still an empty Init(), so
	there's no real per-slot ability data to show yet.

	The Player Status Display's "Level" entry is the TierBadge at the head of the bar: TierSystem.lua
	owns the ladder and replicates tier identity plus its XP window, MeridianSystem replicates the
	running XP total, and the badge fills a meter from the two (see TierBadge.lua and
	Types.TierUpdatePayload for why that arithmetic is presentation rather than a breach of the
	server-owns-truth rule). Same "waits on the owning System" reasoning still applies to the rest of
	that list -- character information and active effects -- and to notifications/menus, which still
	wait on RewardSystem/ProgressionSystem/FactionManager; see docs/ui-ux-philosophy.md's "Current
	build status" for what remains and why.

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
local RunService = game:GetService("RunService")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Constants = require(ReplicatedStorage.Shared.Constants)

local Tokens = require(script.Parent.Parent.Tokens)
local Panel = require(script.Parent.Parent.Components.Panel)
local VitalIcon = require(script.Parent.Parent.Components.VitalIcon)
local AbilitySlot = require(script.Parent.Parent.Components.AbilitySlot)
local TierBadge = require(script.Parent.Parent.Components.TierBadge)
local BountyMarkedBadge = require(script.Parent.Parent.Components.BountyMarkedBadge)
local ClientStateModule = require(script.Parent.Parent.State.ClientState)
local HotbarBindings = require(script.Parent.Parent.Parent.Combat.HotbarBindings)
local AttackInputClient = require(script.Parent.Parent.Parent.Combat.AttackInputClient)

local Children = Fusion.Children

type Scope = Fusion.Scope<typeof(Fusion)>
type ClientState = ClientStateModule.ClientState
type AbilitySlotState = AbilitySlot.AbilitySlotState

local HUD = {}

-- Keybinds are a local input affordance, not gameplay state -- see AbilitySlot.lua's header for
-- why showing these numbers isn't the kind of data fabrication this file otherwise avoids.
local ABILITY_KEYBINDS = { "1", "2", "3", "4", "5" }

-- How long TierBadge's promotion flare is held at full before easing back to rest. Longer than
-- CombatFeedback's parry glint (0.18s) by an order of magnitude, and deliberately so: that cue
-- acknowledges an input the player just made and must not outlive the exchange, while this one
-- announces a permanent progression milestone that may have arrived seconds after the kill that
-- earned it. It still self-clears rather than latching -- a tier-up is a moment, not a mode.
local TIER_PROMOTION_HOLD_SECONDS = 2.5

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

-- The three states a live hotbar slot can be in, from the two independent facts the client already
-- holds: whether a Move-Editor-authored move is bound to it (Client/Combat/HotbarBindings.lua), and
-- whether the server's own cooldown for it is still running (mirrored back through
-- AttackInputClient.OnSlotCooldown). "Active" is deliberately unused -- it would mean a sustained,
-- currently-channelling ability, and nothing in the rebuilt combat stack has one.
local function stateForSlot(moveId: string?, cooldownSeconds: number): AbilitySlotState
	if not moveId then
		return "Locked"
	end
	return if cooldownSeconds > 0 then "Cooldown" else "Available"
end

function HUD.Mount(scope: Scope, playerGui: PlayerGui, clientState: ClientState): ScreenGui
	local abilitySlots = {}
	-- One reactive State Value per slot, seeded from whatever's already bound this session (an
	-- admin who bound a move, then closed and reopened the Move Editor, shouldn't see every slot
	-- flash back to Locked) and kept live by the two subscriptions below -- the same "screen owns a
	-- Fusion Value, an outside module writes into it" shape ClientState.Bootstrap already uses for
	-- server-reflected state, applied here to two client-local sources instead.
	local abilitySlotStates: { Fusion.Value<AbilitySlotState> } = {}
	-- Remaining cooldown per slot, ticked by the gated Heartbeat below. Kept as Fusion Values (rather
	-- than derived from a single clock Value) because AbilitySlot consumes them as two independent
	-- props -- the sweep overlay reads a 1..0 fraction, the countdown label reads seconds.
	local cooldownSeconds: { Fusion.Value<number> } = {}
	local cooldownFractions: { Fusion.Value<number> } = {}
	-- Plain (non-reactive) mirrors of the two facts stateForSlot needs, so recomputing a slot's state
	-- never has to peek at a Fusion Value or ask another module a question it already answered.
	local boundMoveIds: { [number]: string? } = {}
	local cooldownTotals: { [number]: number } = {}
	local cooldownEndsAt: { [number]: number } = {}

	local function refreshSlotState(slot: number): ()
		local slotState = abilitySlotStates[slot]
		if slotState then
			slotState:set(stateForSlot(boundMoveIds[slot], Fusion.peek(cooldownSeconds[slot])))
		end
	end

	for index, keybind in ipairs(ABILITY_KEYBINDS) do
		boundMoveIds[index] = HotbarBindings.Get(index)
		cooldownSeconds[index] = scope:Value(0)
		cooldownFractions[index] = scope:Value(0)

		local slotState = scope:Value(stateForSlot(boundMoveIds[index], 0))
		abilitySlotStates[index] = slotState
		abilitySlots[index] = AbilitySlot(scope, {
			LayoutOrder = index,
			Keybind = keybind,
			State = slotState,
			CooldownFraction = cooldownFractions[index],
			CooldownSeconds = cooldownSeconds[index],
			-- Clickable again -- see this file's header. Routed through the same function the number
			-- keys reach, so the button and the keybind cannot drift apart; that function owns the
			-- binding lookup, the local cooldown check and the request payload, and this screen owns
			-- none of them.
			OnActivated = function()
				AttackInputClient.PressHotbarSlot(index)
			end,
		})
	end

	-- Never unsubscribed -- HUD is mounted once for the life of the client session (see this file's
	-- own header on Mount()'s return shape), the same "connect once, never disconnect" lifetime
	-- every other HUD-wide listener here already has (ClientState.Bootstrap's own remote handlers).
	HotbarBindings.OnChanged(function(slot: number, moveId: string?)
		if boundMoveIds[slot] == nil and moveId == nil then
			return
		end
		boundMoveIds[slot] = moveId
		refreshSlotState(slot)
	end)

	-- Fires with (slot, seconds) when the server puts a slot on cooldown and (slot, 0) when it comes
	-- off -- two edges, not a per-frame push, so the ticking below is this screen's own presentation
	-- concern rather than network traffic.
	AttackInputClient.OnSlotCooldown(function(slot: number, seconds: number)
		if seconds <= 0 then
			cooldownTotals[slot] = nil
			cooldownEndsAt[slot] = nil
			cooldownSeconds[slot]:set(0)
			cooldownFractions[slot]:set(0)
		else
			cooldownTotals[slot] = seconds
			cooldownEndsAt[slot] = os.clock() + seconds
			cooldownSeconds[slot]:set(seconds)
			cooldownFractions[slot]:set(1)
		end
		refreshSlotState(slot)
	end)

	-- A Heartbeat inside a Screen is off-pattern for this codebase and is kept deliberately narrow:
	-- it exists only because AbilitySlot's cooldown sweep and countdown label are, by their nature,
	-- values that have to change every frame, and pushing them from the network sixty times a second
	-- would be far worse. It early-outs on an empty table, so it costs nothing at all except while a
	-- hotbar slot is genuinely cooling -- which, with five slots, is a handful of arithmetic on the
	-- frames it does run.
	RunService.Heartbeat:Connect(function()
		if next(cooldownEndsAt) == nil then
			return
		end
		local now = os.clock()
		for slot, endsAt in cooldownEndsAt do
			local remaining = endsAt - now
			if remaining <= 0 then
				-- Left for AttackInputClient's own expiry callback to clear: it is the owner of that
				-- edge, and clearing here as well would race it into a double refresh. Zeroing the
				-- rendered values is enough to stop showing a negative countdown in the meantime.
				cooldownSeconds[slot]:set(0)
				cooldownFractions[slot]:set(0)
			else
				cooldownSeconds[slot]:set(remaining)
				cooldownFractions[slot]:set(remaining / math.max(cooldownTotals[slot] or remaining, 1e-4))
			end
		end
	end)

	-- The one-shot drive behind TierBadge's promotion flare. The component eases a 0..1 intensity and
	-- owns no timer of its own (TierBadge.lua's header, same split ParryReadyGlint/CombatFeedback
	-- already use), so the pulse lives here -- next to ClientState, which is the only thing that knows
	-- a promotion actually happened rather than a tier merely being synced on login.
	--
	-- Generation-guarded exactly like CombatFeedback's parry glint: two promotions in quick
	-- succession (a single large XP grant crossing two thresholds fires once, but a kill streak can
	-- genuinely promote twice inside the hold window) each schedule their own reset, and only the most
	-- recent is allowed to zero the flare, so the earlier one can't cut the fresher one short.
	local promotionPulse: Fusion.Value<number> = scope:Value(0)
	local promotionGeneration = 0
	scope:Observer(clientState.TierPromotion):onChange(function()
		promotionGeneration += 1
		local generation = promotionGeneration
		promotionPulse:set(1)
		task.delay(TIER_PROMOTION_HOLD_SECONDS, function()
			if promotionGeneration == generation then
				promotionPulse:set(0)
			end
		end)
	end)

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
				-- sliver of dead space above the bar row even while the badge above it was fully
				-- collapsed (Size.Y = 0), reading as "more open space at top than bottom"
				-- (2026-07-24 in-game screenshot review). BountyMarkedBadge.lua's own GAP_TO_NEXT now
				-- bakes that same gap into its own reactive height instead, so it collapses to true
				-- zero together with the badge rather than being layout-imposed on top of it.
				scope:New "UIListLayout" {
					FillDirection = Enum.FillDirection.Vertical,
					HorizontalAlignment = Enum.HorizontalAlignment.Center,
					Padding = UDim.new(0, 0),
					SortOrder = Enum.SortOrder.LayoutOrder,
				},
				-- CombatStateBadge (an "in combat" pill fed by ClientState.InCombat) was removed
				-- alongside the rest of the combat system -- see this file's own header. Only the
				-- bounty pill remains above the bar.
				BountyMarkedBadge(scope, {
					LayoutOrder = -1,
					Marked = clientState.BountyMarked,
					Reward = clientState.BountyReward,
				}),
				-- The single unified bar (see this file's header): vitals group | Divider | ability
				-- group, one horizontal Row instead of the old two stacked rows. Gap is XS (not S)
				-- specifically around the Divider -- S on both sides read as an oversized, dead-looking
				-- gap against the actual in-game render (2026-07-23 design review); XS still gives the
				-- seam clearance on both sides without the panel reading as loosely padded, matching
				-- the reference direction's "no wasted padding... tight and compact."
				Row(scope, 1, Tokens.Space.XS, {
					-- Tier leads the bar, left of the vitals, behind its own divider -- it is the
					-- slowest-changing and most identity-like thing here (it moves a handful of
					-- times per account, not per exchange), so it reads as the label the rest of
					-- the bar belongs to rather than competing with the vitals for the glance
					-- during a fight. Same Divider treatment that already separates the vitals
					-- from the ability slots, for the same reason: these are three groups, not
					-- one undifferentiated strip.
					TierBadge(scope, {
						LayoutOrder = 1,
						Tier = clientState.Tier,
						TierName = clientState.TierName,
						TierFloorXP = clientState.TierFloorXP,
						TierNextXP = clientState.TierNextXP,
						MeridianXP = clientState.MeridianXP,
						PromotionPulse = promotionPulse,
					}),
					Divider(scope, 2),
					Row(scope, 3, Tokens.Space.S, {
						VitalIcon.new(scope, {
							LayoutOrder = 1,
							Glyph = "Cross",
							Caption = "Health",
							Value = clientState.Health,
							Max = clientState.MaxHealth,
							FillColor = Tokens.VitalColor.Health,
							CriticalBelow = 0.25,
							-- Ids live in Constants.UI.VitalIconIds -- with the provenance notes and the
							-- rejected wrapping-Decal ids -- rather than inline here, so that
							-- Client/Loading/AssetPreloader.lua can sweep them at BOOT. HUD.new does not
							-- run until UI.Mount(), which is AFTER the preload gate, so a literal here is
							-- unreachable at preload time by construction.
							IconAssetId = Constants.UI.VitalIconIds.Health,
						}),
						VitalIcon.new(scope, {
							LayoutOrder = 2,
							Glyph = "Spark",
							Caption = "Qi",
							Value = clientState.Qi,
							Max = clientState.MaxQi,
							FillColor = Tokens.VitalColor.Qi,
							CriticalBelow = 0.2,
							-- QiSystem.lua now owns this resource (Server/Systems/QiSystem.lua,
							-- Progression_QiUpdated -> ClientState.Qi/MaxQi) -- no longer Muted as of
							-- this pass. Renders live exactly like Health/Posture below.
							-- Id in Constants.UI.VitalIconIds, same preload reasoning as Health above.
							IconAssetId = Constants.UI.VitalIconIds.Qi,
						}),
						VitalIcon.new(scope, {
							LayoutOrder = 3,
							Glyph = "Diamond",
							Caption = "Posture",
							Value = clientState.Posture,
							Max = clientState.MaxPosture,
							FillColor = Tokens.VitalColor.Posture,
							CriticalBelow = 0.15,
							-- Id in Constants.UI.VitalIconIds, same preload reasoning as Health above.
							IconAssetId = Constants.UI.VitalIconIds.Posture,
						}),
					}),
					Divider(scope, 4),
					Row(scope, 5, Tokens.Space.XS, abilitySlots),
				}),
			},
		}) :: Frame,
	} :: ScreenGui
end

return HUD
