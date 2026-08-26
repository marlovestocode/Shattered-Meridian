--!strict
--[[
	HUD/EngagementDetail.lua

	Owns: the two-row readout that unfolds under HUD/EngagementLine.lua while the player is tagged --
	who they are fighting, how long the tag has left, and what the two of them have traded.

	              IN COMBAT  ------------------        EngagementLine.lua, unchanged by this file
	                Kaito                  3.2s        this band, row 1
	                DEALT 184        TAKEN 96          this band, row 2

	Renders from ClientState.Engagement, which Bootstrap() wires to EngagementSystem's
	Engagement_Changed remote (Server/Combat/Engagement/EngagementSystem.lua) -- never computed or
	guessed at here, per docs/ui-ux-philosophy.md's HUD sync rule. THE COUNTDOWN IS THE ONE THING
	THIS FILE DOES NOT OWN EITHER: it arrives as a prop, ticked by the gated Heartbeat already
	running in HUD/init.lua for the ability cooldowns. A second Heartbeat inside a Component to
	decrement one number would be exactly the duplication that file's own "a Heartbeat inside a
	Screen is off-pattern and is kept deliberately narrow" note is guarding against, and this band is
	mounted for the whole session -- so it would run forever to serve five seconds a fight.

	================================================================================================
	IT COLLAPSES TO A TRUE ZERO HEIGHT, WHICH IS A CONTRACT AND NOT A STYLE CHOICE
	================================================================================================

	This is band 2 of the hotbar's Stack, whose Gap is ZERO and where EVERY band bakes its own
	clearance beneath itself (HUD/init.lua's Stack, and BountyMarkedBadge.GAP_TO_NEXT/
	EngagementLine.GAP_TO_NEXT before it). A UIListLayout's Padding applies between items regardless
	of either item's size, so a nonzero Gap up there would leave a permanent sliver of dead space
	above the dock for a band that is absent 95% of a session. Hence GAP_TO_NEXT below, multiplied by
	the same unfold spring as the content height: out of combat this element occupies nothing at all,
	not a collapsed-but-present strip.

	THE CONTENT IS LATCHED, AND THAT IS THE ONE PIECE OF STATE HERE. The expiry payload the server
	sends carries InCombat = false AND clears OpponentName -- correctly, since there is no longer an
	opponent. But the collapse is a spring, so for the ~quarter second it takes to fold away, this
	band is still on screen with something to draw. Reading the live payload during that window would
	blank the name and zero the numbers on frame one and animate an EMPTY box out, which reads as a
	glitch rather than as a fight ending. So the last ENGAGED payload is held in a Value and the
	content renders from that, while the collapse alone reads the live one. Same instinct as
	BountyMarkedBadge's "or has just been cleared mid-collapse" fallback, resolved properly rather
	than papered over with a placeholder string.

	That latch is why Engagement is typed as a Fusion.StateObject rather than the UsedAs<T> every
	other prop in this folder takes: an Observer needs something observable, and a plain value could
	be passed to a UsedAs prop perfectly legally. Narrowing the type is what makes the requirement a
	compile-time fact instead of a runtime surprise for the next caller (the F7 Storybook included).

	NOT StatRow, THOUGH THE SHAPE IS ITS SHAPE. StatRow's caption is deliberately a plain, fixed
	string (its own header), and the left half of row 1 here is the opponent's name -- the single most
	reactive thing on the band. It also closes each row with a hairline rule, which is chrome tuned
	for a row sat ON a panel in a menu list. Nothing sits behind this band; it floats over open
	gameplay, which is the same correction EngagementLine's header records having to make when its
	first pass styled itself as though it were on a surface. Hence bare Labels carrying their own
	dark text stroke, exactly as that sibling does, and no rules at all.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Types = require(ReplicatedStorage.Shared.Types)

local Tokens = require(script.Parent.Parent.Parent.Tokens)
local Label = require(script.Parent.Parent.Parent.Components.Label)

local Children = Fusion.Children

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>

export type EngagementDetailProps = {
	-- The live payload, nil before the first engagement of the session. A StateObject rather than
	-- UsedAs -- see this file's header on the latch.
	Engagement: Fusion.StateObject<Types.EngagementPayload?>,
	-- Seconds left on the tag, decayed by HUD/init.lua's gated Heartbeat from the SecondsRemaining
	-- the server last sent (Types.EngagementPayload's header on why a duration crosses the wire and
	-- not a deadline). Quantised to tenths there, so this never formats a string it did not need to.
	SecondsRemaining: UsedAs<number>,
	LayoutOrder: number?,
}

-- Matched to EngagementLine's RULE_ENGAGED_WIDTH so the readout sits in the column its own rule
-- draws, rather than in one of its own that happens to be near it. Not imported from that module:
-- it is a private constant there, and a require between two sibling bands to share one number would
-- couple them far harder than the duplication is worth. If one moves, this comment is the pointer.
local PANEL_WIDTH = 168

local ROW_HEIGHT = 15
local ROW_GAP = 2
local CONTENT_HEIGHT = ROW_HEIGHT * 2 + ROW_GAP
-- This band's clearance from the one below it, baked into its own animated height -- see header.
local GAP_TO_NEXT = Tokens.Space.XS

-- How the left column and the right column split the width. The name gets the majority because it is
-- variable-length and the two numerals beside it are not.
local LEFT_FRACTION = 0.58

local UNFOLD_SPRING_SPEED = Tokens.Motion.FadeSpring.Speed
local UNFOLD_SPRING_DAMPING = Tokens.Motion.FadeSpring.Damping

-- The dark outline that carries these rows over whatever is behind them. Same value and same
-- reasoning as EngagementLine.STROKE_TRANSPARENCY: over open world there is no fill behind the
-- glyphs, so they have to bring their own separation.
local STROKE_TRANSPARENCY = 0.4

-- Shown in place of a name when a payload arrives tagged but nameless. Not expected -- the server
-- always stamps opponentName, falling back to the Model's own name for a non-player combatant -- so
-- this is the honest reading of a malformed payload rather than a state the game can reach.
local UNKNOWN_OPPONENT = "UNKNOWN"

-- One row: a caption-weight run on the left, a numeral on the right, both inside a fixed-height
-- frame. Positioned rather than laid out -- two children at fixed fractions need no UIListLayout,
-- and not having one is what keeps the row's own height honest.
local function row(
	scope: Scope,
	name: string,
	layoutOrder: number,
	left: UsedAs<string>,
	leftScale: Label.LabelScale,
	leftColor: UsedAs<Color3>,
	right: UsedAs<string>,
	rightColor: UsedAs<Color3>,
	transparency: UsedAs<number>
): Frame
	return scope:New("Frame")({
		Name = name,
		LayoutOrder = layoutOrder,
		Size = UDim2.new(1, 0, 0, ROW_HEIGHT),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,

		[Children] = {
			Label(scope, {
				Text = left,
				Scale = leftScale,
				Color = leftColor,
				TextTransparency = transparency,
				StrokeColor3 = Tokens.Color.Background,
				StrokeTransparency = STROKE_TRANSPARENCY,
				TextXAlignment = Enum.TextXAlignment.Left,
				Position = UDim2.fromScale(0, 0),
				Size = UDim2.fromScale(LEFT_FRACTION, 1),
			}),
			Label(scope, {
				Text = right,
				Scale = "NumeralSmall",
				Color = rightColor,
				TextTransparency = transparency,
				StrokeColor3 = Tokens.Color.Background,
				StrokeTransparency = STROKE_TRANSPARENCY,
				TextXAlignment = Enum.TextXAlignment.Right,
				Position = UDim2.fromScale(LEFT_FRACTION, 0),
				Size = UDim2.fromScale(1 - LEFT_FRACTION, 1),
			}),
		},
	}) :: Frame
end

local function EngagementDetail(scope: Scope, props: EngagementDetailProps): Frame
	-- The live fact: is there a tag right now. Drives the collapse and nothing else.
	local inCombat = scope:Computed(function(use): boolean
		local payload = use(props.Engagement)
		return payload ~= nil and payload.InCombat
	end)

	-- The held fact: the last payload that was actually engaged. Drives every glyph on the band --
	-- see this file's header on why the two are deliberately different sources.
	local held: Fusion.Value<Types.EngagementPayload?> = scope:Value(nil :: Types.EngagementPayload?)
	scope:Observer(props.Engagement):onChange(function()
		local payload = Fusion.peek(props.Engagement)
		if payload and payload.InCombat then
			held:set(payload)
		end
	end)

	local unfold = scope:Spring(
		scope:Computed(function(use): number
			return if use(inCombat) then 1 else 0
		end),
		UNFOLD_SPRING_SPEED,
		UNFOLD_SPRING_DAMPING
	)
	local contentTransparency = scope:Computed(function(use): number
		return 1 - use(unfold)
	end)

	local opponentText = scope:Computed(function(use): string
		local payload = use(held)
		local name = payload and payload.OpponentName
		return if typeof(name) == "string" and name ~= "" then name else UNKNOWN_OPPONENT
	end)

	-- Clamped at zero rather than allowed to print a negative: the server clamps its own
	-- SecondsRemaining for the same reason, and the local decay can cross zero a frame before the
	-- expiry push arrives.
	local countdownText = scope:Computed(function(use): string
		return string.format("%.1fs", math.max(use(props.SecondsRemaining), 0))
	end)

	-- Rounded for display only. The server's numbers are health damage and can be fractional; a
	-- fight readout wants whole numbers, and "DEALT 183.6" reads as a debug print.
	local dealtText = scope:Computed(function(use): string
		local payload = use(held)
		return `DEALT {math.round(if payload then payload.DamageDealt else 0)}`
	end)
	local takenText = scope:Computed(function(use): string
		local payload = use(held)
		return `TAKEN {math.round(if payload then payload.DamageTaken else 0)}`
	end)

	return scope:New("Frame")({
		-- The SLOT, not the content: this is the thing the hotbar's Stack lays out, and its height is
		-- the animated one. Named apart from the inner frame for the same reason
		-- BountyMarkedBadgeSlot is -- a spec looking for the readout should not find the shell.
		Name = "EngagementDetailSlot",
		LayoutOrder = props.LayoutOrder,
		Size = scope:Computed(function(use): UDim2
			return UDim2.fromOffset(PANEL_WIDTH, math.round((CONTENT_HEIGHT + GAP_TO_NEXT) * use(unfold)))
		end),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		-- Without this the two rows would spill out of the collapsing slot and draw over the bounty
		-- pill and the dock on the way down.
		ClipsDescendants = true,

		[Children] = scope:New("Frame")({
			Name = "EngagementDetail",
			-- Pinned to the TOP of the slot at its full content height, rather than filling the slot:
			-- the slot's height is mid-animation for most of the transition, and a child sized to it
			-- would squash the text as it went instead of wiping it. The trailing GAP_TO_NEXT is dead
			-- space this band carries for the one below it, so the content belongs above it.
			Size = UDim2.new(1, 0, 0, CONTENT_HEIGHT),
			Position = UDim2.fromScale(0, 0),
			BackgroundTransparency = 1,
			BorderSizePixel = 0,

			[Children] = {
				scope:New("UIListLayout")({
					FillDirection = Enum.FillDirection.Vertical,
					HorizontalAlignment = Enum.HorizontalAlignment.Center,
					VerticalAlignment = Enum.VerticalAlignment.Top,
					Padding = UDim.new(0, ROW_GAP),
					SortOrder = Enum.SortOrder.LayoutOrder,
				}),
				-- Who, and how much longer. The name at full text weight because it is the one piece
				-- of information here worth reading first; the countdown in the danger red, matching
				-- the IN COMBAT headline above it -- the two are one signal (the tag, and what is left
				-- of it) and colouring them differently would read as two unrelated states.
				--
				-- THE NAME STAYS NEUTRAL, and that is the whole reason the red means anything. Red here
				-- marks the STATE; the opponent and the damage figures are its DATA. Painting the band
				-- red end to end would leave nothing for the colour to distinguish, which is the failure
				-- docs/ui-ux-philosophy.md's Critical States rule is guarding against when it says
				-- colour is never the only signal.
				row(
					scope,
					"OpponentRow",
					1,
					opponentText,
					-- Sans, alone on this band: a player's name is the one string here that is prose
					-- rather than a readout, and Tokens.Type's own split is exactly that.
					"Detail",
					Tokens.Color.TextPrimary,
					countdownText,
					Tokens.Color.DangerBright,
					contentTransparency
				),
				-- What the two of them have traded THIS fight (both reset when a lapsed tag opens a
				-- new engagement -- Types.EngagementPayload's own header). Both at secondary weight:
				-- this row is the record, not the call to action, and colouring the taken half Danger
				-- would make a number that is merely large read as a warning it is not.
				row(
					scope,
					"DamageRow",
					2,
					dealtText,
					-- BOTH halves mono here, unlike the row above. These are two readings of the same
					-- quantity sat either side of one line, and a sans left against a mono right gave
					-- them two different digit widths and two different baselines for no reason.
					"NumeralSmall",
					Tokens.Color.TextSecondary,
					takenText,
					Tokens.Color.TextSecondary,
					contentTransparency
				),
			},
		}),
	}) :: Frame
end

return EngagementDetail
