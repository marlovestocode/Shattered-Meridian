--!strict
--[[
	TrainingBotSystem.lua

	Owns: the AI sparring partner -- spawning it as a real combatant, reading the fight the way a player
	reads it, handing that to TrainingBotBrain, and carrying out what the brain decides through the SAME
	public entry points a player's remotes reach. Also its body: movement, facing, the roll, every clip
	it plays, its nameplate narration, and its death/revive cycle.

	    HitboxEngine        where the volume is, who is inside it
	    DefenseSystem       what kind of hit that was
	    DamageSystem        how much it hurts, what it does to you
	    AttackRequestSystem what you are trying to throw, and whether you may
	    TrainingBotSystem   a second player, played by the server                     <- this module

	A SIBLING OF THE TOP LAYER, NOT A FIFTH ONE -- the shape CLAUDE.md asks new combat work to default to.
	It consumes existing public surfaces and extension points and nothing in the stack knows it exists:
	  * acts through AttackRequestSystem.Throw/Feint and DefenseSystem.SetBlocking/BeginEvade -- each of
	    which is public precisely "so a bot's decision-making can throw through exactly the same path a
	    player's press does" (their own headers). Every gate a player is refused by, it is refused by:
	    hitstun, stagger, guard-held, cooldowns, the chain beat, the feint window, the evade cooldown.
	  * reads through queries that already existed (HitboxEngine.GetAttackState, DefenseSystem.GetState/
	    GetGuard, the HitstunUntil/CombatBusyUntil/RootControlLocked/Grabbed Attributes) plus ONE new
	    one, AttackRequestSystem.GetInFlight -- which move an opponent started and when, i.e. what a
	    player reads off the windup animation. See that function's own header.
	  * learns from DamageSystem.OnApplied, the documented extension point GrabSystem, EngagementSystem
	    and DebugDummySystem already subscribe through.
	  * registers with HitboxEngine and DefenseSystem exactly the way DebugDummySystem does, and arms
	    itself through AttackRequestSystem.SetWeapon -- so WeaponVisualSystem puts a real Tool in its hand
	    and Main.server.lua's OnWeaponChanged hookup gives it the same per-weapon parry clip (and window)
	    a player holding that weapon gets.

	WHY THE SERVER PLAYS ITS CLIPS. A player's swing/guard/evade clips are played by that player's own
	client on their own Animator and replicate from there (AttackInputClient, DefenseClient,
	ParkourAnimator). The bot has no client, and Attack_Started is only ever sent to a Player. So this
	module plays the same clips -- resolved through the same AttackCatalog entry, WeaponDefenseAnimations
	and EvadeConstants.AnimationIds -- on the bot's server-owned Animator through Shared/Animation/
	AnimationManager (which was written to own "a bot, an NPC" rig as well as the local player's), and
	they replicate to everyone. That is what makes the bot READABLE: you parry its swing off its windup
	exactly as you would a person's.

	THE BODY IS SERVER-OWNED. SetNetworkOwner(nil) at spawn, or the engine hands a nearby player's
	client the physics and every Humanoid:Move and CFrame write here is silently discarded (the
	mirror-image of Server Humanoid:Move being inert on a PLAYER). Knockback therefore lands through
	DamageSystem.applyLaunch's own server-owned branch ("a bot, or a dummy that is not anchored"),
	and GrabSystem's hold weld can carry it (handing it back to the server, not to Auto, on release) --
	so everything a player can do to a player, they can do to it. While Grabbed, this module writes
	nothing to the body at all.

	R6, ON PURPOSE. The game is R6-locked and every authored clip is R6; a bot built R15 (as
	DebugDummySystem's static dummy is) would be refused every clip here without an error.

	IT REMEMBERS YOU ACROSS DEATHS. A defeated bot is rebuilt at its spawn point after RespawnDelay (the
	same honest destroy-and-recreate DebugDummySystem does, for the same reason: Dead is terminal), but
	the Brain -- and with it the habit read on you -- carries over. Its composure and in-flight plans do
	not.

	TARGETING: whoever spawned it while they are alive and within LeashRange, otherwise the nearest live
	player within it, otherwise it walks home. Re-evaluated a few times a second, not per frame.

	Does not own: any decision (TrainingBotBrain.lua), any tunable (Shared/TrainingBot/
	TrainingBotConstants.lua), any combat rule (the four layers), or who may spawn one (DevMenuSystem's
	whitelist gate -- this module trusts its caller, the same trust boundary DebugDummySystem keeps).
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AnimationManager = require(ReplicatedStorage.Shared.Animation.AnimationManager)
local AttackConstants = require(ReplicatedStorage.Shared.Attack.AttackConstants)
local AttackTypes = require(ReplicatedStorage.Shared.Attack.AttackTypes)
local CharacterUtil = require(ReplicatedStorage.Shared.CharacterUtil)
local CombatConstants = require(ReplicatedStorage.Shared.Combat.CombatConstants)
local Constants = require(ReplicatedStorage.Shared.Constants)
local DamageTypes = require(ReplicatedStorage.Shared.Damage.DamageTypes)
local DefenseConstants = require(ReplicatedStorage.Shared.Defense.DefenseConstants)
local DefenseTypes = require(ReplicatedStorage.Shared.Defense.DefenseTypes)
local Logger = require(ReplicatedStorage.Shared.Logger)
local EvadeConstants = require(ReplicatedStorage.Shared.Combat.EvadeConstants)
local EvadeMotion = require(ReplicatedStorage.Shared.Combat.EvadeMotion)
local AirComboAttributes = require(ReplicatedStorage.Shared.AirCombo.AirComboAttributes)
local AirComboConstants = require(ReplicatedStorage.Shared.AirCombo.AirComboConstants)
local ParryWindows = require(ReplicatedStorage.Shared.Defense.ParryWindows)
local TrainingBotConstants = require(ReplicatedStorage.Shared.TrainingBot.TrainingBotConstants)
local Trove = require(ReplicatedStorage.Shared.Trove)
local Types = require(ReplicatedStorage.Shared.Types)
local WeaponDefenseAnimations = require(ReplicatedStorage.Shared.Defense.WeaponDefenseAnimations)
local WeaponIdleAnimations = require(ReplicatedStorage.Shared.Combat.WeaponIdleAnimations)
local WeaponRoster = require(ReplicatedStorage.Shared.Combat.WeaponRoster)

local AttackCatalog = require(script.Parent.Parent.AttackCatalog)
local AttackRequestSystem = require(script.Parent.Parent.Attack.AttackRequestSystem)
local AirComboSystem = require(script.Parent.Parent.AirCombo.AirComboSystem)
local DamageSystem = require(script.Parent.Parent.Damage.DamageSystem)
local DefenseSystem = require(script.Parent.Parent.Defense.DefenseSystem)
local HitboxEngine = require(script.Parent.Parent.HitboxEngine.HitboxEngine)
local GameplayEvents = require(script.Parent.Parent.Parent.Events.GameplayEvents)
local TrainingBotBrain = require(script.Parent.TrainingBotBrain)

type DefenseOutcome = DefenseTypes.DefenseOutcome
type DamageResult = DamageTypes.DamageResult
type Brain = TrainingBotBrain.Brain
type Intent = TrainingBotBrain.Intent
type Perception = TrainingBotBrain.Perception
type SwingView = TrainingBotBrain.SwingView

local logger = Logger.scope("TrainingBotSystem")

local TrainingBotSystem = {}

local Config = TrainingBotConstants.Config

-- Animation layers on the bot's own AnimationManager. One exclusive slot each, so a swing, a guard, a
-- roll and the walk cycle never have to negotiate with each other by hand.
local LAYER_LOCOMOTION = "Locomotion"
local LAYER_ATTACK = "Attack"
local LAYER_DEFENSE = "Defense"
local LAYER_TRAVERSAL = "Traversal"
local SOURCE = "TrainingBot"

-- The DefenseStates in which a guard is actually up -- what the guard POSE is shown for. Driven off the
-- server's own state rather than the bot's wish to guard, so a press DefenseSystem is holding until the
-- body is free (SetBlocking's deferral) is not shown as a guard it does not yet have.
local GUARD_UP: { [string]: boolean } = { Raising = true, ParryWindow = true, Blocking = true }
-- The DefenseStates in which the bot cannot act at all.
local DISABLED_STATES: { [string]: boolean } = { Staggered = true, GuardBroken = true }

-- The bot's evade directions, to the directional clips a player's evade plays for the same direction
-- (EvadeConstants.AnimationIds). Blank means "not authored": no clip -- the same glide a player's is.
local EVADE_CLIPS: { [string]: string } = {
	Back = EvadeConstants.AnimationIds.Back,
	Left = EvadeConstants.AnimationIds.Left,
	Right = EvadeConstants.AnimationIds.Right,
}

local THROW_RETRY_SECONDS = 0.05
local RETARGET_SECONDS = 0.4
local MOVING_SPEED = 1.5

type Bot = {
	Id: number,
	Model: Model,
	Humanoid: Humanoid,
	Root: BasePart,
	CombatantId: number,
	StyleName: TrainingBotConstants.StyleName,
	DifficultyName: TrainingBotConstants.DifficultyName,
	Owner: Player?,
	SpawnCFrame: CFrame,
	Brain: Brain,
	Animations: AnimationManager.AnimationManagerInstance,
	Life: Trove.TroveInstance,
	Label: TextLabel,
	WeaponId: Types.WeaponId?,
	Alive: boolean,
	Removed: boolean,

	Target: Model?,
	-- A target set through SetTarget, which wins over the player search while it is a live combatant.
	ForcedTarget: Model?,
	NextRetargetAt: number,
	NextThrowAt: number,
	NextBillboardAt: number,
	LastEvadeAt: number,
	-- When the current evade glide started, and which way it goes. EvadeStartedAt = -math.huge is "not
	-- evading"; the glide is over once EvadeMotion.SpeedAt says so.
	EvadeStartedAt: number,
	EvadeDirection: Vector3,
	-- When the swing currently presented on the attack layer is scheduled to finish, or nil.
	SwingEndsAt: number?,
	GuardShown: boolean,
	GuardHeld: boolean,
	-- When its guard last came down -- the clock DefenseConstants.Parry.MinUnguardedSeconds runs on.
	GuardReleasedAt: number,
	LocomotionClip: string?,
	LastAttacker: Player?,
}

local active: { Bot } = {}
local byModel: { [Model]: Bot } = {}
local nextId = 0

local started = false
-- The clock of the most recent Step -- what an outcome callback (which has no clock of its own) hands
-- the brain, so it stays on the same timeline as everything Step handed it.
local lastStepNow = 0
local heartbeatTrove = Trove.New()
local appliedDisconnect: (() -> ())? = nil
local botFolder: Folder? = nil

-- Helpers ------------------------------------------------------------------------------------------

local function folderInstance(): Folder
	local existing = botFolder
	if existing and existing.Parent ~= nil then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = "TrainingBots"
	folder.Parent = Workspace
	botFolder = folder
	return folder
end

local function flat(vector: Vector3): Vector3
	return Vector3.new(vector.X, 0, vector.Z)
end

local function unitOr(vector: Vector3, fallback: Vector3): Vector3
	if vector.Magnitude < 1e-4 then
		return fallback
	end
	return vector.Unit
end

-- Degrees between two horizontal directions.
local function angleBetween(a: Vector3, b: Vector3): number
	local fa, fb = flat(a), flat(b)
	if fa.Magnitude < 1e-4 or fb.Magnitude < 1e-4 then
		return 0
	end
	return math.deg(math.acos(math.clamp(fa.Unit:Dot(fb.Unit), -1, 1)))
end

local function numberAttribute(humanoid: Humanoid, name: string): number
	local value = humanoid:GetAttribute(name)
	return if typeof(value) == "number" then value else 0
end

-- How far a weapon's swing reaches, root to target root, as the bot judges it. The house swing is a
-- root-anchored box whose far face sits at -Offset.Z + Size.Z/2 studs; 85% of that is where a hit is
-- dependable rather than a graze on the box's edge. A Blade-mode weapon swings its own blade part,
-- which no config number describes, so it falls back.
local function reachFor(weaponId: Types.WeaponId?): number
	if weaponId == nil then
		return Config.FallbackReach
	end
	local hitbox = WeaponRoster.SwingHitbox(weaponId)
	if hitbox.Mode == "Blade" then
		return Config.FallbackReach
	end
	local far = -hitbox.Offset.Position.Z + hitbox.Size.Z * 0.5
	return math.clamp(far * 0.85, 3, 14)
end

-- The parry window a guard press opens for this weapon -- the same resolution DefenseSystem.pressGuard
-- makes (the weapon's own parry clip, else the shared default), so the bot aims its press at the
-- window that will actually open. Defaults to the registered house window if neither is armed yet.
local function parryWindowFor(weaponId: Types.WeaponId?): (number, number)
	local window = ParryWindows.Get(WeaponDefenseAnimations.GetParry(weaponId))
		or ParryWindows.Get(DefenseConstants.ParryAnimationId)
	if window then
		return window.Open, window.Close
	end
	return 0, 0.2
end

local function swingViewOf(model: Model): SwingView?
	local view = AttackRequestSystem.GetInFlight(model)
	if not view then
		return nil
	end
	return {
		StartedAt = view.StartedAt,
		WindupSeconds = view.WindupSeconds,
		Feintable = view.Feintable,
		Heavy = view.PowerLevel >= 2,
	}
end

local function attackStateOf(model: Model): string
	local id = HitboxEngine.GetCombatantId(model)
	if not id then
		return "Idle"
	end
	return HitboxEngine.GetAttackState(id) or "Idle"
end

local function guardFractionOf(model: Model): number
	local guard, guardMax = DefenseSystem.GetGuard(model)
	if guard == nil or guardMax == nil or guardMax <= 0 then
		return 1
	end
	return math.clamp(guard / guardMax, 0, 1)
end

-- The rig ------------------------------------------------------------------------------------------

local function buildRig(): Model
	local description = Instance.new("HumanoidDescription")
	local color = Config.BillboardColor
	description.HeadColor = Color3.fromRGB(234, 184, 146)
	description.TorsoColor = color
	description.LeftArmColor = color
	description.RightArmColor = color
	description.LeftLegColor = Color3.fromRGB(40, 36, 44)
	description.RightLegColor = Color3.fromRGB(40, 36, 44)
	local model = Players:CreateHumanoidModelFromDescription(description, Enum.HumanoidRigType.R6)
	model.Name = "TrainingBot"
	return model
end

local function attachBillboard(model: Model): TextLabel
	local adornee = model:FindFirstChild("Head") or model:FindFirstChild("HumanoidRootPart")

	local gui = Instance.new("BillboardGui")
	gui.Name = "TrainingBotLog"
	gui.Size = UDim2.fromOffset(320, 94)
	gui.StudsOffset = Vector3.new(0, 3, 0)
	gui.AlwaysOnTop = true
	gui.MaxDistance = 90
	gui.Adornee = if adornee and adornee:IsA("BasePart") then adornee :: BasePart else nil

	local label = Instance.new("TextLabel")
	label.Name = "Log"
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundColor3 = Color3.new(0, 0, 0)
	label.BackgroundTransparency = 0.4
	label.BorderSizePixel = 0
	label.Font = Enum.Font.Code
	label.TextSize = 13
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextYAlignment = Enum.TextYAlignment.Top
	label.TextWrapped = true
	label.Text = ""
	label.Parent = gui

	gui.Parent = model
	return label
end

local function refreshBillboard(bot: Bot): ()
	if bot.Label.Parent == nil then
		return
	end
	local humanoid = bot.Humanoid
	local guard, guardMax = DefenseSystem.GetGuard(bot.Model)
	local brain = bot.Brain
	bot.Label.Text = table.concat({
		`TRAINING BOT | {bot.StyleName} | {bot.DifficultyName} | {bot.WeaponId or "Unarmed"}`,
		string.format(
			"HP %d/%d | Guard %d/%d | Nerve %d%%",
			math.max(math.floor(humanoid.Health), 0),
			math.floor(humanoid.MaxHealth),
			math.floor(guard or 0),
			math.floor(guardMax or 0),
			math.floor(brain.Composure * 100 + 0.5)
		),
		if bot.Alive then `> {brain.Narration}` else `> Defeated -- back in {Config.RespawnDelay}s`,
		`Read: {TrainingBotBrain.DescribeRead(brain)}`,
		TrainingBotBrain.DescribeAnswers(brain),
	}, "\n")
end

-- Presentation -------------------------------------------------------------------------------------

local function presentSwing(bot: Bot, moveId: string, now: number): ()
	local entry = AttackCatalog.Get(moveId)
	if not entry then
		return
	end
	local total = entry.Definition.WindupSeconds + entry.Definition.ActiveSeconds + entry.Definition.RecoverySeconds
	bot.SwingEndsAt = now + total
	if entry.AnimationId == "" then
		-- An unanimated move still swings and still hits -- AttackInputClient returns in the same case.
		return
	end
	local speed = entry.PlaybackSpeed
	bot.Animations:SetClaim(LAYER_ATTACK, SOURCE, {
		Clip = entry.AnimationId,
		Looped = false,
		Speed = if speed > 0 and speed == speed then speed else 1,
		Priority = Enum.AnimationPriority.Action,
		FadeIn = AttackConstants.Presentation.SwingFadeSeconds,
		FadeOut = AttackConstants.Presentation.SwingFadeSeconds,
		MaxSeconds = total,
	})
end

local function cutSwing(bot: Bot): ()
	bot.SwingEndsAt = nil
	bot.Animations:SetClaim(LAYER_ATTACK, SOURCE, nil)
end

-- Guard pose: the parry clip once, settling into the held-guard loop -- the sequence DefenseClient plays
-- for a player's press, off the same per-weapon resolvers.
local function presentGuard(bot: Bot, up: boolean): ()
	if up == bot.GuardShown then
		return
	end
	bot.GuardShown = up
	if not up then
		bot.Animations:SetClaim(LAYER_DEFENSE, SOURCE, nil)
		return
	end
	local fade = DefenseConstants.Presentation.BlockAnimationFadeSeconds
	local holdClip = WeaponDefenseAnimations.GetBlock(bot.WeaponId)
	bot.Animations:SetClaim(LAYER_DEFENSE, SOURCE, {
		Clip = WeaponDefenseAnimations.GetParry(bot.WeaponId),
		Looped = false,
		Priority = Enum.AnimationPriority.Action,
		FadeIn = fade,
		FadeOut = fade,
		MaxSeconds = 1,
		OnFinished = function(_clip: string, reason: AnimationManager.FinishReason)
			if reason ~= "Completed" or not bot.GuardShown or holdClip == "" then
				return
			end
			bot.Animations:SetClaim(LAYER_DEFENSE, SOURCE, {
				Clip = holdClip,
				Looped = true,
				Priority = Enum.AnimationPriority.Action,
				FadeIn = fade,
				FadeOut = fade,
			})
		end,
	})
end

local function presentLocomotion(bot: Bot, sprinting: boolean): ()
	local speed = flat(bot.Root.AssemblyLinearVelocity).Magnitude
	local clip: string?
	if speed > MOVING_SPEED then
		clip = if sprinting then CombatConstants.AnimationIds.Running else CombatConstants.AnimationIds.Walking
	else
		local idle = WeaponIdleAnimations.Get(bot.WeaponId)
		clip = if idle ~= "" then idle else nil
	end
	if clip == bot.LocomotionClip then
		return
	end
	bot.LocomotionClip = clip
	if clip == nil or clip == "" then
		bot.Animations:SetClaim(LAYER_LOCOMOTION, SOURCE, nil)
		return
	end
	bot.Animations:SetClaim(LAYER_LOCOMOTION, SOURCE, {
		Clip = clip,
		Looped = true,
		Priority = if speed > MOVING_SPEED then Enum.AnimationPriority.Movement else Enum.AnimationPriority.Idle,
		FadeIn = 0.2,
		FadeOut = 0.2,
	})
end

-- Targeting ----------------------------------------------------------------------------------------

local function liveCombatant(model: Model?): boolean
	return model ~= nil
		and model.Parent ~= nil
		and CharacterUtil.LiveHumanoidOf(model) ~= nil
		and HitboxEngine.GetCombatantId(model) ~= nil
end

local function chooseTarget(bot: Bot): Model?
	local forced = bot.ForcedTarget
	if forced and liveCombatant(forced) then
		return forced
	end
	local origin = bot.Root.Position
	local owner = bot.Owner
	if owner and owner.Parent ~= nil then
		local character = owner.Character
		local root = if character then CharacterUtil.RootOf(character) else nil
		if
			character
			and root
			and liveCombatant(character)
			and (root.Position - origin).Magnitude <= Config.LeashRange
		then
			return character
		end
	end
	local best: Model? = nil
	local bestDistance = Config.LeashRange
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = if character then CharacterUtil.RootOf(character) else nil
		if character and root and liveCombatant(character) then
			local distance = (root.Position - origin).Magnitude
			if distance <= bestDistance then
				best = character
				bestDistance = distance
			end
		end
	end
	return best
end

-- Perception ---------------------------------------------------------------------------------------

-- Whether a wall stands close behind `victim` along the line from `attacker` -- where a Spike would send
-- them, and so whether the Spike's wall splat is on offer.
local wallRayParams = RaycastParams.new()
wallRayParams.FilterType = Enum.RaycastFilterType.Exclude
wallRayParams.RespectCanCollide = true
local function wallBehind(attacker: Model, victim: Model): boolean
	local attackerRoot = CharacterUtil.RootOf(attacker)
	local victimRoot = CharacterUtil.RootOf(victim)
	if not attackerRoot or not victimRoot then
		return false
	end
	local direction = flat(victimRoot.Position - attackerRoot.Position)
	if direction.Magnitude < 1e-3 then
		return false
	end
	wallRayParams.FilterDescendantsInstances = { attacker, victim }
	local hit =
		Workspace:Raycast(victimRoot.Position, direction.Unit * TrainingBotConstants.Air.SpikeWallStuds, wallRayParams)
	return hit ~= nil and math.abs(hit.Normal.Y) <= AirComboConstants.Spike.WallMaxNormalY
end

local function perceive(bot: Bot, now: number): Perception
	local root = bot.Root
	local humanoid = bot.Humanoid
	local model = bot.Model
	local selfState = DefenseSystem.GetState(model) or "Neutral"
	local parryOpen, parryClose = parryWindowFor(bot.WeaponId)

	local perception: Perception = {
		Now = now,
		HasTarget = false,
		Distance = math.huge,
		Reach = reachFor(bot.WeaponId),
		TargetReach = Config.FallbackReach,
		FacingError = 0,
		BearingFromTarget = 0,
		TargetSwing = nil,
		TargetAttackState = "Idle",
		TargetDefenseState = "Neutral",
		TargetGuardFraction = 1,
		TargetStunned = false,
		SelfSwing = swingViewOf(model),
		SelfAttackState = attackStateOf(model),
		-- CombatBusyUntil is the later of the swing's end and any hitstun, and nothing rewrites it when a
		-- swing is cut short by a parry or a trade -- so once the engine says the swing is over, only the
		-- hitstun half still holds the body. Read raw, a parried bot believed itself committed through the
		-- whole cancelled swing and let the counter land rather than parrying it back.
		SelfBusyUntil = if attackStateOf(model) == "Idle"
			then numberAttribute(humanoid, Constants.Attributes.HitstunUntil)
			else numberAttribute(humanoid, Constants.Attributes.CombatBusyUntil),
		SelfDefenseState = selfState,
		SelfGuardFraction = guardFractionOf(model),
		SelfHealthFraction = if humanoid.MaxHealth > 0 then humanoid.Health / humanoid.MaxHealth else 0,
		SelfDisabled = numberAttribute(humanoid, Constants.Attributes.HitstunUntil) > now or humanoid:GetAttribute(
			Constants.Attributes.Grabbed
		) == true or humanoid:GetAttribute(Constants.Attributes.Grabbing) == true or DISABLED_STATES[selfState] == true,
		-- A stagger no longer stops a guard from mattering when parry trading is on (DefenseConstants.Rally):
		-- a staggered combatant may parry back, and so may the bot.
		SelfLocked = humanoid:GetAttribute(Constants.Attributes.Grabbed) == true
			or humanoid:GetAttribute(Constants.Attributes.Grabbing) == true
			or selfState == "GuardBroken"
			or (selfState == "Staggered" and not DefenseConstants.Rally.ParryFromStagger),
		ParryArmableAt = if bot.GuardHeld
			then math.huge
			else bot.GuardReleasedAt + DefenseConstants.Parry.MinUnguardedSeconds,
		SelfEvading = now - bot.EvadeStartedAt < EvadeConstants.DurationSeconds,
		EvadeReady = now - bot.LastEvadeAt >= DefenseConstants.Evade.CooldownSeconds,
		HomeDistance = flat(bot.SpawnCFrame.Position - root.Position).Magnitude,
		FeintWindowFraction = AttackConstants.Feint.WindowFraction,
		ParryOpen = parryOpen,
		ParryClose = parryClose,
		EvadeStartup = DefenseConstants.Evade.StartupSeconds,
		EvadeActive = DefenseConstants.Evade.ActiveSeconds,
	}

	local target = bot.Target
	local targetRoot = if target then CharacterUtil.RootOf(target) else nil
	local targetHumanoid = if target then CharacterUtil.HumanoidOf(target) else nil
	if target and targetRoot and targetHumanoid then
		local toTarget = flat(targetRoot.Position - root.Position)
		perception.HasTarget = true
		perception.Distance = toTarget.Magnitude
		perception.TargetReach = reachFor(AttackRequestSystem.GetWeapon(target))
		perception.FacingError = angleBetween(root.CFrame.LookVector, toTarget)
		perception.BearingFromTarget = angleBetween(targetRoot.CFrame.LookVector, -toTarget)
		perception.TargetSwing = swingViewOf(target)
		perception.TargetAttackState = attackStateOf(target)
		perception.TargetDefenseState = DefenseSystem.GetState(target) or "Neutral"
		perception.TargetGuardFraction = guardFractionOf(target)
		perception.TargetStunned = numberAttribute(targetHumanoid, Constants.Attributes.HitstunUntil) > now
	end

	-- The air combo, from its own queries -- the same "read through the public surface" shape every other
	-- field here keeps (AirComboSystem.GetCombo is a read-only view).
	perception.SelfAirHeld = AirComboAttributes.IsHeld(humanoid)
	local combo = AirComboSystem.GetCombo(model)
	if combo and combo.Attacker == model then
		perception.SelfAirAttacker = true
		perception.SelfAirHitsLanded = combo.AirHitsLanded
		perception.AirPressReadyAt = combo.LaunchedAt + AirComboConstants.Timing.FirstPressSeconds
		perception.WallBehindTarget = wallBehind(model, combo.Victim)
	end
	return perception
end

-- Actuation ----------------------------------------------------------------------------------------

-- Turns the body toward `direction` at the difficulty's turn rate. A finite rate is deliberate: it is
-- what lets a player circle it for a Backstab.
local function turnToward(bot: Bot, direction: Vector3, deltaTime: number): ()
	local wanted = flat(direction)
	if wanted.Magnitude < 1e-3 then
		return
	end
	local root = bot.Root
	local look = flat(root.CFrame.LookVector)
	local current = math.atan2(-look.X, -look.Z)
	local desired = math.atan2(-wanted.X, -wanted.Z)
	local delta = (desired - current + math.pi) % (2 * math.pi) - math.pi
	local maxStep = math.rad(bot.Brain.Difficulty.TurnRateDegrees) * deltaTime
	local yaw = current + math.clamp(delta, -maxStep, maxStep)
	root.CFrame = CFrame.new(root.Position) * CFrame.Angles(0, yaw, 0)
end

local function evadeDirection(bot: Bot, toTarget: Vector3, direction: TrainingBotBrain.EvadeDirection): Vector3
	local forward = unitOr(flat(toTarget), flat(bot.Root.CFrame.LookVector))
	local right = forward:Cross(Vector3.yAxis)
	if direction == "Left" then
		return (-right - forward * 0.3).Unit
	elseif direction == "Right" then
		return (right - forward * 0.3).Unit
	end
	return -forward
end

local function applyIntent(bot: Bot, intent: Intent, perception: Perception, now: number, deltaTime: number): ()
	local model = bot.Model
	local humanoid = bot.Humanoid
	local root = bot.Root
	local target = bot.Target
	local targetRoot = if target then CharacterUtil.RootOf(target) else nil
	local toTarget = if targetRoot then flat(targetRoot.Position - root.Position) else Vector3.zero

	-- Guard: only the EDGES reach DefenseSystem, exactly as a player's key down/up does. A press is what
	-- opens a parry window, so re-sending "true" every frame would be wrong, not just wasteful.
	if intent.Guard ~= bot.GuardHeld then
		bot.GuardHeld = intent.Guard
		if not intent.Guard then
			bot.GuardReleasedAt = now
		end
		DefenseSystem.SetBlocking(model, intent.Guard, now)
	end

	-- Evading out of a held guard is legal (BeginEvade drops the guard itself), exactly as for a player.
	if intent.Evade then
		local ok = DefenseSystem.BeginEvade(model, now)
		if ok then
			bot.LastEvadeAt = now
			-- The same glide a player's evade is (EvadeMotion.SpeedAt, driven in the body section below), and
			-- the same clip rule: the directional clip when one is authored, otherwise no clip at all.
			bot.EvadeStartedAt = now
			bot.EvadeDirection = evadeDirection(bot, toTarget, intent.Evade)
			local evadeClip = EVADE_CLIPS[intent.Evade]
			if evadeClip ~= nil and evadeClip ~= "" then
				bot.Animations:SetClaim(LAYER_TRAVERSAL, SOURCE, {
					Clip = evadeClip,
					Looped = false,
					Priority = Enum.AnimationPriority.Action,
					FadeIn = 0.05,
					FadeOut = 0.1,
					MaxSeconds = EvadeConstants.DurationSeconds,
				})
			end
		end
	end

	if intent.Feint then
		local ok = AttackRequestSystem.Feint(model, now)
		if ok then
			cutSwing(bot)
		end
	end

	-- Only asked while its own swing is over -- the engine refuses a second concurrent swing as Busy, and
	-- asking every retry tick mid-swing would cost a catalogue resolve per tick for a guaranteed no.
	if intent.Attack and now >= bot.NextThrowAt and perception.SelfAttackState == "Idle" then
		local request: AttackTypes.AttackRequest = { Kind = intent.Attack, Modifier = intent.Modifier }
		local accepted = AttackRequestSystem.Throw(model, request, false, now)
		if accepted then
			local view = AttackRequestSystem.GetInFlight(model)
			if view then
				presentSwing(bot, view.MoveId, now)
				TrainingBotBrain.OnOwnSwingAccepted(bot.Brain, intent.Attack, {
					StartedAt = view.StartedAt,
					WindupSeconds = view.WindupSeconds,
					Feintable = view.Feintable,
					Heavy = view.PowerLevel >= 2,
				}, AttackConstants.Feint.WindowFraction)
			end
		else
			bot.NextThrowAt = now + THROW_RETRY_SECONDS
		end
	end

	-- A swing the server cut short (hit, parried, traded, feinted) stops showing.
	if bot.SwingEndsAt and now < bot.SwingEndsAt - 0.03 and AttackRequestSystem.GetInFlight(model) == nil then
		cutSwing(bot)
	elseif bot.SwingEndsAt and now >= bot.SwingEndsAt then
		bot.SwingEndsAt = nil
	end

	presentGuard(bot, GUARD_UP[perception.SelfDefenseState] == true)

	-- The body. Nothing is written while someone else's constraints own it: a grab's, or an air combo's
	-- (held as the victim, or driven to its follow slot as the attacker -- AirComboSystem), or a finisher's
	-- flight (platform-standing under the server's velocity). Turning the root here would fight all of them.
	if
		humanoid:GetAttribute(Constants.Attributes.Grabbed) == true
		or AirComboAttributes.IsParticipant(humanoid)
		or humanoid.PlatformStand
	then
		humanoid:Move(Vector3.zero, false)
		return
	end

	if now - bot.EvadeStartedAt < EvadeConstants.DurationSeconds then
		-- The same glide curve a player's evade drives (Shared/Combat/EvadeMotion.lua), so the two are one
		-- move rather than two copies of the same numbers.
		humanoid:Move(Vector3.zero, false)
		local velocity = root.AssemblyLinearVelocity
		root.AssemblyLinearVelocity = bot.EvadeDirection * EvadeMotion.SpeedAt(now - bot.EvadeStartedAt)
			+ Vector3.new(0, velocity.Y, 0)
	else
		local locked = humanoid:GetAttribute(Constants.Attributes.RootControlLocked) == true
			or perception.SelfDisabled
			or perception.SelfAttackState == "Windup"
			or perception.SelfAttackState == "Active"
		local direction = Vector3.zero
		if not locked then
			local forward = unitOr(toTarget, Vector3.zero)
			if intent.Move == "Approach" then
				direction = forward
			elseif intent.Move == "Retreat" then
				direction = -forward
			elseif intent.Move == "Strafe" then
				direction = forward:Cross(Vector3.yAxis) * intent.StrafeSign
			elseif intent.Move == "Home" then
				direction = unitOr(flat(bot.SpawnCFrame.Position - root.Position), Vector3.zero)
			end
		end
		humanoid.WalkSpeed = if bot.GuardHeld
			then Config.GuardWalkSpeed
			elseif intent.Sprint then Config.SprintSpeed
			else Config.WalkSpeed
		humanoid:Move(direction, false)
	end

	-- Facing: the target while there is one (a player in combat is locked on), else where it walks.
	if perception.HasTarget then
		turnToward(bot, toTarget, deltaTime)
	elseif intent.Move == "Home" then
		turnToward(bot, flat(bot.SpawnCFrame.Position - root.Position), deltaTime)
	end

	presentLocomotion(bot, intent.Sprint)
end

-- Lifecycle of one bot -----------------------------------------------------------------------------

-- Forward-declared: onDied schedules a respawn through it, and it wires onDied onto every new life.
local spawnInto: (
	spawnCFrame: CFrame,
	styleName: TrainingBotConstants.StyleName,
	difficultyName: TrainingBotConstants.DifficultyName,
	owner: Player?,
	brain: Brain?,
	weaponId: Types.WeaponId?
) -> Bot?

local function unregisterCombat(bot: Bot): ()
	HitboxEngine.UnregisterCombatant(bot.CombatantId)
	DefenseSystem.UnregisterCombatant(bot.Model)
	bot.Life:Clean()
end

local function removeFromActive(bot: Bot): ()
	local index = table.find(active, bot)
	if index then
		table.remove(active, index)
	end
	byModel[bot.Model] = nil
	bot.Removed = true
end

local function destroyBot(bot: Bot): ()
	unregisterCombat(bot)
	removeFromActive(bot)
	bot.Animations:Destroy()
	GameplayEvents.FireTrainingBotDespawned(bot.Model)
	if bot.Model.Parent ~= nil then
		bot.Model:Destroy()
	end
end

local function onDied(bot: Bot): ()
	if not bot.Alive then
		return
	end
	bot.Alive = false
	HitboxEngine.UnregisterCombatant(bot.CombatantId)
	DefenseSystem.UnregisterCombatant(bot.Model)
	refreshBillboard(bot)
	logger:info(
		"Training bot defeated",
		{ id = bot.Id, killer = if bot.LastAttacker then bot.LastAttacker.Name else nil }
	)
	local owner = bot.Owner
	if owner then
		GameplayEvents.FireTrainingBotKilled(bot.Model, owner, bot.LastAttacker)
	end

	task.delay(Config.RespawnDelay, function()
		if bot.Removed then
			return
		end
		local brain = bot.Brain
		destroyBot(bot)
		spawnInto(bot.SpawnCFrame, bot.StyleName, bot.DifficultyName, bot.Owner, brain, bot.WeaponId)
	end)
end

spawnInto = function(
	spawnCFrame: CFrame,
	styleName: TrainingBotConstants.StyleName,
	difficultyName: TrainingBotConstants.DifficultyName,
	owner: Player?,
	brain: Brain?,
	requestedWeapon: Types.WeaponId?
): Bot?
	local ok, modelOrError = pcall(buildRig)
	if not ok then
		logger:error("Failed to build training bot rig", { errorMessage = tostring(modelOrError) })
		return nil
	end
	local model = modelOrError :: Model
	local humanoid = CharacterUtil.HumanoidOf(model)
	local root = CharacterUtil.RootOf(model)
	if not humanoid or not root then
		logger:error("Training bot rig built with no Humanoid/HumanoidRootPart")
		model:Destroy()
		return nil
	end

	humanoid.MaxHealth = Config.MaxHealth
	humanoid.Health = Config.MaxHealth
	humanoid.WalkSpeed = Config.WalkSpeed
	humanoid.AutoRotate = false
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	-- A launch should not leave it lying on the floor for seconds; a player's character recovers too.
	humanoid:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, false)

	model:PivotTo(spawnCFrame)
	model.Parent = folderInstance()
	-- See this file's header: without this the engine may hand the body to a nearby client.
	pcall(function()
		root:SetNetworkOwner(nil)
	end)

	nextId += 1
	local id = nextId
	local now = os.clock()
	-- The weapon it was spawned with (the Admin Menu's picker), kept across respawns; else the roster's
	-- default. A requested id the roster no longer knows falls back rather than spawning it unarmed.
	local weaponId = if requestedWeapon and WeaponRoster.Has(requestedWeapon)
		then requestedWeapon
		else WeaponRoster.Default()

	local combatantId = HitboxEngine.RegisterCombatant(model, root, humanoid)
	DefenseSystem.RegisterCombatant(model, root, humanoid, WeaponDefenseAnimations.GetParry(weaponId))
	-- Arms it through the attack layer's own setter, so WeaponVisualSystem equips the Tool and the boot
	-- script's OnWeaponChanged hookup sets the matching parry clip -- the same two consumers a player's
	-- draw reaches.
	if weaponId then
		AttackRequestSystem.SetWeapon(model, weaponId, now)
	end

	local animations = AnimationManager.new({ Name = `TrainingBot#{id}` })
	animations:Bind(model)

	local thinker = brain or TrainingBotBrain.new(styleName, difficultyName, Random.new())
	-- A new life keeps what it learned about you, not its mood or its half-finished plans.
	thinker.Threat = nil
	thinker.Plan = nil
	thinker.Composure = 1
	thinker.Narration = if brain then "Back for more" else "Sizing you up"

	local bot: Bot = {
		Id = id,
		Model = model,
		Humanoid = humanoid,
		Root = root,
		CombatantId = combatantId,
		StyleName = styleName,
		DifficultyName = difficultyName,
		Owner = owner,
		SpawnCFrame = spawnCFrame,
		Brain = thinker,
		Animations = animations,
		Life = Trove.New(),
		Label = attachBillboard(model),
		WeaponId = weaponId,
		Alive = true,
		Removed = false,
		Target = nil,
		ForcedTarget = nil,
		NextRetargetAt = 0,
		NextThrowAt = 0,
		NextBillboardAt = 0,
		LastEvadeAt = -math.huge,
		EvadeStartedAt = -math.huge,
		EvadeDirection = Vector3.zero,
		SwingEndsAt = nil,
		GuardShown = false,
		GuardHeld = false,
		GuardReleasedAt = -math.huge,
		LocomotionClip = nil,
		LastAttacker = nil,
	}

	bot.Life:Connect(humanoid.Died, function()
		onDied(bot)
	end)

	table.insert(active, bot)
	byModel[model] = bot
	refreshBillboard(bot)
	logger:info("Training bot spawned", {
		id = id,
		style = styleName,
		difficulty = difficultyName,
		weapon = weaponId,
		owner = if owner then owner.Name else nil,
	})
	return bot
end

-- The loop -----------------------------------------------------------------------------------------

local function stepBot(bot: Bot, deltaTime: number, now: number): ()
	if not bot.Alive or bot.Model.Parent == nil then
		return
	end
	if now >= bot.NextRetargetAt or not liveCombatant(bot.Target) then
		bot.Target = chooseTarget(bot)
		bot.NextRetargetAt = now + RETARGET_SECONDS
	end

	local perception = perceive(bot, now)
	local intent = TrainingBotBrain.Think(bot.Brain, perception)
	applyIntent(bot, intent, perception, now, deltaTime)

	if now >= bot.NextBillboardAt then
		bot.NextBillboardAt = now + Config.BillboardRefreshSeconds
		refreshBillboard(bot)
	end
end

function TrainingBotSystem.Step(deltaTime: number, now: number): ()
	lastStepNow = now
	for _, bot in table.clone(active) do
		local ok, err = pcall(stepBot, bot, deltaTime, now)
		if not ok then
			-- One bot erroring must not take the others (or this Heartbeat) down with it.
			logger:error("Training bot step failed", { id = bot.Id, errorMessage = tostring(err) })
		end
	end
end

-- Every resolved contact in the server; the byModel lookups make it a no-op for anything not involving
-- a bot -- the same filter DebugDummySystem.onDamageApplied uses.
local function onDamageApplied(outcome: DefenseOutcome, _result: DamageResult): ()
	local now = lastStepNow
	local asAttacker = byModel[outcome.Attacker]
	if asAttacker and asAttacker.Alive then
		TrainingBotBrain.OnOutcome(asAttacker.Brain, "Attacker", outcome.Kind, now)
	end
	local asDefender = byModel[outcome.Defender]
	if asDefender and asDefender.Alive then
		TrainingBotBrain.OnOutcome(asDefender.Brain, "Defender", outcome.Kind, now)
		local attackerPlayer = Players:GetPlayerFromCharacter(outcome.Attacker)
		if attackerPlayer then
			asDefender.LastAttacker = attackerPlayer
		end
	end
end

-- Public -------------------------------------------------------------------------------------------

-- Spawns one bot at `spawnCFrame`, evicting the oldest past Config.MaxActive. Unknown style/difficulty
-- names fall back to the defaults rather than failing -- the caller (DevMenuSystem) validates first, so
-- reaching here with one is a programming error worth a warning, not a refusal. `weaponId` is what it
-- fights with (nil, or an id the roster does not know, means WeaponRoster.Default()).
function TrainingBotSystem.Spawn(
	spawnCFrame: CFrame,
	styleName: string?,
	difficultyName: string?,
	owner: Player?,
	weaponId: Types.WeaponId?
): (Model?, string?)
	local style = if TrainingBotConstants.IsStyle(styleName)
		then styleName :: TrainingBotConstants.StyleName
		else TrainingBotConstants.DefaultStyle
	local difficulty = if TrainingBotConstants.IsDifficulty(difficultyName)
		then difficultyName :: TrainingBotConstants.DifficultyName
		else TrainingBotConstants.DefaultDifficulty
	if style ~= styleName or difficulty ~= difficultyName then
		logger:warn(
			"Training bot spawn fell back to a default preset",
			{ style = styleName, difficulty = difficultyName }
		)
	end

	while #active >= Config.MaxActive do
		destroyBot(active[1])
	end

	local bot = spawnInto(spawnCFrame, style, difficulty, owner, nil, weaponId)
	if not bot then
		return nil, "SpawnFailed"
	end
	return bot.Model, nil
end

function TrainingBotSystem.DespawnAll(): number
	local count = #active
	for _, bot in table.clone(active) do
		destroyBot(bot)
	end
	logger:info("All training bots despawned", { count = count })
	return count
end

function TrainingBotSystem.ActiveCount(): number
	return #active
end

-- Points the bot at `target` (any live combatant -- another bot included, for watching two spar) in
-- place of its own player search, or hands the choice back for nil. A target that dies or unregisters
-- is ignored until it is live again. Returns false for a model that is not a bot.
function TrainingBotSystem.SetTarget(model: Model, target: Model?): boolean
	local bot = byModel[model]
	if not bot then
		return false
	end
	bot.ForcedTarget = target
	bot.NextRetargetAt = 0
	return true
end

-- For a spec or a debug readout: the brain driving the bot built as `model`, or nil.
function TrainingBotSystem.GetBrain(model: Model): Brain?
	local bot = byModel[model]
	return if bot then bot.Brain else nil
end

-- Lifecycle ----------------------------------------------------------------------------------------

function TrainingBotSystem.Attach(): ()
	if appliedDisconnect then
		return
	end
	appliedDisconnect = DamageSystem.OnApplied(onDamageApplied)
end

function TrainingBotSystem.Init(): ()
	if started then
		return
	end
	-- Its Heartbeat reads state the four combat layers wrote earlier in the same frame, so it must be
	-- connected after all of them -- asserted rather than trusted, like each layer's own Init.
	assert(AttackRequestSystem.GetInFlight ~= nil, "TrainingBotSystem.Init() requires AttackRequestSystem")
	assert(DamageSystem.OnApplied ~= nil, "TrainingBotSystem.Init() requires DamageSystem")
	started = true
	TrainingBotSystem.Attach()
	heartbeatTrove:Connect(RunService.Heartbeat, function(deltaTime: number)
		TrainingBotSystem.Step(deltaTime, os.clock())
	end)
	logger:info("TrainingBotSystem.Init() complete")
end

function TrainingBotSystem.Shutdown(): ()
	heartbeatTrove:Clean()
	if appliedDisconnect then
		appliedDisconnect()
		appliedDisconnect = nil
	end
	started = false
end

-- Spec-only: every bot and subscription gone.
function TrainingBotSystem.Reset(): ()
	TrainingBotSystem.Shutdown()
	TrainingBotSystem.DespawnAll()
	nextId = 0
	lastStepNow = 0
end

return TrainingBotSystem :: Types.SystemModule & typeof(TrainingBotSystem)
