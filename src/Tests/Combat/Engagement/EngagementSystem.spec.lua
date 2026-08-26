--!strict
-- Covers Server/Combat/Engagement/EngagementSystem.lua -- the combat tag: what opens one, what
-- refuses to, how it expires, and what a leaver has to be scrubbed out of.
--
-- ================================================================================================
-- THE ONE THING THIS FILE DOES DIFFERENTLY, AND WHY
-- ================================================================================================
--
-- Every other spec in Tests/Combat drives its module end-to-end and asserts on the result. This one
-- CANNOT, and the reason is not a shortcut: EngagementSystem's table is keyed by Player, and a Player
-- cannot be fabricated in this harness. Instance.new("Player") errors outright -- Tests/Combat/Attack/
-- AttackRequestSystem.spec.lua's header records the same limit, and Tests/Admin/AdminActionSystem.
-- spec.lua's does for its own Player-keyed wrappers. A spec that let EngagementSystem.Attach() run
-- and then threw real hits would watch every one of them resolve two nil Players and tag nobody, and
-- would pass while asserting nothing.
--
-- So the exchange is SPLIT rather than faked wholesale:
--
--   the CONTACT is real       -- real rigs, real HitboxEngine volume, real DefenseSystem
--                                classification, real DamageSystem pricing. `capture` below listens on
--                                DamageSystem.OnApplied and keeps the genuine DefenseOutcome and
--                                DamageResult, so "a blocked hit deals zero and still tags" is
--                                asserted against the damage layer's OWN zero, never a hand-written
--                                one, and the Kind strings are whatever the defence layer actually
--                                resolved.
--   the IDENTITY is a stand-in -- `{ Name = ..., UserId = ... } :: any`, the same table-cast-to-Player
--                                shape Tests/Combat/RateLimiter.spec.lua and Tests/Combat/
--                                ChangeNotifier.spec.lua already use. EngagementSystem only ever uses
--                                a Player as a table key and reads .Name/.UserId off it, so a table
--                                is a complete stand-in for every path here.
--
-- Those two are rejoined by EngagementSystem.RecordExchange, which is the public seam that exists for
-- precisely this reason (see that function's header and the Combatant type's). Attach() is therefore
-- deliberately NEVER called: it would subscribe the real adapter, which would resolve nil Players on
-- every one of these contacts and do nothing. What is not covered here is that adapter's own two
-- Players:GetPlayerFromCharacter lines -- three statements with no branching -- and that gap is
-- deferred to the two-client playtest, stated plainly rather than papered over.
--
-- Init() is never called either, for the ordinary reason every spec in this folder gives: it would
-- connect a real Heartbeat racing these synthetic Steps and create remotes with nobody to fire at.
-- Time is driven through Step(deltaTime, now) on all four layers in Main.server.lua's boot order.
-- Nothing here sleeps.

