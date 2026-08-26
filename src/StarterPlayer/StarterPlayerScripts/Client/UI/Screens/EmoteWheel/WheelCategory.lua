--!strict
--[[
	WheelCategory.lua

	Owns: the one mapping from a Types.EmoteCategory to the token colour that stands for it on the
	wheel -- read by WheelSegment.lua (the slot's category mark) and WheelHub.lua (the readout's
	eyebrow), which is exactly why it is its own file rather than a table inside either of them: two
	surfaces showing the same emote in the same instant, disagreeing about what colour "Greeting" is,
	is the specific bug this closes before it happens.

	WHY A CATEGORY MARK AND NOT AN ICON. Every entry in Shared/Emotes/EmoteDefinitions.lua ships with
	Icon = "" today, and this codebase never fabricates a plausible-looking asset id (see that file's
	own header). A per-emote icon therefore cannot be drawn at all yet. A per-CATEGORY mark can,
	because a category is real authored data on every definition -- so the wheel gets a genuine second
	information channel (a row of eight identical text tiles becomes eight tiles a player can tell
	apart at a glance by hue) without inventing a single asset. WheelSegment.lua's IconAssetId prop is
	still the branch point for the day real icons exist; the mark is what sits there until then.

	Every colour here is a Tokens.lua reference, never a literal -- docs/ui-ux-philosophy.md's
	"Colors, spacing, and type come from Tokens.lua exclusively" rule applies to a lookup table as
	much as to a component body. The hues are picked so that no two categories a player is likely to
	hold at once (the eight-entry EmoteConstants.DefaultLoadout spans Greeting/Social/Reaction/
	Sitting/Dance) land on neighbouring hues.

	UNKNOWN CATEGORIES RESOLVE, THEY DO NOT ERROR. Types.EmoteCategory is a compile-time union and
	EmoteConstants.Categories is its runtime allow-list, but this file is a THIRD place that has to
	be kept in step with both, and the failure mode if someone adds a seventh category and misses this
	one must be "the mark is violet" and not "the emote wheel throws while the player is holding it
	open". Tint() therefore always returns a colour.

	Does not own: what a category means (Shared/Emotes/EmoteDefinitions.lua authors it per emote), or
	validating that a category is legal (Shared/Emotes/EmoteRegistry.lua's Validate).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage.Shared.Types)

local Tokens = require(script.Parent.Parent.Parent.Tokens)

local WheelCategory = {}

local TINTS: { [string]: Color3 } = {
	Greeting = Tokens.Color.FactionCelestial,
	Social = Tokens.Color.AccentPrimary,
	Reaction = Tokens.Color.Warning,
	Dance = Tokens.AttributeColor.Pressure,
	Sitting = Tokens.Color.TextSecondary,
	Rare = Tokens.Color.AccentSecondary,
}

local FALLBACK_TINT = Tokens.Color.AccentPrimary

-- The token colour standing for `category` on the wheel. Never errors and never returns nil -- see
-- this file's header on why that matters for a surface a player holds open with a key.
function WheelCategory.Tint(category: Types.EmoteCategory?): Color3
	if category == nil then
		return FALLBACK_TINT
	end
	return TINTS[category] or FALLBACK_TINT
end

-- The category as it is rendered in a tracked-caps eyebrow. Kept here beside Tint so a caller never
-- has to decide between `string.upper(definition.Category)` at one call site and something else at
-- the next, and so the empty/no-selection case answers once, in one place.
function WheelCategory.Label(category: Types.EmoteCategory?): string
	if category == nil then
		return ""
	end
	return string.upper(category)
end

return WheelCategory
