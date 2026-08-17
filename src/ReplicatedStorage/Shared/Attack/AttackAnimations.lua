--!strict
--[[
	AttackAnimations.lua

	Owns: which animation clip each hand-authored attack plays. THIS IS THE ONE FILE TO EDIT to give
	swings an animation -- paste an asset id next to a MoveId below and that attack animates on the
	very next swing, with no other change anywhere.

	WHY THIS FILE EXISTS AT ALL, given the Move Creation System already has an AnimationId field.
	Because that field is only reachable for a CUSTOM move. A "Default" move -- every hand-authored
	attack in Constants.Combat.Weapons, which is the entire live move set -- is a fresh projection built
	by DefaultMoveRegistry on every read, and that projection hardcodes AnimationId = "" and never
	stores one (see its own header: the Move Editor deliberately hides the Animation section for
	Category == "Default"). So a Default move has nowhere to put a clip id, and before this file the
	whole live move set was structurally unable to have an animation. This is that missing shelf.

	THE PRECEDENCE IS: an authored MoveDefinition.AnimationId wins, and this table is the fallback --
	see AttackCatalog.Get, which is the one place the two are combined. A custom move authored in the
	Move Editor with a real clip keeps it; a Default move with nothing to author reaches here.

	"" MEANS "WIRED, NOT YET AUTHORED", the same convention Constants.Combat.AnimationIds and
	Constants.Flight.AnimationIds already use, and it is a first-class value here rather than an
	oversight: every slot below is deliberately blank because THIS REPO DOES NOT GUESS ASSET IDS (see
	Constants.UI.VitalIconIds' own note, and AdminConfig's "never guess or invent a UserId"). A blank id
	resolves to no clip and no error anywhere -- AnimationManager refuses the claim silently, and
	Client/Combat/AttackInputClient.lua returns before even making it. The swing still happens, still
	hits, still deals damage; it just is not animated yet.

	SO: to animate the game's attacks, upload the clips and fill in the strings below. Nothing else has
	to change -- not the client, not the server, not the catalogue, not the preloader (which sweeps
	GetPreloadIds below, so an id pasted here is warm before the first swing rather than hitching on it).

	EITHER FORM OF ID WORKS -- a bare "82318659005476" or a full "rbxassetid://82318659005476". The
	engine only understands the second, but the first is what Roblox's own asset page, Toolbox and
	Creator Dashboard all display, so it is what actually gets pasted. See normalize() below for why
	that mismatch is worth a helper rather than a rule an author has to remember: a bare id resolves to
	nothing, silently, in a file that looks correctly filled in.

	ONE CLIP PER MOVE, not a timeline. The Move Creation System's richer MoveDefinition.Animations list
	(AnimationTimeline.Clip, with per-clip start/stop/speed/fade/blend control) is not reached from here
	-- it is a custom-move authoring feature, and its runtime playback path went with the combat
	teardown. A single clip per attack is what the rebuilt client actually plays today; when timeline
	playback comes back, this file is the fallback it falls back TO, not something it replaces.

	Does not own: playing anything (Client/Combat/AttackInputClient.lua claims the clip through
	Shared/Animation/AnimationManager.lua), which move a press throws (SwingSequencer), or the timing
	the clip should sync to (AttackTypes.AttackStartedPayload carries the server's real windup/active/
	recovery for exactly that).
]]

local AttackAnimations = {}