local CollectionService = game:GetService("CollectionService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Constants = require(ReplicatedStorage.Shared.Constants)
local DamageSystem = require(ServerScriptService.Server.Combat.Damage.DamageSystem)
local DamageTypes = require(ReplicatedStorage.Shared.Damage.DamageTypes)
local DefenseSystem = require(ServerScriptService.Server.Combat.Defense.DefenseSystem)
local DefenseTypes = require(ReplicatedStorage.Shared.Defense.DefenseTypes)
local EngagementConstants = require(ReplicatedStorage.Shared.Engagement.EngagementConstants)
local EngagementSystem = require(ServerScriptService.Server.Combat.Engagement.EngagementSystem)
local HitboxEngine = require(ServerScriptService.Server.Combat.HitboxEngine.HitboxEngine)
local HitboxTypes = require(ReplicatedStorage.Shared.HitboxEngine.HitboxTypes)
local MoveRegistryManager = require(ServerScriptService.Server.Combat.MoveRegistryManager)
local ParryWindows = require(ReplicatedStorage.Shared.Defense.ParryWindows)
local WeaponFixture = require(ServerScriptService.Tests.TestHelpers.WeaponFixture)

-- A real roster weapon, for the same reason GrabSystem.spec installs one: the MoveId below has to
-- RESOLVE through AttackCatalog, and a spec that installs no weapon gets a catalogue with no weapon
-- moves in it.
local WEAPON = WeaponFixture.Install()[1]

local FRAME = 1 / 60
local PARRY_ANIMATION = "rbxassetid://spec-engagement-parry"
local WINDOW_OPEN = 0
local WINDOW_CLOSE = 0.3

local MOVE_ID = `default:{WEAPON}:Basic:1`

local TAG = EngagementConstants.TagDurationSeconds

type Dummy = {
	Model: Model,
	Root: BasePart,
	Humanoid: Humanoid,
	Id: number,
}

local spawned: { Model } = {}

-- The stand-in identity -- see this file's header. Cast through `any` exactly as RateLimiter.spec and
-- ChangeNotifier.spec do; UserId is distinct per call so the leaver scrub, which matches ON UserId,
-- is actually being asked a question it could get wrong.
--
-- TrackPlayer is called on the way out, which is not incidental: it is what Players.PlayerAdded does
-- for a real player, and skipping it would leave every stand-in in a state no live player is ever in.
-- ChangeNotifier.Update reports "no change" for a player it has never seen (that module's own header
-- -- establishing a baseline is not a change), so an unseeded stand-in never gets the InCombat
-- Attribute written on its rising edge.
local nextUserId = 0
local function fakePlayer(name: string, character: Model?): Player
	nextUserId += 1
	local player = { Name = name, UserId = nextUserId, Character = character } :: any
	EngagementSystem.TrackPlayer(player)
	return player
end

local function makeDummy(name: string, position: Vector3, lookAt: Vector3?): Dummy
	local model = Instance.new("Model")
	model.Name = name

	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = Vector3.new(2, 2, 1)
	root.Anchored = true
	root.CanCollide = false
	root.CFrame = if lookAt then CFrame.lookAt(position, lookAt) else CFrame.new(position)
	root.Parent = model

	local humanoid = Instance.new("Humanoid")
	humanoid.RequiresNeck = false
	humanoid.Parent = model

	model.PrimaryPart = root
	model.Parent = Workspace
	table.insert(spawned, model)

	local id = HitboxEngine.RegisterCombatant(model, root, humanoid)
	DefenseSystem.RegisterCombatant(model, root, humanoid, PARRY_ANIMATION)
	return { Model = model, Root = root, Humanoid = humanoid, Id = id }
end

local function makeDefinition(): HitboxTypes.AttackDefinition
	return (
		HitboxTypes.SanitizeDefinition({
			DebugName = MOVE_ID,
			Shape = "Box",
			BaseDimensions = { Width = 4, Height = 6, Length = 6 },
			Scaling = { ComboStageMultipliers = { 1 }, MaxScaleMultiplier = 8 },
			Offset = CFrame.new(0, 0, -4),
			AttachmentPart = "Root",
			WindupSeconds = 0,
			ActiveSeconds = 5,
			RecoverySeconds = 0,
			LocksMovement = false,
		})
	)
end

-- One frame, in Main.server.lua's boot order. EngagementSystem.Step goes last, as the sibling that
-- reads the damage layer's output.
local function step(deltaTime: number, now: number): ()
	HitboxEngine.Step(deltaTime, now)
	DefenseSystem.Step(deltaTime, now)
	DamageSystem.Step(deltaTime, now)
	EngagementSystem.Step(deltaTime, now)
end

-- The real outcome of the most recent contact, captured off the damage layer's own signal.
local captured: { Outcome: DefenseTypes.DefenseOutcome, Result: DamageTypes.DamageResult }? = nil
local captureDisconnect: (() -> ())? = nil

-- Throws one real attack from `attacker` and returns what the defence and damage layers made of it.
-- Errors rather than returning nil on a miss: every case here depends on a contact having actually
-- landed, and a silent nil would turn a geometry regression into a fleet of confusing assertion
-- failures somewhere else.
local function landHit(attacker: Dummy, now: number): (DefenseTypes.DefenseOutcome, DamageTypes.DamageResult)
	captured = nil
	HitboxEngine.RequestAttack(attacker.Id, makeDefinition(), 1, 1)
	step(FRAME, now)
	local hit = captured
	assert(hit, "the spec's own attack did not resolve into a DamageSystem outcome")
	return hit.Outcome, hit.Result
end

-- Lands a real hit and replays it through RecordExchange under the two given identities -- the join
-- described in this file's header. Returns the outcome so a case can assert on what the defence layer
-- actually decided.
local function exchange(
	attacker: Dummy,
	attackerPlayer: Player?,
	defender: Dummy,
	defenderPlayer: Player?,
	now: number
): DefenseTypes.DefenseOutcome
	local outcome, result = landHit(attacker, now)
	-- The engine picked the target, not this spec -- so check it picked the one the case is about
	-- before attributing an identity to it. A third rig drifting into the volume would otherwise show
	-- up as an inexplicable assertion failure several lines later.
	assert(outcome.Defender == defender.Model, "the spec's attack resolved against an unexpected defender")
	EngagementSystem.RecordExchange(
		{ Model = outcome.Attacker, Player = attackerPlayer },
		{ Model = outcome.Defender, Player = defenderPlayer },
		outcome.Kind,
		result.Damage,
		now
	)
	return outcome
end

-- A synthetic exchange between two real Models under two given identities, with no contact thrown at
-- all. Used by the cases that are about EngagementSystem's OWN arithmetic -- deadline assignment,
-- accumulation -- where routing through a second real swing would be testing HitboxEngine's ability
-- to start one again rather than anything this module does. The cases where the outcome Kind or the
-- damage figure has to be genuine use `exchange` above instead.
local SYNTHETIC_DAMAGE = 7

local function record(
	attacker: Dummy,
	attackerPlayer: Player?,
	defender: Dummy,
	defenderPlayer: Player?,
	now: number,
	damage: number?
): ()
	EngagementSystem.RecordExchange(
		{ Model = attacker.Model, Player = attackerPlayer },
		{ Model = defender.Model, Player = defenderPlayer },
		"Clean",
		damage or SYNTHETIC_DAMAGE,
		now
	)
end

-- Two dummies facing each other at a distance the definition above comfortably reaches.
local function facingPair(): (Dummy, Dummy)
	local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4))
	local defender = makeDummy("Defender", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0))
	return attacker, defender
