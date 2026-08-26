--!strict
--[[
	DefaultBloodlineRegistry.lua

	Owns: the thirteen hand-authored bloodlines the game ships with -- world-bible.md's "Thirteen
	bloodlines exist" is a fixed canon count (Constants.BloodlineCount = 13), and this is where that
	roster actually lives. The Kit Editor can still add or override on top, exactly as
	DefaultMoveRegistry and the Move Editor relate for moves.

	ITS OWN BOOT STEP, immediately after BloodlineManager. Not folded into BloodlineManager.Init,
	which resets the registry to EMPTY and is relied on for exactly that by BloodlineManager.spec's
	per-test clean slate -- seeding from there would make every count assertion in that file depend
	on the size of this roster. A separate step also puts the seed in the boot log where it belongs.

	It exists because there was no code-side source of bloodline content AT ALL. The only way a
	bloodline could reach the registry was a Kit Editor record in a DataStore, so a fresh server
	booted with zero bloodlines and every downstream reader -- the spin, the on-kill advancement, the
	character sheet's own bloodline line -- degraded quietly against an empty roster.

	HOW A BLOODLINE IS OBTAINED VS. ADVANCED, because they are deliberately different and the canon
	is specific about only one of them:

	  * OBTAINED by the roll at character creation (BloodlineSystem.Spin). Blood is luck. You do not
	    earn what already runs in you, and nothing in the canon says you should.
	  * ADVANCED by combat, one stage at a time (BloodlineSystem's own OnPlayerKilled dispatch
	    against AwakeningCondition.Params.RequiredKills). This is the half progression-systems.md
	    pins down: "a real in-combat achievement, not a purchase or timer -- reinforcing
	    fight-to-grow." Every RequiredKills below is therefore a PER-STAGE-STEP cost, not a one-time
	    unlock price.

	RARITY BUYS A LONGER LADDER, NOT A BIGGER NUMBER. progression-systems.md: "each stage is a new
	kit tool, not just a number increase." So a rarer bloodline gets MORE STAGES and a HARDER
	per-step kill cost -- not merely larger deltas on the same two stages. A Common bloodline settles
	in two stages; the Ascendant one takes four and asks twenty kills for each.

	NativeRaceId is what the spin's own eligibility filter reads (BloodlineSystem.EligibleForSpin).
	Seven bloodlines are race-agnostic; Firmborn, Rivenkin and Hollowborn get two natives each, so
	those three roll from a pool of nine. The majority being race-agnostic is deliberate -- a roster
	where most blood was race-locked would make the roll feel like chargen had already chosen for you.

	HUMAN HAS NO NATIVE BLOODLINE, and that is the point rather than an omission. world-bible.md and
	Constants.RaceWorldLines both say it outright -- "No fragment of the old Meridian marked you
	before birth" -- so a bloodline that belonged to Humans by birth would contradict the one thing
	their identity is built on. They roll the seven shared lineages, which is also what makes every
	Human draw an Unbound one in spirit: blood that was never supposed to be theirs.

	RACE FLAVOR, NOT FACTION ASSIGNMENT. Constants.lua's own RaceWorldLines header is explicit that
	the per-race lore deliberately stops short of "asserting new binding canon (faction ties, detailed
	sub-history)". This file holds that same line: each native bloodline is written against its
	race's ESTABLISHED identity (Firmborn held their ground and the ground held back; Rivenkin were
	already moving when the world cracked; Hollowborn's fragment burns near the surface; Human is
	unwritten) and against the three factional inheritances as INHERITANCES, never by declaring that
	a given race belongs to a given sect.

	THE ONE NAMED BLOODLINE IN THE CANON IS TIANLONG -- world-bible.md names it as a dragon-vein
	lineage and uses it for the contested-authority example: "a Human awakening a dragon-vein
	bloodline like Tianlong is framed as contested authority, not inherited birthright." It is
	authored here as race-agnostic (so a Human CAN draw it) with RequiresAscended on its advancement,
	which is the existing Human Ascension gate doing exactly the job its own header describes: the
	blood sits in you from the roll, and refuses to advance until you have ascended. The difficulty
	gap tells the story, which is what progression-systems.md asks for.

	Does not own: validation (BloodlineManager.Validate re-checks every entry here through the exact
	same function a Kit Editor submission goes through -- see Seed below on why that matters), the
	stage effects' runtime (EffectSystem), or persistence (nothing here is written to a DataStore).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage.Shared.Types)
