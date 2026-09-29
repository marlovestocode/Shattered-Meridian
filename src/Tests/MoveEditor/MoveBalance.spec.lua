--!strict
-- Covers Server/Systems/Support/MoveBalance.lua -- the Move Editor's frame data, balance counts and the
-- "Match timing to clip" numbers.
--
-- The balance cases assert against the LIVE constants (DefenseConstants, DamageConstants, the combo
-- curve), never literals, because the whole claim is that the readout follows those modules when they
-- are retuned. The ClipMatch cases run the matched numbers through the real AttackCatalog twice -- once
-- with the clip's length known, once with it hidden -- because "the two timelines agree" is the only
-- proof the button does what it says.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local AttackCatalog = require(ServerScriptService.Server.Combat.AttackCatalog)
local AttackConstants = require(ReplicatedStorage.Shared.Attack.AttackConstants)
local AttackWindows = require(ReplicatedStorage.Shared.Attack.AttackWindows)
local CombatConstants = require(ReplicatedStorage.Shared.Combat.CombatConstants)
local DamageConstants = require(ReplicatedStorage.Shared.Damage.DamageConstants)
local DamageResolver = require(ServerScriptService.Server.Combat.Damage.DamageResolver)
local DefaultMoveRegistry = require(ServerScriptService.Server.Combat.DefaultMoveRegistry)
local DefenseConstants = require(ReplicatedStorage.Shared.Defense.DefenseConstants)
local MoveBalance = require(ServerScriptService.Server.Systems.Support.MoveBalance)
local MoveRegistryManager = require(ServerScriptService.Server.Combat.MoveRegistryManager)
local MoveTypes = require(ReplicatedStorage.Shared.MoveTypes)
local WeaponFixture = require(ServerScriptService.Tests.TestHelpers.WeaponFixture)

local WEAPON = WeaponFixture.Install()[1]
local DEFAULT_MOVE_ID = `default:{WEAPON}:Basic:1`
local CUSTOM_CLIP = "rbxassetid://7700001"

local function customMove(overrides: { [string]: any }?): MoveTypes.MoveDefinition
	local candidate: { [string]: any } = {
		MoveId = "balance-spec",
		DisplayName = "Balance Spec",
		Author = "Spec",
		CreatedAt = 1,
		UpdatedAt = 1,
		Shape = "Box",
		Dimensions = { Width = 4, Height = 5, Length = 5 },
		OffsetX = 0,
		OffsetY = 0,
		OffsetZ = -3,
		WindupSeconds = 0.2,
		ActiveSeconds = 0.15,
		RecoverySeconds = 0.4,
		Cooldown = 0.8,
		Damage = 10,
		PostureDamage = 8,
		AnimationId = "",
	}
	for key, value in pairs(overrides or {}) do
		candidate[key] = value
	end
	return MoveRegistryManager.Validate(candidate) :: MoveTypes.MoveDefinition
end

local function timing(windup: number, active: number, recovery: number, cooldown: number): any
	return {
		WindupSeconds = windup,
		ActiveSeconds = active,
		RecoverySeconds = recovery,
		Cooldown = cooldown,
		PlaybackSpeed = 1,
		AnimationId = "",
	}
end

-- Serves every clip `length` seconds long with `markerName` at `marker` -- AttackCatalog.spec's shape.
local function serveClip(length: number, marker: number?, markerName: string): ()
	AttackWindows.SetExtractor(function(): KeyframeSequence?
		local sequence = Instance.new("KeyframeSequence")
		if marker then
			local keyframe = Instance.new("Keyframe")
			keyframe.Time = marker
			local markerInstance = Instance.new("KeyframeMarker")
			markerInstance.Name = markerName
			markerInstance.Parent = keyframe
			keyframe.Parent = sequence
		end
		local closing = Instance.new("Keyframe")
		closing.Time = length
		closing.Parent = sequence
		return sequence
	end)
end

local function clearClips(): ()
	AttackWindows.Reset()
	AttackWindows.SetExtractor(function()
		return nil
	end)
end

local function matchFor(move: MoveTypes.MoveDefinition, animationId: string): any
	return MoveBalance.MatchClip(
		move,
		AttackWindows.WindupOverride(move.MoveId, animationId),
		AttackWindows.ClipLength(animationId)
	)
end

-- The catalogue's timeline for `moveId` with the clip's length known, then with it hidden. They agree
-- exactly when the authored numbers already match the clip.
local function bothTimelines(moveId: string): (any, any)
	local known = AttackCatalog.Get(moveId) :: any
	local previous = AttackConstants.Windows.SyncToClipLength
	AttackConstants.Windows.SyncToClipLength = false
	local unknown = AttackCatalog.Get(moveId) :: any
	AttackConstants.Windows.SyncToClipLength = previous
	return known.Definition, unknown.Definition
end

local AUTHORED_BASIC_TEMPO = AttackConstants.Tempo.ByStage.Basic