end

return function()
	beforeEach(function()
		DefenseSystem.Attach()
		DamageSystem.Attach()
		-- NOT EngagementSystem.Attach() -- see this file's header.
		ParryWindows.Register(PARRY_ANIMATION, WINDOW_OPEN, WINDOW_CLOSE)
		captureDisconnect = DamageSystem.OnApplied(
			function(outcome: DefenseTypes.DefenseOutcome, result: DamageTypes.DamageResult)
				captured = { Outcome = outcome, Result = result }
			end
		)
	end)

	afterEach(function()
		if captureDisconnect then
			captureDisconnect()
			captureDisconnect = nil
		end
		captured = nil
		EngagementSystem.Reset()
		DamageSystem.Reset()
		DefenseSystem.Reset()
		HitboxEngine.Reset()
		ParryWindows.Reset()
		MoveRegistryManager.Init()
		for _, model in spawned do
			model:Destroy()
		end
		table.clear(spawned)
	end)

	describe("EngagementSystem -- what opens a tag", function()
		it("tags BOTH sides of a resolved exchange", function()
			local base = os.clock()
			local attacker, defender = facingPair()
			local attackerPlayer, defenderPlayer = fakePlayer("Attacker"), fakePlayer("Defender")

			exchange(attacker, attackerPlayer, defender, defenderPlayer, base + FRAME)

			expect(EngagementSystem.IsInCombat(attackerPlayer)).to.equal(true)
			expect(EngagementSystem.IsInCombat(defenderPlayer)).to.equal(true)
		end)

		it("names each side's opponent as the other one", function()
			local base = os.clock()
			local attacker, defender = facingPair()
			local attackerPlayer, defenderPlayer = fakePlayer("Ryu"), fakePlayer("Kaito")

			exchange(attacker, attackerPlayer, defender, defenderPlayer, base + FRAME)

			local attackerView = EngagementSystem.GetEngagement(attackerPlayer, base + FRAME)
			local defenderView = EngagementSystem.GetEngagement(defenderPlayer, base + FRAME)
			assert(attackerView and defenderView, "both sides should hold an engagement")
			expect(attackerView.OpponentName).to.equal("Kaito")
			expect(defenderView.OpponentName).to.equal("Ryu")
			expect(attackerView.OpponentUserId).to.equal(defenderPlayer.UserId)
			expect(defenderView.OpponentUserId).to.equal(attackerPlayer.UserId)
		end)

		it("tags a lone player fighting a non-player combatant that carries no dummy tag", function()
			local base = os.clock()
			local attacker, defender = facingPair()
			local attackerPlayer = fakePlayer("Attacker")

			-- No identity on the defender at all: the shape a future bot or NPC boss arrives in.
			exchange(attacker, attackerPlayer, defender, nil, base + FRAME)

			expect(EngagementSystem.IsInCombat(attackerPlayer)).to.equal(true)
			local view = EngagementSystem.GetEngagement(attackerPlayer, base + FRAME)
			assert(view, "the attacker should hold an engagement")
			-- Falls back to the Model's own name, and carries no UserId.
			expect(view.OpponentName).to.equal("Defender")
			expect(view.OpponentUserId).to.equal(nil)
		end)

		it("still tags on a hit that dealt no health damage at all", function()
			local base = os.clock()
			local attacker, defender = facingPair()
			local attackerPlayer, defenderPlayer = fakePlayer("Attacker"), fakePlayer("Defender")

			-- A real raised guard, classified by the real defence layer -- so the zero asserted below
			-- is the damage layer's own, not one this spec wrote. Stepped past WINDOW_CLOSE first,
			-- exactly as DamageSystem.spec's own blocking cases do: raising Block OPENS a parry window,
			-- and a hit landing inside it resolves Parried rather than Blocked.
			DefenseSystem.SetBlocking(defender.Model, true, base)
			step(FRAME, base + WINDOW_CLOSE + FRAME)
			local at = base + WINDOW_CLOSE + 2 * FRAME
			local outcome, result = landHit(attacker, at)
			EngagementSystem.RecordExchange(
				{ Model = outcome.Attacker, Player = attackerPlayer },
				{ Model = outcome.Defender, Player = defenderPlayer },
				outcome.Kind,
				result.Damage,
				at
			)

			expect(result.Damage).to.equal(0)
			expect(outcome.Kind).to.equal("Blocked")
			expect(EngagementSystem.IsInCombat(attackerPlayer)).to.equal(true)
			expect(EngagementSystem.IsInCombat(defenderPlayer)).to.equal(true)
		end)
	end)

	describe("EngagementSystem -- what refuses to tag", function()
		-- THE TAG IS APPLIED BY THIS SPEC, not by anything in the live build. DebugDummySystem stopped
		-- applying it on 2026-08-25 -- a debug dummy tags you now, deliberately (see its buildRig and
		-- EngagementConstants.DummyTag). These two cases therefore cover the MECHANISM, which is still
		-- live and still the thing a future non-adversary prop will rely on, rather than any rig that
		-- currently carries it.
		it("tags NEITHER side when the target carries the dummy tag", function()
			local base = os.clock()
			local attacker, defender = facingPair()
			CollectionService:AddTag(defender.Model, EngagementConstants.DummyTag)
			local attackerPlayer, defenderPlayer = fakePlayer("Attacker"), fakePlayer("Defender")

			exchange(attacker, attackerPlayer, defender, defenderPlayer, base + FRAME)

			expect(EngagementSystem.IsInCombat(attackerPlayer)).to.equal(false)
			expect(EngagementSystem.IsInCombat(defenderPlayer)).to.equal(false)
		end)

		it("tags neither side when the ATTACKER is the tagged rig", function()
			local base = os.clock()
			local attacker, defender = facingPair()
			CollectionService:AddTag(attacker.Model, EngagementConstants.DummyTag)
			local attackerPlayer, defenderPlayer = fakePlayer("Attacker"), fakePlayer("Defender")

			exchange(attacker, attackerPlayer, defender, defenderPlayer, base + FRAME)

			expect(EngagementSystem.IsInCombat(attackerPlayer)).to.equal(false)
			expect(EngagementSystem.IsInCombat(defenderPlayer)).to.equal(false)
		end)

		it("never tags a combatant for hitting itself", function()
			local base = os.clock()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4))
			local attackerPlayer = fakePlayer("Attacker")

			EngagementSystem.RecordExchange(
				{ Model = attacker.Model, Player = attackerPlayer },
				{ Model = attacker.Model, Player = attackerPlayer },
				"Clean",
				10,
				base
			)

			expect(EngagementSystem.IsInCombat(attackerPlayer)).to.equal(false)
		end)

		it("records nothing for an exchange with no player on either side", function()
			local base = os.clock()
			local attacker, defender = facingPair()

			exchange(attacker, nil, defender, nil, base + FRAME)

			expect(EngagementSystem.TaggedCount()).to.equal(0)
		end)
	end)

	describe("EngagementSystem -- expiry", function()
		it("holds the tag right up to the last moment before TagDurationSeconds", function()
			local base = os.clock()
			local attacker, defender = facingPair()
			local attackerPlayer, defenderPlayer = fakePlayer("Attacker"), fakePlayer("Defender")

			local at = base + FRAME
			exchange(attacker, attackerPlayer, defender, defenderPlayer, at)
			EngagementSystem.Step(FRAME, at + TAG - FRAME)

			expect(EngagementSystem.IsInCombat(attackerPlayer)).to.equal(true)
			expect(EngagementSystem.IsInCombat(defenderPlayer)).to.equal(true)
		end)

		it("drops both rows once TagDurationSeconds has elapsed", function()
			local base = os.clock()
			local attacker, defender = facingPair()
			local attackerPlayer, defenderPlayer = fakePlayer("Attacker"), fakePlayer("Defender")

			local at = base + FRAME
			exchange(attacker, attackerPlayer, defender, defenderPlayer, at)
			EngagementSystem.Step(FRAME, at + TAG)

			expect(EngagementSystem.IsInCombat(attackerPlayer)).to.equal(false)
			expect(EngagementSystem.IsInCombat(defenderPlayer)).to.equal(false)
			-- A lapsed tag DELETES its row rather than leaving a false-flagged husk -- see the
			-- `engagements` declaration on why those two facts are one fact here.
			expect(EngagementSystem.GetEngagement(attackerPlayer, at + TAG)).to.equal(nil)
			expect(EngagementSystem.TaggedCount()).to.equal(0)
		end)

		it("pushes the deadline out when a fresh exchange refreshes the tag", function()
			local base = os.clock()
			local attacker, defender = facingPair()
			local attackerPlayer, defenderPlayer = fakePlayer("Attacker"), fakePlayer("Defender")

			local first = base + FRAME
			record(attacker, attackerPlayer, defender, defenderPlayer, first)
			local second = first + 0.25
			record(attacker, attackerPlayer, defender, defenderPlayer, second)

			-- Past the FIRST deadline but not the second: still tagged, because the refresh moved it.
			EngagementSystem.Step(FRAME, first + TAG + FRAME)
			expect(EngagementSystem.IsInCombat(attackerPlayer)).to.equal(true)

			EngagementSystem.Step(FRAME, second + TAG)
			expect(EngagementSystem.IsInCombat(attackerPlayer)).to.equal(false)
		end)

		it("ASSIGNS the deadline forward rather than keeping a longer one already running", function()
			local base = os.clock()
			local attacker, defender = facingPair()
			local attackerPlayer, defenderPlayer = fakePlayer("Attacker"), fakePlayer("Defender")

			-- The case that actually separates assign-forward from math.max, which the case above
			-- cannot: the FIRST exchange is stamped a full second ahead of the second one, so a
			-- math.max would keep its longer deadline and the tag would outlive the later assignment.
			-- Assign-forward means the most recently recorded exchange wins outright, which is the
			-- documented contract (see EngagementConstants.TagDurationSeconds).
			--
			-- Driven through RecordExchange rather than two real swings on purpose: this is about one
			-- assignment in this module, and stepping the shared engine backwards to stage it would be
			-- testing something else entirely.
			local ahead = base + 1
			record(attacker, attackerPlayer, defender, defenderPlayer, ahead)
			local behind = base + FRAME
			record(attacker, attackerPlayer, defender, defenderPlayer, behind)

			EngagementSystem.Step(FRAME, behind + TAG)

			expect(EngagementSystem.IsInCombat(attackerPlayer)).to.equal(false)
		end)
	end)

	describe("EngagementSystem -- damage traded", function()
		it("accumulates dealt and taken on opposite sides of the same exchange", function()
			local base = os.clock()
			local attacker, defender = facingPair()
			local attackerPlayer, defenderPlayer = fakePlayer("Attacker"), fakePlayer("Defender")

			local at = base + FRAME
			local _outcome = exchange(attacker, attackerPlayer, defender, defenderPlayer, at)
			local firstResult = (captured :: any).Result.Damage

			local attackerView = EngagementSystem.GetEngagement(attackerPlayer, at)
			local defenderView = EngagementSystem.GetEngagement(defenderPlayer, at)
			assert(attackerView and defenderView, "both sides should hold an engagement")

			-- The same one number, read from each end.
			expect(attackerView.DamageDealt).to.equal(firstResult)
			expect(attackerView.DamageTaken).to.equal(0)
			expect(defenderView.DamageTaken).to.equal(firstResult)
			expect(defenderView.DamageDealt).to.equal(0)
			expect(firstResult > 0).to.equal(true)
		end)

		it("adds a second exchange's damage to the first", function()
			local base = os.clock()
			local attacker, defender = facingPair()
			local attackerPlayer, defenderPlayer = fakePlayer("Attacker"), fakePlayer("Defender")

			local at = base + FRAME
			exchange(attacker, attackerPlayer, defender, defenderPlayer, at)
			local first = (captured :: any).Result.Damage
			-- The second contribution is synthetic: this case is about the `+=`, and a second real
			-- swing would additionally be asserting that the engine can start one on the next frame.
			record(attacker, attackerPlayer, defender, defenderPlayer, at + FRAME)

			local attackerView = EngagementSystem.GetEngagement(attackerPlayer, at + FRAME)
			local defenderView = EngagementSystem.GetEngagement(defenderPlayer, at + FRAME)
			assert(attackerView and defenderView, "both sides should hold an engagement")
			expect(attackerView.DamageDealt).to.equal(first + SYNTHETIC_DAMAGE)
			expect(defenderView.DamageTaken).to.equal(first + SYNTHETIC_DAMAGE)
		end)

		it("resets the totals when a LAPSED tag opens a fresh engagement", function()
			local base = os.clock()
			local attacker, defender = facingPair()
			local attackerPlayer, defenderPlayer = fakePlayer("Attacker"), fakePlayer("Defender")

			local at = base + FRAME
			exchange(attacker, attackerPlayer, defender, defenderPlayer, at)
			expect(((captured :: any).Result.Damage :: number) > 0).to.equal(true)

			-- Let it lapse completely, then start again.
			EngagementSystem.Step(FRAME, at + TAG)
			expect(EngagementSystem.IsInCombat(attackerPlayer)).to.equal(false)

			local later = at + TAG + 1
			record(attacker, attackerPlayer, defender, defenderPlayer, later)

			local view = EngagementSystem.GetEngagement(attackerPlayer, later)
			assert(view, "the attacker should hold a fresh engagement")
			-- THIS fight's number, not the session's: exactly the one exchange just recorded, with the
			-- real hit from the previous engagement gone rather than carried over.
			expect(view.DamageDealt).to.equal(SYNTHETIC_DAMAGE)
		end)
	end)

	describe("EngagementSystem -- the InCombat Attribute", function()
		it("writes the Attribute on the rising edge for a player whose character is resolvable", function()
			local base = os.clock()
			local attacker, defender = facingPair()
			-- The stand-in carries a Character, which is all CharacterUtil.HumanoidOf needs to find the
			-- Humanoid the Attribute goes on. The defender deliberately carries none -- that is the
			-- dead/respawning shape, and publishing to them must not throw.
			local attackerPlayer = fakePlayer("Attacker", attacker.Model)
			local defenderPlayer = fakePlayer("Defender")

			exchange(attacker, attackerPlayer, defender, defenderPlayer, base + FRAME)

			expect(attacker.Humanoid:GetAttribute(Constants.Attributes.InCombat)).to.equal(true)
		end)

		it("writes it back to false on the expiry edge", function()
			local base = os.clock()
			local attacker, defender = facingPair()
			local attackerPlayer = fakePlayer("Attacker", attacker.Model)
			local defenderPlayer = fakePlayer("Defender")

			local at = base + FRAME
			exchange(attacker, attackerPlayer, defender, defenderPlayer, at)
			EngagementSystem.Step(FRAME, at + TAG)

			expect(attacker.Humanoid:GetAttribute(Constants.Attributes.InCombat)).to.equal(false)
		end)
	end)

	describe("EngagementSystem.ReleasePlayer", function()
		it("drops the leaver's own row", function()
			local base = os.clock()
			local attacker, defender = facingPair()
			local attackerPlayer, defenderPlayer = fakePlayer("Attacker"), fakePlayer("Defender")

			exchange(attacker, attackerPlayer, defender, defenderPlayer, base + FRAME)
			EngagementSystem.ReleasePlayer(attackerPlayer)

			expect(EngagementSystem.IsInCombat(attackerPlayer)).to.equal(false)
			-- The survivor keeps their own tag: one side quitting does not end the other's fight.
			expect(EngagementSystem.IsInCombat(defenderPlayer)).to.equal(true)
		end)

		it("scrubs the leaver's UserId out of every OTHER engagement", function()
			local base = os.clock()
			local attacker, defender = facingPair()
			local attackerPlayer, defenderPlayer = fakePlayer("Attacker"), fakePlayer("Defender")

			exchange(attacker, attackerPlayer, defender, defenderPlayer, base + FRAME)
			local before = EngagementSystem.GetEngagement(defenderPlayer, base + FRAME)
			assert(before, "the defender should hold an engagement")
			expect(before.OpponentUserId).to.equal(attackerPlayer.UserId)

			EngagementSystem.ReleasePlayer(attackerPlayer)

			local after = EngagementSystem.GetEngagement(defenderPlayer, base + FRAME)
			assert(after, "the defender should still hold their engagement")
			expect(after.OpponentUserId).to.equal(nil)
			-- The NAME survives deliberately -- see ReleasePlayer's header. The survivor's panel should
			-- keep naming who they were fighting for the rest of the tag.
			expect(after.OpponentName).to.equal("Attacker")
		end)

		it("is safe for a player who was never tagged at all", function()
			local stranger = fakePlayer("Stranger")

			EngagementSystem.ReleasePlayer(stranger)

			expect(EngagementSystem.IsInCombat(stranger)).to.equal(false)
			expect(EngagementSystem.TaggedCount()).to.equal(0)
		end)
	end)

	describe("EngagementSystem.GetAll", function()
		it("returns one row per live engagement and none once they lapse", function()
			local base = os.clock()
			local attacker, defender = facingPair()
			local attackerPlayer, defenderPlayer = fakePlayer("Attacker"), fakePlayer("Defender")

			local at = base + FRAME
			exchange(attacker, attackerPlayer, defender, defenderPlayer, at)
			expect(#EngagementSystem.GetAll(at)).to.equal(2)

			EngagementSystem.Step(FRAME, at + TAG)
			expect(#EngagementSystem.GetAll(at + TAG)).to.equal(0)
		end)
	end)
end
