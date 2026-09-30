--!strict
--[[
	DebugDummySystem.lua

	Owns: a fresh, from-scratch training dummy for the rebuilt combat stack -- spawning it as a real,
	fully-registered HitboxEngine/DefenseSystem combatant, the server-wide "hold guard" toggle that
	makes Blocked/Parried/GuardBroken testable against it (not just Clean/Backstab), auto-reviving it
	in place after a delay instead of leaving a tester to re-spawn one, and a live BillboardGui showing
	what just happened to it -- plus routing every one of those events through Logger.scope so the same
	activity shows up in the Live Admin Console and in Studio output.

	THIS IS A FRESH BUILD, NOT A REVIVAL. The old training dummy (CombatSystem.SpawnTrainingDummy,
	TrainingBotSystem.lua's AI-controlled sibling) was deleted along with the rest of CombatSystem --
	see AdminActionSystem.lua's and DevMenuSystem.lua's own headers, which still reference it in past
	tense. Nothing here requires or resurrects either deleted module. What DID survive the teardown is
	Constants.Debug.TrainingDummy (MaxHealth/RespawnDelay/SpawnDistance/MaxActive/LabelColor all still
	tuned and waiting -- see that table's own header for the one field, MaxPosture, that no longer
	applies to the rebuilt stack) and the DevMenu_SpawnDummy remote name, both reused rather than
	re-minted.

	A DUMMY IS A REAL COMBATANT, NOT A MOCK. It registers with HitboxEngine.RegisterCombatant and
	DefenseSystem.RegisterCombatant exactly the way a player's own character does (both functions'
	own headers say as much: "anything the engine accepts as a fighter, this accepts as a defender, so
	a bot and a dummy get the same defensive rules a player does with no branching anywhere") --
	so Basic/Heavy/Hotbar moves, Clean/Backstab/GuardBroken/Trade outcomes, and a landed Grab all
	resolve against it through the exact same pipeline a live player goes through. It deliberately
	NEVER registers with AttackRequestSystem -- that layer's own registry is populated only by
	Players.PlayerAdded/CharacterAdded, and a dummy is never a Player, so simply never calling into
	that module is the whole story; there is no exclusion to implement.

	GRAB WORKS FOR FREE, BUT ONLY BECAUSE THE RIG IS UNANCHORED. Server/Combat/Grab/GrabSystem.lua
	welds a held victim into the attacker's assembly, and refuses a grounded (anchored) body outright --
	welding one would pin the attacker in place rather than lift the victim. A dummy's whole body (Humanoid, HumanoidRootPart, every
	limb) is therefore left unanchored, standing under Roblox's own ordinary Humanoid stabilization the
	same way a real character does; WalkSpeed/JumpPower are pinned to 0 instead so it never wanders
	(nothing drives MoveDirection on it anyway -- there is no AI here, unlike TrainingBotSystem's
	deleted sibling). Confirmed, not assumed: this module is exercised end to end by GrabSystem.spec's
	own dummy-shaped rigs, and a live dummy uses the identical RegisterCombatant/PrimaryPart contract.

	THE GUARD TOGGLE IS SERVER-WIDE, NOT PER-DUMMY, AND THAT IS A DELIBERATE SCOPE CALL. A per-dummy
	target picker would need new admin-action plumbing this codebase has never grown (every existing
	action resolves "self" or an explicit roster row -- there is no "pick one of several spawned
	non-player Models" concept anywhere). A blanket toggle covering every currently-active dummy, and
	seeded onto every future one for as long as it stays on, is the simplest design that still makes
	the whole DefenseStateMachine reachable: SetBlocking(model, true, now) is a sustained hold, not a
	timed parry input, so Blocked is trivially testable, and Parried is testable too for a tester who
	raises guard and then lands their own swing inside the resulting window -- every dummy is
	registered with parryAnimationId = nil, which DefenseSystem.RegisterCombatant's own contract
	resolves to the SAME shared default every real player uses (defaultParryAnimationId, set once via
	DefenseSystem.SetDefaultParryAnimation in Main.server.lua), not a dummy-specific stub. A real
	timed-parry BOT (reacting to an incoming swing on its own) is a materially bigger feature and stays
	out of scope here -- its tunables were deleted with TrainingBotSystem.lua since neither ever had a
	caller; re-author them if this gets rebuilt.

	"REVIVE IN PLACE" MEANS DESTROY-AND-RECREATE, HONESTLY. Roblox's own Dead HumanoidStateType is
	terminal -- Constants.Debug.TrainingDummy.RespawnDelay's own header already documented this before
	this module existed. So a defeated dummy is unregistered immediately (it must stop being a legal
	HitboxEngine/DefenseSystem target the instant it dies, same as a real player), waits out
	RespawnDelay showing "Defeated -- reviving" on its own billboard, then the old corpse Model is
	destroyed and a fresh rig is built at the SAME captured spawn CFrame -- never wherever it happened
	to end up (a real risk once Grab can throw it across the room). From a tester's seat this reads as
	"it got back up," which is the whole point; it is a new Instance underneath.

	THE BILLBOARD IS EVENT-DRIVEN, NEVER A POLLING LOOP. This module owns no Heartbeat at all --
	everything it reacts to already has its own signal: DamageSystem.OnApplied for a resolved hit
	(damage, outcome kind, the move's own DebugName), Humanoid.HealthChanged for a live HP number,
	Humanoid:GetAttributeChangedSignal(Grabbed) for a hold starting/ending (GrabSystem's own
	Attribute -- see that module's header; this file never talks to GrabSystem directly, the exact same
	"read the seam, not the system" posture RunSystem/ParkourController already take), and
	Humanoid.Died for the revive cycle above. A one-shot task.delay handles the revive timer itself.
	Nothing here samples anything on a timer.

	    HitboxEngine     where the volume is, who is inside it
	    DefenseSystem    what kind of hit that was
	    DamageSystem     how much it hurts, what it does to you
	    GrabSystem       what happens instead of ordinary knockback, when a move says so
	    DebugDummySystem a disposable, self-narrating target none of the above had to change for  <- this module

	Does not own: whether a hit resolves as Clean/Blocked/Parried/etc. (DefenseSystem/DamageResolver),
	whether a hold/throw is legal (GrabSystem), authorization or rate-limiting for the admin actions
	that drive this module (DevMenuSystem.lua, identical trust boundary to AdminActionSystem's own:
	this module trusts its caller is already an authorized, rate-limited request), or the Admin Menu UI
	itself (Client/UI/Screens/DevTools/DevMenu/).
]]

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants = require(ReplicatedStorage.Shared.Constants)
local CharacterUtil = require(ReplicatedStorage.Shared.CharacterUtil)
local DamageTypes = require(ReplicatedStorage.Shared.Damage.DamageTypes)
local DefenseTypes = require(ReplicatedStorage.Shared.Defense.DefenseTypes)
local Logger = require(ReplicatedStorage.Shared.Logger)

local DamageSystem = require(script.Parent.Parent.Combat.Damage.DamageSystem)
local DefenseSystem = require(script.Parent.Parent.Combat.Defense.DefenseSystem)
local HitboxEngine = require(script.Parent.Parent.Combat.HitboxEngine.HitboxEngine)

type DefenseOutcome = DefenseTypes.DefenseOutcome
type DamageResult = DamageTypes.DamageResult

local logger = Logger.scope("DebugDummySystem")

local DebugDummySystem = {}

local Config = Constants.Debug.TrainingDummy

-- One active dummy's own bookkeeping -- everything this module needs to unregister it, revive it, and
-- keep its billboard current. Never returned to a caller; DebugDummySystem's public surface is
-- entirely functions, not this record.
type Dummy = {
	Model: Model,
	Humanoid: Humanoid,
	RootPart: BasePart,
	CombatantId: number,
	-- Captured once at spawn, never updated -- a revive always returns here, not to wherever a Grab
	-- throw or ordinary knockback carried the body before it died. See this file's header on why
	-- "revive in place" is honest about meaning THIS place, not the current one.
	SpawnCFrame: CFrame,
	LogLabel: TextLabel,
	-- Most-recent-first, capped at Config.LogLineCount by pushLogLine.
	LogLines: { string },
	-- False from the moment Humanoid.Died fires until the fresh replacement takes this entry's place
	-- in `active` -- guards onDummyDied against firing twice for the same corpse (Humanoid.Died only
	-- ever fires once per life, but this is the same defensive idiom GrabSystem's own hold-release
	-- guards use rather than trusting a Roblox event's own documented cardinality).
	Alive: boolean,
	-- True once this entry has been fully retired (revived, individually despawned, or swept by
	-- DespawnAll) -- the guard a stale scheduled revive checks before acting, since a task.delay
	-- callback has no way to be cancelled outright.
	Removed: boolean,
	Connections: { RBXScriptConnection },
}

-- Oldest-first -- index 1 is always the next one MaxActive eviction removes, and the next one
-- DespawnAll iterates first (order does not matter for DespawnAll, but oldest-first is what makes
-- "evict index 1" correct for the MaxActive case).
local active: { Dummy } = {}
local byModel: { [Model]: Dummy } = {}

-- SERVER-WIDE, seeded onto every dummy spawned while it is true -- see this file's header on why a
-- per-dummy toggle was never worth building.
local guardEnabled = false

local dummyFolder: Folder? = nil
local appliedDisconnect: (() -> ())? = nil
local started = false

-- Helpers ------------------------------------------------------------------------------------------

local function debugLog(message: string, data: { [string]: any }?): ()
	logger:debug(message, data)
end

-- Every spawned dummy lives under one Workspace folder rather than loose in Workspace root -- purely
-- organizational (nothing reads this folder back), the same "a dedicated, obviously-named home for a
-- dev-tooling Instance" precedent HitboxEngine's own debug-volume folder (Workspace.
-- HitboxDebugVolumes) already sets.
local function dummyFolderInstance(): Folder
	local existing = dummyFolder
	if existing and existing.Parent ~= nil then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = "DebugDummies"
	folder.Parent = Workspace
	dummyFolder = folder
	return folder
end

-- Building the rig -----------------------------------------------------------------------------------

-- An empty HumanoidDescription (default body parts, no asset upload/reference, no network round trip)
-- is enough for a generic, fully-rigged body, with no asset round trip. Colored to match
-- Config.LabelColor so the body itself reads as "practice dummy" at a glance, not just the nameplate
-- above it.
local function buildRig(): Model
	local description = Instance.new("HumanoidDescription")
	description.HeadColor = Config.LabelColor
	description.TorsoColor = Config.LabelColor
	description.LeftArmColor = Config.LabelColor
	description.RightArmColor = Config.LabelColor
	description.LeftLegColor = Config.LabelColor
	description.RightLegColor = Config.LabelColor

	-- R6, like every character in this game. It was R15, and an R6 clip -- which every animation authored
	-- here is -- silently does nothing on an R15 rig: a grab's VictimAnimation never played on the dummy,
	-- and the dummy was the one victim a solo tester has (TrainingBotSystem's header already named this
	-- trap for bots).
	local model = Players:CreateHumanoidModelFromDescription(description, Enum.HumanoidRigType.R6)
	model.Name = "DebugDummy"
	-- DELIBERATELY UNTAGGED, so hitting a dummy PUTS YOU IN COMBAT like hitting anything else does.
	--
	-- This rig briefly carried Shared/Engagement/EngagementConstants.DummyTag, which exempted it from
	-- the combat tag on the reasoning that a practice target is not an adversary. That was wrong here,
	-- and it contradicted this file's own opening principle -- A DUMMY IS A REAL COMBATANT, NOT A MOCK.
	-- Two concrete reasons it came back out:
	--   * A dummy is the ONLY sparring partner a solo tester has. Exempting it made the entire
	--     engagement layer unreachable without a second client: no HUD readout, no parkour combat
	--     gate, no emote refusal. A debug target that cannot exercise the thing you are debugging is
	--     not serving its purpose.
	--   * The "don't punish someone practising" worry does not apply to THIS rig. It is admin-spawned
	--     dev tooling that no ordinary player ever meets, so the only person it can inconvenience is
	--     the person who deliberately spawned it.
	-- The tag itself still exists and still works -- see EngagementConstants.DummyTag -- for a genuine
	-- non-adversary (a scenery target dummy in a training area that regular players swing at). Nothing
	-- applies it today.
	return model
end

-- The billboard --------------------------------------------------------------------------------------

-- One TextLabel filling the whole BillboardGui rather than a status line plus a separate scrolling
-- log -- simplest thing that reads correctly at a glance, and refreshBillboardText below only ever has
-- one Text property to write. Adornee prefers Head (present on every rig this module builds) and
-- falls back to the root part defensively, in case a future rig source ever lacks one.
local function attachBillboard(model: Model): TextLabel
	local adornee = model:FindFirstChild("Head") or model:FindFirstChild("HumanoidRootPart")

	local gui = Instance.new("BillboardGui")
	gui.Name = "DebugDummyLog"
	gui.Size = Config.BillboardSize
	gui.StudsOffset = Vector3.new(0, 2.5, 0)
	gui.AlwaysOnTop = true
	gui.MaxDistance = 80
	gui.Adornee = if adornee and adornee:IsA("BasePart") then adornee :: BasePart else nil

	local label = Instance.new("TextLabel")
	label.Name = "Log"
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundColor3 = Color3.new(0, 0, 0)
	label.BackgroundTransparency = 0.35
	label.BorderSizePixel = 0
	label.Font = Enum.Font.Code
	label.TextSize = 14
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextYAlignment = Enum.TextYAlignment.Top
	label.TextWrapped = true
	label.Text = ""
	label.Parent = gui

	gui.Parent = model
	return label
end

-- "HP 340/500 | Guard 62/100 | GRABBED" -- read fresh every call rather than cached, since Health and
-- Guard both change on their own schedules this module does not own. DefenseSystem.GetGuard returns
-- (nil, nil) for an unregistered model (a dummy mid-revive, between unregistering and its replacement
-- existing) -- defaulted to 0 rather than erroring, the same defensive-read posture every Attribute
-- read in this combat stack already takes.
local function statusLine(dummy: Dummy): string
	local humanoid = dummy.Humanoid
	local guard, guardMax = DefenseSystem.GetGuard(dummy.Model)
	local grabbedSuffix = if humanoid:GetAttribute(Constants.Attributes.Grabbed) == true then " | GRABBED" else ""
	return string.format(
		"HP %d/%d | Guard %d/%d%s",
		math.max(math.floor(humanoid.Health), 0),
		math.floor(humanoid.MaxHealth),
		math.floor(guard or 0),
		math.floor(guardMax or 0),
		grabbedSuffix
	)
end

local function refreshBillboardText(dummy: Dummy): ()
	if dummy.LogLabel.Parent == nil then
		return
	end
	local lines = { "DEBUG DUMMY", statusLine(dummy) }
	for _, line in dummy.LogLines do
		table.insert(lines, line)
	end
	dummy.LogLabel.Text = table.concat(lines, "\n")
end

-- Appends one line to the rolling log (newest first, capped at Config.LogLineCount) and repaints the
-- billboard. The one function every event source below funnels through, so the cap is enforced in
-- exactly one place.
local function pushLogLine(dummy: Dummy, line: string): ()
	table.insert(dummy.LogLines, 1, line)
	while #dummy.LogLines > Config.LogLineCount do
		table.remove(dummy.LogLines)
	end
	refreshBillboardText(dummy)
end

-- Registry lifecycle -----------------------------------------------------------------------------

-- Drops this dummy's HitboxEngine/DefenseSystem registration and every listener it owns. Idempotent --
-- both engines' own Unregister functions already no-op on an unknown id/model, and disconnecting an
-- already-disconnected RBXScriptConnection is a documented no-op -- so this is safe to call from both
-- onDummyDied and a DespawnAll sweep without either needing to know whether the other already ran.
local function unregisterCombat(dummy: Dummy): ()
	HitboxEngine.UnregisterCombatant(dummy.CombatantId)
	DefenseSystem.UnregisterCombatant(dummy.Model)
	for _, connection in dummy.Connections do
		connection:Disconnect()
	end
	table.clear(dummy.Connections)
end

-- Forward-declared: onDummyDied schedules a call to this, and this is defined further down (it needs
-- spawnAt, which is defined after the event-source connections onDummyDied itself sets up).
local reviveInPlace: (dummy: Dummy) -> ()

-- Humanoid.Died handler -- unregisters immediately (a dead body must stop being a legal target on the
-- same frame it dies, same as a real player), leaves the corpse and its billboard in place so
-- "Defeated -- reviving in Xs" is visible, then schedules the swap. See this file's header on why this
-- is destroy-and-recreate rather than a true in-place heal.
local function onDummyDied(dummy: Dummy): ()
	if not dummy.Alive then
		return
	end
	dummy.Alive = false
	unregisterCombat(dummy)
	pushLogLine(dummy, `[Defeated] Reviving in {Config.RespawnDelay}s`)
	logger:info("Debug dummy defeated", { model = dummy.Model.Name })

	task.delay(Config.RespawnDelay, function()
		reviveInPlace(dummy)
	end)
end

-- The event log's one narration function -- "[Clean] 18 dmg (default:Primary:Basic:1)" or
-- "[Blocked] (default:Primary:Heavy:1)" for a zero-damage outcome. outcome.Report.DebugName is the
-- same MoveId DamageSystem's own applyOutcome resolves through AttackCatalog -- carried here as-is
-- rather than re-resolving the catalogue entry, since a name is all this billboard needs to say.
local function describeOutcome(outcome: DefenseOutcome, result: DamageResult): string
	local moveId = outcome.Report.DebugName
	if result.Damage > 0 then
		return string.format("[%s] %.1f dmg (%s)", outcome.Kind, result.Damage, moveId)
	end
	return string.format("[%s] (%s)", outcome.Kind, moveId)
end

-- DamageSystem.OnApplied fires for EVERY resolved contact in the server, not just this module's own
-- dummies -- the byModel lookup below is what makes this a no-op for every hit that has nothing to do
-- with a dummy, the same "cheap table read, ignore what is not mine" filter GrabSystem's own
-- onDamageApplied uses against DamageResult.Grab.
local function onDamageApplied(outcome: DefenseOutcome, result: DamageResult): ()
	local dummy = byModel[outcome.Defender]
	if not dummy then
		return
	end
	pushLogLine(dummy, describeOutcome(outcome, result))
	debugLog("Debug dummy hit", {
		model = dummy.Model.Name,
		kind = outcome.Kind,
		damage = result.Damage,
		moveId = outcome.Report.DebugName,
	})
end

-- Builds one dummy at `spawnCFrame`, registers it with the engine and the defence layer, wires its
-- billboard/event listeners, seeds the current server-wide guard state onto it, and appends it to
-- `active`. Returns nil (logged) only if the rig itself fails to build -- everything after that point
-- is this module's own Instances and cannot fail the same way.
local function spawnAt(spawnCFrame: CFrame): Model?
	local ok, modelOrError = pcall(buildRig)
	if not ok then
		logger:error("Failed to build debug dummy rig", { errorMessage = tostring(modelOrError) })
		return nil
	end
	local model = modelOrError :: Model
	model:PivotTo(spawnCFrame)
	model.Parent = dummyFolderInstance()

	local humanoid = CharacterUtil.HumanoidOf(model)
	local rootPart = CharacterUtil.RootOf(model)
	-- Defensive rather than expected to ever trip -- every rig CreateHumanoidModelFromDescription
	-- produces has both, but a malformed rig must not reach RegisterCombatant with a nil dressed as a
	-- real Instance (the same failure mode DamageSystem.humanoidOf's own typeof guard exists to avoid
	-- one layer up).
	if not humanoid or not rootPart then
		logger:error("Debug dummy rig built with no Humanoid/HumanoidRootPart", { model = model.Name })
		model:Destroy()
		return nil
	end

	humanoid.MaxHealth = Config.MaxHealth
	humanoid.Health = Config.MaxHealth
	-- Never moves on its own -- there is no AI here, unlike the deleted TrainingBotSystem's bots, so
	-- this is belt-and-suspenders against nothing ever calling Humanoid:MoveTo/Move rather than a
	-- meaningful behavioral choice.
	humanoid.WalkSpeed = 0
	humanoid.JumpPower = 0

	-- Registers exactly the way a player's own character does -- see this file's header. parryAnimationId
	-- is deliberately nil, NOT a dummy-specific stub: DefenseSystem.RegisterCombatant's own contract
	-- (`parryAnimationId or defaultParryAnimationId`) resolves that to the same shared default clip
	-- every real player inherits, so a dummy can be Parried, not merely Blocked.
	local combatantId = HitboxEngine.RegisterCombatant(model, rootPart, humanoid)
	DefenseSystem.RegisterCombatant(model, rootPart, humanoid, nil)

	local logLabel = attachBillboard(model)

	local dummy: Dummy = {
		Model = model,
		Humanoid = humanoid,
		RootPart = rootPart,
		CombatantId = combatantId,
		SpawnCFrame = spawnCFrame,
		LogLabel = logLabel,
		LogLines = {},
		Alive = true,
		Removed = false,
		Connections = {},
	}

	table.insert(
		dummy.Connections,
		humanoid.Died:Connect(function()
			onDummyDied(dummy)
		end)
	)
	table.insert(
		dummy.Connections,
		humanoid.HealthChanged:Connect(function()
			refreshBillboardText(dummy)
		end)
	)
	table.insert(
		dummy.Connections,
		humanoid:GetAttributeChangedSignal(Constants.Attributes.Grabbed):Connect(function()
			local grabbed = humanoid:GetAttribute(Constants.Attributes.Grabbed) == true
			pushLogLine(dummy, if grabbed then "[Grab] Held" else "[Grab] Released")
		end)
	)

	if guardEnabled then
		DefenseSystem.SetBlocking(model, true, os.clock())
	end

	refreshBillboardText(dummy)
	table.insert(active, dummy)
	byModel[model] = dummy

	logger:info("Debug dummy spawned", { model = model.Name, activeCount = #active })
	return model
end

-- Removes `dummy` from the live tables without touching the Instance itself -- shared by
-- reviveInPlace (which destroys the old model right after) and the MaxActive eviction/DespawnAll paths
-- (which do the same). Kept separate from unregisterCombat above because a dummy can leave `active`
-- for a reason that has nothing to do with combat registration (e.g. it was already unregistered by
-- onDummyDied and is only now being swapped for its replacement).
local function removeFromActive(dummy: Dummy): ()
	local index = table.find(active, dummy)
	if index then
		table.remove(active, index)
	end
	byModel[dummy.Model] = nil
	dummy.Removed = true
end

reviveInPlace = function(dummy: Dummy): ()
	-- Already handled by something else in the meantime (a DespawnAll that ran during the delay) --
	-- see Dummy.Removed's own header for why this check exists at all: a task.delay callback has no
	-- way to be cancelled outright, only checked against once it fires.
	if dummy.Removed then
		return
	end
	local spawnCFrame = dummy.SpawnCFrame
	removeFromActive(dummy)
	if dummy.Model.Parent ~= nil then
		dummy.Model:Destroy()
	end
	spawnAt(spawnCFrame)
end

-- Public ------------------------------------------------------------------------------------------

-- Spawns one dummy at `spawnCFrame`, evicting the OLDEST active one first if this would exceed
-- Config.MaxActive -- see that constant's own header. Returns (nil, reason) only when the rig itself
-- failed to build; DevMenuSystem's own handler is what turns that into a DevMenuActionResult.
function DebugDummySystem.Spawn(spawnCFrame: CFrame): (Model?, string?)
	if #active >= Config.MaxActive then
		local oldest = active[1]
		unregisterCombat(oldest)
		removeFromActive(oldest)
		if oldest.Model.Parent ~= nil then
			oldest.Model:Destroy()
		end
		debugLog("Debug dummy evicted (MaxActive reached)", { model = oldest.Model.Name })
	end

	local model = spawnAt(spawnCFrame)
	if not model then
		return nil, "SpawnFailed"
	end
	return model, nil
end

-- Despawns every currently-active dummy (including one mid-revive-delay -- its pending
-- reviveInPlace call will see Dummy.Removed and no-op) and returns how many were live at the moment
-- of the call.
function DebugDummySystem.DespawnAll(): number
	local count = #active
	-- Iterated over a snapshot, not `active` itself -- removeFromActive mutates `active` in place, and
	-- iterating a table while removing from the middle of it is exactly the mistake that invites.
	local snapshot = table.clone(active)
	for _, dummy in snapshot do
		unregisterCombat(dummy)
		removeFromActive(dummy)
		if dummy.Model.Parent ~= nil then
			dummy.Model:Destroy()
		end
	end
	logger:info("All debug dummies despawned", { count = count })
	return count
end

-- Sets the server-wide guard toggle and applies it to every dummy alive right now -- see this file's
-- header on why this is a blanket toggle rather than a per-dummy one. Returns the value that actually
-- took effect (always `enabled` here -- there is no rejection path -- but returned rather than assumed
-- for the same "never let the client optimistically guess a server-wide toggle" reasoning
-- SetHitboxDebug's own header gives).
function DebugDummySystem.SetGuard(enabled: boolean): boolean
	guardEnabled = enabled
	local now = os.clock()
	for _, dummy in active do
		if dummy.Alive then
			DefenseSystem.SetBlocking(dummy.Model, enabled, now)
			pushLogLine(dummy, if enabled then "[Guard] Raised" else "[Guard] Lowered")
		end
	end
	logger:info("Debug dummy guard toggled", { enabled = enabled, activeCount = #active })
	return guardEnabled
end

function DebugDummySystem.IsGuardEnabled(): boolean
	return guardEnabled
end

function DebugDummySystem.ActiveCount(): number
	return #active
end

-- Lifecycle ----------------------------------------------------------------------------------------

-- Subscribes to the damage layer's outcome signal, and nothing else -- split out of Init for the same
-- reason every other DamageSystem.OnApplied subscriber in this stack (DamageSystem's own Attach,
-- GrabSystem.Attach) keeps the two separate: a spec has to drive this module without a real Heartbeat
-- racing it, and this module has no Heartbeat of its own to race in the first place, but the split is
-- kept anyway for the same idempotent-resubscribe contract those two already establish. Idempotent.
function DebugDummySystem.Attach(): ()
	if appliedDisconnect then
		return
	end
	appliedDisconnect = DamageSystem.OnApplied(onDamageApplied)
end

function DebugDummySystem.Init(): ()
	if started then
		return
	end
	-- Same "a comment cannot fail a boot" posture every other Init in this stack takes -- this module
	-- has no Heartbeat ordering to assert (see this file's header on why it owns none at all), only
	-- that the one signal it subscribes to already exists.
	assert(DamageSystem.OnApplied ~= nil, "DebugDummySystem.Init() requires DamageSystem to be available")
	started = true
	DebugDummySystem.Attach()
	logger:info("DebugDummySystem.Init() complete")
end

function DebugDummySystem.Shutdown(): ()
	if appliedDisconnect then
		appliedDisconnect()
		appliedDisconnect = nil
	end
	started = false
end

-- Drops every active dummy and every subscription, and clears the server-wide guard flag -- spec-only,
-- so one case cannot serve another its state, the same role Reset plays for every other module in this
-- stack.
function DebugDummySystem.Reset(): ()
	if appliedDisconnect then
		appliedDisconnect()
		appliedDisconnect = nil
	end
	DebugDummySystem.DespawnAll()
	guardEnabled = false
end

return DebugDummySystem
