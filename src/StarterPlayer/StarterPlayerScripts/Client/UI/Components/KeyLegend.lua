--!strict
--[[
	KeyLegend.lua

	Owns: a legend laid out as one horizontal RUN -- cap, caption, gap, cap, caption -- centred under
	whatever it annotates. The hotbar's sub-dock strip ("M User Menu   K Settings   B Emote") is this.

	NOT A HORIZONTAL KeyHint, and the difference is the whole reason both exist. Components/KeyHint.
	lua is a ROW in a STACK: its caps share one fixed-width column so that a column of descriptions
	forms a single flush left edge, which is what makes a dense corner console readable. That column
	is meaningless here -- there is no second line to align to -- and enforcing it would pad every
	cap out to the width of the widest one in the run, spacing the entries irregularly for no reason.
	This lays out at each entry's natural width instead, and separates entries by a real gap.

	Both draw their caps with Components/KeyCap.lua, so the two legends cannot drift on what a key
	looks like even though they disagree about how a legend is arranged.

	QUIET, BUT IT CARRIES ITS OWN CONTRAST. This sits under the combat HUD, where
	docs/ui-ux-philosophy.md's rule is "minimal, informative, out of the player's way" -- so it is
	deliberately low-emphasis. What it can NOT be is low-contrast, and that is a different thing: there
	is no panel behind this strip, so what sits behind a cap is the game world, which is a bright
	daylit field as readily as a dark interior. Three consequences, all of them the difference between
	"restrained" and "invisible" (2026-08-25, from an in-game screenshot over grass):
	  * the caps take Components/KeyCap.lua's "Overlay" tone, which carries a real fill of its own
	    rather than the 2.4% white wash that reads as a recessed key on a dark panel and as nothing at
	    all anywhere else;
	  * the captions are TextSecondary, not TextDisabled -- the disabled step is calibrated against
	    this palette's near-black surfaces, and the doc's own "must still clear a legibility floor"
	    rule is about a panel, not about open sky;
	  * and they carry a dark text stroke, the same technique Label.lua exposes for combat text that
	    "should never require reading effort" over a busy background.

	Does not own: what any key is bound to. Entries are handed in with reactive Key strings so a
	rebind (Client/Input/KeybindManager.lua) re-letters the cap in place, with no rebuild.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Tokens = require(script.Parent.Parent.Tokens)
local KeyCap = require(script.Parent.KeyCap)
local Label = require(script.Parent.Label)
local Stack = require(script.Parent.Stack)

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>

export type KeyLegendEntry = {
	-- Reactive: a rebindable action's glyph has to change without the legend being rebuilt.
	Key: UsedAs<string>,
	-- Plain string. Unlike the key, what an action DOES never changes at runtime -- and a caller who
	-- genuinely needs it to wants two entries and a Visible toggle, not a reactive caption.
	Text: string,
}

export type KeyLegendProps = {
	Entries: { KeyLegendEntry },
	LayoutOrder: UsedAs<number>?,
	Visible: UsedAs<boolean>?,
	-- Space between whole entries. Deliberately much wider than the cap-to-caption gap inside one:
	-- that contrast is the only thing telling the eye which caption belongs to which cap, since
	-- nothing here is boxed.
	Gap: number?,
	Name: string?,
}

local CAP_MIN_WIDTH = 21
local CAP_HEIGHT = 19
-- Inside one entry. Small enough that a cap and its caption read as one object.
local CAP_TO_TEXT_GAP = Tokens.Space.S
local DEFAULT_ENTRY_GAP = Tokens.Space.XXL
-- Firm enough to separate the glyphs from a bright background, soft enough not to read as an outline
-- around the letters at this size.
local CAPTION_STROKE_TRANSPARENCY = 0.35

local function entryRow(scope: Scope, entry: KeyLegendEntry, order: number): Frame
	return Stack.Row(scope, {
		Name = `LegendEntry{order}`,
		LayoutOrder = order,
		Size = UDim2.fromOffset(0, CAP_HEIGHT),
		AutomaticSize = Enum.AutomaticSize.X,
		Gap = CAP_TO_TEXT_GAP,
		AlignY = Enum.VerticalAlignment.Center,

		Children = {
			KeyCap(scope, {
				Name = "Cap",
				Key = entry.Key,
				-- See this file's header: nothing is behind this strip, so each cap brings its own
				-- background rather than borrowing a panel's.
				Tone = "Overlay",
				LayoutOrder = 1,
				MinWidth = CAP_MIN_WIDTH,
				Height = CAP_HEIGHT,
			}),
			Label(scope, {
				Text = entry.Text:upper(),
				-- The small tracked-caps register would be the obvious pick for three words of chrome,
				-- but a tracked step means Components/TrackedLabel.lua -- one TextLabel per character,
				-- ~30 instances for this strip alone, permanently mounted over live combat. NumeralSmall
				-- keeps the mono, caps, small-chrome read for one instance per caption instead. This is
				-- the cheapest surface on the HUD and it should stay that way.
				Scale = "NumeralSmall",
				Color = Tokens.Color.TextSecondary,
				-- Not decoration: this is what holds the caption together over a bright background,
				-- where the fill behind a cap cannot help because there is no fill behind the text.
				StrokeColor3 = Tokens.Color.Background,
				StrokeTransparency = CAPTION_STROKE_TRANSPARENCY,
				-- Auto on both axes from a zero base. Omitting Size would auto-size too, but from a
				-- scale-1 width, and this row is AutomaticSize.X -- see Label.lua's AutoWidth prop.
				AutoWidth = true,
				LayoutOrder = 2,
			}),
		},
	})
end

local function KeyLegend(scope: Scope, props: KeyLegendProps): Frame
	local children: { Instance } = {}
	for index, entry in ipairs(props.Entries) do
		table.insert(children, entryRow(scope, entry, index))
	end

	return Stack.Row(scope, {
		Name = props.Name or "KeyLegend",
		LayoutOrder = props.LayoutOrder,
		Visible = props.Visible,
		Size = UDim2.fromOffset(0, CAP_HEIGHT),
		AutomaticSize = Enum.AutomaticSize.X,
		Gap = props.Gap or DEFAULT_ENTRY_GAP,
		AlignY = Enum.VerticalAlignment.Center,
		Children = children,
	})
end

return KeyLegend