local Constants = require(ReplicatedStorage.Shared.Constants)
local Logger = require(ReplicatedStorage.Shared.Logger)
local BloodlineManager = require(script.Parent.BloodlineManager)

local DefaultBloodlineRegistry = {}

local logger = Logger.scope("DefaultBloodlineRegistry")

-- Per-stage-step kill costs by rarity. Named rather than inlined thirteen times so the ladder's
-- shape is legible in one place, and so a balance pass is one edit per tier instead of thirteen.
local KILLS = {
	Common = 3,
	Uncommon = 5,
	Rare = 8,
	Legendary = 12,
	Ascendant = 20,
}

-- Shorthands for the two effect shapes this roster uses. EffectSystem's third kind (QiRestore) is
-- only meaningful as an Instant on an Active ability, so it is spelled out at the one site that
-- wants it rather than given a helper nothing else calls.
local function bound(attributeKey: string, delta: number): any
	return { Kind = "AttributeDelta", Lifetime = "Bound", AttributeKey = attributeKey, Delta = delta }
end

local function timed(attributeKey: string, delta: number, durationSeconds: number): any
	return {
		Kind = "AttributeDelta",
		Lifetime = "Timed",
		AttributeKey = attributeKey,
		Delta = delta,
		DurationSeconds = durationSeconds,
	}
end

