--!strict
--[[
	Tokens.lua

	Owns: the single shared design token set (colors, spacing, corner radius, type scale) for
	every UI surface -- docs/ui-ux-philosophy.md's "UI equivalent of Constants.lua." No component
	or screen should hardcode a color, spacing value, or font size that belongs here.

	Palette direction: deep-violet void with bronze as a second accent -- see docs/ui-ux-philosophy.
	md's "The base palette is now violet/bronze" note, which supersedes that doc's canon Color
	Language section and records why the cold blue-grey identity was replaced. Sharp edges and
	restrained ornamentation are unchanged; only the hue family moved. This is locked visual
	identity; don't introduce a new hue family without revisiting that doc first.
]]

local UserInputService = game:GetService("UserInputService")

local Tokens = {}

-- Read once at require time, not tracked reactively -- which input methods this session's platform
-- supports is a stable fact for the whole client lifetime in practice (docs/design/
-- intro-redesign-handoff.md Phase F's mobile pass), unlike Camera.ViewportSize (a live window size a
-- desktop player can actually resize, which DOES need reactive tracking -- see
-- Screens/Onboarding/Attributes.lua's own PipRail for that case).
local IS_TOUCH = UserInputService.TouchEnabled

-- "9px type floors at 12px on touch" (handoff's mobile pass) -- applied once here rather than at
-- each of Eyebrow/Chip/Abbrev's own definitions below so the rule can't drift between them.
local function nineOrTwelveOnTouch(): number
	return if IS_TOUCH then 12 else 9
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
	-- "committed / permanent / already spent" -- the split the old single-accent palette couldn't
	-- express. AccentPrimaryBright is the text-on-dark weight of the primary, never a fill.
	AccentPrimary = Color3.fromRGB(154, 136, 200),
	AccentPrimaryBright = Color3.fromRGB(180, 160, 224),
	AccentSecondary = Color3.fromRGB(196, 164, 110),

	-- Text.
	TextPrimary = Color3.fromRGB(200, 192, 216),
	TextSecondary = Color3.fromRGB(138, 127, 160),
	TextDisabled = Color3.fromRGB(74, 68, 96),

	-- Critical/state colors. Per docs/ui-ux-philosophy.md's Critical States rule these are never
	-- the only signal for a state change -- components pair them with a shape/motion cue (see
	-- Bar.lua/VitalIcon.lua's CriticalBelow prop for the reference implementation). Warning shares a
	-- swatch with AccentSecondary and still keeps its own token: "this meter is in trouble" and
	-- "this choice is permanent" are different concepts that shouldn't be coupled by a shared hue.
	Danger = Color3.fromRGB(168, 80, 96),
	Warning = Color3.fromRGB(196, 164, 110),
	Positive = Color3.fromRGB(80, 136, 112),

	-- Faction accents (world-bible.md). Flat keys rather than a Tokens.FactionColor map because
	-- there's exactly one consumer today (Screens/DevMenu/ContentArea.lua's color preview) and no
	-- design pressure to iterate them -- the second consumer earns the map, per the same
	-- "wait for a real second caller" rule Section.lua/Geometry.lua's headers already follow.
	FactionCelestial = Color3.fromRGB(158, 196, 219),
	FactionDemonic = Color3.fromRGB(176, 58, 46),
	FactionUnbound = Color3.fromRGB(158, 150, 176),

	-- DEPRECATED, pending a mechanical sweep. Both are retained ONLY so the ~25 screens/components
	-- that haven't been migrated yet still compile and still pick up the new palette. New code uses
	-- Tokens.Border.Standard (a Tint) and Tokens.Color.AccentPrimary respectively.
	--
	-- BorderSubtle is the one value here that is NOT simply the new token: it's Border.Standard
	-- PRE-COMPOSITED over Surface (160,140,200 at 18% over 13,10,22), because the sites still using
	-- it assign a plain Color3 to a UIStroke and have nowhere to put the matching Transparency. The
	-- opaque hue on its own would render as a bright lavender hairline on every panel in the game.
	-- Sites migrating off this should take Border.Standard's real Color AND Transparency, which
	-- composites correctly over any surface rather than only over Surface.
	BorderSubtle = Color3.fromRGB(40, 33, 54),
	BorderAccent = Color3.fromRGB(154, 136, 200),
}

-- Player Status vitals (docs/ui-ux-philosophy.md's Gameplay State Colors -- NOT superseded by the
-- palette change; the three vitals keep their canon hues).
--
-- Their own table, not three keys on Tokens.Color, because the redesign's primary accent is called
-- "qi" at source (it's the Meridian-fragment violet) and collided head-on with a token named
-- Tokens.Color.Qi that means something completely different -- the player's energy bar. Anyone
-- reading the design spec beside a flat Tokens.Color would wire the accent to the vital and turn
-- every button in the game pale cyan. Separating the tables makes that a compile error instead.
--
-- The vitals stay visually distinct from each other rather than cohering with the chrome: telling
-- Health from Qi from Posture at a glance is the whole job, and hue-family cohesion is subordinate
-- to it.
Tokens.VitalColor = {
	Health = Color3.fromRGB(196, 48, 56), -- crimson / blood-like
	Qi = Color3.fromRGB(163, 224, 235), -- pale cyan / frost blue
	Posture = Color3.fromRGB(199, 149, 34), -- amber / burnished gold
}

-- One color per Constants.CharacterCreation.AttributeFields entry, keyed by that exact field name
-- so callers can index it while iterating the canonical field list rather than re-typing six names.
--
-- Lives here rather than under Screens/Onboarding/ because these are permanent character-sheet
-- semantics, not chargen decoration -- the same six colors are wanted by the level-up screen, gear
-- comparison, and the Attunement/tier-up screen Constants.lua's AttributeBudget comment already
-- anticipates. Scoping them to one screen guarantees a duplicate within two features.
--
-- The three attributes that GOVERN a vital take that vital's exact color rather than the redesign's
-- own invented swatches. The Figma file colors Fortitude blue and MeridianFlow violet, but Fortitude
-- is posture (amber on the HUD) and MeridianFlow is qi (pale cyan on the HUD) -- shipping the
-- design's colors would spend character creation teaching an association the hotbar contradicts
-- thirty seconds later. The remaining three (no vital of their own) keep the design's swatches.
-- Cast to an index signature (not left as a sealed six-key record) so a caller iterating
-- Constants.CharacterCreation.AttributeFields can index this with that loop's own `field: string`
-- variable directly -- the same pattern Constants.lua's own AttributeEffects/AttributeAbbreviations
-- already use, for the identical reason.
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

-- Shared control-sizing tokens -- born out of Screens/DevMenu/init.lua, whose ~24 rows/buttons
-- across the Spawn/Admin/Tuning tabs each hand-typed their own literal UDim2.new/fromOffset height
-- (`0, 40` on every full-width action button and the Health/Godmode/Flight/Collide split rows; `32`
-- on every hitbox/standalone/flight-tuning stepper's "<"/">" buttons AND the value Label/Tab beside
-- them, since those need to line up on the same row height). Two different literals repeated ~23
-- times combined with zero shared name -- exactly the "UI equivalent of Constants.lua" gap this
-- file's own header warns against. Named generically (not "DevMenuRowHeight") since nothing about
-- either value is DevMenu-specific -- any future screen with the same "one action per row" or
-- "icon-button beside a value label" shape reuses these instead of re-guessing 40/32.
Tokens.Control = {
	-- Standard height for a single-row control: a full-width action button (e.g. "Spawn Training
	-- Dummy", "Reset Stage to Default") or one cell of a split row (Heal Full / Set HP to 1, the
	-- Godmode/Flight/Collide toggle trio).
	RowHeight = 40,
	-- Standard size for a small square icon/step button (hitbox/standalone/flight tuner's "<"/">"
	-- cycle buttons, the +-0.01/+-0.1 stepper buttons) -- also reused as the plain HEIGHT for the
	-- value Label/Tab sitting beside one of these buttons on the same row, so the row's contents stay
	-- vertically aligned without a separate token for "the same number, but as a height."
	StepButtonSize = 32,
	-- Minimum square size for anything a finger has to hit. Roblox skews heavily touch, and the
	-- redesign's own 28px steppers are below what a thumb can reliably land on.
	TouchTargetSize = 44,
	-- Horizontal clearance (offset studs) the header's target-name label reserves from the panel's
	-- right edge so its right-aligned text never sits underneath the circular close ("X") button
	-- anchored there.
	CloseButtonClearance = 36,
	-- Hairline separator thickness -- born out of the Hotbar's vitals/ability-slot divider
	-- (Screens/HUD/init.lua), generic enough for any future screen that needs the same "one thin
	-- seam between two grouped sections" shape (e.g. a future Menus.lua column split) rather than a
	-- Hotbar-specific name.
	DividerThickness = 1,
}

-- Two radii, not one. Sharp stays the default for panel chrome per docs/ui-ux-philosophy.md's Shape
-- Language ("avoid perfect rounded rectangles"); Hairline is the redesign's 2px softening, used only
-- on small filled elements (meter fills, allocation pips, the archetype chip) where a truly square
-- 2px-tall sliver reads as an artifact rather than as intent.
--
-- Replaces the old singular Tokens.CornerRadius, which by construction couldn't express a design
-- with two radii. Still the base for every surface that hasn't opted into the true cut-corner
-- silhouette -- see Client/UI/ChamferedSurface.lua (Panel/AbilitySlot/VitalIcon's optional
-- Chamfered treatment) for that geometry, which the redesign's menu register deliberately does not
-- use; that file's own header explains the split.
Tokens.Radius = {
	Sharp = UDim.new(0, 0),
	Hairline = UDim.new(0, 2),
}

-- DEPRECATED alias for Tokens.Radius.Sharp, retained for the same unmigrated call sites as
-- Color.BorderSubtle/BorderAccent above.
Tokens.CornerRadius = Tokens.Radius.Sharp

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
-- lookup survives unchanged. If a step here has no callers once the Onboarding rebuild lands,
-- delete it -- this table is sized to the design, and the design may not use all of it.
Tokens.Type = {
	-- Serif: headings and proper nouns. The "this is a thing in the world" register.
	Title = { Face = serif(Enum.FontWeight.SemiBold), Size = 28 },
	Heading = { Face = serif(Enum.FontWeight.SemiBold), Size = 22 },
	CardTitle = { Face = serif(Enum.FontWeight.SemiBold), Size = 15 },
	SerifInline = { Face = serif(Enum.FontWeight.Regular), Size = 11 },

	-- Sans: everything the player reads as instruction rather than as world.
	BodyLarge = { Face = sans(Enum.FontWeight.Regular), Size = 15 },
	Body = { Face = sans(Enum.FontWeight.Regular), Size = 13 },
	Detail = { Face = sans(Enum.FontWeight.Light), Size = 11 },
	DetailEmphasis = { Face = sans(Enum.FontWeight.Light, true), Size = 11 },
	Micro = { Face = sans(Enum.FontWeight.SemiBold), Size = 10, Tracking = 2 },
	Eyebrow = { Face = sans(Enum.FontWeight.SemiBold), Size = nineOrTwelveOnTouch(), Tracking = 3 },
	Action = { Face = sans(Enum.FontWeight.SemiBold), Size = 11, Tracking = 2 },
	Chip = { Face = sans(Enum.FontWeight.SemiBold), Size = nineOrTwelveOnTouch(), Tracking = 2 },

	-- Mono: every numeral in the game, plus the three-letter attribute abbreviations that sit
	-- beside them and have to share their column rhythm.
	NumeralLarge = { Face = mono(Enum.FontWeight.Medium), Size = 20 },
	Numeral = { Face = mono(Enum.FontWeight.Regular), Size = 13 },
	NumeralSmall = { Face = mono(Enum.FontWeight.Regular), Size = 10 },
	Abbrev = { Face = mono(Enum.FontWeight.Regular), Size = nineOrTwelveOnTouch(), Tracking = 1 },

	-- No more Display/Subheading/Caption aliases -- the last call sites (the Subheading judgment
	-- sweep, docs/design/intro-redesign-handoff.md Phase F) migrated off them, so all three are now
	-- unreferenced and were deleted outright rather than kept as dead weight.
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
