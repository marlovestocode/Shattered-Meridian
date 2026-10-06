--!strict
--[[
	HUD/EngagementLine.lua

	Owns: the one-line combat-state readout above the hotbar dock -- a tracked mono caps word and a
	hairline rule under it, both driven from ClientState.InCombat.

	IT IS LIVE AS OF 2026-08-25, AND IT LIT UP WITHOUT ONE LINE CHANGING IN THIS FILE. For most of this
	module's life it said "AWAITING ENGAGEMENT" and nothing else could happen: the combat teardown had
	removed Combat_InCombatChanged's creator, so ClientState.InCombat stayed false for a whole session
	and AttributeConstants.InCombat was read by Client/Parkour but written by nobody. This rendered
	the state it was given, which was genuinely "not in a tracked engagement" -- honest rather than
	fabricated. Server/Combat/Engagement/EngagementSystem.lua is the producer that was missing; it
	publishes both that Attribute and the Engagement_Changed payload ClientState now reflects into
	InCombat. Kept as a worked example of docs/ui-ux-philosophy.md's Framework contract that a field
	may exist ahead of its owning System and be wired the moment it fires -- this is what the payoff
	looked like.

	IT IS THE HEADLINE, NOT THE WHOLE READOUT. HUD/EngagementDetail.lua is the band directly beneath
	this one and carries who the opponent is, how long the tag has left and what has been traded. The
	split is deliberate rather than incidental: this line answers a question the player asks with their
	peripheral vision ("am I in a fight?") and has to stay legible without being read, which is what
	the tracked caps run and the rule under it are for. Detail belongs to something they choose to
	look at.

	NO IDLE ANIMATION, deliberately -- this is the one place the rebuild departs from its reference
	design, which breathes the whole indicator on a permanent 2-second opacity loop. Two reasons, and
	the second is the real one:
	  * Mechanically, Roblox has no CSS keyframes. The word is a Components/TrackedLabel.lua run --
	    one TextLabel per character, because Roblox has no letter-spacing -- so "pulse the text" is
	    nineteen tweens or a CanvasGroup render target, permanently mounted over live combat, for
	    decoration.
	  * Editorially, docs/ui-ux-philosophy.md's Final Design Rule asks of every element: "does this
	    make the player feel more connected to the world and combat?" A loop that runs identically
	    whether you are being hunted or standing in a safe zone answers no -- it is motion that carries
	    no information, which is exactly what that doc's "controlled, never excessive" is guarding
	    against.
	What it does instead is put the motion on the TRANSITION, where there is something to say: entering
	combat takes the word to full opacity, carries it off the accent to the danger red, and widens the
	rule -- all off one spring. At rest it costs nothing at all.

	RESTING IS NOT FAINT. The first pass treated "quiet" as "low contrast" and set the resting run at
	0.45 transparency in the plain accent, which is how a label sat ON a dark panel is tuned. This is
	not on a panel -- it floats over open gameplay, where the background is as likely to be a daylit
	field as a dark interior -- so it now renders near-opaque in AccentPrimaryBright with a dark text
	stroke underneath it. Low EMPHASIS is a job for size, position and colour; it is not a job for
	making the text hard to see, and the two got conflated. The engaged state keeps its differential by
	moving further at the other end rather than by this one staying dim.

	Two label runs, one visible at a time, rather than one run with reactive text: TrackedLabel's Text
	is deliberately a plain string (its own header -- a reactive run would have to tear down and
	rebuild N instances per change, inside a Fusion scope with no mechanism for that). Wrapping each in
	its own Visible frame culls the hidden one from rendering entirely, which is why this costs one
	run, not two.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)

local Tokens = require(script.Parent.Parent.Parent.Tokens)
local Divider = require(script.Parent.Parent.Parent.Components.Divider)
local TrackedLabel = require(script.Parent.Parent.Parent.Components.TrackedLabel)

local Children = Fusion.Children

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>

export type EngagementLineProps = {
	InCombat: UsedAs<boolean>,
	LayoutOrder: number?,
}

-- The two states this line can report. Short, all-caps and static, which is what TrackedLabel is for.
local RESTING_TEXT = "AWAITING ENGAGEMENT"
local ENGAGED_TEXT = "IN COMBAT"

-- Abbrev is the tracked MONO step -- the reference design's `font-mono tracking-[0.3em]`. Every other
-- tracked step in Tokens.Type is sans, and this line reads as a system readout rather than as prose.
local TEXT_SCALE: TrackedLabel.TrackedScale = "Abbrev"
local TEXT_HEIGHT = Tokens.Type.Abbrev.Size + 2

local RULE_RESTING_WIDTH = 112
local RULE_ENGAGED_WIDTH = 168
local RULE_GAP = Tokens.Space.XS
-- The rule's own weight. See the Tint at its call site for why this is not a Tokens.Border step.
local RULE_TRANSPARENCY = 0.25
-- Clearance to whatever band comes next, baked into this element's own height rather than left to
-- the dock's UIListLayout Padding. Exactly the call Components/BountyMarkedBadge.lua's GAP_TO_NEXT
-- makes, and for the same reason: that badge collapses to zero height when the player is unmarked,
-- and a nonzero layout Padding would leave a permanent sliver of dead space above the dock whether or
-- not the badge was showing. The dock's stack therefore runs at Padding 0 and every band owns the gap
-- beneath itself.
local GAP_TO_NEXT = Tokens.Space.S

-- A fade spring, not a state spring: this is a whole element changing register, not an edge highlight
-- catching up, and Tokens.Motion's own split is by what is moving.
local SPRING_SPEED = Tokens.Motion.FadeSpring.Speed
local SPRING_DAMPING = Tokens.Motion.FadeSpring.Damping

-- How faint the line sits when nothing is happening. Raised from 0.45 on 2026-08-25 after an in-game
-- screenshot: 0.45 was calibrated as though this sat on a panel, and it does not -- it floats over
-- open gameplay, where the background can be a bright sky. "Quiet" has to mean low EMPHASIS, not low
-- contrast, and at 0.45 over daylight it was simply hard to read. The differential to the engaged
-- state is preserved by widening the gap at the other end instead (the engaged run goes fully opaque
-- AND turns red AND widens its rule), so entering combat still reads as a clear change.
local RESTING_TRANSPARENCY = 0.12

-- The dark outline that carries the run over whatever is behind it. Same technique and same reasoning
-- as Components/KeyLegend.lua's captions: over the world there is no fill behind the glyphs, so they
-- have to bring their own separation. Firm enough to hold against a bright sky, soft enough not to
-- read as an outlined font at this size.
local STROKE_TRANSPARENCY = 0.4

local function labelRun(
	scope: Scope,
	name: string,
	text: string,
	visible: UsedAs<boolean>,
	color: UsedAs<Color3>,
	transparency: UsedAs<number>
): Frame
	return scope:New "Frame" {
		-- Named per state rather than both being "Run": both exist at once and only one is Visible, so
		-- an identical name would leave either of them unfindable by path -- including to the spec that
		-- checks which one is showing.
		Name = name,
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		-- Culls the hidden run outright rather than drawing it at full transparency -- see header.
		Visible = visible,

		[Children] = TrackedLabel(scope, {
			Text = text,
			Scale = TEXT_SCALE,
			Color = color,
			TextTransparency = transparency,
			-- There is no fill behind these glyphs -- see STROKE_TRANSPARENCY above.
			StrokeColor3 = Tokens.Color.Background,
			StrokeTransparency = STROKE_TRANSPARENCY,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
		}),
	} :: Frame
end

local function EngagementLine(scope: Scope, props: EngagementLineProps): Frame
	-- 0 at rest, 1 engaged. One spring drives colour, brightness and the rule's width together, so the
	-- three cannot fall out of phase and one transition costs one spring rather than three.
	local engagement = scope:Spring(
		scope:Computed(function(use)
			return if use(props.InCombat) then 1 else 0
		end),
		SPRING_SPEED,
		SPRING_DAMPING
	)

	-- ACCENT AT REST, DANGER RED ENGAGED. Both ends are the "-Bright" text weights (Tokens.Color's
	-- documented "text-on-dark weight, never a fill"), which is precisely what this run is.
	--
	-- Engaged used to land on TextPrimary -- near-white. That was wrong, and not only as taste: white
	-- is this palette's ordinary READING weight, worn by every label in the game, so the one element
	-- whose entire job is to shout "you are in a fight" was resolving to the least marked colour it
	-- could have picked. It read as the line merely brightening rather than changing state. Red is
	-- what docs/ui-ux-philosophy.md's Critical States section reserves for exactly this, and the rule
	-- there -- colour is never the ONLY signal -- is already satisfied twice over here: the WORD
	-- changes (AWAITING ENGAGEMENT -> IN COMBAT) and the rule beneath it widens, both off this same
	-- spring. The colour is the third cue, not the only one.
	local textColor = scope:Computed(function(use)
		return Tokens.Color.AccentPrimaryBright:Lerp(Tokens.Color.DangerBright, use(engagement))
	end)
	local textTransparency = scope:Computed(function(use)
		return RESTING_TRANSPARENCY * (1 - use(engagement))
	end)

	local isEngaged = scope:Computed(function(use)
		return use(props.InCombat) == true
	end)
	local isResting = scope:Computed(function(use)
		return use(props.InCombat) ~= true
	end)

	local rule = Divider.Gradient(scope, {
		-- Fades to nothing at BOTH ends: this rule belongs to the word above it rather than growing
		-- out of anything, so neither end should read as an edge.
		Fade = "Both",
		-- The accent at full weight, not Tokens.Border.Lit's 32% edge -- a border tint is calibrated
		-- for an edge sat ON a surface, and this rule has open gameplay behind it. Same correction the
		-- text above it needed.
		--
		-- Tint carries the TRANSPARENCY only; Color below overrides its colour so the rule can cross to
		-- the danger red with the word instead of staying accent-purple under a red headline. It rides
		-- the same `engagement` spring as the text and the width, so all three still arrive together --
		-- which is the property this element was built around (see the spring's own comment).
		Tint = { Color = Tokens.Color.AccentPrimary, Transparency = RULE_TRANSPARENCY },
		Color = scope:Computed(function(use)
			return Tokens.Color.AccentPrimary:Lerp(Tokens.Color.DangerBright, use(engagement))
		end),
		LayoutOrder = 2,
		Size = scope:Computed(function(use)
			local width = RULE_RESTING_WIDTH + (RULE_ENGAGED_WIDTH - RULE_RESTING_WIDTH) * use(engagement)
			return UDim2.fromOffset(math.round(width), 1)
		end),
	})

	return scope:New "Frame" {
		Name = "EngagementLine",
		LayoutOrder = props.LayoutOrder,
		Size = UDim2.fromOffset(RULE_ENGAGED_WIDTH, TEXT_HEIGHT + RULE_GAP + 1 + GAP_TO_NEXT),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,

		[Children] = {
			scope:New "UIListLayout" {
				FillDirection = Enum.FillDirection.Vertical,
				HorizontalAlignment = Enum.HorizontalAlignment.Center,
				-- Top, not Center: the trailing GAP_TO_NEXT above is dead space this element carries for
				-- the band below it, and centring would split it either side of the content instead.
				VerticalAlignment = Enum.VerticalAlignment.Top,
				Padding = UDim.new(0, RULE_GAP),
				SortOrder = Enum.SortOrder.LayoutOrder,
			},
			scope:New "Frame" {
				Name = "Readout",
				LayoutOrder = 1,
				Size = UDim2.new(1, 0, 0, TEXT_HEIGHT),
				BackgroundTransparency = 1,
				BorderSizePixel = 0,

				[Children] = {
					labelRun(scope, "RestingRun", RESTING_TEXT, isResting, textColor, textTransparency),
					labelRun(scope, "EngagedRun", ENGAGED_TEXT, isEngaged, textColor, textTransparency),
				},
			},
			rule,
		},
	} :: Frame
end

return EngagementLine
