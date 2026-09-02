--!strict
--[[
	KeyHint.lua

	Owns: one line of a control legend -- a run of key caps followed by what pressing them does.

	WHY A COMPONENT RATHER THAN A LABEL WITH A SLASH IN IT. Every control legend this codebase has
	written so far has been one long TextLabel: `W/S throttle  ·  A/D steer  ·  [E] to let go`. That is
	the shape a legend takes when nobody has decided it is UI yet, and it fails three of this project's
	own rules at once -- docs/ui-ux-philosophy.md asks for "high contrast information hierarchy" and
	"clean spacing" and gets one undifferentiated grey run; the key and its meaning are typeset
	identically, so the thing a player is scanning for has no more visual weight than the prose around
	it; and it cannot express state, so a toggle that is currently ON looks exactly like one that is
	off.

	THE KEY COLUMN IS FIXED WIDTH AND THAT IS THE WHOLE POINT OF THE LAYOUT. Every hint in a stack
	shares one cap-column width, so the descriptions form a single flush left edge no matter whether a
	row's trigger is one key or three. A row-by-row natural width would ripple every label a few pixels
	sideways and produce exactly the "unintentional placement" the philosophy doc's "every element
	should appear intentionally placed" rule is about. The column width is a prop rather than measured
	here, because only the caller knows what the widest row in ITS stack is -- see Screens/BlimpHelm.

	ACTIVE IS A REAL STATE, NOT A COLOR SWAP. A hint whose action is currently engaged (autopilot
	holding, a mode latched) lights its caps AND brightens its description AND, when the caller gives
	one, swaps in different words -- so the state survives docs/ui-ux-philosophy.md's Critical States
	rule, which forbids relying on color alone. A caller that has no state to show simply omits both
	props and gets a static row.

	Does not own: the cap itself. That was a private helper here until a third surface wanted one and
	Components/KeyCap.lua was extracted (see that file's header for the two tone registers and why
	both survived the extraction); this file owns the ROW -- the fixed cap column, the description
	beside it, and the Active text swap -- and hands each cap's own drawing to that component.

	Does not own: what any key is bound to. A row is named by raw strings (`Keys`), by rebindable
	actions (`Actions`), or by contextual per-device bindings (`Bindings`) -- exactly one of the three,
	never a mix -- and it resolves none of them itself: both of the latter two hand the question to
	Components/KeyCap.lua, which hands it to Client/Input/Glyph.lua. The exclusivity is per-ROW rather
	than per-panel precisely because one legend can need more than one kind at once.

	`Keys` IS NOW THE NARROWEST OF THE THREE, and that is a correction rather than a deprecation. It
	was the only way to name the helm's steering keys, which are deliberately raw (see
	Client/Blimp/BlimpController.lua's header on why they are not KeybindActions) -- but a raw STRING
	is a keyboard key, so that legend told a player holding a controller to press W. `Bindings` is what
	those rows want; `Keys` is left for a cap naming something with no per-device answer at all.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Tokens = require(script.Parent.Parent.Tokens)
local Types = require(ReplicatedStorage.Shared.Types)
local Glyph = require(script.Parent.Parent.Parent.Input.Glyph)
local KeyCap = require(script.Parent.KeyCap)
local Label = require(script.Parent.Label)

local Children = Fusion.Children

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>

export type KeyHintProps = {
	-- The caps, left to right. Two entries render as two separate caps with a hairline gap rather
	-- than as one cap reading "W/S" -- they are two keys, and a legend that draws them as one is
	-- telling the player to press something that does not exist.
	--
	-- Each cap's TEXT is reactive even though the LIST is not: a legend's shape is fixed at build time
	-- (a row is two keys or it is one), but a row naming a rebindable action has to be able to change
	-- its glyph when the player rebinds it without the panel being torn down and rebuilt.
	--
	-- Optional only because `Actions` below can supply the caps instead; exactly one of the two must
	-- be given.
	Keys: { UsedAs<string> }?,
	-- PREFER THIS over Keys for anything a player presses. A Key is a KEYBOARD key: a row built from
	-- Keys shows W/S/A to a player holding a controller, which is exactly what
	-- Screens/BlimpHelm/init.lua's hardcoded literals did. An Action-driven cap resolves against
	-- whichever device is in the player's hands and re-resolves on both a device switch and a rebind,
	-- with no subscription needed here or at the call site -- see Components/KeyCap.lua's own header.
	--
	-- Same fixed-list/reactive-glyph split Keys documents above: WHICH actions a row names is decided
	-- at build time, what each one currently draws is not.
	Actions: { Types.KeybindAction }?,
	-- The third way to name a row, for CONTEXTUAL controls -- keys that are real and pressable but are
	-- deliberately not Types.KeybindActions, so `Actions` cannot name them and `Keys` can only ever
	-- name them for one device. The blimp helm's whole legend is this: its throttle, rudder, all-stop
	-- and autopilot are read only while a player is holding a wheel (see Client/Blimp/BlimpController.
	-- lua's header for why they are not rebindable actions), and until this prop existed that legend
	-- drew the literal string "W" at a player holding a controller.
	--
	-- Same fixed-list/reactive-glyph split as the two above, and the same per-ROW exclusivity: a row is
	-- named by exactly one of Keys/Actions/Bindings. Per-row rather than per-panel because the helm
	-- legend genuinely needs two kinds at once -- see this file's header.
	Bindings: { Glyph.Binding }?,
	Text: UsedAs<string>,
	-- Shown INSTEAD of Text while Active. Omit for a row with no state of its own.
	ActiveText: UsedAs<string>?,
	Active: UsedAs<boolean>?,
	-- Shared across every row in one stack so the descriptions line up -- see file header.
	KeyColumnWidth: number,
	-- This row's own height. Defaults to ROW_HEIGHT below, which is what every legend inside a
	-- corner console wants and what every caller passed by omission until now.
	--
	-- IT IS A PROP SO A CALLER CAN SIZE A CONTAINER AROUND IT. A panel that cannot use
	-- AutomaticSize -- a chamfered one, since Components/Panel.lua's own header records that the two
	-- are incompatible -- has to state its height as a literal sum of its children's. Reading that
	-- sum off a private constant in THIS file would be exactly the silently-invalidated allowance
	-- CLAUDE.md's Stack entry warns about: a one-pixel change here would leave the caller clipping
	-- with no error anywhere. Passing the number IN means the caller's arithmetic and the row's
	-- actual height are the same value by construction. Screens/FurnacePrompt is the first such
	-- caller.
	RowHeight: number?,
	Visible: UsedAs<boolean>?,
	LayoutOrder: UsedAs<number>?,
}

-- DENSE ON PURPOSE. The one surface using this is a corner console the size of a minimap, sat over
-- live gameplay -- docs/ui-ux-philosophy.md's HUD rule is "minimal, informative, out of the player's
-- way", and a legend that eats a sixth of the screen fails the third of those however well it reads.
-- Every metric here is the smallest that still leaves a cap unmistakably a KEY rather than a letter.
local ROW_HEIGHT = 17
local CAP_HEIGHT = 15
-- Wide enough for one glyph plus its padding; a longer cap ("SPACE", "SHIFT") grows past it on its
-- own via AutomaticSize.X, which is why this is a MINIMUM rather than a size.
local CAP_MIN_WIDTH = 17
local CAP_GAP = 3

local function KeyHint(scope: Scope, props: KeyHintProps): Frame
	local named = (if props.Keys ~= nil then 1 else 0)
		+ (if props.Actions ~= nil then 1 else 0)
		+ (if props.Bindings ~= nil then 1 else 0)
	assert(
		named == 1,
		"KeyHint needs exactly one of Keys, Actions or Bindings -- see KeyHintProps on which to reach for"
	)

	local active: UsedAs<boolean> = props.Active or false

	local caps: { Instance } = {
		scope:New "UIListLayout" {
			FillDirection = Enum.FillDirection.Horizontal,
			Padding = UDim.new(0, CAP_GAP),
			SortOrder = Enum.SortOrder.LayoutOrder,
			VerticalAlignment = Enum.VerticalAlignment.Center,
		},
	}
	-- One loop over whichever list was given -- the cap itself takes Key, Action or Binding and asserts
	-- the same exclusivity, so no branch here needs to know what the others render.
	local capCount = if props.Actions ~= nil
		then #(props.Actions :: { Types.KeybindAction })
		elseif props.Bindings ~= nil then #(props.Bindings :: { Glyph.Binding })
		else #(props.Keys :: { UsedAs<string> })
	for index = 1, capCount do
		table.insert(
			caps,
			KeyCap(scope, {
				Name = `Cap{index}`,
				Key = if props.Keys ~= nil then (props.Keys :: { UsedAs<string> })[index] else nil,
				Action = if props.Actions ~= nil then (props.Actions :: { Types.KeybindAction })[index] else nil,
				Binding = if props.Bindings ~= nil then (props.Bindings :: { Glyph.Binding })[index] else nil,
				Active = active,
				LayoutOrder = index,
				MinWidth = CAP_MIN_WIDTH,
				Height = CAP_HEIGHT,
			})
		)
	end

	local text: UsedAs<string> = if props.ActiveText
		then scope:Computed(function(use)
			return if use(active) then use(props.ActiveText :: UsedAs<string>) else use(props.Text)
		end)
		else props.Text

	return scope:New "Frame" {
		Name = "KeyHint",
		Size = UDim2.new(1, 0, 0, props.RowHeight or ROW_HEIGHT),
		BackgroundTransparency = 1,
		Visible = props.Visible,
		LayoutOrder = props.LayoutOrder,

		[Children] = {
			scope:New "Frame" {
				Name = "Keys",
				Size = UDim2.new(0, props.KeyColumnWidth, 1, 0),
				BackgroundTransparency = 1,
				[Children] = caps,
			},
			Label(scope, {
				Text = text,
				-- CHIP, NOT Detail, AND THE CHANGE IS THE POINT OF THIS ROW'S TYPOGRAPHY. Detail is
				-- the smallest PROSE step -- 13px Regular, the face this UI sets paragraphs in -- and
				-- a legend description is not prose. It is a LABEL naming a control, sat beside a
				-- bold uppercase cap, and setting it in prose type inverted the hierarchy: the thing
				-- the player scans for (the key) was rendering SMALLER and lighter than the
				-- explanation next to it. Chip is the same 11px bold step the cap's own glyph uses,
				-- so a row now reads as one object at one weight rather than as a key with a
				-- sentence stuck to it.
				--
				-- It is also what stopped the descriptions overflowing. MEASURED 2026-08-25 against a
				-- real render pass, in the two-column grid Screens/BlimpHelm lays these out in:
				-- "Telegraph" is 47px at Detail against 38px of column, so it ran under the next
				-- cell's caps, and the Active swap "Autopilot on" was 58px into the same 38. At Chip
				-- the widest description on that panel is 42px against 47px of column.
				--
				-- Chip carries Tracking = 1, which only Components/TrackedLabel.lua honours; this text
				-- is reactive (it swaps on Active) so it cannot go through that component, and gets
				-- Chip's face and size without its tracking. That is the same trade every reactive
				-- caps label in this codebase makes, and at 11px bold the tracking was never what was
				-- carrying legibility here.
				Scale = "Chip",
				Color = scope:Computed(function(use)
					return if use(active) then Tokens.Color.AccentPrimaryBright else Tokens.Color.TextSecondary
				end),
				-- Offset by the column width plus a gap rather than laid out beside the caps: the row
				-- has exactly two children and a fixed left column, so absolute placement is both
				-- simpler than a second list layout and immune to the caps' AutomaticSize changing
				-- the description's start edge -- which is the flush left edge this component exists
				-- to guarantee.
				--
				-- Space.XS rather than Space.S, for the four pixels: this component is DENSE ON
				-- PURPOSE (see the metrics block above) and its one caller lays it out in an 88px
				-- grid cell, where eight pixels of gutter between a cap and its own label is width
				-- spent on nothing. At 11px bold, four still separates them cleanly.
				Position = UDim2.fromOffset(props.KeyColumnWidth + Tokens.Space.XS, 0),
				Size = UDim2.new(1, -(props.KeyColumnWidth + Tokens.Space.XS), 1, 0),
			}),
		},
	} :: Frame
end

return KeyHint
