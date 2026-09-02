--!strict
--[[
	CharacterCreationConstants.lua

	Owns: the first-time-player onboarding surface -- the closed race roster, the attribute
	point-pool budget and its per-race prefills, display-name rules, the cinematic/hold-to-confirm
	timing, the per-race arrival spawn paths, and the two per-remote call budgets. Read by
	Server/Systems/CharacterCreationSystem.lua, Client/Onboarding/OnboardingClient.lua and
	Client/UI/Screens/Onboarding/*.

	Lifted out of Constants.lua. Constants.CharacterCreation re-exports this module, so every
	existing Constants.CharacterCreation.X call site keeps working unchanged; new code should
	require this module directly.

	The FIRST of these splits that is not a verbatim move, for one reason worth naming: RaceIds
	casts through Types.RaceId, so this module carries its own Types require where
	AttributeConstants/DebugConstants/FXConstants carry none.

	THE DERIVED AttributeFloors BLOCK TRAVELS WITH THE TABLE and must stay in this file. It reads
	four fields of the table above it (AttributeBudget, RaceIds, RacePrefills, AttributeFields) and
	writes a fifth back onto it, so leaving it behind in Constants.lua would turn a plain
	within-one-file ordering requirement into a cross-module load-order dependency -- and one whose
	failure mode is a silently absent AttributeFloors rather than an error, since the server's
	ValidateAttributeBlock indexes it per race.

	Does not own: the VALIDATION that reads these numbers (CharacterCreationSystem's own
	Validate* functions -- server-side, and unreachable from client code), the storage/autosave
	concerns of the profile this flow writes into (Constants.PlayerData), or the camera/FX staging
	wrapped around the same player flow (Constants.Intro, which stays a distinct table for the
	reason its own header gives).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage.Shared.Types)

-- First-time-player onboarding / character creation (Server/Systems/CharacterCreationSystem.lua,
-- Client/Onboarding/OnboardingClient.lua + UI/Screens/Onboarding/*). A first-time player is detected
-- purely by `profile.raceId == nil` (PlayerDataSystem.PlayerProfile) -- no new boolean flag, and a
-- returning player never sees this flow again. Grouped as its own top-level table (not folded into
-- Constants.PlayerData) since chargen has its own distinct tuning surface -- race/attribute
-- balance, name rules, cinematic timing -- that has nothing to do with PlayerDataSystem's own
-- DataStore/autosave concerns, the same "distinct feature, distinct table" reasoning
-- Constants.BugReport's own header gives for staying separate from Constants.PlayerData.
local CharacterCreationConstants = {
	-- The four fixed races (world-bible.md, Constants.RaceCount = 4) -- a closed set
	-- CharacterCreationSystem.ValidateRaceId checks a client-submitted race choice against. Real,
	-- final content for this pass, not a placeholder roster.
	RaceIds = ({ "Human", "Firmborn", "Rivenkin", "Hollowborn" } :: any) :: { Types.RaceId },

	-- Types.AttributeBlock's six fields, in one fixed, canonical order -- both
	-- CharacterCreationSystem.ValidateAttributeBlock (server) and the Attributes/RaceSelect screens
	-- (client, Client/UI/Screens/Onboarding/) iterate this same list rather than each independently
	-- re-typing the six field names, so the two sides can never drift out of sync on what the six
	-- attributes are called.
	AttributeFields = { "Vitality", "Fortitude", "MeridianFlow", "Might", "Pressure", "Fleetness" },

	-- Three-letter abbreviations for the Attributes screen's stat rows and the Origin card's 6-up
	-- stat grid (docs/design/intro-redesign-figma-spec.md sections 4-5) -- keyed the same way as
	-- AttributeFields immediately above so a caller iterating that list can look these up directly
	-- rather than re-deriving an abbreviation from the full name.
	AttributeAbbreviations = {
		Vitality = "VIT",
		Fortitude = "FOR",
		MeridianFlow = "QIF",
		Might = "MGT",
		Pressure = "PRS",
		Fleetness = "FLT",
	} :: { [string]: string },

	-- What each attribute is CALLED on screen, as opposed to what its field is named in code. Keyed
	-- the same way as AttributeFields/AttributeAbbreviations above, and every surface that shows an
	-- attribute to a player reads this rather than rendering the raw key.
	--
	-- It exists for exactly one entry. `MeridianFlow` is the field name in Types.AttributeBlock, in
	-- every saved profile, in KitValidation's allow-list, in Types.ActiveModifierAttributeKey, and in
	-- ~15 bloodline stage effects in DefaultBloodlineRegistry -- so renaming the KEY is a data
	-- migration across a persisted schema, not a copy change. What the player actually needed was the
	-- LABEL: "MeridianFlow" is jargon that reads as a system name, where the thing it governs is
	-- plainly your qi (user, 2026-08-20). So the key stays and the label is "Qi Flow", with the
	-- abbreviation moving MER -> QIF to match.
	--
	-- The other five map to themselves. They are listed anyway rather than left to fall through to
	-- the key, so that a sixth rename is a one-line edit here instead of a discovery that only one
	-- attribute in the table ever had a display name.
	AttributeDisplayNames = {
		Vitality = "Vitality",
		Fortitude = "Fortitude",
		MeridianFlow = "Qi Flow",
		Might = "Might",
		Pressure = "Pressure",
		Fleetness = "Fleetness",
	} :: { [string]: string },

	-- Attribute point budget -- every one of the six attributes (Types.AttributeBlock) starts at
	-- BaseValuePerAttribute (10), and RaceIds share one BonusPoolTotal (18) between a race's own
	-- pre-committed lean (RacePrefills below, worth RacePrecommittedPoints net points -- except
	-- Human, who gets no pre-fill and keeps the full pool as free points instead) and whatever the
	-- player freely reallocates on the Attributes screen. TotalBudget (78 = 10*6 + 18) is the exact
	-- sum CharacterCreationSystem.ValidateAttributeBlock requires -- every race reaches the same
	-- total, only the starting lean differs. MaxPerAttribute is a per-attribute creation-time bound
	-- (a future Attunement/tier-up points-per-tier screen is expected to raise attributes past 20
	-- later, but that's a different budget check this pass deliberately doesn't need to anticipate).
	--
	-- MinPerAttribute raised 5 -> 10 (docs/design/intro-redesign-handoff.md Phase D, the interim
	-- point-pool rebalance -- TierSystem.lua is still an empty Init() with no point-grant mechanism,
	-- which rules out the handoff's "full" rebalance for this pass; user decision, 2026-07-25).
	-- Rationale: MeridianFlow does nothing yet (see AttributeEffects below), so under the old
	-- MinPerAttribute=5 the dominant play was dump MeridianFlow/Fortitude to the floor and pour
	-- everything into Might -- a 30% permanent stat swing the redesign's own numeric-transparency UI
	-- would have handed the player on sight. Raising the floor kills that strategy without touching
	-- BonusPoolTotal or requiring TierSystem to exist.
	--
	-- A flat floor alone would make Hollowborn's own starting block invalid (BaseValuePerAttribute +
	-- RacePrefills.Hollowborn.Vitality = 10 - 1 = 9, one below this new floor) -- AttributeFloors
	-- below is the fix: a per-race, per-field floor that's normally MinPerAttribute but never higher
	-- than that race's own prefilled starting value.
	AttributeBudget = {
		BaseValuePerAttribute = 10,
		BonusPoolTotal = 18,
		RacePrecommittedPoints = 2,
		MinPerAttribute = 10,
		MaxPerAttribute = 20,
		TotalBudget = 78,
	},

	-- Per-race starting attribute deltas from BaseValuePerAttribute above -- an empty/missing entry
	-- for a given attribute means no delta (stays at base). Human is deliberately the empty table:
	-- "no pre-fill" IS the design (flat baseline, all 18 points free) rather than a race that simply
	-- hasn't been authored yet. Hollowborn's net is +3 MeridianFlow / -1 Vitality (+2 net, same
	-- RacePrecommittedPoints worth as Firmborn/Rivenkin's flat +2), not a flat single-attribute lean
	-- -- CharacterCreationSystem/the Attributes screen both derive a race's starting block by summing
	-- BaseValuePerAttribute + these deltas per attribute, never by assuming "one attribute gets +2."
	RacePrefills = {
		Human = {},
		Firmborn = { Fortitude = 2 },
		Rivenkin = { Might = 2 },
		Hollowborn = { MeridianFlow = 3, Vitality = -1 },
	} :: { [string]: { [string]: number } },

	-- RaceHooks (deprecated) removed: it was retained only until "the Onboarding rebuild (Phase E)
	-- migrates RaceSelect.lua's last reference off it." Phase E has landed and a full-tree search
	-- finds zero remaining readers, so the table is gone rather than left as a second, staler answer
	-- to the same question the three tables below now own.

	-- Three-layer replacement for the former RaceHooks (docs/design/intro-redesign-figma-spec.md's Origin
	-- card + docs/design/intro-redesign-handoff.md Phase C/E's progressive-disclosure card). Every
	-- unselected Origin card shows Name + Epithet + WorldLine + CostLine; the selected card also
	-- expands to the real per-attribute numbers (RacePrefills), which these three deliberately never
	-- restate as hardcoded digits -- a copy string that quotes "+2 Fortitude" goes stale the moment
	-- RacePrefills changes under it, so CostLines stays qualitative and the UI reads the real number
	-- from Budget/RacePrefills directly.
	--
	-- Epithets are the Figma's own, taken verbatim -- they're good, and they're the layer the old
	-- RaceHooks lacked entirely. WorldLines and CostLines are new, written against
	-- world-bible.md's Shattering/Meridian Particle framing (Shattered Meridian Studio skill) rather
	-- than inventing unrelated lore -- the skill's current world-bible.md/progression-systems.md
	-- don't yet carry a dedicated per-race lore write-up of their own (only this game's Constants.lua
	-- did, in RaceHooks' mechanical register), so these lines stay at the same restrained altitude
	-- the old hooks held rather than asserting new binding canon (faction ties, detailed sub-history)
	-- a UI copy pass isn't positioned to author solo.
	RaceEpithets = {
		Human = "The Unwritten",
		Firmborn = "Heirs of the Stonepath",
		Rivenkin = "Born of the Fracture Lines",
		Hollowborn = "Vessels of Broken Qi",
	} :: { [string]: string },
	RaceWorldLines = {
		Human = "No fragment of the old Meridian marked you before birth. What you become is still yours to write.",
		Firmborn = "When the Shattering came, their ancestors held their ground instead of fleeing it -- and the ground held them back.",
		Rivenkin = "Their ancestors were already moving when the world cracked open, and never really stopped.",
		Hollowborn = "Their Meridian fragment burns closer to the surface than most -- already hollowing out room to hold more of it.",
	} :: { [string]: string },
	-- Honest cost layer -- Firmborn/Rivenkin are a single pre-spent lean (RacePrefills sets ONE field
	-- positive, nothing is reduced to pay for it -- the "cost" is that the point is already committed
	-- before the player gets to allocate freely); Hollowborn is the one race with a real two-sided
	-- trade (MeridianFlow up, Vitality down), and its line says so.
	RaceCostLines = {
		Human = "No starting lean -- every point is unspent, and yours to place.",
		Firmborn = "A lean toward Fortitude, already spent for you before you begin.",
		Rivenkin = "A lean toward Might, already spent for you before you begin.",
		Hollowborn = "A deep lean toward Qi Flow, paid for out of Vitality.",
	} :: { [string]: string },

	-- Plain-language one-line effect shown under each attribute on the Attributes screen (screen 2).
	-- MeridianFlow's now reflects a live mechanic -- QiSystem.lua (Shared/QiConstants.lua's
	-- MaxQiPerMeridianFlowPoint/RegenPerSecondPerMeridianFlowPoint) actually reads this attribute,
	-- so the "(not active yet)" caveat that used to sit here would now be stale, not honest.
	-- Fleetness is deliberately scoped to movement + Dash/Sprint/Slide cooldown trim ONLY --
	-- combat-philosophy.md's attack-speed/combo-timing/parry-window feel stays attribute-invariant,
	-- so this copy never implies otherwise.
	AttributeEffects = {
		Vitality = "Max Health",
		Fortitude = "Max Posture + regen",
		MeridianFlow = "Max Qi + regen",
		Might = "Outgoing health damage",
		Pressure = "Outgoing posture damage",
		Fleetness = "Movement speed + Dash/Sprint/Slide cooldown trim",
	} :: { [string]: string },

	-- Display name rules (screen 3) -- the in-game character name, separate from the Roblox
	-- username, NOT globally unique (no reservation table -- CharacterCreationSystem.lua never checks
	-- another player's name). CharacterCreationSystem.ValidateDisplayName enforces length/charset;
	-- server-side TextService:FilterStringAsync/GetNonChatStringForBroadcastAsync (same call site
	-- pattern as BugReportSystem.Submit) runs after that, and Denylist is a final studio-authored
	-- blocklist checked in addition to the moderation filter.
	DisplayName = {
		MinLength = 3,
		MaxLength = 20,
		-- Staff/authority IMPERSONATION terms specifically -- a genuinely different concern from the
		-- profanity/harassment content TextService:FilterStringAsync above already exists to catch
		-- (and is this codebase's compliant, always-up-to-date source of truth for that). A name like
		-- "Admin" or "RobloxSupport" isn't profane, so the moderation filter has no reason to touch
		-- it, but it lets a player pose as staff to scam/mislead others in-game -- a distinct, real
		-- abuse vector this denylist exists specifically to close. ValidateDisplayName checks
		-- substring containment, case-insensitively, against `name:lower()` -- every term here is
		-- already lowercase for that reason, and deliberately spelled out in FULL (never a short
		-- fragment like "mod" or "gm") to keep false-positive collisions with legitimate names low --
		-- "mod"/"gm" alone would reject real names that merely happen to contain those letters in
		-- sequence (e.g. "Sigmund" contains "gm"), where a full word like "moderator" essentially
		-- never appears by coincidence inside an unrelated name.
		Denylist = {
			"admin",
			"administrator",
			"moderator",
			"gamemaster",
			"developer",
			"roblox",
			"official staff",
			"game staff",
			"support staff",
		} :: { string },
		-- NameEntry.lua's "Suggest" button (docs/design/intro-redesign-handoff.md's designer
		-- direction: "blank-field paralysis is the biggest drop-off point in any chargen flow").
		-- Real, curated names, not placeholder text -- every one already satisfies MinLength/MaxLength
		-- and ValidateDisplayName's charset gate, so a suggestion needs no special-cased validation
		-- path; it writes into the same DisplayName Value a typed name would and is re-validated
		-- identically at Finalize.
		SuggestedNames = {
			"Kaelen",
			"Wren",
			"Iskra",
			"Thane",
			"Marek",
			"Sable",
			"Orin",
			"Vesna",
			"Callan",
			"Ashe",
			"Doran",
			"Lyric",
			"Bren",
			"Rovena",
		} :: { string },
	},

	RemoteNames = {
		GetOnboardingState = "CharacterCreation_GetOnboardingState",
		Finalize = "CharacterCreation_Finalize",
		-- Fire-and-forget RemoteEvent (Client/Intro/IntroClient.lua -> CharacterCreationSystem.lua),
		-- sent once the local player's get-up AnimationTrack finishes playing. This is what ends the
		-- isolation (Frozen/Godmode/Invisible) handleGetOnboardingState below applies -- see
		-- CharacterCreationSystem.lua's own header for why a client-reported "I'm done" signal is an
		-- acceptable trust level here (one-shot, low-stakes, same tier as GetOnboardingState/
		-- spawnedThisSession) rather than duplicating an animation-length timer server-side too.
		AwakeningComplete = "CharacterCreation_AwakeningComplete",
	},

	-- Named Workspace instances CharacterCreationSystem.lua resolves via WaitForChild.
	-- default.project.json DOES author this Workspace tree (see its own "Onboarding" node) --
	-- ThresholdSpawn is an isolated "Waking Threshold" pocket space outside SafeZones/
	-- ContestedZones/VoidFractureZones/Territories (a first-time player is frozen there for the
	-- lying-down cinematic + creator); each entry in ArrivalSpawnPaths is a race-specific arrival
	-- point chargen teleports (PivotTo) the player to once Finalize succeeds -- "world" here means a
	-- race-keyed zone in this same place, not a separate Roblox Place (WorldSystem.lua/
	-- TerritorySystem.lua already use "world"/"region" this way; nothing in this repo has
	-- multi-place teleport infra, and CharacterCreation_Finalize picks the entry keyed by the
	-- SERVER-VALIDATED raceId, which is what keeps this server-authoritative without needing any).
	ThresholdSpawnPath = { "Onboarding", "WakingThresholdSpawn" },
	ArrivalSpawnPaths = {
		Human = { "Onboarding", "ArrivalSpawns", "Human" },
		Firmborn = { "Onboarding", "ArrivalSpawns", "Firmborn" },
		Rivenkin = { "Onboarding", "ArrivalSpawns", "Rivenkin" },
		Hollowborn = { "Onboarding", "ArrivalSpawns", "Hollowborn" },
	} :: { [string]: { string } },

	-- Cinematic timing (Client/Onboarding/OnboardingClient.lua + UI/Screens/Onboarding/Cinematic.lua).
	-- The intro plays for CinematicDurationSeconds unless held-skipped first. Cut from 19s/6 lines to
	-- 12s/4 lines (docs/design/intro-redesign-handoff.md's designer direction) -- CINEMATIC_LINE_COUNT
	-- in OnboardingClient.lua must match Cinematic.lua's own line count, the same documented coupling
	-- as before.
	--
	-- HoldToSkipSeconds and HoldToConfirmSeconds used to share one value ("held input, ~1s") despite
	-- meaning opposite things -- skipping unwatched lore vs. permanently creating a character. Now
	-- deliberately different: skip is the FASTER, lower-stakes gesture (0.6s), confirm is the
	-- SLOWER, higher-stakes one (1.6s) -- the two hold durations are now themselves part of how each
	-- gesture communicates its own weight, not just their surrounding copy.
	CinematicDurationSeconds = 12,
	HoldToSkipSeconds = 0.6,
	HoldToConfirmSeconds = 1.6,
	-- The skip affordance fades in this many seconds into the cinematic, not at t=0 (designer
	-- direction: "telling the player they may leave before giving them a reason to stay is
	-- backwards").
	SkipHintRevealSeconds = 4,

	-- Per-remote call budgets, same convention as Constants.BugReport.SubmitMaxCallsPerSecond/
	-- Constants.Settings.MaxCallsPerSecondPerPlayer -- GetOnboardingState's own WaitForProfile yield
	-- and Finalize's TextService:FilterStringAsync yield are both real server work a modified client
	-- could otherwise spam ahead of (or during, before) the existing spawnedThisSession/
	-- finalizingPlayers in-flight guards.
	GetOnboardingStateMaxCallsPerSecond = 2,
	FinalizeMaxCallsPerSecond = 2,
}

-- Precomputed per-race, per-field allocation floor -- see AttributeBudget's own comment above for
-- why this exists (the interim point-pool rebalance) and RacePrefills for the source data. A
-- separate `do` block (not part of the table literal above) because it's DERIVED from
-- AttributeBudget/RacePrefills/RaceIds/AttributeFields, all of which must already exist to compute
-- it. Computed ONCE here rather than as a function duplicated on both sides of the client/server
-- boundary -- CharacterCreationSystem.ValidateAttributeBlock (server) can't be required from client
-- code at all (ServerScriptService isn't replicated), and the Attributes screen's stepper clamp
-- (client) needs the identical numbers, so both just read this table instead of two independently
-- re-deriving the same formula.
do
	local budget = CharacterCreationConstants.AttributeBudget
	local floors: { [string]: { [string]: number } } = {}
	for _, raceId in ipairs(CharacterCreationConstants.RaceIds) do
		local prefill = CharacterCreationConstants.RacePrefills[raceId] or {}
		local perField: { [string]: number } = {}
		for _, field in ipairs(CharacterCreationConstants.AttributeFields) do
			-- min, not max: the floor is normally MinPerAttribute, but never higher than this race's
			-- OWN prefilled starting value -- a race whose prefill already sits below the flat floor
			-- (today, only Hollowborn's Vitality: 10 - 1 = 9) is grandfathered in at its own number
			-- rather than starting the Attributes screen already in violation of a rule the player
			-- had no chance to satisfy from screen 1. A POSITIVE prefill (Firmborn's Fortitude,
			-- Rivenkin's Might) never raises the floor above MinPerAttribute -- a prefill is a
			-- starting lean the player must stay free to reallocate away, not a locked-in minimum.
			perField[field] = math.min(budget.MinPerAttribute, budget.BaseValuePerAttribute + (prefill[field] or 0))
		end
		floors[raceId] = perField
	end
	CharacterCreationConstants.AttributeFloors = floors :: { [string]: { [string]: number } }
end

return CharacterCreationConstants
