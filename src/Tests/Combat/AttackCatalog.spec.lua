--!strict
-- Covers Server/Combat/AttackCatalog.lua -- the Move-Creation-System-to-engine bridge.
--
-- Exercised against the REAL registries rather than stubs, because the whole claim this module makes
-- is that authored moves reach the combat stack intact. A stubbed registry would verify the plumbing
-- and prove nothing about the bridge.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local AttackCatalog = require(ServerScriptService.Server.Combat.AttackCatalog)
local AttackConstants = require(ReplicatedStorage.Shared.Attack.AttackConstants)
local AttackWindows = require(ReplicatedStorage.Shared.Attack.AttackWindows)
local DefaultMoveRegistry = require(ServerScriptService.Server.Combat.DefaultMoveRegistry)
local LiveTuningContract = require(ServerScriptService.Tests.TestHelpers.LiveTuningContract)
local MoveRegistryManager = require(ServerScriptService.Server.Combat.MoveRegistryManager)
local MoveTypes = require(ReplicatedStorage.Shared.MoveTypes)
local WeaponFixture = require(ServerScriptService.Tests.TestHelpers.WeaponFixture)

-- A real roster weapon's real first basic stage, which DefaultMoveRegistry projects from
-- CombatConstants.Weapons.Baseline. Used rather than invented because a catalogue that only resolves
-- moves the spec itself authored would never catch the bridge breaking against real authored data.
local WEAPON = WeaponFixture.Install()[1]
local DEFAULT_MOVE_ID = `default:{WEAPON}:Basic:1`
local HEAVY_MOVE_ID = `default:{WEAPON}:Heavy:1`