-- Every authored bloodline, in rarity order (commonest first) so the roster reads as a ladder.
-- Written as plain tables rather than typed ones: every entry goes through BloodlineManager.Validate
-- in Seed below, which is the real contract, and a type annotation here would only assert agreement
-- that the validator already proves.
local BLOODLINES: { any } = {
	--
	-- Common -- four, race-agnostic-leaning, two stages each.
	--
	{
		BloodlineId = "emberline",
		DisplayName = "Emberline",
		RarityTier = "Common",
		FlavorText = "The commonest inheritance there is: a fragment that never went out. It warms the "
			.. "meridians rather than filling them, and it asks almost nothing of the body that carries it.",
		AwakeningCondition = { Kind = "OnPlayerKilled", Params = { RequiredKills = KILLS.Common } },
		Stages = {
			{
				StageIndex = 1,
				DisplayName = "Banked Coal",
				PassiveEffects = { bound("Vitality", 2) },
			},
			{
				StageIndex = 2,
				DisplayName = "Open Flame",
				PassiveEffects = { bound("Vitality", 3), bound("Might", 1) },
				GrantedAbility = {
					Id = "emberline_flare",
					DisplayName = "Flare",
					Description = "Spend the banked heat at once. Might rises sharply for a short window.",
					Kind = "Active",
					CooldownSeconds = 45,
					QiCost = 20,
					Effects = { timed("Might", 6, 8) },
				},
			},
		},
	},
	{
		BloodlineId = "stillwater_vein",
		DisplayName = "Stillwater Vein",
		RarityTier = "Common",
		FlavorText = "A fragment that settled instead of scattering. Its carriers are hard to rush and "
			.. "harder to break -- the Celestial inheritance at its plainest, patience without ceremony.",
		AwakeningCondition = { Kind = "OnPlayerKilled", Params = { RequiredKills = KILLS.Common } },
		Stages = {
			{
				StageIndex = 1,
				DisplayName = "Level Surface",
				PassiveEffects = { bound("Fortitude", 2) },
			},
			{
				StageIndex = 2,
				DisplayName = "Deep Water",
				PassiveEffects = { bound("Fortitude", 4) },
				GrantedAbility = {
					Id = "stillwater_hold",
					DisplayName = "Hold",
					Description = "Refuse to be moved. Fortitude rises steeply while it lasts.",
					Kind = "Active",
					CooldownSeconds = 50,
					QiCost = 25,
					Effects = { timed("Fortitude", 8, 6) },
				},
			},
		},
	},
	{
		BloodlineId = "gutterlight",
		DisplayName = "Gutterlight",
		RarityTier = "Common",
		FlavorText = "Meridian dust that pooled where nobody was looking, in the low places of the "
			.. "Median Paradise. Unglamorous, widespread, and quietly generous to whoever ends up with it.",
		AwakeningCondition = { Kind = "OnPlayerKilled", Params = { RequiredKills = KILLS.Common } },
		Stages = {
			{
				StageIndex = 1,
				DisplayName = "Guttering",
				PassiveEffects = { bound("MeridianFlow", 2) },
			},
			{
				StageIndex = 2,
				DisplayName = "Steady Burn",
				PassiveEffects = { bound("MeridianFlow", 4) },
				GrantedAbility = {
					Id = "gutterlight_draw",
					DisplayName = "Draw Up",
					Description = "Pull on the pooled light. Restores a portion of your Qi at once.",
					Kind = "Active",
					CooldownSeconds = 60,
					QiCost = 0,
					Effects = { { Kind = "QiRestore", Lifetime = "Instant", QiRestoreAmount = 60 } },
				},
			},
		},
	},
	{
		BloodlineId = "pathstone",
		DisplayName = "Pathstone",
		RarityTier = "Common",
		FlavorText = "The blood of people who stayed put. It reads as stubbornness until the ground "
			.. "starts moving, and then it reads as the only sensible thing anyone did.",
		NativeRaceId = "Firmborn",
		AwakeningCondition = { Kind = "OnPlayerKilled", Params = { RequiredKills = KILLS.Common } },
		Stages = {
			{
				StageIndex = 1,
				DisplayName = "Footing",
				PassiveEffects = { bound("Fortitude", 3) },
			},
			{
				StageIndex = 2,
				DisplayName = "Bedrock",
				PassiveEffects = { bound("Fortitude", 5), bound("Vitality", 2) },
				GrantedAbility = {
					Id = "pathstone_setstance",
					DisplayName = "Set Stance",
					Description = "Take the Stonepath's own footing. Posture and health hold far better, briefly.",
					Kind = "Active",
					CooldownSeconds = 55,
					QiCost = 25,
					Effects = { timed("Fortitude", 7, 7), timed("Vitality", 5, 7) },
				},
			},
		},
	},

	--
	-- Uncommon -- three, three stages each.
	--
	{
		BloodlineId = "fracture_step",
		DisplayName = "Fracture Step",
		RarityTier = "Uncommon",
		FlavorText = "Inherited from those who were already running when the Meridian broke. The "
			.. "fragment never quite settled, and neither do they.",
		NativeRaceId = "Rivenkin",
		AwakeningCondition = { Kind = "OnPlayerKilled", Params = { RequiredKills = KILLS.Uncommon } },
		Stages = {
			{
				StageIndex = 1,
				DisplayName = "Loose Footing",
				PassiveEffects = { bound("Fleetness", 3) },
			},
			{
				StageIndex = 2,
				DisplayName = "Running Crack",
				PassiveEffects = { bound("Fleetness", 5), bound("Might", 2) },
			},
			{
				StageIndex = 3,
				DisplayName = "Never Stopped",
				PassiveEffects = { bound("Fleetness", 8), bound("Might", 3) },
				GrantedAbility = {
					Id = "fracture_step_run",
					DisplayName = "Run The Line",
					Description = "Follow the fracture wherever it goes. Movement and strikes both sharpen.",
					Kind = "Active",
					CooldownSeconds = 60,
					QiCost = 35,
					Effects = { timed("Fleetness", 10, 8), timed("Might", 5, 8) },
				},
			},
		},
	},
	{
		BloodlineId = "sablecourt",
		DisplayName = "Sablecourt",
		RarityTier = "Uncommon",
		FlavorText = "A Demonic inheritance with manners. It grows faster than it should and is polite "
			.. "about the bill until the moment it isn't -- strength through what the Firmament forbids.",
		AwakeningCondition = { Kind = "OnPlayerKilled", Params = { RequiredKills = KILLS.Uncommon } },
		Stages = {
			{
				StageIndex = 1,
				DisplayName = "Invitation",
				PassiveEffects = { bound("Might", 3) },
			},
			{
				StageIndex = 2,
				DisplayName = "Accepted Terms",
				PassiveEffects = { bound("Might", 5), bound("Pressure", 2) },
			},
			{
				StageIndex = 3,
				DisplayName = "The Bill",
				-- The two-sided trade this bloodline's flavor promises: real offensive power, paid
				-- for out of the body carrying it. The only negative Bound delta in the roster.
				PassiveEffects = { bound("Might", 9), bound("Pressure", 4), bound("Vitality", -3) },
				GrantedAbility = {
					Id = "sablecourt_collect",
					DisplayName = "Collect",
					Description = "Call in what you are owed. Enormous pressure for a short, expensive window.",
					Kind = "Active",
					CooldownSeconds = 75,
					QiCost = 45,
					Effects = { timed("Pressure", 12, 6), timed("Might", 6, 6) },
				},
			},
		},
	},
	{
		BloodlineId = "hollow_choir",
		DisplayName = "Hollow Choir",
		RarityTier = "Uncommon",
		FlavorText = "Their fragment sits close enough to the surface to hum. Carriers describe it as "
			.. "being one voice in something much larger that has not finished arriving.",
		NativeRaceId = "Hollowborn",
		AwakeningCondition = { Kind = "OnPlayerKilled", Params = { RequiredKills = KILLS.Uncommon } },
		Stages = {
			{
				StageIndex = 1,
				DisplayName = "First Voice",
				PassiveEffects = { bound("MeridianFlow", 4) },
			},
			{
				StageIndex = 2,
				DisplayName = "Answering",
				PassiveEffects = { bound("MeridianFlow", 7) },
			},
			{
				StageIndex = 3,
				DisplayName = "Full Choir",
				PassiveEffects = { bound("MeridianFlow", 11), bound("Pressure", 3) },
				GrantedAbility = {
					Id = "hollow_choir_swell",
					DisplayName = "Swell",
					Description = "Let the choir rise. Qi returns in a rush and the pressure of it lands on whoever is close.",
					Kind = "Active",
					CooldownSeconds = 65,
					QiCost = 0,
					Effects = {
						{ Kind = "QiRestore", Lifetime = "Instant", QiRestoreAmount = 120 },
						timed("Pressure", 8, 6),
					},
				},
			},
		},
	},

	--
	-- Rare -- three, three stages each, one native to each of the three non-Human races.
	--
	{
		BloodlineId = "iron_liturgy",
		DisplayName = "Iron Liturgy",
		RarityTier = "Rare",
		FlavorText = "Ordered qi kept as a discipline rather than a gift -- the Firmament's own habit "
			.. "of turning power into procedure. It rewards patience and punishes improvisation.",
		NativeRaceId = "Firmborn",
		AwakeningCondition = { Kind = "OnPlayerKilled", Params = { RequiredKills = KILLS.Rare } },
		Stages = {
			{
				StageIndex = 1,
				DisplayName = "First Rite",
				PassiveEffects = { bound("Fortitude", 4), bound("Pressure", 2) },
			},
			{
				StageIndex = 2,
				DisplayName = "Observed Form",
				PassiveEffects = { bound("Fortitude", 7), bound("Pressure", 4) },
			},
			{
				StageIndex = 3,
				DisplayName = "Full Liturgy",
				PassiveEffects = { bound("Fortitude", 11), bound("Pressure", 7) },
				GrantedAbility = {
					Id = "iron_liturgy_recite",
					DisplayName = "Recite",
					Description = "Hold the form exactly. Guard-breaking pressure climbs for as long as you keep it.",
					Kind = "Active",
					CooldownSeconds = 70,
					QiCost = 40,
					Effects = { timed("Pressure", 14, 10) },
				},
			},
		},
	},
	{
		BloodlineId = "riven_mirror",
		DisplayName = "Riven Mirror",
		RarityTier = "Rare",
		FlavorText = "A fragment that split along the same lines the world did, and kept both halves. "
			.. "Carriers are quick in a way that reads as two people taking turns.",
		NativeRaceId = "Rivenkin",
		AwakeningCondition = { Kind = "OnPlayerKilled", Params = { RequiredKills = KILLS.Rare } },
		Stages = {
			{
				StageIndex = 1,
				DisplayName = "Hairline",
				PassiveEffects = { bound("Fleetness", 4), bound("Might", 2) },
			},
			{
				StageIndex = 2,
				DisplayName = "Split Image",
				PassiveEffects = { bound("Fleetness", 7), bound("Might", 4) },
			},
			{
				StageIndex = 3,
				DisplayName = "Both Halves",
				PassiveEffects = { bound("Fleetness", 10), bound("Might", 7) },
				GrantedAbility = {
					Id = "riven_mirror_double",
					DisplayName = "Take Turns",
					Description = "Let both halves move at once. Speed and force spike together.",
					Kind = "Active",
					CooldownSeconds = 70,
					QiCost = 40,
					Effects = { timed("Fleetness", 12, 8), timed("Might", 9, 8) },
				},
			},
		},
	},
	{
		BloodlineId = "vessel_of_ash",
		DisplayName = "Vessel of Ash",
		RarityTier = "Rare",
		FlavorText = "What the Void leaves in someone it has already been through. Hollowed out further "
			.. "than is safe, and holding correspondingly more.",
		NativeRaceId = "Hollowborn",
		AwakeningCondition = { Kind = "OnPlayerKilled", Params = { RequiredKills = KILLS.Rare } },
		Stages = {
			{
				StageIndex = 1,
				DisplayName = "Emptied",
				PassiveEffects = { bound("MeridianFlow", 5), bound("Vitality", -2) },
			},
			{
				StageIndex = 2,
				DisplayName = "Filled Again",
				PassiveEffects = { bound("MeridianFlow", 9), bound("Vitality", -2) },
			},
			{
				StageIndex = 3,
				DisplayName = "Ash Vessel",
				PassiveEffects = { bound("MeridianFlow", 14), bound("Pressure", 5), bound("Vitality", -3) },
				GrantedAbility = {
					Id = "vessel_of_ash_pour",
					DisplayName = "Pour Out",
					Description = "Empty the vessel deliberately. A large Qi return, and everything near you feels it.",
					Kind = "Active",
					CooldownSeconds = 80,
					QiCost = 0,
					Effects = {
						{ Kind = "QiRestore", Lifetime = "Instant", QiRestoreAmount = 200 },
						timed("Pressure", 10, 8),
					},
				},
			},
		},
	},

	--
	-- Legendary -- two, four stages each. Both race-agnostic: blood this rare answers to nobody's
	-- birth race, which is also what makes it worth drawing.
	--
	{
		BloodlineId = "unwritten_name",
		DisplayName = "The Unwritten Name",
		RarityTier = "Legendary",
		FlavorText = "The Unbound inheritance in its purest form -- a fragment that never belonged to "
			.. "anyone, attaching itself to whoever refuses hardest to be told what they are. It is the "
			.. "most flexible blood there is and the least forgiving of a mistake.",
		AwakeningCondition = { Kind = "OnPlayerKilled", Params = { RequiredKills = KILLS.Legendary } },
		Stages = {
			{
				StageIndex = 1,
				DisplayName = "Unclaimed",
				PassiveEffects = { bound("Might", 3), bound("Fleetness", 3) },
			},
			{
				StageIndex = 2,
				DisplayName = "Contested",
				PassiveEffects = { bound("Might", 5), bound("Fleetness", 5), bound("Pressure", 3) },
			},
			{
				StageIndex = 3,
				DisplayName = "Argued For",
				PassiveEffects = { bound("Might", 8), bound("Fleetness", 8), bound("Pressure", 5) },
				GrantedAbility = {
					Id = "unwritten_name_insist",
					DisplayName = "Insist",
					Description = "Make the claim anyway. Everything sharpens at once, briefly.",
					Kind = "Active",
					CooldownSeconds = 90,
					QiCost = 50,
					Effects = { timed("Might", 9, 8), timed("Fleetness", 9, 8), timed("Pressure", 9, 8) },
				},
			},
			{
				StageIndex = 4,
				DisplayName = "Written In",
				PassiveEffects = {
					bound("Might", 12),
					bound("Fleetness", 12),
					bound("Pressure", 8),
					bound("MeridianFlow", 5),
				},
				GrantedAbility = {
					Id = "unwritten_name_sign",
					DisplayName = "Sign It",
					Description = "The world stops arguing. A long window where nothing about you is provisional.",
					Kind = "Active",
					CooldownSeconds = 150,
					QiCost = 90,
					Effects = {
						timed("Might", 14, 12),
						timed("Fleetness", 14, 12),
						timed("Pressure", 14, 12),
						timed("Fortitude", 10, 12),
					},
				},
			},
		},
	},
	{
		BloodlineId = "corrupt_crown",
		DisplayName = "The Corrupt Crown",
		RarityTier = "Legendary",
		FlavorText = "The Demonic path taken to its conclusion and then one step past it. It grows "
			.. "faster than any Celestial lineage and it is entirely honest about what that costs.",
		AwakeningCondition = { Kind = "OnPlayerKilled", Params = { RequiredKills = KILLS.Legendary } },
		Stages = {
			{
				StageIndex = 1,
				DisplayName = "Offered",
				PassiveEffects = { bound("Might", 5), bound("Vitality", -2) },
			},
			{
				StageIndex = 2,
				DisplayName = "Worn",
				PassiveEffects = { bound("Might", 9), bound("Pressure", 4), bound("Vitality", -3) },
			},
			{
				StageIndex = 3,
				DisplayName = "Fitted",
				PassiveEffects = { bound("Might", 14), bound("Pressure", 7), bound("Vitality", -5) },
				GrantedAbility = {
					Id = "corrupt_crown_decree",
					DisplayName = "Decree",
					Description = "Say it as though it is already true. Overwhelming force, and nothing held back for later.",
					Kind = "Active",
					CooldownSeconds = 95,
					QiCost = 55,
					Effects = { timed("Might", 16, 8), timed("Pressure", 12, 8), timed("Fortitude", -6, 8) },
				},
			},
			{
				StageIndex = 4,
				DisplayName = "Crowned",
				PassiveEffects = {
					bound("Might", 20),
					bound("Pressure", 11),
					bound("Vitality", -7),
					bound("Fortitude", -3),
				},
				GrantedAbility = {
					Id = "corrupt_crown_reign",
					DisplayName = "Reign",
					Description = "Hold the crown on. For as long as it lasts nothing survives contact, including you.",
					Kind = "Active",
					CooldownSeconds = 160,
					QiCost = 100,
					Effects = {
						timed("Might", 22, 10),
						timed("Pressure", 18, 10),
						timed("Vitality", -10, 10),
					},
				},
			},
		},
	},

	--
	-- Ascendant -- one. The canon's own named bloodline, and the roster's rarest draw by a factor of
	-- five over Legendary (BloodlineConstants.RarityWeights: Ascendant 1, Legendary 5).
	--
	{
		BloodlineId = "tianlong",
		DisplayName = "Tianlong",
		RarityTier = "Ascendant",
		FlavorText = "The dragon-vein. Ordered qi in its oldest and most disciplined form, and the "
			.. "lineage the Firmament measures every other against. It does not care whose veins it "
			.. "ended up in -- but it will not move for someone who has not yet become something.",
		-- Race-agnostic ON PURPOSE, so a Human can draw it -- that draw IS world-bible.md's contested
		-- authority example. What separates inherited from contested is RequiresAscended below, not a
		-- race lock: the blood is in you from the roll and refuses to ADVANCE until you have ascended.
		-- "The difficulty gap itself should tell the story" (progression-systems.md).
		AwakeningCondition = {
			Kind = "OnPlayerKilled",
			Params = { RequiredKills = KILLS.Ascendant, RequiresAscended = 1 },
		},
		Stages = {
			{
				StageIndex = 1,
				DisplayName = "Coiled",
				PassiveEffects = { bound("Fortitude", 5), bound("Pressure", 5), bound("MeridianFlow", 5) },
			},
			{
				StageIndex = 2,
				DisplayName = "Stirring",
				PassiveEffects = {
					bound("Fortitude", 9),
					bound("Pressure", 9),
					bound("MeridianFlow", 9),
					bound("Might", 4),
				},
			},
			{
				StageIndex = 3,
				DisplayName = "Risen",
				PassiveEffects = {
					bound("Fortitude", 14),
					bound("Pressure", 14),
					bound("MeridianFlow", 14),
					bound("Might", 8),
				},
				GrantedAbility = {
					Id = "tianlong_ascend",
					DisplayName = "Ascend",
					Description = "The vein straightens. Every measure of you rises together, and holds.",
					Kind = "Active",
					CooldownSeconds = 120,
					QiCost = 80,
					Effects = {
						timed("Might", 12, 12),
						timed("Pressure", 12, 12),
						timed("Fortitude", 12, 12),
						timed("MeridianFlow", 12, 12),
					},
				},
			},
			{
				StageIndex = 4,
				DisplayName = "Tianlong",
				PassiveEffects = {
					bound("Vitality", 10),
					bound("Fortitude", 20),
					bound("MeridianFlow", 20),
					bound("Might", 14),
					bound("Pressure", 20),
					bound("Fleetness", 10),
				},
				GrantedAbility = {
					Id = "tianlong_heavens_length",
					DisplayName = "The Heaven's Length",
					Description = "For a long moment you are the whole vein, end to end, and the world defers.",
					Kind = "Active",
					CooldownSeconds = 240,
					QiCost = 150,
					Effects = {
						timed("Might", 20, 15),
						timed("Pressure", 20, 15),
						timed("Fortitude", 20, 15),
						timed("Fleetness", 15, 15),
						{ Kind = "QiRestore", Lifetime = "Instant", QiRestoreAmount = 300 },
					},
				},
			},
		},
	},
}

