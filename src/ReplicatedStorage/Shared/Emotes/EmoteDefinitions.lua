--!strict
--[[
	EmoteDefinitions.lua

	Owns: the authored content roster for the Emote System -- a pure `{ [Types.EmoteId]:
	Types.EmoteDefinition }` data table, no Instance/Player coupling, no logic. The sole reason this
	lives in its own file rather than as one more Constants.lua table: it's genuinely content (this
	codebase's existing "content vs. tunables" split -- see EmoteConstants.lua's own header), and a
	live game keeps adding entries here for years the same way Constants.CharacterCreation.RaceIds'
	four races don't, but a bloodline/art roster eventually will.

	AnimationId/Icon are "" for every unauthored entry below -- this codebase never fabricates a
	plausible-looking asset id (see Constants.Combat.AnimationIds' own header for the precedent:
	Heavy1/Heavy2 sit exactly as empty, wired-but-unauthored strings until a real clip is supplied).
	Every play/preload path already degrades safely on an empty id (Client/FX/EmoteAnimator.lua skips
	building a template for it, the same way CombatAnimator.lua does). Wave/Taunt/Cheer are the
	entries with a real clip authored so far -- like every other AnimationId in this codebase
	(Constants.lua's own Combat.AnimationIds/FlightTuning tables), each MUST carry the "rbxassetid://"
	content-URI prefix, not just the bare numeric id: Animator:LoadAnimation resolves that prefix as a
	scheme, so a bare number silently fails to resolve to real keyframe data instead of erroring
	loudly.

	"" means unauthored -- NOT the bare prefix "rbxassetid://". Several entries below used to carry
	that prefix-only string as their placeholder, which reads as unauthored to a human but is a
	non-empty string to every `AnimationId ~= ""` guard in the codebase: it slipped past
	EmoteAnimator's skip-the-template check into a real LoadAnimation call on an id-less URI, and past
	EmoteSystem's own hasClip() (which decides whether an emote's length is owned by the client's
	track or by Duration below). Leave an unauthored clip as exactly "".

	DURATION IS NOT THE LENGTH OF THE ANIMATION. For an entry with a real clip, the clip's own length
	is what ends the emote -- the acting client reports its natural end through Emote_NotifyFinished
	(Server/Systems/EmoteSystem.lua's WHAT ENDS A ONE-SHOT EMOTE header). Duration only still ends an
	emote that has no clip authored yet, where there is no track whose end could be reported. It is
	kept on clip-bearing entries as authored design intent and as the fallback if a clip is ever
	removed, and Client/FX/EmoteAnimator.lua warns at play time when it drifts from the real clip --
	but do NOT expect retuning it to change how long an authored emote actually plays.

	Two entries (VictoryPose, CelestialBow) are deliberately LOCKED from the start -- not because
	they're meant to ship gated forever, but to prove the unlock plumbing (EmoteUnlockService.
	GrantEmote/RollEmote) actually has a non-Default consumer to exercise before AchievementSystem/a
	future quest or live-ops system exists to call it for real.

	Does not own: validating this data (Shared/Emotes/EmoteRegistry.lua), granting/tracking which
	player has unlocked which entry (Server/Systems/EmoteUnlockService.lua), or deciding whether a
	request to play one is currently legal (Server/Systems/EmoteSystem.lua).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage.Shared.Types)

