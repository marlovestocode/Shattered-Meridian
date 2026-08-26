--!strict
--[[
	BloodlineConstants.lua

	Owns: every tuning number and remote name the bloodline SPIN uses -- how many rerolls a player
	starts with, how a BloodlineDefinition.RarityTier turns into a draw weight, and the one remote
	the onboarding creator calls.

	Its own file rather than a Constants.lua section, matching Shared/ArtConstants.lua's own
	precedent for the sibling progression layer, and sitting next to BloodlineTypes.lua because
	RarityWeights below only means anything in terms of that module's RarityTier field.

	WEIGHTS LIVE HERE, NOT ON THE DEFINITION, and that is the whole design decision worth stating.
	BloodlineDefinition.RarityTier is deliberately a FREE-FORM string ("Common", "Rare",
	"Ascendant", ...) -- its own header calls it "purely a list-UI grouping aid, never read by
	resolution logic". Giving every definition its own numeric Weight instead would make the odds
	un-auditable: an author tuning one bloodline's weight in the Kit Editor would silently shift
	every other bloodline's real probability, because a weighted draw is relative. A tier -> weight
	table keeps the odds readable in ONE place and makes "how rare is Ascendant" a question with an
	answer, while leaving authors the free-form tag they already have.

	An UNRECOGNISED tier is not an error -- it draws at DefaultWeight. RarityTier is free-form by
	contract, so a spin must never crash or silently exclude a bloodline because someone typed a tier
	this table has not heard of; it draws at the commonest rate and shows up in a log.

	Does not own: what a bloodline IS or does (BloodlineTypes/BloodlineManager), who may awaken one
	(BloodlineSystem.Awaken already enforces NativeRaceId and the already-awakened rule), or when the
	spin UI appears (Client/Onboarding).
]]

local BloodlineConstants = {}

-- Client -> server, RemoteFunction: roll one bloodline for the calling player. A RemoteFunction and
-- not a fire-and-forget event because the creator has to render what was rolled and how many
-- rerolls remain -- a silently-ignored spin would leave the button looking broken.
BloodlineConstants.RemoteNames = {
	Spin = "Bloodline_Spin",
}

-- Rerolls a brand-new profile starts with, ON TOP of the first free roll. So a player gets
-- 1 + StartingRerolls total chances during onboarding before the button runs dry.
--
-- 3 rather than 0 or 99: enough that a player who rolls something they dislike is not stuck with
-- their very first result, few enough that the roll still means something. Nothing grants more yet
-- -- see PlayerProfile.bloodlineRerolls' own header on why that is a deliberate stub rather than an
-- oversight.
BloodlineConstants.StartingRerolls = 3

-- Hard ceiling on how many rerolls one profile may hold at once. Nothing in normal play can reach
-- it -- StartingRerolls is 3 and no live-ops path grants more yet -- so this exists purely as a sane
-- bound on the one thing that CAN grant them: BloodlineSystem.GrantRerolls, called from the admin
-- menu. A held button, a stuck client, or a fat-fingered amount should top out at a number a
-- DataStore is happy to round-trip, not climb until the profile write starts failing on a value it
-- cannot represent exactly.
BloodlineConstants.MaxHeldRerolls = 99

-- How many rerolls the dev menu's own grant button hands out per press. Five rather than one so a
-- tester can actually exercise the reroll flow (which REPLACES a bloodline each time -- see
-- BloodlineSystem.Spin) several times without walking back to the menu, and rather than "fill to
-- max" so the count still visibly moves and the ceiling above stays testable.
BloodlineConstants.DevGrantRerollAmount = 5

-- RarityTier -> relative draw weight. Bigger is commoner. These are RELATIVE, never percentages:
-- the spin sums the weights of everything actually eligible for that player and draws in proportion,
-- so the real odds shift with how many bloodlines are authored at each tier -- which is correct, and
-- is why no percentage is written down here to go stale.
BloodlineConstants.RarityWeights = {
	Common = 100,
	Uncommon = 45,
	Rare = 18,
	Legendary = 5,
	Ascendant = 1,
} :: { [string]: number }

-- What an unrecognised RarityTier draws at -- see this file's header on why this is a fallback
-- rather than a rejection. Matches Common: a tier nobody has assigned odds to should be the LEAST
-- surprising outcome, never accidentally the rarest.
BloodlineConstants.DefaultWeight = 100

-- Resolves a tier string to its weight, falling back as described above. A function rather than a
-- raw table read so every caller gets the fallback -- there is exactly one way to ask this question.
function BloodlineConstants.WeightFor(rarityTier: string): number
	return BloodlineConstants.RarityWeights[rarityTier] or BloodlineConstants.DefaultWeight
end

return BloodlineConstants
