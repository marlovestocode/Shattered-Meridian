--!strict
--[[
	LegibleText.lua

	Owns: one pass that makes every piece of text under a root a step bolder and a pixel larger -- for a dense
	tool panel (the Move Editor) whose body copy is Tokens.Type's 12-14px Regular/Medium, which is the register
	the player-facing HUD is tuned for and is too thin for a screen full of small labels and numbers.

	WHY A PASS AND NOT A TOKEN. Tokens.Type is read by ~a dozen shared components (NumericField, Tab, Toggle,
	Dropdown, StatRow, TextField...) at the moment they build, and none of them take a "denser register" prop.
	Raising the steps themselves would re-letter the whole game's UI, hand-measured heights and all; threading
	a prop through every component would be a dozen API changes for one screen. This restyles the TEXT
	INSTANCES instead, once each, as they join the root -- including the lazily built pages, which arrive long
	after mount.

	WHAT IT TOUCHES: FontFace weight (anything lighter than SemiBold becomes SemiBold -- Bold and the serif
	display faces are already heavy and are left alone) and TextSize (+Boost, only below LARGE_FROM, so a
	22px numeral or a 28px title does not grow). NOTHING ELSE. Colour, transparency and position stay with
	the component that owns them, which is also why it is safe against Fusion: no component binds FontFace or
	TextSize reactively (they are all set once, at build), so there is no later write to fight. A component
	that ever does must opt out with the NoLegible attribute.

	EACH INSTANCE IS RESTYLED ONCE, marked with an attribute, so a re-parent or a second Apply over the same
	root cannot compound the boost.

	A layout that measures its text with a constant (Fields.lua's chipWidth) must budget for the boost; the
	constants there say so.

	Does not own: the panel's scale (ViewportScale.Reflow), or which screens use it.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)

type Scope = Fusion.Scope<typeof(Fusion)>

local LegibleText = {}

local MARKER = "LegibleApplied"
-- A text instance carrying this attribute (any value) is never restyled.
local OPT_OUT = "NoLegible"
-- Text at or above this size is a title or a hero numeral: it is already legible, and growing it is what
-- breaks a hand-measured layout.
local LARGE_FROM = 16
local DEFAULT_BOOST = 1
local FLOOR_WEIGHT = Enum.FontWeight.SemiBold

local function isText(instance: Instance): boolean
	return instance:IsA("TextLabel") or instance:IsA("TextButton") or instance:IsA("TextBox")
end

local function restyle(instance: Instance, boost: number): ()
	if not isText(instance) or instance:GetAttribute(MARKER) or instance:GetAttribute(OPT_OUT) then
		return
	end
	instance:SetAttribute(MARKER, true)
	local text = instance :: TextLabel
	local face = text.FontFace
	if face.Weight.Value < FLOOR_WEIGHT.Value then
		text.FontFace = Font.new(face.Family, FLOOR_WEIGHT, face.Style)
	end
	if text.TextSize < LARGE_FROM then
		text.TextSize += boost
	end
end

-- Restyles everything under `root` now and everything added to it later, until `scope` is cleaned.
function LegibleText.Apply(scope: Scope, root: Instance, boost: number?): ()
	local amount = boost or DEFAULT_BOOST
	for _, descendant in root:GetDescendants() do
		restyle(descendant, amount)
	end
	table.insert(
		scope,
		root.DescendantAdded:Connect(function(descendant: Instance)
			restyle(descendant, amount)
		end)
	)
end

return LegibleText