local EmoteDefinitions: { [Types.EmoteId]: Types.EmoteDefinition } = {
	-- A brief, low-commitment gesture -- allowed to carry into a lingering in-combat window (a wave
	-- after a fight ends) and doesn't lock movement, so it reads as a quick flourish rather than a
	-- full stop.
	Wave = {
		Id = "Wave",
		DisplayName = "Wave",
		Description = "A friendly wave.",
		AnimationId = "rbxassetid://135500644773627",
		Icon = "",
		Category = "Greeting",
		Loop = false,
		Duration = 2,
		MovementLocked = false,
		CombatAllowed = true,
		CancelOnDamage = true,
		Unlock = { Type = "Default" },
	},

	-- A deeper, more deliberate social gesture -- locks movement for its duration (a bow reads as
	-- broken if the player can still strafe mid-animation) and is out of place mid-fight.
	Bow = {
		Id = "Bow",
		DisplayName = "Bow",
		Description = "A formal, respectful bow.",
		AnimationId = "",
		Icon = "",
		Category = "Social",
		Loop = false,
		Duration = 2.5,
		MovementLocked = true,
		CombatAllowed = false,
		CancelOnDamage = true,
		Unlock = { Type = "Default" },
	},

	-- A reaction, not a greeting -- short enough and low-commitment enough to still fire in a
	-- lingering in-combat window (mocking laughter right after a close call is thematic).
	Laugh = {
		Id = "Laugh",
		DisplayName = "Laugh",
		Description = "Hearty, mocking laughter.",
		AnimationId = "",
		Icon = "",
		Category = "Reaction",
		Loop = false,
		Duration = 3,
		MovementLocked = false,
		CombatAllowed = true,
		CancelOnDamage = true,
		Unlock = { Type = "Default" },
	},

	-- The one entry here whose whole point is a combat context -- taunting an opponent while still
	-- InCombat is the design intent, not an edge case to guard against.
	Taunt = {
		Id = "Taunt",
		DisplayName = "Taunt",
		Description = "A provocative taunt aimed at a nearby rival.",
		AnimationId = "rbxassetid://81032790089362",
		Icon = "",
		Category = "Reaction",
		Loop = false,
		Duration = 2,
		MovementLocked = false,
		CombatAllowed = true,
		CancelOnDamage = true,
		Unlock = { Type = "Default" },
	},

	-- A sustained, vulnerable pose -- locks movement, forbidden while InCombat, and breaks the
	-- instant the player takes damage, same as Dance below.
	Sit = {
		Id = "Sit",
		DisplayName = "Sit",
		Description = "Sit down and rest.",
		AnimationId = "",
		Icon = "",
		Category = "Sitting",
		Loop = true,
		Duration = nil,
		MovementLocked = true,
		CombatAllowed = false,
		CancelOnDamage = true,
		Unlock = { Type = "Default" },
	},

	-- A reaction like Laugh/Taunt above -- brief enough to allow carrying into a lingering
	-- in-combat window.
	Cheer = {
		Id = "Cheer",
		DisplayName = "Cheer",
		Description = "A triumphant cheer.",
		AnimationId = "rbxassetid://107111167555249",
		Icon = "",
		Category = "Reaction",
		Loop = false,
		Duration = 2.5,
		MovementLocked = false,
		CombatAllowed = true,
		CancelOnDamage = true,
		Unlock = { Type = "Default" },
	},

	-- The briefest gesture in the starter roster -- a quick directional callout, same low-commitment
	-- shape as Wave.
	Point = {
		Id = "Point",
		DisplayName = "Point",
		Description = "Point something out.",
		AnimationId = "",
		Icon = "",
		Category = "Greeting",
		Loop = false,
		Duration = 1.5,
		MovementLocked = false,
		CombatAllowed = true,
		CancelOnDamage = true,
		Unlock = { Type = "Default" },
	},

	-- A sustained, vulnerable pose -- same MovementLocked/CombatAllowed/CancelOnDamage shape as Sit
	-- above, for the same reason.
	Dance = {
		Id = "Dance",
		DisplayName = "Dance",
		Description = "Bust a move.",
		AnimationId = "",
		Icon = "",
		Category = "Dance",
		Loop = true,
		Duration = nil,
		MovementLocked = true,
		CombatAllowed = false,
		CancelOnDamage = true,
		Unlock = { Type = "Default" },
	},

	-- LOCKED example #1 -- earned once AchievementSystem (still a stub) grants "FirstVictory" through
	-- EmoteUnlockService.GrantEmote. A sustained victory pose, same commitment shape as Bow/Sit.
	VictoryPose = {
		Id = "VictoryPose",
		DisplayName = "Victory Pose",
		Description = "A commanding pose, earned by a first victory.",
		AnimationId = "",
		Icon = "",
		Category = "Rare",
		Loop = false,
		Duration = 3,
		MovementLocked = true,
		CombatAllowed = false,
		CancelOnDamage = true,
		Unlock = { Type = "Achievement", Id = "FirstVictory" },
	},

	-- LOCKED example #2 -- reachable only through EmoteUnlockService.RollEmote("RareEmotes", ...);
	-- EmoteConstants.RollPools.RareEmotes names this exact id. A flourished, Celestial-flavored bow
	-- distinct enough from the Default Bow above to read as a genuine rare reward.
	CelestialBow = {
		Id = "CelestialBow",
		DisplayName = "Celestial Bow",
		Description = "An elaborate bow, radiant with Celestial qi.",
		AnimationId = "",
		Icon = "",
		Category = "Rare",
		Loop = false,
		Duration = 3,
		MovementLocked = true,
		CombatAllowed = false,
		CancelOnDamage = true,
		Unlock = { Type = "Roll", Pool = "RareEmotes" },
	},
}

return EmoteDefinitions