-- Serves every clip as a sequence `length` seconds long, carrying a marker named `markerName`
-- (AttackM1 unless given) at `marker` when given -- the shape an exported clip has: marker keyframes
-- wherever they were authored, and a last keyframe at the clip's end.
local function serveClip(length: number, marker: number?, markerName: string?): ()
	AttackWindows.SetExtractor(function(): KeyframeSequence?
		local sequence = Instance.new("KeyframeSequence")
		if marker then
			local keyframe = Instance.new("Keyframe")
			keyframe.Time = marker
			local markerInstance = Instance.new("KeyframeMarker")
			markerInstance.Name = markerName or "AttackM1"
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

local function total(entry: any): number
	local definition = entry.Definition
	return definition.WindupSeconds + definition.ActiveSeconds + definition.RecoverySeconds
end

-- The string's tempo (AttackConstants.Tempo) is pinned to 1 for every case here but the one that is
-- about it: the numbers below are the clip-sync and marker mechanics, stated in the authored timeline's
-- own seconds, and a tempo would restate every one of them divided by it. DefaultMoveRegistry reads the
-- constant per projection, so a live write reaches the next Get.
local AUTHORED_BASIC_TEMPO = AttackConstants.Tempo.ByStage.Basic

return function()
	beforeEach(function()
		AttackConstants.Tempo.ByStage.Basic = 1
	end)

	afterEach(function()
		AttackConstants.Tempo.ByStage.Basic = AUTHORED_BASIC_TEMPO
		AttackCatalog.Reset()
		MoveRegistryManager.Init()
	end)

	describe("AttackCatalog.Get -- the string's tempo", function()
		afterEach(clearClips)

		it("plays an M1 clip slower and stretches its windup and recovery, but never its hit window", function()
			AttackConstants.Tempo.ByStage.Basic = 0.75
			local entry = AttackCatalog.Get(DEFAULT_MOVE_ID) :: any
			expect(entry.PlaybackSpeed).to.be.near(0.75, 1e-6)
			expect(entry.Definition.WindupSeconds).to.be.near(0.31 / 0.75, 1e-6)
			expect(entry.Definition.RecoverySeconds).to.be.near(0.14 / 0.75, 1e-6)
			expect(entry.Definition.ActiveSeconds).to.be.near(0.22, 1e-6)
		end)

		it("times a synced M1 against its clip played at the tempo", function()
			AttackConstants.Tempo.ByStage.Basic = 0.75
			serveClip(0.6, 0.3)
			AttackWindows.Prefetch("rbxassetid://104588315151150")
			local entry = AttackCatalog.Get(DEFAULT_MOVE_ID) :: any
			expect(entry.Definition.WindupSeconds).to.be.near(0.3 / 0.75, 1e-6)
			expect(total(entry)).to.be.near(0.6 / 0.75, 1e-6)
		end)

		it("leaves a Heavy at its own tempo", function()
			AttackConstants.Tempo.ByStage.Basic = 0.75
			local entry = AttackCatalog.Get(HEAVY_MOVE_ID) :: any
			expect(entry.PlaybackSpeed).to.be.near(AttackConstants.Tempo.ByStage.Heavy, 1e-6)
		end)

		it("lets a weapon override one stage's tempo without touching its other stages", function()
			local previous = AttackConstants.Tempo.ByWeapon[WEAPON]
			AttackConstants.Tempo.ByStage.Basic = 0.75
			AttackConstants.Tempo.ByWeapon[WEAPON] = { Basic = 0.9 }
			local basic = AttackCatalog.Get(DEFAULT_MOVE_ID) :: any
			local heavy = AttackCatalog.Get(HEAVY_MOVE_ID) :: any
			AttackConstants.Tempo.ByWeapon[WEAPON] = previous
			expect(basic.PlaybackSpeed).to.be.near(0.9, 1e-6)
			expect(basic.Definition.WindupSeconds).to.be.near(0.31 / 0.9, 1e-6)
			expect(heavy.PlaybackSpeed).to.be.near(AttackConstants.Tempo.ByStage.Heavy, 1e-6)
		end)
	end)

	describe("AttackCatalog.Get -- resolution", function()
		it("resolves a Default move into an engine definition and a damage profile", function()
			local entry = AttackCatalog.Get(DEFAULT_MOVE_ID)
			expect(entry).to.be.ok()
			local resolved = entry :: any
			expect(resolved.MoveId).to.equal(DEFAULT_MOVE_ID)
			expect(resolved.Definition).to.be.ok()
			expect(resolved.Profile).to.be.ok()
			expect(type(resolved.Profile.Damage)).to.equal("number")
			expect(resolved.Profile.Damage > 0).to.equal(true)
		end)

		it("names the definition by MoveId, which is what makes the round trip work", function()
			-- HitReport.DebugName is the ONLY key the damage layer has to look an attack back up by. If
			-- this were ever separately authored, a landed hit could not be priced at all.
			local entry = AttackCatalog.Get(DEFAULT_MOVE_ID) :: any
			expect(entry.Definition.DebugName).to.equal(DEFAULT_MOVE_ID)
		end)

		it("returns nil for an unknown id rather than a stand-in attack", function()
			-- Substituting a default would turn "this ability is broken" into "this ability does the
			-- wrong thing," which is far harder to notice.
			expect(AttackCatalog.Get("no-such-move")).to.equal(nil)
			expect(AttackCatalog.Get("")).to.equal(nil)
			expect(AttackCatalog.Get(nil :: any)).to.equal(nil)
		end)
	end)

	describe("AttackCatalog.Get -- precedence", function()
		it("prefers a custom move over a Default one sharing its id", function()
			-- A custom move sharing an id with a Default one is the more specific intent (AttackCatalog's
			-- resolveMove).
			local default = DefaultMoveRegistry.Get(DEFAULT_MOVE_ID)
			expect(default).to.be.ok()

			local custom = MoveTypes.Clone(default :: any)
			custom.Damage = (default :: any).Damage + 777
			MoveRegistryManager.Upsert(custom)

			local entry = AttackCatalog.Get(DEFAULT_MOVE_ID) :: any
			expect(entry.Profile.Damage).to.equal((default :: any).Damage + 777)
		end)

		it("falls back to the Default registry once the custom move is deleted", function()
			local default = DefaultMoveRegistry.Get(DEFAULT_MOVE_ID) :: any
			local custom = MoveTypes.Clone(default)
			custom.Damage = default.Damage + 777
			MoveRegistryManager.Upsert(custom)
			MoveRegistryManager.Delete(DEFAULT_MOVE_ID)

			local entry = AttackCatalog.Get(DEFAULT_MOVE_ID) :: any
			expect(entry.Profile.Damage).to.equal(default.Damage)
		end)

		it("sees an edit immediately, because it holds no cache", function()
			-- The Move Editor's whole "edits take effect immediately" design depends on this. A cache
			-- here would need invalidating on both Upsert and Delete and could serve a stale move.
			local default = DefaultMoveRegistry.Get(DEFAULT_MOVE_ID) :: any
			local custom = MoveTypes.Clone(default)
			custom.Damage = 1
			MoveRegistryManager.Upsert(custom)
			expect((AttackCatalog.Get(DEFAULT_MOVE_ID) :: any).Profile.Damage).to.equal(1)

			custom = MoveTypes.Clone(custom)
			custom.Damage = 2
			MoveRegistryManager.Upsert(custom)
			expect((AttackCatalog.Get(DEFAULT_MOVE_ID) :: any).Profile.Damage).to.equal(2)
		end)
	end)

	describe("AttackCatalog.Get -- the WindupSeconds override's Cooldown bound", function()
		-- CombatConstants.Weapons.Baseline.Stages.Basic[1]: WindupSeconds 0.31, ActiveSeconds 0.22,
		-- RecoverySeconds 0.14, Cooldown 0.44. Active+Recovery = 0.36, so the override survives only
		-- when it is at least Cooldown - (Active+Recovery) = 0.08.
		--
		-- The bound only exists while the clip's LENGTH is unknown -- with it known, the swing is the
		-- clip's length whatever the marker says (see the next describe). A read clip always has a
		-- length, so these cases switch clip syncing off to reach the unknown-length path.
		local ANIMATION_ID = "rbxassetid://104588315151150" -- AttackAnimations' baseline Basic:1 clip

		local function withoutClipSync(body: () -> ()): ()
			LiveTuningContract.withRestore(function()
				AttackConstants.Windows.SyncToClipLength = false
				body()
			end, function()
				AttackConstants.Windows.SyncToClipLength = true
			end)
		end

		afterEach(clearClips)

		it("keeps the hardcoded WindupSeconds when the override would drop the swing below its own Cooldown", function()
			serveClip(0.05, 0.05) -- 0.05 + 0.22 + 0.14 = 0.41, under the 0.44 Cooldown
			AttackWindows.Prefetch(ANIMATION_ID)
			withoutClipSync(function()
				local entry = AttackCatalog.Get(DEFAULT_MOVE_ID) :: any
				expect(entry.Definition.WindupSeconds).to.be.near(0.31, 1e-6)
			end)
		end)

		it("applies the override once the swing still meets or exceeds its own Cooldown", function()
			serveClip(0.10, 0.10) -- 0.10 + 0.22 + 0.14 = 0.46, at or over the 0.44 Cooldown
			AttackWindows.Prefetch(ANIMATION_ID)
			withoutClipSync(function()
				local entry = AttackCatalog.Get(DEFAULT_MOVE_ID) :: any
				expect(entry.Definition.WindupSeconds).to.be.near(0.10, 1e-6)
			end)
		end)
	end)

	describe("AttackCatalog.Get -- the swing ends when its clip does", function()
		-- Basic[1]: Windup 0.31, Active 0.22, Recovery 0.14 (total 0.67), Cooldown 0.44.
		-- Heavy[1]: Windup 0.600, Active 0.22, Recovery 0.55 (total 1.37), Cooldown 1.37.
		local BASIC_CLIP = "rbxassetid://104588315151150"
		local HEAVY_CLIP = "rbxassetid://83363364108102"

		afterEach(clearClips)

		it("keeps the authored timeline for a clip that has not been read", function()
			local entry = AttackCatalog.Get(DEFAULT_MOVE_ID) :: any
			expect(entry.Definition.WindupSeconds).to.be.near(0.31, 1e-6)
			expect(entry.Definition.RecoverySeconds).to.be.near(0.14, 1e-6)
			expect(entry.PlaybackSpeed).to.equal(1)
		end)

		it("stretches recovery so the swing lasts exactly as long as a longer clip", function()
			serveClip(0.9)
			AttackWindows.Prefetch(BASIC_CLIP)
			local entry = AttackCatalog.Get(DEFAULT_MOVE_ID) :: any
			expect(total(entry)).to.be.near(0.9, 1e-6)
			expect(entry.Definition.RecoverySeconds).to.be.near(0.37, 1e-6)
		end)

		it("opens the hitbox on the move's own delay, for its own window, whatever the clip's length", function()
			serveClip(0.9)
			AttackWindows.Prefetch(BASIC_CLIP)
			local entry = AttackCatalog.Get(DEFAULT_MOVE_ID) :: any
			expect(entry.Definition.WindupSeconds).to.be.near(0.31, 1e-6)
			expect(entry.Definition.ActiveSeconds).to.be.near(0.22, 1e-6)
		end)

		it("syncs Heavy too, which no marker ever touches", function()
			serveClip(1.6)
			AttackWindows.Prefetch(HEAVY_CLIP)
			local entry = AttackCatalog.Get(HEAVY_MOVE_ID) :: any
			expect(entry.Definition.WindupSeconds).to.be.near(0.6, 1e-6)
			expect(total(entry)).to.be.near(1.6, 1e-6)
		end)

		it("puts the hitbox on the clip's marker, and still ends on the clip's end", function()
			-- 0.05 would have been refused by the Cooldown bound above; with the length known it is not
			-- needed, because the swing is the clip's 0.9 either way.
			serveClip(0.9, 0.05)
			AttackWindows.Prefetch(BASIC_CLIP)
			local entry = AttackCatalog.Get(DEFAULT_MOVE_ID) :: any
			expect(entry.Definition.WindupSeconds).to.be.near(0.05, 1e-6)
			expect(total(entry)).to.be.near(0.9, 1e-6)
		end)

		it("never cuts the hit window to fit a clip too short for it -- recovery just goes to zero", function()
			serveClip(0.4) -- shorter than Windup + Active (0.53)
			AttackWindows.Prefetch(BASIC_CLIP)
			local entry = AttackCatalog.Get(DEFAULT_MOVE_ID) :: any
			expect(entry.Definition.WindupSeconds).to.be.near(0.31, 1e-6)
			expect(entry.Definition.ActiveSeconds).to.be.near(0.22, 1e-6)
			expect(entry.Definition.RecoverySeconds).to.equal(0)
		end)

		it("opens a Heavy's hitbox on its clip's Hit marker", function()
			serveClip(1.6, 0.45, "Hit")
			AttackWindows.Prefetch(HEAVY_CLIP)
			local entry = AttackCatalog.Get(HEAVY_MOVE_ID) :: any
			expect(entry.Definition.WindupSeconds).to.be.near(0.45, 1e-6)
			expect(entry.Definition.ActiveSeconds).to.be.near(0.22, 1e-6)
			expect(total(entry)).to.be.near(1.6, 1e-6)
		end)

		it("pulls a swing-length Cooldown down with a shorter clip, so no dead time follows it", function()
			serveClip(1.0) -- Heavy's authored Cooldown is its whole 1.37 timeline
			AttackWindows.Prefetch(HEAVY_CLIP)
			local entry = AttackCatalog.Get(HEAVY_MOVE_ID) :: any
			expect(total(entry)).to.be.near(1.0, 1e-6)
			expect(entry.Cooldown).to.be.near(1.0, 1e-6)
		end)

		it("leaves a Cooldown authored longer than its swing alone -- that one is a real gate", function()
			local custom = MoveTypes.Clone(DefaultMoveRegistry.Get(DEFAULT_MOVE_ID) :: any)
			custom.AnimationId = "rbxassetid://custom-clip"
			custom.Cooldown = 5
			MoveRegistryManager.Upsert(custom)
			serveClip(0.9)
			AttackWindows.Prefetch("rbxassetid://custom-clip")
			local entry = AttackCatalog.Get(DEFAULT_MOVE_ID) :: any
			expect(total(entry)).to.be.near(0.9, 1e-6)
			expect(entry.Cooldown).to.equal(5)
		end)

		it("plays a fast weapon's clip fast, and times the swing against the clip at that speed", function()
			local weapons = workspace:FindFirstChild("Weapons") :: Instance
			local model = weapons:FindFirstChild(WEAPON) :: Instance
			LiveTuningContract.withRestore(function()
				model:SetAttribute("WeaponSpeed", 2)
				WeaponFixture.Rebuild()
				serveClip(0.9, 0.2)
				AttackWindows.Prefetch(BASIC_CLIP)
				local entry = AttackCatalog.Get(DEFAULT_MOVE_ID) :: any
				expect(entry.PlaybackSpeed).to.equal(2)
				-- The 0.2s marker, reached in half the time.
				expect(entry.Definition.WindupSeconds).to.be.near(0.1, 1e-6)
				-- The 0.9s clip, played at 2x.
				expect(total(entry)).to.be.near(0.45, 1e-6)
			end, function()
				model:SetAttribute("WeaponSpeed", nil)
				WeaponFixture.Rebuild()
			end)
		end)

		it("respects AttackConstants.Windows.SyncToClipLength", function()
			serveClip(0.9)
			AttackWindows.Prefetch(BASIC_CLIP)
			LiveTuningContract.withRestore(function()
				AttackConstants.Windows.SyncToClipLength = false
				expect((AttackCatalog.Get(DEFAULT_MOVE_ID) :: any).Definition.RecoverySeconds).to.be.near(0.14, 1e-6)
			end, function()
				AttackConstants.Windows.SyncToClipLength = true
			end)
		end)
	end)

	describe("AttackCatalog.Has", function()
		it("answers existence without paying for the projection", function()
			expect(AttackCatalog.Has(DEFAULT_MOVE_ID)).to.equal(true)
			expect(AttackCatalog.Has("no-such-move")).to.equal(false)
			expect(AttackCatalog.Has("")).to.equal(false)
		end)
	end)
end