-- MoveId -> animation asset id. Keys are DefaultMoveRegistry's own synthetic ids, which is the same
-- scheme SwingSequencer builds when it resolves a press -- see that module for how one is formed.
--
-- An id not listed here is not an error: Get returns "" for anything unknown, which is exactly what an
-- unauthored slot resolves to anyway. Add a key when there is a clip to put in it.
local IDS: { [string]: string } = {
	-- Primary weapon ------------------------------------------------------------------------------
	-- The light string. Three stages, thrown in order, wrapping back to 1 -- so these three read as a
	-- sequence and are worth authoring as one: a clip that ends where the next begins.
	["default:Primary:Basic:1"] = "82318659005476",
	["default:Primary:Basic:2"] = "98404078606361",
	["default:Primary:Basic:3"] = "91462396635095",
	-- The heavy string. Two stages, much longer windups (0.6s on stage 1) -- a clip here has real room
	-- to telegraph, which is the whole point of a heavy in this game's defence model: the windup IS the
	-- tell a defender parries off.
	["default:Primary:Heavy:1"] = "",
	["default:Primary:Heavy:2"] = "",
	-- Thrown only when a full Basic string LANDED (AttackConstants.Finisher.MinComboStage) -- the
	-- payoff swing, and the one most worth a distinctive clip.
	["default:Primary:Finisher"] = "",

	-- Secondary weapon ----------------------------------------------------------------------------
	["default:Secondary:Basic:1"] = "",
	["default:Secondary:Basic:2"] = "",
	["default:Secondary:Basic:3"] = "",
	["default:Secondary:Heavy:1"] = "",
	["default:Secondary:Heavy:2"] = "",
	["default:Secondary:Finisher"] = "",

	-- Standalone attacks --------------------------------------------------------------------------
	-- Catalogued and throwable through the hotbar, but not part of either string. Listed so they are
	-- authorable from the same place rather than being the one set that needs a different mechanism.
	["default:DashPunch"] = "",
	["default:DashHit"] = "",
	["default:AirSlam"] = "",
}

-- Re-exported so the table is browsable (a debug readout, a future editor listing every animatable
-- attack) without every reader having to go through Get one id at a time. Assigned rather than
-- declared inline because Luau has no syntax for annotating a field's type at its assignment site,
-- and the annotation is what keeps a typo'd key from silently typing as something else.
AttackAnimations.Ids = IDS

-- Accepts an asset id in either form an author might reasonably paste and returns the one the engine
-- actually understands.
--
-- WHY THIS IS NOT PEDANTRY. Roblox's own asset page, the Toolbox and the Creator Dashboard all show a
-- bare number, so a bare number is what gets copied -- but AnimationManager.resolveAssetId accepts a
-- registry key or a string matching "^rbxassetid://" and treats EVERYTHING ELSE as an unauthored slot.
-- A bare id therefore resolves to nil, the claim is refused, and the swing silently plays no
-- animation -- with no error, no warning, and a config file that looks correctly filled in. That is
-- the worst possible failure for the one file whose whole promise is "paste an id here and it works",
-- so this normalises rather than making the promise conditional on knowing the prefix.
--
-- Left as-is if the prefix is already there, so both forms are equally correct to author.
local function normalize(assetId: string): string
	if assetId == "" then
		return ""
	end
	if string.match(assetId, "^rbxassetid://") then
		return assetId
	end
	-- Digits only. Anything else -- a full URL, a typo, a name -- is passed through untouched rather
	-- than guessed at: prefixing a malformed id would turn "this did nothing" into "this points at
	-- someone else's asset", which is far harder to notice.
	if string.match(assetId, "^%d+$") then
		return `rbxassetid://{assetId}`
	end
	return assetId
end

-- The clip for `moveId`, or "" when it has none. Never nil, never errors on an unknown id -- callers
-- treat "" and "unknown" identically ("do not claim a clip"), so distinguishing them would only give
-- every call site a second case to get wrong.
function AttackAnimations.Get(moveId: string): string
	if typeof(moveId) ~= "string" then
		return ""
	end
	return normalize(IDS[moveId] or "")
end

-- Every non-blank id, deduplicated, for Client/Loading/AssetPreloader.lua's boot-time sweep.
--
-- Returns raw content ids rather than Animation Instances, the same contract
-- DefenseClient.GetPreloadInstances and ParkourAnimator's own provider already use -- AnimationManager
-- pools its template Instances internally and does not hand them out.
--
-- Deduplicated because sharing one clip across several stages is a completely reasonable thing to do
-- while authoring (and is exactly what Constants.Flight.AnimationIds does across its own six slots),
-- and preloading the same id six times is six times the work for one asset.
function AttackAnimations.GetPreloadIds(): { string }
	local seen: { [string]: boolean } = {}
	local ids: { string } = {}
	for _, raw in IDS do
		-- Normalised here too, not just in Get: ContentProvider is as literal about the prefix as the
		-- animation loader is, so preloading a bare id would warm nothing while the real one still
		-- cold-loads on the first swing.
		local id = normalize(raw)
		if id ~= "" and not seen[id] then
			seen[id] = true
			table.insert(ids, id)
		end
	end
	return ids
end

return AttackAnimations
