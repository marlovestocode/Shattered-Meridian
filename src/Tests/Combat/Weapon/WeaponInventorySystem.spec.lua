--!strict
-- Covers Server/Combat/Weapon/WeaponInventorySystem.lua -- the owned/selected/drawn triple and the
-- rules that move between them.
--
-- DRIVEN THROUGH THE PUBLIC FUNCTIONS, NOT THE REMOTES. Pickup/ToggleDraw/SelectNext are the entire
-- production reaction to a prompt and a keypress (the remote handlers do nothing but rate-limit and
-- forward), so calling them directly exercises the real code path rather than a copy of it. The
-- ProximityPrompt wiring and the PlayerLifecycle binding are NOT covered here: both need a real
-- Player, and a bare Instance.new("Player") errors in this headless harness -- the same
-- already-accepted gap AttackRequestSystem.spec.lua's own header documents. Deferred to Studio.
--
-- A FAKE PLAYER TABLE stands in for the Player key. Every function under test uses the player purely
-- as an identity to key a record by (and reads .Name only for a log line), so a table with a Name is
-- indistinguishable from the real thing for this module's purposes -- and it is the only way to reach
-- these paths headlessly at all.

local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local AttackRequestSystem = require(ServerScriptService.Server.Combat.Attack.AttackRequestSystem)
local SwingSequencer = require(ServerScriptService.Server.Combat.Attack.SwingSequencer)
local WeaponInventorySystem = require(ServerScriptService.Server.Combat.Weapon.WeaponInventorySystem)
local WeaponVisualSystem = require(ServerScriptService.Server.Combat.Weapon.WeaponVisualSystem)
local WeaponFixture = require(ServerScriptService.Tests.TestHelpers.WeaponFixture)

local TOOL_NAME = "EquippedWeaponVisual"

local ROSTER = WeaponFixture.Install()
local FIRST_WEAPON = ROSTER[1]
local SECOND_WEAPON = ROSTER[2]

local nextId = 0
local spawned: { Instance } = {}

-- A minimal rig, matching AttackRequestSystem.spec.lua's own makeDummy. Deliberately without a
-- RightHand, so these cases assert that a Tool was EQUIPPED onto the character rather than anything
-- about the grip Motor6D -- that is Roblox's own mechanism, not this stack's to re-prove.
local function makeCharacter(name: string): Model
	local model = Instance.new("Model")
	model.Name = name

	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = Vector3.new(2, 2, 1)
	root.Anchored = true
	root.CanCollide = false
	root.Parent = model

	local humanoid = Instance.new("Humanoid")
	humanoid.RequiresNeck = false
	humanoid.Parent = model

	model.PrimaryPart = root
	model.Parent = Workspace
	table.insert(spawned, model)
	return model
end

-- See this file's header on why a table is a sufficient stand-in. Fresh per case so no two share a
-- record. `withCharacter` gives it a real rig, which is what the end-to-end draw cases need --
-- applyToCharacter reads player.Character and nothing else off it.
local function fakePlayer(withCharacter: boolean?): any
	nextId += 1
	local name = `Spec{nextId}`
	return {
		Name = name,
		Character = if withCharacter then makeCharacter(name) else nil,
	}
end