-- Every authored entry, in one call. Kept as a function rather than run at require time so
-- BloodlineManager.Init's own `bloodlines = {}` reset can never land AFTER the seed and silently
-- empty it -- Main.server.lua boots the Manager first and this immediately after.
--
-- Each entry goes through BloodlineManager.Validate, exactly like a Kit Editor submission, and a
-- rejection is logged and SKIPPED rather than thrown: one mis-authored bloodline should cost the
-- roster that bloodline, never the server's boot. The count assert is deliberately a warn too --
-- world-bible.md fixes the roster at thirteen, so drifting off that number is a content bug worth
-- seeing in a log, but not one worth refusing to start over.
function DefaultBloodlineRegistry.Init(): ()
	local seeded = 0
	for _, candidate in ipairs(BLOODLINES) do
		local validated, reason = BloodlineManager.Validate(candidate)
		if validated then
			BloodlineManager.Upsert(validated)
			seeded += 1
		else
			logger:error("Default bloodline failed validation and was skipped", {
				bloodlineId = tostring(candidate.BloodlineId),
				reason = reason,
			})
		end
	end

	if seeded ~= Constants.BloodlineCount then
		logger:warn("Seeded bloodline count differs from canon", {
			seeded = seeded,
			expected = Constants.BloodlineCount,
		})
	end
	logger:info("DefaultBloodlineRegistry.Init() complete", { seeded = seeded })
end

-- Exposed for the spec, which asserts the roster is the canon thirteen and that every entry
-- survives Validate -- the two things this file can get wrong that nothing else would notice.
function DefaultBloodlineRegistry.List(): { any }
	return BLOODLINES
end

return DefaultBloodlineRegistry :: Types.SystemModule
