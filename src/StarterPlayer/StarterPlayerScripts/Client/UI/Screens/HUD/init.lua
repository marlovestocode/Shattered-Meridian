--!strict
--[[
	HUD/init.lua

	Owns: the always-visible HUD surface -- the central hotbar dock (docs/ui-ux-philosophy.md's
	"Player Status Display" and "Ability System UI" sections), assembled as five bands stacked
	bottom-centre:

	              engagement line      HUD/EngagementLine.lua -- combat state, off ClientState.InCombat
	              bounty pill          Components/BountyMarkedBadge.lua -- zero height when unmarked
	  +-----------o------------------------------------------------------+
	  | armament  | TierBadge  |  [ Health  Qi  Posture ]  |  [ 1 .. 5 ]  |   the dock
	  +-----------o------------------------------------------------------+
	              key legend           Components/KeyLegend.lua -- M / K / B, live from KeybindManager

	The armament island (HUD/ArmamentIsland.lua) is not a sixth band and not a neighbour -- it is
	BOLTED to the dock's left edge, sharing that edge as its own: one rule at the seam, one height,
	one content baseline, and a bronze bead through the joint. It springs out of the dock on the first
	weapon pickup and is absent before then. Screens/WeaponInventory hands in the state it renders;
	the geometry of the joint belongs here, next to the dock chrome it has to match. See that file's
	header for the seam, and the dock band in Mount below for the fastener and why the island is
	pinned rather than laid out.

	Renders directly from ClientState -- never computes or guesses at a value ClientState doesn't
	already hold, per that doc's HUD sync rule against optimistic HUD state.

	2026-08-25 REBUILD, against a reference hotbar design. What actually changed, beyond the skin:

	* THREE MODULES, NOT FIVE PEERS. The old bar was one flat run -- tier, hairline, vitals, hairline,
	  slots -- where the separators were the only thing suggesting the parts belonged to different
	  systems, and they had to be recoloured to TextSecondary just to be seen at all. The vitals and
	  the ability slots now sit in their own RECESSED GROUP BOXES (moduleGroup below), which is what
	  the reference design uses instead of louder lines, and the separators go back to being genuine
	  hairlines -- a gradient rule that fades out at both ends (Components/Divider.lua's Gradient with
	  the new Vertical orientation) rather than a solid bar of colour. Structure now comes from the
	  containers, so the seams don't have to shout.

	* THE TIER MODULE LEADS, AND IS BRONZE. Unchanged in position -- it is the slowest-changing, most
	  identity-like thing here, so it reads as the label the rest of the dock belongs to rather than
	  competing for the glance during a fight -- but it is now a numeral PLATE beside its own name and
	  meter, in Tokens.Color.AccentSecondary. See TierBadge.lua's header on why the hue split
	  (committed/permanent vs. interactive/live) is what lets a mid-fight glance tell the tier module
	  from the vitals before reading either.

	* THE DOCK KEEPS ITS CHAMFER *AND* GETS CORNER BRACKETS. Those were mutually exclusive until this
	  pass -- a bracket anchored at a rectangular corner floats over a chamfered panel's cut void --
	  and the fix was to move the bracket, not drop it: Panel.lua's new BracketInset, set to
	  ChamferedSurface.CHAMFER_PX, lands each elbow exactly where the cut ends, so the bronze arms
	  brace the chamfer instead of ignoring it. See Panel.lua's and CornerBracket.lua's headers.

	* THE KEY LEGEND IS REAL, NOT PRINTED. The reference design's sub-dock strip names three keys; all
	  three are live Types.KeybindActions here, read through Client/Input/KeybindManager.lua and
	  re-read on its new OnChanged, so rebinding Settings from K re-letters the cap instead of leaving
	  the HUD quietly lying about it. The HOTBAR's own 1-5 are NOT read that way and deliberately so:
	  Constants.Keybinds excludes HotbarSlot* from the rebind UI (Server/Systems/SettingsSystem.lua
	  enforces the same exclusion), and KeyCode.Name for those spells "One".."Five" -- the digit in a
	  tile corner is the honest label and a literal is the honest way to write it.

	Slot state is three-way: Locked when nothing is bound, Cooldown while the server's own
	CooldownSeconds for that slot is still running (AttackInputClient mirrors it back through
	OnSlotCooldown), and Available otherwise. The cooldown is the server's number echoed, not a
	locally-run timer of this screen's own -- the same "render what you were told" rule the rest of
	this file keeps. "Active" stays unused: it would mean a sustained, currently-channelling ability,
	and nothing in the rebuilt combat stack has one.

	Every ability slot still reflects Client/Combat/HotbarBindings.lua's slot->MoveId binding and
	activates through Client/Combat/AttackInputClient.PressHotbarSlot -- the same function the number
	keys go through, so "the button does the same thing as its keybind" is one code path rather than
	two that can drift.

	The ability row is a real, styled mount point, not a placeholder comment -- but a slot with nothing
	bound still renders in the doc's "Locked" appearance, because ArtSystem is still an empty Init()
	and there is no real per-slot ability data to show yet.

	Mount() returns the dock's root FRAME, not a ScreenGui and not a *Handle table. It is always-on
	with no open/closed state to expose, which is one of the two documented Mount() return shapes (see
	docs/ui-ux-philosophy.md's Framework section, "Mount() return-value contract") -- but as of Phase 2
	the dock is a region tile rather than a surface, so what comes back is the tile UI/init.lua hands
	to Regions:Add("BottomCentre", 10, ...). See the Mount() comment below for the three things this
	file stopped owning.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Constants = require(ReplicatedStorage.Shared.Constants)
local Types = require(ReplicatedStorage.Shared.Types)

local Tokens = require(script.Parent.Parent.Tokens)
local ChamferedSurface = require(script.Parent.Parent.ChamferedSurface)
local Panel = require(script.Parent.Parent.Components.Panel)
local Divider = require(script.Parent.Parent.Components.Divider)
local Inset = require(script.Parent.Parent.Components.Inset)
local Stack = require(script.Parent.Parent.Components.Stack)
local ModuleWell = require(script.Parent.Parent.Components.ModuleWell)
local VitalIcon = require(script.Parent.Parent.Components.VitalIcon)
local AbilitySlot = require(script.Parent.Parent.Components.AbilitySlot)
local TierBadge = require(script.Parent.Parent.Components.TierBadge)
local KeyLegend = require(script.Parent.Parent.Components.KeyLegend)
local BountyMarkedBadge = require(script.Parent.Parent.Components.BountyMarkedBadge)
local ClientStateModule = require(script.Parent.Parent.State.ClientState)
local EngagementLine = require(script.EngagementLine)
local ArmamentIsland = require(script.ArmamentIsland)
local KeybindManager = require(script.Parent.Parent.Parent.Input.KeybindManager)
local HotbarBindings = require(script.Parent.Parent.Parent.Combat.HotbarBindings)
local AttackInputClient = require(script.Parent.Parent.Parent.Combat.AttackInputClient)

local Children = Fusion.Children

type Scope = Fusion.Scope<typeof(Fusion)>
type ClientState = ClientStateModule.ClientState
type AbilitySlotState = AbilitySlot.AbilitySlotState

local HUD = {}

-- Keybinds are a local input affordance, not gameplay state -- see AbilitySlot.lua's header for why
-- showing these numbers isn't the kind of data fabrication this file otherwise avoids. Literals
-- rather than KeybindManager lookups: see this file's header on why, for these five specifically.
local ABILITY_KEYBINDS = { "1", "2", "3", "4", "5" }

-- The sub-dock legend. Three real Types.KeybindActions, spelled live -- see this file's header.
local LEGEND_ACTIONS: { { Action: Types.KeybindAction, Text: string } } = {
	{ Action = "CharacterMenuToggle", Text = "Character" },
	{ Action = "SettingsToggle", Text = "Settings" },
	{ Action = "EmoteWheel", Text = "Emote" },
}

-- How long TierBadge's promotion flare is held at full before easing back to rest. Longer than
-- CombatFeedback's parry glint (0.18s) by an order of magnitude, and deliberately so: that cue
-- acknowledges an input the player just made and must not outlive the exchange, while this one
-- announces a permanent progression milestone that may have arrived seconds after the kill that
-- earned it. It still self-clears rather than latching -- a tier-up is a moment, not a mode.
local TIER_PROMOTION_HOLD_SECONDS = 2.5

-- The seam between two modules. 60% of the dock's own content height, which is the tier plate's --
-- a full-height rule reads as a wall between two panels rather than as a seam within one.
local SEPARATOR_HEIGHT = 40

-- The bead that fastens the armament island to this dock -- see the dock band in Mount below. Seven,
-- which is the rack strip's own selected-bead size: the fastener and the thing it fastens are the
-- same mark at the same weight, so the joint reads as part of the island's vocabulary rather than as
-- a decoration someone added to the seam.
local SEAM_BOLT_SIZE = 7

-- The countdown label is quantised to tenths (see the Heartbeat below). Ten updates a second is
-- already faster than the eye resolves a changing digit, and it is a sixth of the string formatting.
local COUNTDOWN_STEPS_PER_SECOND = 10

-- A recessed well holding one module's tiles. The reference design's `bg-black/30 rounded-md
-- border-white/5` group box, and the reason this dock's separators can go back to being hairlines
-- (see this file's header): the container carries the grouping, so the line between two containers
-- doesn't have to.
--
-- The UICorner/UIStroke/UIPadding here are safe among a Stack's Children precisely because none of
-- them is a GuiObject -- a UIListLayout arranges GuiObject children only, which is the distinction
-- Components/Layer.lua's header is about.
-- A RECESSED GROUP BOX around one cluster of dock readouts. The chrome moved to
-- Components/ModuleWell.lua on 2026-08-25, at its third call site (Screens/BlimpFuel), which is
-- CLAUDE.md's own bar for promoting a shared module -- Screens/BlimpHelm's copy of it had already
-- named this file as the first of the three and pre-registered the trigger. Nothing about the dock's
-- own group changed: same fill, same hairline, same M/S inset, passed explicitly here because the
-- shared default is the tighter inset the two corner instruments want.
--
-- The reasoning this file reached first, and which the shared component now carries: the container
-- carries the grouping, so the line between two containers does not have to. That is why the dock's
-- Divider.Plain rules went away when these arrived, and why a rule inside a well would be the same
-- statement twice.
local function moduleGroup(scope: Scope, name: string, layoutOrder: number, gap: number, children: { Instance }): Frame
	return ModuleWell(scope, {
		Name = name,
		Direction = "Horizontal",
		LayoutOrder = layoutOrder,
		Gap = gap,
		AlignY = Enum.VerticalAlignment.Center,
		Inset = { X = Tokens.Space.M, Y = Tokens.Space.S },
		Children = children,
	})
end

local function separator(scope: Scope, layoutOrder: number): Frame
	return Divider.Gradient(scope, {
		Orientation = "Vertical",
		-- Fades to nothing at both ends: this rule belongs to the gap between two modules rather than
		-- growing out of either, so neither end should terminate hard.
		Fade = "Both",
		Tint = Tokens.Border.Standard,
		LayoutOrder = layoutOrder,
		Size = UDim2.fromOffset(Tokens.Control.DividerThickness, SEPARATOR_HEIGHT),
	})
end

-- The three states a live hotbar slot can be in, from the two independent facts the client already
-- holds: whether a Move-Editor-authored move is bound to it (Client/Combat/HotbarBindings.lua), and
-- whether the server's own cooldown for it is still running (mirrored back through
-- AttackInputClient.OnSlotCooldown).
local function stateForSlot(moveId: string?, cooldownSeconds: number): AbilitySlotState
	if not moveId then
		return "Locked"
	end
	return if cooldownSeconds > 0 then "Cooldown" else "Available"
end

-- Returns the dock's band stack as a TILE, not a surface. It has no ScreenGui of its own as of
-- Phase 2 of docs/architecture/2026-08-25-hud-shell-plan.md -- UI/init.lua hands what comes back to
-- Shell/Regions.lua's BottomCentre, which is the region that has been reserved for it since Phase 1.
-- Three things this screen used to own went with it, and all three were the same fact written three
-- times: where the bottom of the screen is.
--
--   * ITS OWN ScreenGui, with IgnoreGuiInset = true -- one of only three surfaces in the client that
--     set that, which is exactly the inconsistency plan 2.3 is about. The region host is full-bleed
--     for everything now.
--   * ITS OWN ViewportScale.Compute, which is a ViewportSize connection. There is one for the whole
--     client now, made on the root scope and passed to the region host; the dock reads it through
--     the host's UIScale like every other tile.
--   * ITS OWN BOTTOM MARGIN, hand-multiplied by that scale in a Computed, with a comment explaining
--     that a UIScale does not affect Position. That was true of the UIScale this file had, which sat
--     on the band stack itself; it is not true of the one on the host ScreenGui above it, which
--     scales its descendants' position offsets as well as their sizes. So BottomCentre's ordinary
--     Tokens.Space.L edge inset is the margin now, it scales, and no one has to remember why.
-- THE ARMAMENT ISLAND IS BOLTED TO THIS DOCK, so this file owns the joint -- see
-- HUD/ArmamentIsland.lua, which is a sibling of HUD/EngagementLine.lua for exactly that reason. What
-- comes in is the STATE (Screens/WeaponInventory's Fusion Values, which is what a weapon is; the
-- dock has no business knowing that), and what this file builds is the plate, the seam and the
-- fastener, twenty lines from the dock's own chrome props rather than in another folder restating
-- them from memory.
--
-- Optional: passing nothing gives the bare dock, byte-identical to what it was before the island
-- existed, which is what Tests/UI/Hotbar.spec.lua's existing cases mount.
function HUD.Mount(scope: Scope, clientState: ClientState, armament: ArmamentIsland.ArmamentState?): Frame
	local abilitySlots = {}
	-- One reactive State Value per slot, seeded from whatever's already bound this session (an admin
	-- who bound a move, then closed and reopened the Move Editor, shouldn't see every slot flash back
	-- to Locked) and kept live by the two subscriptions below -- the same "screen owns a Fusion Value,
	-- an outside module writes into it" shape ClientState.Bootstrap already uses for server-reflected
	-- state, applied here to two client-local sources instead.
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
	-- The countdown's last PUBLISHED tenth, per slot -- the whole point of the quantisation below.
	local publishedTenths: { [number]: number } = {}

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
			-- Routed through the same function the number keys reach, so the button and the keybind
			-- cannot drift apart; that function owns the binding lookup, the local cooldown check and
			-- the request payload, and this screen owns none of them.
			OnActivated = function()
				AttackInputClient.PressHotbarSlot(index)
			end,
		})
	end

	-- Never unsubscribed -- HUD is mounted once for the life of the client session (see this file's
	-- own header on Mount()'s return shape), the same "connect once, never disconnect" lifetime every
	-- other HUD-wide listener here already has (ClientState.Bootstrap's own remote handlers).
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
			publishedTenths[slot] = 0
			cooldownSeconds[slot]:set(0)
			cooldownFractions[slot]:set(0)
		else
			cooldownTotals[slot] = seconds
			cooldownEndsAt[slot] = os.clock() + seconds
			publishedTenths[slot] = math.ceil(seconds * COUNTDOWN_STEPS_PER_SECOND)
			cooldownSeconds[slot]:set(seconds)
			cooldownFractions[slot]:set(1)
		end
		refreshSlotState(slot)
	end)

	-- A Heartbeat inside a Screen is off-pattern for this codebase and is kept deliberately narrow: it
	-- exists only because AbilitySlot's cooldown sweep is, by its nature, a value that has to change
	-- every frame, and pushing it from the network sixty times a second would be far worse. It
	-- early-outs on an empty table, so it costs nothing at all except while a slot is genuinely
	-- cooling.
	--
	-- The SWEEP moves every frame because it is a continuous position the eye tracks. The COUNTDOWN
	-- does not: it is quantised to tenths and only written when the displayed tenth actually changes.
	-- That matters because its label formats a string on every write (AbilitySlot's `%.1fs`), so an
	-- unquantised version allocated a fresh string per slot per frame for the whole cooldown -- garbage
	-- generated at exactly the moment the client can least afford it, to redraw digits that were
	-- already identical five frames in six.
	RunService.Heartbeat:Connect(function()
		if next(cooldownEndsAt) == nil then
			return
		end
		local now = os.clock()
		for slot, endsAt in cooldownEndsAt do
			local remaining = endsAt - now
			if remaining <= 0 then
				-- Left for AttackInputClient's own expiry callback to clear the TABLES: it is the owner
				-- of that edge, and clearing here as well would race it into a double refresh. Zeroing
				-- the rendered values is enough to stop showing a negative countdown in the meantime.
				cooldownFractions[slot]:set(0)
				if publishedTenths[slot] ~= 0 then
					publishedTenths[slot] = 0
					cooldownSeconds[slot]:set(0)
				end
			else
				cooldownFractions[slot]:set(remaining / math.max(cooldownTotals[slot] or remaining, 1e-4))
				local tenths = math.ceil(remaining * COUNTDOWN_STEPS_PER_SECOND)
				if publishedTenths[slot] ~= tenths then
					publishedTenths[slot] = tenths
					cooldownSeconds[slot]:set(tenths / COUNTDOWN_STEPS_PER_SECOND)
				end
			end
		end
	end)

	-- The legend's caps, spelled from whatever each action is bound to right now and re-spelled on
	-- every rebind. One Value per entry rather than one table Value, so a rebind of one action can
	-- never invalidate the other two labels' Computeds.
	local legendKeys: { Fusion.Value<string> } = {}
	local legendEntries: { KeyLegend.KeyLegendEntry } = {}
	for index, entry in ipairs(LEGEND_ACTIONS) do
		local key = scope:Value(KeybindManager.Describe(KeybindManager.Get(entry.Action)))
		legendKeys[index] = key
		legendEntries[index] = { Key = key, Text = entry.Text }
	end
	-- Same connect-once-never-disconnect lifetime as the two subscriptions above.
	KeybindManager.OnChanged(function()
		for index, entry in ipairs(LEGEND_ACTIONS) do
			legendKeys[index]:set(KeybindManager.Describe(KeybindManager.Get(entry.Action)))
		end
	end)

	-- The one-shot drive behind TierBadge's promotion flare. The component eases a 0..1 intensity and
	-- owns no timer of its own (TierBadge.lua's header, same split ParryReadyGlint/CombatFeedback
	-- already use), so the pulse lives here -- next to ClientState, which is the only thing that knows
	-- a promotion actually happened rather than a tier merely being synced on login.
	--
	-- Generation-guarded exactly like CombatFeedback's parry glint: two promotions in quick succession
	-- (a single large XP grant crossing two thresholds fires once, but a kill streak can genuinely
	-- promote twice inside the hold window) each schedule their own reset, and only the most recent is
	-- allowed to zero the flare, so the earlier one can't cut the fresher one short.
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

	local dock = Panel(scope, {
		Name = "HotbarDock",
		LayoutOrder = 3,
		AutomaticSize = Enum.AutomaticSize.XY,
		Elevated = false,
		Chamfered = true,
		-- Both treatments at once, which BracketInset is what makes legal -- see this file's header
		-- and Panel.lua's. Bronze and un-rivetted: the reference design's frame accents are plain
		-- L-arms, and bronze is what keeps them reading as the dock's own forged frame rather than as
		-- four more interactive violet elements competing with the slots inside.
		CornerAccent = true,
		CornerAccentColor = Tokens.Color.AccentSecondary,
		CornerAccentRivets = false,
		BracketArmLength = 10,
		BracketInset = ChamferedSurface.CHAMFER_PX,
		-- NO SurfaceTexture, for two independent reasons and either alone would settle it. Register:
		-- docs/ui-ux-philosophy.md's Shape Language puts the tiled surface grain on MENU surfaces and
		-- the cut-corner silhouette on COMBAT surfaces, and says using one register's treatment on the
		-- other's surface "is the wrong register -- not a stylistic choice either way." This dock is a
		-- combat surface; the chamfer is its texture. Mechanics: Components/MeridianField.lua cannot
		-- be mounted in an AutomaticSize container at all -- it is Scale-sized all the way down, and
		-- an auto-sized parent latches onto that and inflates. Setting it here is what rendered this
		-- dock at full screen height on first run; see Panel.lua's SurfaceTexture prop for the
		-- measured rule.
		-- AccentPrimary matches nothing else on the frame by accident: it is the same violet the vital
		-- tiles and ability slots carry, so the dock's outer edge reads as the same forged material
		-- they are cut from. Softened a step below full opacity -- fully opaque reads as harsh against
		-- the bronze brackets' own brightness.
		BorderColor3 = Tokens.Color.AccentPrimary,
		BorderTransparency = 0.3,

		Children = {
			Inset(scope, { X = Tokens.Space.XL, Y = Tokens.Space.M }),
			Stack.Row(scope, {
				Name = "Modules",
				Size = UDim2.fromOffset(0, 0),
				AutomaticSize = Enum.AutomaticSize.XY,
				Gap = Tokens.Space.L,
				AlignY = Enum.VerticalAlignment.Center,

				Children = {
					TierBadge(scope, {
						LayoutOrder = 1,
						Tier = clientState.Tier,
						TierName = clientState.TierName,
						TierFloorXP = clientState.TierFloorXP,
						TierNextXP = clientState.TierNextXP,
						MeridianXP = clientState.MeridianXP,
						PromotionPulse = promotionPulse,
					}),
					separator(scope, 2),
					moduleGroup(scope, "Vitals", 3, Tokens.Space.M, {
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
							-- Client/Loading/AssetPreloader.lua can sweep them at BOOT. HUD.Mount does
							-- not run until UI.Mount(), which is AFTER the preload gate, so a literal
							-- here is unreachable at preload time by construction.
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
							-- QiSystem.lua owns this resource (Server/Systems/QiSystem.lua,
							-- Progression_QiUpdated -> ClientState.Qi/MaxQi), so it is live, not Muted.
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
					separator(scope, 4),
					moduleGroup(scope, "Abilities", 5, Tokens.Space.M, abilitySlots),
				},
			}),
		},
	})

	-- THE DOCK BAND, AND WHY IT IS A BARE FRAME RATHER THAN A Stack OR A Layer.
	--
	-- It holds the dock plus, when there is one, the island and the bead that fastens them. The dock
	-- is the only child at the origin, so this frame's AutomaticSize resolves to exactly the dock's
	-- size -- which is what gives the island something dock-shaped to pin against, and what keeps the
	-- three OTHER bands (engagement line, bounty pill, key legend) centred on the dock rather than on
	-- the dock-plus-island.
	--
	-- NO UIListLayout, hence no Stack: the island must NOT be laid out. Measured in this repo's own
	-- harness before it was written -- an offset-sized child pinned to negative X neither inflates an
	-- AutomaticSize parent nor displaces its siblings (host stayed 300x98 with the pinned child at
	-- AbsolutePosition.X = -120), while the same child given a Scale HEIGHT inside an AutomaticSize.Y
	-- parent latched onto the viewport and came back 793 tall. Both facts are load-bearing: the first
	-- is why the dock cannot move, and the second is why ArmamentIsland's slot and plate are
	-- offset-sized on both axes.
	--
	-- That is a strictly stronger guarantee than the mirror spacer this replaced. Reserving the
	-- island's width in a centred row and cancelling it with an invisible frame of the same width on
	-- the far side DOES keep the dock still -- but only for as long as the two agree to the pixel, in
	-- the pre-UIScale coordinate space, on every frame of an under-damped spring. Pinning removes the
	-- arithmetic rather than getting it right, and takes the island's Width out of the contract with
	-- it.
	--
	-- Layer.lua is the right tool for pinning something into a frame that HAS a layout; there is none
	-- here, so its two wrapper frames would buy nothing and its Scale-sized holders are precisely the
	-- shape the measurement above rules out.
	local dockBand: Frame = dock
	if armament then
		local island = ArmamentIsland(scope, armament)

		-- THE FASTENER. One bronze bead straddling the seam -- half on the dock, half on the island --
		-- at the one point on that edge the dock's own bracket elbows leave clear. It is what turns a
		-- flush butt joint into a VISIBLE one: the island already borrows the dock's edge rather than
		-- drawing its own (ArmamentIsland's header, seam point 2), and a shared rule with nothing on
		-- it reads as one plate with a score line rather than as two plates fastened together. A
		-- point, deliberately, not a rule down the seam: a point joins, a line divides.
		--
		-- Bronze because this palette's bronze is "committed / permanent" and a bolt is exactly that,
		-- and the same 45-degree bead the rack strip and Divider.Flourish use, so it introduces no new
		-- mark. ZIndex 6 clears everything Panel.lua builds (its accent overlay is the highest at 5) --
		-- necessary because the host ScreenGui is ZIndexBehavior.Sibling, where a descendant's own
		-- ZIndex is global rather than scoped to its parent.
		--
		-- Rides the island's OWN spring rather than a second one: it must not be sitting on the dock's
		-- edge with nothing attached to it, and two springs off one boolean are one retune away from
		-- disagreeing about how far out the island is.
		local seamBolt = scope:New "Frame" {
			Name = "SeamBolt",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0, 0.5),
			Size = UDim2.fromOffset(SEAM_BOLT_SIZE, SEAM_BOLT_SIZE),
			Rotation = 45,
			BackgroundColor3 = Tokens.Color.AccentSecondary,
			BackgroundTransparency = scope:Computed(function(use)
				return 1 - math.clamp(use(island.Presence), 0, 1)
			end),
			BorderSizePixel = 0,
			ZIndex = 6,
		}

		dockBand = scope:New "Frame" {
			Name = "DockBand",
			LayoutOrder = 3,
			Size = UDim2.fromOffset(0, 0),
			AutomaticSize = Enum.AutomaticSize.XY,
			BackgroundTransparency = 1,
			BorderSizePixel = 0,

			[Children] = {
				dock,
				island.Content,
				seamBolt,
			},
		} :: Frame
	end

	-- NO AnchorPoint AND NO Position, which is the region tile contract (Shell/Regions.lua, contract 1)
	-- and not a style preference: BottomCentre's UIListLayout overwrites a child's Position on every
	-- layout pass, so a tile that set one would have it silently discarded. The bottom margin that
	-- used to live on this Position is BottomCentre's edge inset now.
	return Stack.New(scope, {
		Name = "Hotbar",
		Size = UDim2.fromOffset(0, 0),
		AutomaticSize = Enum.AutomaticSize.XY,
		AlignX = Enum.HorizontalAlignment.Center,
		-- ZERO, and every band owns the gap BENEATH itself instead. A UIListLayout's Padding applies
		-- between items regardless of either item's actual size, and BountyMarkedBadge collapses to
		-- a true zero height when the player is unmarked -- so any nonzero value here would leave a
		-- permanent sliver of dead space above the dock whether or not the badge was showing. That
		-- is why the badge already bakes its own GAP_TO_NEXT into its animated height, and why
		-- EngagementLine now does the same.
		Gap = 0,

		Children = {
			EngagementLine(scope, {
				LayoutOrder = 1,
				InCombat = clientState.InCombat,
			}),
			BountyMarkedBadge(scope, {
				LayoutOrder = 2,
				Marked = clientState.BountyMarked,
				Reward = clientState.BountyReward,
			}),
			dockBand,
			-- The legend's own clearance from the dock, as padding on a holder rather than baked
			-- into KeyLegend: that component is generic (Components/, not Screens/HUD/) and has no
			-- business knowing what it happens to sit under here.
			scope:New("Frame")({
				Name = "LegendBand",
				LayoutOrder = 4,
				Size = UDim2.fromOffset(0, 0),
				AutomaticSize = Enum.AutomaticSize.XY,
				BackgroundTransparency = 1,
				BorderSizePixel = 0,

				[Children] = {
					Inset(scope, { Top = Tokens.Space.M }),
					KeyLegend(scope, { Entries = legendEntries }),
				},
			}),
		},
	}) :: Frame
end

return HUD