return function()
	afterEach(function()
		WeaponInventorySystem.Reset()
		WeaponVisualSystem.Reset()
		AttackRequestSystem.Reset()
		SwingSequencer.Reset()
		for _, instance in spawned do
			instance:Destroy()
		end
		table.clear(spawned)
	end)

	describe("WeaponInventorySystem -- a fresh player", function()
		it("owns nothing and has nothing drawn", function()
			local player = fakePlayer()
			expect(#WeaponInventorySystem.GetOwned(player)).to.equal(0)
			expect(WeaponInventorySystem.IsDrawn(player)).to.equal(false)
		end)

		it("cannot draw with an empty inventory, and does not error trying", function()
			local player = fakePlayer()
			expect(WeaponInventorySystem.ToggleDraw(player)).to.equal(false)
			expect(WeaponInventorySystem.IsDrawn(player)).to.equal(false)
		end)
	end)

	describe("WeaponInventorySystem.Pickup", function()
		it("adds a roster weapon and selects the first one picked up", function()
			local player = fakePlayer()
			expect(WeaponInventorySystem.Pickup(player, FIRST_WEAPON)).to.equal(true)

			local owned = WeaponInventorySystem.GetOwned(player)
			expect(#owned).to.equal(1)
			expect(owned[1]).to.equal(FIRST_WEAPON)
			-- Selected implicitly, so the very next draw press works with no other control discovered.
			expect(WeaponInventorySystem.ToggleDraw(player)).to.equal(true)
		end)

		it("is a no-op for a weapon already owned, rather than a duplicate entry", function()
			local player = fakePlayer()
			WeaponInventorySystem.Pickup(player, FIRST_WEAPON)
			expect(WeaponInventorySystem.Pickup(player, FIRST_WEAPON)).to.equal(false)
			expect(#WeaponInventorySystem.GetOwned(player)).to.equal(1)
		end)

		it("refuses a weapon the roster does not know", function()
			local player = fakePlayer()
			expect(WeaponInventorySystem.Pickup(player, "NotARealWeapon")).to.equal(false)
			expect(#WeaponInventorySystem.GetOwned(player)).to.equal(0)
		end)

		it("keeps pickup order, which is what SelectNext cycles through", function()
			local player = fakePlayer()
			WeaponInventorySystem.Pickup(player, SECOND_WEAPON)
			WeaponInventorySystem.Pickup(player, FIRST_WEAPON)

			local owned = WeaponInventorySystem.GetOwned(player)
			expect(owned[1]).to.equal(SECOND_WEAPON)
			expect(owned[2]).to.equal(FIRST_WEAPON)
		end)
	end)

	describe("WeaponInventorySystem.ToggleDraw", function()
		it("draws, then sheathes, on successive presses", function()
			local player = fakePlayer()
			WeaponInventorySystem.Pickup(player, FIRST_WEAPON)

			expect(WeaponInventorySystem.ToggleDraw(player)).to.equal(true)
			expect(WeaponInventorySystem.IsDrawn(player)).to.equal(true)

			expect(WeaponInventorySystem.ToggleDraw(player)).to.equal(false)
			expect(WeaponInventorySystem.IsDrawn(player)).to.equal(false)
		end)

		it("keeps the selection across a sheath, so re-drawing returns the same weapon", function()
			local player = fakePlayer()
			WeaponInventorySystem.Pickup(player, FIRST_WEAPON)
			WeaponInventorySystem.Pickup(player, SECOND_WEAPON)
			WeaponInventorySystem.SelectNext(player)

			WeaponInventorySystem.ToggleDraw(player)
			WeaponInventorySystem.ToggleDraw(player)
			expect(WeaponInventorySystem.IsDrawn(player)).to.equal(false)

			-- Same weapon back, not a reset to the first owned -- see the module's own SELECTED note.
			WeaponInventorySystem.ToggleDraw(player)
			expect(WeaponInventorySystem.IsDrawn(player)).to.equal(true)
			expect(#WeaponInventorySystem.GetOwned(player)).to.equal(2)
		end)
	end)

	describe("WeaponInventorySystem -- drawing actually reaches the character", function()
		-- THE REGRESSION THIS FILE EXISTS FOR. Every other case here asserts the System's own bookkeeping,
		-- and all of them passed while drawing a weapon put NOTHING in anybody's hand: applyToCharacter
		-- was calling SwingSequencer.SetWeapon, which mutates the record and fires no signal, so
		-- WeaponVisualSystem was never told and no Tool was ever built. The HUD said DRAWN, the sequencer
		-- agreed the player was armed, and there was no sword. Two components agreeing with each other is
		-- not evidence the third consumer was updated -- so these cases follow the value all the way to a
		-- real Tool on a real character rather than stopping at IsDrawn.
		it("equips a real Tool onto the character when drawn", function()
			WeaponVisualSystem.Attach()
			local player = fakePlayer(true)
			WeaponInventorySystem.Pickup(player, FIRST_WEAPON)

			expect(player.Character:FindFirstChild(TOOL_NAME)).to.equal(nil)
			WeaponInventorySystem.ToggleDraw(player)

			local tool = player.Character:FindFirstChild(TOOL_NAME)
			expect(tool).to.be.ok()
			assert(tool and tool:IsA("Tool"), "drawing must put a real Tool on the character")
			expect(tool:GetAttribute("WeaponId")).to.equal(FIRST_WEAPON)
		end)

		it("removes the Tool again when sheathed", function()
			WeaponVisualSystem.Attach()
			local player = fakePlayer(true)
			WeaponInventorySystem.Pickup(player, FIRST_WEAPON)

			WeaponInventorySystem.ToggleDraw(player)
			expect(player.Character:FindFirstChild(TOOL_NAME)).to.be.ok()

			WeaponInventorySystem.ToggleDraw(player)
			expect(player.Character:FindFirstChild(TOOL_NAME)).to.equal(nil)
		end)

		it("arms the sequencer on draw and empties it on sheathe, so swings follow the sword", function()
			local player = fakePlayer(true)
			WeaponInventorySystem.Pickup(player, FIRST_WEAPON)

			-- Sheathed: nothing in hand, so nothing resolves -- this is what makes "you cannot swing a
			-- weapon you put away" need no gate of its own.
			expect(SwingSequencer.GetWeapon(player.Character)).to.equal(nil)

			WeaponInventorySystem.ToggleDraw(player)
			expect(SwingSequencer.GetWeapon(player.Character)).to.equal(FIRST_WEAPON)

			WeaponInventorySystem.ToggleDraw(player)
			expect(SwingSequencer.GetWeapon(player.Character)).to.equal(nil)
		end)

		it("swaps the held Tool when selection changes while drawn", function()
			WeaponVisualSystem.Attach()
			local player = fakePlayer(true)
			WeaponInventorySystem.Pickup(player, FIRST_WEAPON)
			WeaponInventorySystem.Pickup(player, SECOND_WEAPON)
			WeaponInventorySystem.ToggleDraw(player)

			WeaponInventorySystem.SelectNext(player)

			local tool = player.Character:FindFirstChild(TOOL_NAME)
			assert(tool, "the character must still be holding something after a select")
			expect(tool:GetAttribute("WeaponId")).to.equal(SECOND_WEAPON)
		end)
	end)

	describe("WeaponInventorySystem.SelectNext", function()
		it("returns nil for an empty inventory rather than erroring", function()
			expect(WeaponInventorySystem.SelectNext(fakePlayer())).to.equal(nil)
		end)

		it("cycles through owned weapons and wraps at the end", function()
			local player = fakePlayer()
			WeaponInventorySystem.Pickup(player, FIRST_WEAPON)
			WeaponInventorySystem.Pickup(player, SECOND_WEAPON)

			-- Pickup selected FIRST_WEAPON, so one cycle lands on the second and another wraps back.
			expect(WeaponInventorySystem.SelectNext(player)).to.equal(SECOND_WEAPON)
			expect(WeaponInventorySystem.SelectNext(player)).to.equal(FIRST_WEAPON)
		end)

		it("stays on the only weapon when just one is owned", function()
			local player = fakePlayer()
			WeaponInventorySystem.Pickup(player, FIRST_WEAPON)
			expect(WeaponInventorySystem.SelectNext(player)).to.equal(FIRST_WEAPON)
		end)
	end)
end
