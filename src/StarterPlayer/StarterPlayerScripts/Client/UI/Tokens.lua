--!strict
--[[
	Tokens.lua

	Owns: the single shared design token set (colors, spacing, corner radius, type scale) for
	every UI surface -- docs/ui-ux-philosophy.md's "UI equivalent of Constants.lua." No component
	or screen should hardcode a color, spacing value, or font size that belongs here.

	Palette direction: deep-violet void with bronze as a second accent -- see docs/ui-ux-philosophy.
	md's Base Palette section. Locked visual identity; don't introduce a new hue family without
	revisiting that doc first.
]]

local UserInputService = game:GetService("UserInputService")

local Tokens = {}

-- Read once at require time, not tracked reactively -- which input methods this session's platform
-- supports is a stable fact for the whole client lifetime in practice, unlike Camera.ViewportSize (a
-- live window size a desktop player can actually resize, which DOES need reactive tracking -- see
-- Screens/Onboarding/Attributes.lua's own PipRail for that case).
local IS_TOUCH = UserInputService.TouchEnabled

-- Exported so the rest of the UI reads this session's input mode from ONE place rather than each
-- module opening its own UserInputService.TouchEnabled. Shell/Regions.lua is the second reader (it
-- lifts the two bottom regions clear of Roblox's default touch controls); the type floors below are
-- the first. Both want the same immutable-per-session fact, and two independent reads of it is how
-- they would eventually come to disagree about what a touch device is.
Tokens.IsTouch = IS_TOUCH

-- Small type floors at 12px on touch. Applied once here rather than at each of Eyebrow/Chip/Abbrev's
-- own definitions below so the rule can't drift between them. Takes the desktop size as an argument
-- since the three tracked small steps don't share one size -- a hardcoded floor would silently pull
-- all three back down to whichever is smallest.
local function floorOnTouch(desktopSize: number): number
	return if IS_TOUCH then math.max(desktopSize, 12) else desktopSize
end

-- A color paired with the transparency it's meant to be drawn at. The design expresses its whole
-- border and fill system as one hue at varying alpha (borders at 9%/18%/32%, fills at 1.6%-6%);
-- Roblox splits that across two properties (UIStroke.Color/.Transparency, Frame.BackgroundColor3/
-- .BackgroundTransparency), so a Color3-only token would force every call site to hand-type the
-- matching transparency literal beside it -- exactly the drift Tokens.Control's own comment below
-- was created to stop. Deliberately NOT pre-composited to opaque hexes: these are genuinely
-- translucent and read differently over Background than over Surface.
export type Tint = { Color: Color3, Transparency: number }

Tokens.Color = {
	-- Backgrounds and surfaces, darkest to lightest.
	Background = Color3.fromRGB(8, 6, 16),
	Surface = Color3.fromRGB(13, 10, 22),
	SurfaceElevated = Color3.fromRGB(19, 16, 32),

	-- The two accents. AccentPrimary is "interactive / live / selected"; AccentSecondary (bronze) is
	-- "committed / permanent / already spent" -- a split a single-accent palette can't express.
	-- AccentPrimaryBright is the text-on-dark weight of the primary, never a fill.
	AccentPrimary = Color3.fromRGB(154, 136, 200),
	AccentPrimaryBright = Color3.fromRGB(180, 160, 224),
	AccentSecondary = Color3.fromRGB(196, 164, 110),

	-- Text, ordered TextPrimary > TextSecondary > TextDisabled. TextDisabled must still clear a
	-- legibility floor -- a disabled control should read as unavailable, never as invisible.
	TextPrimary = Color3.fromRGB(224, 218, 238),
	TextSecondary = Color3.fromRGB(172, 163, 196),
	TextDisabled = Color3.fromRGB(122, 114, 146),

	-- Critical/state colors. Per docs/ui-ux-philosophy.md's Critical States rule these are never
	-- the only signal for a state change -- pair with a shape/motion cue (Bar.lua/VitalIcon.lua's
	-- CriticalBelow prop). Warning shares a swatch with AccentSecondary but keeps its own token:
	-- "this meter is in trouble" and "this choice is permanent" shouldn't be coupled by one hue.
	Danger = Color3.fromRGB(168, 80, 96),
	Warning = Color3.fromRGB(196, 164, 110),
	Positive = Color3.fromRGB(80, 136, 112),

	-- Faction accents (world-bible.md). Flat keys, not a Tokens.FactionColor map -- one consumer
	-- today (Screens/DevMenu/ContentArea.lua's color preview); a second caller earns the map.
	FactionCelestial = Color3.fromRGB(158, 196, 219),
	FactionDemonic = Color3.fromRGB(176, 58, 46),
	FactionUnbound = Color3.fromRGB(158, 150, 176),
}

-- Player Status vitals (docs/ui-ux-philosophy.md's Gameplay State Colors). Their own table, not
-- three keys on Tokens.Color, because the chrome's primary accent is called "qi" at the design
-- source (the violet Meridian-fragment) and collides head-on with a Qi *vital* named the same
-- thing -- separating the tables turns that mixup into a compile error instead of every button in
-- the game going pale cyan. The vitals keep their own hues rather than cohering with the chrome:
-- telling Health from Qi from Posture at a glance outranks hue-family cohesion.
Tokens.VitalColor = {
	Health = Color3.fromRGB(196, 48, 56), -- crimson / blood-like
	Qi = Color3.fromRGB(163, 224, 235), -- pale cyan / frost blue
	Posture = Color3.fromRGB(199, 149, 34), -- amber / burnished gold
}

-- One color per Constants.CharacterCreation.AttributeFields entry. Lives here (not under
-- Screens/Onboarding/) because these are permanent character-sheet semantics also wanted by the
-- level-up screen and gear comparison, not chargen decoration -- scoping them to one screen
-- guarantees a duplicate within two features.
--
-- The three attributes that GOVERN a vital take that vital's exact color rather than the source
-- design's own swatches (which color Fortitude blue and MeridianFlow violet): Fortitude is posture
-- (amber on the HUD) and MeridianFlow is qi (pale cyan), and shipping the mismatched colors would
-- teach an association in character creation the hotbar contradicts thirty seconds later. The
-- remaining three (no vital of their own) keep the source swatches.
--
-- Cast to an index signature so a caller iterating AttributeFields can index this with that loop's
-- own `field: string` directly, matching Constants.lua's AttributeEffects/AttributeAbbreviations.
Tokens.AttributeColor = {
	Vitality = Tokens.VitalColor.Health,
	Fortitude = Tokens.VitalColor.Posture,
	MeridianFlow = Tokens.VitalColor.Qi,
	Might = Color3.fromRGB(184, 144, 96),
	Pressure = Color3.fromRGB(152, 104, 160),
	Fleetness = Color3.fromRGB(80, 136, 112),
} :: { [string]: Color3 }

-- Border tiers, consumed by a UIStroke (Color + Transparency). Separate table from Tokens.Wash
-- despite the identical shape: a stroke and a background are different rendering surfaces, and a
-- token named Border handed to a BackgroundColor3 should read as a mistake at the call site.
Tokens.Border = {
	-- The 9% hairline -- inset dividers inside a card, section seams.
	Hairline = { Color = Color3.fromRGB(160, 140, 200), Transparency = 0.91 } :: Tint,
	-- The 18% standard panel edge. This is the default; reach for the others deliberately.
	Standard = { Color = Color3.fromRGB(160, 140, 200), Transparency = 0.82 } :: Tint,
	-- The 32% emphasis edge -- corner brackets, the flourish rule's lit end.
	Lit = { Color = Color3.fromRGB(180, 160, 220), Transparency = 0.68 } :: Tint,
	-- The 40% accent edge on a selected/active surface.
	Accent = { Color = Tokens.Color.AccentPrimary, Transparency = 0.6 } :: Tint,
	-- THE LINE BETWEEN TWO JOINED SURFACES, and the one tint here that is not an edge. Every entry
	-- above describes where a panel STOPS, and edges in this UI are quiet on purpose. This one is a
	-- DIVISION: it runs through the middle of a single assembled object and says the two halves are
	-- two instruments. The hotbar dock and its armament island wear it, and so do the helm console
	-- and its furnace plate.
	--
	-- It is deliberately LOUDER than any panel border here, which is the inversion worth noting: a
	-- joined assembly needs its internal division to out-read its outer edge, or the two halves merge
	-- back into one object and the whole point of the joint is lost. At 0.2 against the panel edge's
	-- own 0.3, on a 2px rule against their 1px, it still is.
	--
	-- TUNED IN TWO PASSES AND BOTH ARE WORTH KEEPING. It began as AccentPrimary at 0.3 -- the panels'
	-- own edge treatment, one pixel wide -- and read as a seam in the material rather than as a
	-- boundary between two things. Taken to fully opaque it read as too loud for the surrounding
	-- chrome. 0.2 is the owner's landing point between the two.
	--
	-- ONE THING THIS KNOWINGLY BENDS: Tokens.Color's own note calls AccentPrimaryBright "the
	-- text-on-dark weight of the primary, never a fill", and this is a fill. Kept at the owner's
	-- direction after the alternative was raised -- the hue is what makes the division read against
	-- two surfaces that are both AccentPrimary at the edge. Flagged so the next person to reach for
	-- Bright as a fill knows this one is an exception rather than a precedent.
	Seam = { Color = Tokens.Color.AccentPrimaryBright, Transparency = 0.2 } :: Tint,
}

-- Fill washes, consumed as a BackgroundColor3 + BackgroundTransparency pair on a Frame.
Tokens.Wash = {
	-- An unselected card's barely-there lift off the panel.
	CardResting = { Color = Color3.fromRGB(255, 255, 255), Transparency = 0.984 } :: Tint,
	-- A recessed strip inside a card -- the stat-bias summary, a stepper button's face.
	Inset = { Color = Color3.fromRGB(255, 255, 255), Transparency = 0.976 } :: Tint,
	-- Every meter's unfilled track.
	TrackBase = { Color = Color3.fromRGB(255, 255, 255), Transparency = 0.96 } :: Tint,
	-- Tick marks on a track, and an unspent allocation pip.
	Tick = { Color = Color3.fromRGB(255, 255, 255), Transparency = 0.94 } :: Tint,
	-- Scrims that darken a chrome band against the panel behind it.
	RailScrim = { Color = Color3.fromRGB(0, 0, 0), Transparency = 0.7 } :: Tint,
	FooterScrim = { Color = Color3.fromRGB(0, 0, 0), Transparency = 0.8 } :: Tint,
	-- Accent-tinted fills: AccentFill backs an active chip/step box, AccentBloom is the faint
	-- wash behind a selected surface.
	AccentFill = { Color = Tokens.Color.AccentPrimary, Transparency = 0.88 } :: Tint,
	AccentBloom = { Color = Tokens.Color.AccentPrimary, Transparency = 0.94 } :: Tint,
}

Tokens.Space = {
	XS = 4,
	S = 8,
	M = 12,
	L = 16,
	XL = 24,
	XXL = 32,
	XXXL = 48,
}

-- Shared control-sizing tokens -- the "UI equivalent of Constants.lua" for row heights and button
-- sizes. Named generically, not per-screen (e.g. not "DevMenuRowHeight"), since nothing about these
-- values is specific to whichever screen first needed them: any future screen with the same "one
-- action per row" or "icon-button beside a value label" shape reuses these instead of re-guessing.
Tokens.Control = {
	-- Standard height for a single-row control: a full-width action button, or one cell of a split
	-- row.
	RowHeight = 40,
	-- Standard size for a small square icon/step button -- also reused as the plain HEIGHT for a
	-- value Label/Tab sitting beside one, so the row's contents stay vertically aligned.
	StepButtonSize = 32,
	-- Minimum square size for anything a finger has to hit.
	TouchTargetSize = 44,
	-- Horizontal clearance a right-aligned header label reserves from a pinned close ("X") button.
	CloseButtonClearance = 36,
	-- Hairline separator thickness for a seam between two grouped sections.
	DividerThickness = 1,
	-- Twice a divider, and the same weight as a CornerBracket arm. Not an arbitrary step up: the
	-- elbows bracing each corner of a joined assembly are 2px, so the line dividing its two halves is
	-- the same forged detail at the same weight rather than a heavier version of a hairline. See
	-- Tokens.Border.Seam for why this one is allowed to be loud.
	SeamRuleThickness = 2,
}

-- Two radii, not one. Sharp is the default for panel chrome per docs/ui-ux-philosophy.md's Shape
-- Language ("avoid perfect rounded rectangles"); Hairline is a 2px softening used only on small
-- filled elements (meter fills, allocation pips, the archetype chip) where a truly square 2px-tall
-- sliver reads as an artifact rather than as intent. Sharp is also the base for every surface that
-- hasn't opted into the true cut-corner silhouette -- see ChamferedSurface.lua for that geometry,
-- which the menu register deliberately doesn't use.
Tokens.Radius = {
	Sharp = UDim.new(0, 0),
	Hairline = UDim.new(0, 2),
}

-- Font families. Derived from Enum.Font at load rather than hardcoding an
-- `rbxasset://fonts/families/*.json` path -- same "don't guess an asset id" discipline
-- VitalIcon.lua's header holds this repo to. Going through Font.new (rather than staying on
-- Enum.Font) is what buys real weights and italic, neither of which Enum.Font can express.
--
-- None of the redesign's three families exist on Roblox, so each maps to the closest built-in:
--   Cinzel (display serif)   -> Merriweather. Bodoni is closer in character but its hairlines
--                               vanish at 15px on a near-black ground, and 15px is exactly where
--                               the design puts race names.
--   Rajdhani (squared sans)  -> TitilliumWeb. Jura is a closer skeleton but its 300 weight
--                               disappears at 11px on dark. Most likely of the three to want an
--                               in-Studio second opinion.
--   JetBrains Mono           -> RobotoMono. Direct, and its fixed advance width gives the design's
--                               tabular-nums numerals for free.
-- Swapping in real uploaded font assets later is a change to these three lines only.
local SERIF_FAMILY = Font.fromEnum(Enum.Font.Merriweather).Family
local SANS_FAMILY = Font.fromEnum(Enum.Font.TitilliumWeb).Family
local MONO_FAMILY = Font.fromEnum(Enum.Font.RobotoMono).Family

local function serif(weight: Enum.FontWeight): Font
	return Font.new(SERIF_FAMILY, weight, Enum.FontStyle.Normal)
end

local function sans(weight: Enum.FontWeight, italic: boolean?): Font
	return Font.new(SANS_FAMILY, weight, if italic then Enum.FontStyle.Italic else Enum.FontStyle.Normal)
end

local function mono(weight: Enum.FontWeight): Font
	return Font.new(MONO_FAMILY, weight, Enum.FontStyle.Normal)
end

-- The type scale. `Face` holds a Font (assigned to TextLabel.FontFace), NOT an Enum.Font (assigned
-- to TextLabel.Font) -- the field was renamed from `Font` precisely so the two can't be confused,
-- since setting both properties on one instance is order-dependent and silently wrong.
--
-- `Tracking` is letter-spacing in WHOLE PIXELS, present only on the steps that need it. Roblox has
-- no letter-spacing property and no RichText tag for it, so the only thing that can realize it is
-- Components/TrackedLabel.lua, which lays out one TextLabel per character over a UIListLayout whose
-- Padding is this value. Stored in pixels rather than em because that Padding is a UDim -- em would
-- make every call site multiply by size. A step carrying Tracking must be rendered by TrackedLabel;
-- the Label/TrackedLabel prop types are disjoint so passing one to the wrong component is a
-- compile error rather than a silently-untracked label.
--
-- Three registers, deliberately flat rather than nested, so Label.lua's single Tokens.Type[scale]
-- lookup survives unchanged. If a step here has no callers, delete it -- this table is sized to the
-- design, and the design may not use all of it.
--
-- Weights/sizes were tuned for legibility on this palette's near-black ground, not guessed: a light
-- weight below ~12px is where it loses readability first (regular/bold reads far better than it
-- looks on paper); tracked all-caps steps (Eyebrow/Chip/Abbrev) read as deliberate small caps with
-- LESS tracking and a larger size, not more of either; mono numerals need to out-weight the label
-- beside them, since the number is the thing the player came to read. If text still reads small on
-- a large display, that's Components/ModalScreen.lua's AutoScale (grows the whole panel with the
-- viewport) to fix, not another bump here -- type size answers "small for its own box," not "small
-- on my monitor."
Tokens.Type = {
	-- Serif: headings and proper nouns. The "this is a thing in the world" register.
	Title = { Face = serif(Enum.FontWeight.Bold), Size = 28 },
	Heading = { Face = serif(Enum.FontWeight.Bold), Size = 22 },
	CardTitle = { Face = serif(Enum.FontWeight.Bold), Size = 16 },
	SerifInline = { Face = serif(Enum.FontWeight.Medium), Size = 12 },

	-- Sans: everything the player reads as instruction rather than as world.
	BodyLarge = { Face = sans(Enum.FontWeight.SemiBold), Size = 15 },
	Body = { Face = sans(Enum.FontWeight.Medium), Size = 14 },
	Detail = { Face = sans(Enum.FontWeight.Regular), Size = 13 },
	DetailEmphasis = { Face = sans(Enum.FontWeight.Regular, true), Size = 13 },
	Micro = { Face = sans(Enum.FontWeight.Bold), Size = 12, Tracking = 2 },
	Eyebrow = { Face = sans(Enum.FontWeight.Bold), Size = floorOnTouch(12), Tracking = 2 },
	Action = { Face = sans(Enum.FontWeight.Bold), Size = floorOnTouch(13), Tracking = 2 },
	Chip = { Face = sans(Enum.FontWeight.Bold), Size = floorOnTouch(11), Tracking = 1 },

	-- Mono: every numeral in the game, plus the three-letter attribute abbreviations that sit
	-- beside them and have to share their column rhythm.
	NumeralLarge = { Face = mono(Enum.FontWeight.Bold), Size = 22 },
	Numeral = { Face = mono(Enum.FontWeight.Medium), Size = 14 },
	NumeralSmall = { Face = mono(Enum.FontWeight.Medium), Size = 12 },
	Abbrev = { Face = mono(Enum.FontWeight.Bold), Size = floorOnTouch(12), Tracking = 1 },

	-- No more Display/Subheading/Caption aliases -- the last call sites migrated off them, so all
	-- three were unreferenced and were deleted outright rather than kept as dead weight.
}

-- Line-height multipliers, assigned to TextLabel.LineHeight (Roblox's own unit: a multiple of the
-- font's natural line spacing, where 1 is the property's default and leaves rendering untouched).
--
-- Its own table rather than a field on Tokens.Type, for two reasons. Label.lua's single
-- `Tokens.Type[scale]` lookup stays a one-liner instead of growing a per-step leading branch; and
-- Components/TrackedLabel.lua -- which lays out ONE TextLabel per character over a horizontal
-- UIListLayout -- physically cannot express line height at all, so a Tracking-carrying step must
-- never be handed one it would silently ignore. Keeping leading out of Tokens.Type is what makes
-- that impossible by construction, the same disjoint-by-design split Label/TrackedLabel's own scale
-- unions already use.
--
-- Two entries, deliberately: leading here is a binary decision (single-line chrome vs. wrapped
-- prose), not a scale with intermediate steps.
Tokens.Leading = {
	-- The default, and the value to omit rather than pass. Single-line chrome, numerals, button
	-- captions, field labels -- anything that never wraps to a second line.
	Tight = 1,
	-- Wrapped explanatory copy: a Section description, a NumericField/Toggle hint, an empty-state
	-- body. 1.2 is the first value at which two 11px Detail lines stop reading as one 22px block on
	-- this palette's near-black ground.
	Prose = 1.2,
}

-- Motion presets. Two mechanisms, one table, distinguished by suffix.
--
-- Pick between them by what's moving, not by taste: a *Spring tracks a continuously-changing live
-- value (health draining, a reticle chasing a target) and its settle time is emergent; a *Tween
-- plays a discrete state transition over a designed duration (a card being selected, a screen
-- entering). The redesign specifies durations, so its transitions are tweens.
--
-- The design's cubic-bezier(.4, 0, .2, 1) has no exact Roblox equivalent -- Quart/Out is the
-- closest built-in. Pinned here once so no call site re-derives it.
Tokens.Motion = {
	-- VitalIcon's hotbar fill catching up to the real value.
	FillSpring = { Speed = 20, Damping = 1 },
	-- LockOnReticle chasing a moving combat target -- snappier than a vital's fill.
	FollowSpring = { Speed = 24, Damping = 1 },
	-- AbilitySlot's edge highlight easing in/out on a state change.
	StateSpring = { Speed = 24, Damping = 1 },
	-- DamageNumberLabel's one-shot rise-and-fade. RiseOffset is the rise distance itself (pixels).
	RiseSpring = { Speed = 6, Damping = 1, RiseOffset = 34 },
	-- PostureBreakBanner/StatusBanner's one-shot entrance fade-in.
	FadeSpring = { Speed = 14, Damping = 0.7 },
	-- ParryReadyGlint's screen-edge flash -- fast, near-critically-damped so it pops in and melts
	-- out without ringing, matching the "instant acknowledgment" intent of the local parry cue.
	-- StrokeThickness/PeakTransparency are the glint's own visual-tuning siblings to Speed/Damping.
	GlintSpring = { Speed = 32, Damping = 1, StrokeThickness = 5, PeakTransparency = 0.2 },
	-- An HUD ISLAND ARRIVING BESIDE THE DOCK -- Screens/WeaponInventory's armament island swinging
	-- out from the hotbar's left edge on the first pickup.
	--
	-- THE ONLY UNDER-DAMPED SPRING IN THIS TABLE, and the one place in the HUD where an overshoot is
	-- the point rather than a defect. Every other spring here is Damping = 1 (critical) because it is
	-- easing a value toward a number the player is READING -- a vital's fill, a cooldown edge -- and
	-- a bar that sailed past its own value and came back would be lying about the number for as long
	-- as it took to settle. This one carries no number. It is a panel arriving, and the overshoot is
	-- what makes it read as a thing with mass being pushed out rather than a rectangle whose width
	-- changed (Shared/FlightMath.lua's header makes the same distinction for the flight camera).
	--
	-- 0.68, not lower: docs/ui-ux-philosophy.md's Animation Philosophy asks for "smooth, controlled,
	-- intentional -- never bouncy, arcade-like". A second-order step response overshoots by
	-- exp(-pi*z / sqrt(1 - z^2)), so at z = 0.68 the island passes its rest width by about 5%, once,
	-- peaking a quarter second in and settled inside a second. A second visible bounce would be the
	-- arcade register that section rules out.
	IslandSpring = { Speed = 17, Damping = 0.68 },

	-- Hover/press color changes.
	HoverTween = TweenInfo.new(0.2, Enum.EasingStyle.Quart, Enum.EasingDirection.Out),
	-- A discrete selection/state change on a card or chip.
	StateTween = TweenInfo.new(0.3, Enum.EasingStyle.Quart, Enum.EasingDirection.Out),
	-- A whole screen entering (the design's slide-up).
	EnterTween = TweenInfo.new(0.35, Enum.EasingStyle.Quart, Enum.EasingDirection.Out),
	-- A meter or arc jumping to a new value.
	FillTween = TweenInfo.new(0.4, Enum.EasingStyle.Quart, Enum.EasingDirection.Out),
}

return Tokens