return function()
	local function expectSameTimeline(a: any, b: any): ()
		expect(a.WindupSeconds).to.be.near(b.WindupSeconds, 1e-6)
		expect(a.ActiveSeconds).to.be.near(b.ActiveSeconds, 1e-6)
		expect(a.RecoverySeconds).to.be.near(b.RecoverySeconds, 1e-6)
	end

	describe("MoveBalance.Compute -- frames", function()
		it("rounds each phase to the nearest frame at the configured rate", function()
			local balance = MoveBalance.Compute(timing(0.2, 0.15, 0.4, 0.8), customMove())
			expect(balance.FrameRate).to.equal(60)
			expect(balance.StartupFrames).to.equal(12)
			expect(balance.ActiveFrames).to.equal(9)
			expect(balance.RecoveryFrames).to.equal(24)
			expect(balance.TotalFrames).to.equal(45)
			expect(balance.CooldownFrames).to.equal(48)
		end)

		it("counts advantage from contact: hitstun on hit, nothing on block", function()
			local hitstun = DamageConstants.Hitstun.Seconds
			local balance = MoveBalance.Compute(timing(0.2, 0.15, 0.4, 0.8), customMove())
			expect(balance.OnHitFrames.Min).to.equal(math.floor((hitstun - 0.55) * 60 + 0.5))
			expect(balance.OnHitFrames.Max).to.equal(math.floor((hitstun - 0.4) * 60 + 0.5))
			-- No blockstun: the attacker's remaining commitment IS the blocker's punish window.
			expect(balance.OnBlockFrames.Min).to.equal(-33)
			expect(balance.OnBlockFrames.Max).to.equal(-24)
			expect(balance.OnHitFrames.Max > balance.OnHitFrames.Min).to.equal(true)
		end)

		it("prices damage per second against the swing or the cooldown, whichever is longer", function()
			local swingBound = MoveBalance.Compute(timing(0.2, 0.15, 0.4, 0.5), customMove())
			expect(swingBound.DamagePerSecond).to.be.near(10 / 0.75, 1e-6)
			local cooldownBound = MoveBalance.Compute(timing(0.2, 0.15, 0.4, 2), customMove())
			expect(cooldownBound.DamagePerSecond).to.be.near(5, 1e-6)
		end)
	end)

	describe("MoveBalance.Compute -- hits", function()
		local plain = timing(0.2, 0.15, 0.4, 0.8)

		it("says never, rather than dividing by zero, for a move with no damage or posture", function()
			local balance = MoveBalance.Compute(plain, customMove({ Damage = 0, PostureDamage = 0 }))
			expect(balance.HitsToKill).to.equal(nil)
			expect(balance.StringHitsToKill).to.equal(nil)
			expect(balance.CleanHitsToBreakGuard).to.equal(nil)
			expect(balance.DamagePerSecond).to.equal(0)
		end)

		it("counts an exact divisor as exact", function()
			local health = CombatConstants.MaxHealth
			expect(MoveBalance.Compute(plain, customMove({ Damage = health / 8 })).HitsToKill).to.equal(8)
			expect(MoveBalance.Compute(plain, customMove({ Damage = health })).HitsToKill).to.equal(1)
			expect(MoveBalance.Compute(plain, customMove({ Damage = health / 8 + 0.01 })).HitsToKill).to.equal(8)
			expect(MoveBalance.Compute(plain, customMove({ Damage = health / 8 - 0.01 })).HitsToKill).to.equal(9)
		end)

		it("walks the real combo curve for the string count", function()
			local damage = 10
			local balance = MoveBalance.Compute(plain, customMove({ Damage = damage }))
			local dealt, hits = 0, 0
			repeat
				hits += 1
				dealt += damage * DamageResolver.ComboMultiplier(hits)
			until dealt >= CombatConstants.MaxHealth
			expect(balance.StringHitsToKill).to.equal(hits)
			expect((balance.StringHitsToKill :: number) <= (balance.HitsToKill :: number)).to.equal(true)
		end)

		it("reads guard math off the live defence constants, by weight class", function()
			local guard = DefenseConstants.Guard
			for _, level in { 1, 2, 4 } do
				local balance = MoveBalance.Compute(plain, customMove({ PowerLevel = level }))
				expect(balance.BlockedHitsToBreakGuard).to.equal(
					math.ceil(guard.Max / (guard.DrainPerPowerLevel * level))
				)
				expect(balance.StaggeredBlocksToBreakGuard).to.equal(
					math.ceil(
						guard.Max / (guard.DrainPerPowerLevel * level * DefenseConstants.Stagger.GuardDrainMultiplier)
					)
				)
			end
			local posture = MoveBalance.Compute(plain, customMove({ PostureDamage = 8 }))
			expect(posture.CleanHitsToBreakGuard).to.equal(
				math.ceil(guard.Max / (8 * DamageConstants.Guard.PressurePerPostureDamage))
			)
		end)
	end)

	describe("MoveBalance.MatchClip", function()
		beforeEach(function()
			AttackConstants.Tempo.ByStage.Basic = 1
		end)

		afterEach(function()
			AttackConstants.Tempo.ByStage.Basic = AUTHORED_BASIC_TEMPO
			clearClips()
			AttackCatalog.Reset()
			DefaultMoveRegistry.Reset(DEFAULT_MOVE_ID)
			MoveRegistryManager.Init()
		end)

		it("is nil while the clip's length is unknown", function()
			expect(MoveBalance.MatchClip(customMove(), 0.2, nil)).to.equal(nil)
			expect(MoveBalance.MatchClip(customMove(), nil, nil)).to.equal(nil)
		end)

		it("makes a custom move's authored timeline equal its clip-synced one", function()
			serveClip(0.9, 0.25, AttackConstants.Windows.HitMarkerName)
			AttackWindows.Prefetch(CUSTOM_CLIP)
			local move = customMove({ AnimationId = CUSTOM_CLIP })
			MoveRegistryManager.Upsert(move)

			local known, unknown = bothTimelines(move.MoveId)
			-- Before matching, the two disagree -- otherwise this case would prove nothing.
			expect(math.abs(known.RecoverySeconds - unknown.RecoverySeconds) > 1e-3).to.equal(true)

			local match = matchFor(move, CUSTOM_CLIP)
			expect(match).to.be.ok()
			local matched = MoveTypes.ToWire(move)
			matched.WindupSeconds = match.WindupSeconds
			matched.RecoverySeconds = match.RecoverySeconds
			matched.Author = move.Author
			matched.CreatedAt = move.CreatedAt
			matched.UpdatedAt = move.UpdatedAt
			MoveRegistryManager.Upsert(MoveRegistryManager.Validate(matched) :: MoveTypes.MoveDefinition)

			local knownAfter, unknownAfter = bothTimelines(move.MoveId)
			expectSameTimeline(knownAfter, unknownAfter)
			-- And the clip still decides: matching moved the authored numbers, not the swing.
			expectSameTimeline(knownAfter, known)
		end)

		it("matches a weapon stage played at a string tempo", function()
			AttackConstants.Tempo.ByStage.Basic = 0.75
			serveClip(0.9, 0.3, "AttackM1")
			local animationId = (AttackCatalog.Get(DEFAULT_MOVE_ID) :: any).AnimationId
			expect(animationId ~= "").to.equal(true)
			AttackWindows.Prefetch(animationId)
			local move = DefaultMoveRegistry.Get(DEFAULT_MOVE_ID) :: MoveTypes.MoveDefinition

			local match = matchFor(move, animationId)
			expect(match).to.be.ok()
			local wire = MoveTypes.ToWire(move)
			wire.WindupSeconds = match.WindupSeconds
			wire.RecoverySeconds = match.RecoverySeconds
			expect(DefaultMoveRegistry.ApplyEdit(DEFAULT_MOVE_ID, wire)).to.be.ok()

			local known, unknown = bothTimelines(DEFAULT_MOVE_ID)
			expectSameTimeline(known, unknown)
		end)

		it("keeps the authored windup for a clip with no strike marker, and still matches recovery", function()
			serveClip(0.9, nil, AttackConstants.Windows.HitMarkerName)
			AttackWindows.Prefetch(CUSTOM_CLIP)
			local move = customMove({ AnimationId = CUSTOM_CLIP })
			MoveRegistryManager.Upsert(move)

			local match = matchFor(move, CUSTOM_CLIP)
			expect(match.WindupSeconds).to.be.near(move.WindupSeconds, 1e-9)
			local matched = MoveTypes.ToWire(move)
			matched.RecoverySeconds = match.RecoverySeconds
			matched.Author = move.Author
			matched.CreatedAt = move.CreatedAt
			matched.UpdatedAt = move.UpdatedAt
			MoveRegistryManager.Upsert(MoveRegistryManager.Validate(matched) :: MoveTypes.MoveDefinition)

			local known, unknown = bothTimelines(move.MoveId)
			expectSameTimeline(known, unknown)
		end)

		it("places the strike marker where the catalogue opens the hitbox", function()
			serveClip(0.9, 0.25, AttackConstants.Windows.HitMarkerName)
			AttackWindows.Prefetch(CUSTOM_CLIP)
			local move = customMove({ AnimationId = CUSTOM_CLIP })
			MoveRegistryManager.Upsert(move)
			local entry = AttackCatalog.Get(move.MoveId) :: any
			local marker = AttackWindows.WindupOverride(move.MoveId, CUSTOM_CLIP) :: number
			expect(MoveBalance.StrikeSeconds(move, marker, entry.PlaybackSpeed)).to.be.near(
				entry.Definition.WindupSeconds,
				1e-6
			)
		end)
	end)
end
