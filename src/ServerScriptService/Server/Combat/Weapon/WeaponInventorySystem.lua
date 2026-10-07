--!strict
--[[
	WeaponInventorySystem.lua

	Owns: which weapons a player has PICKED UP, which one of those is SELECTED, and whether it is
	currently DRAWN or SHEATHED. Also owns the hold-E prompt on every weapon in the world that puts one
	into an inventory in the first place.

	THE THREE STATES, kept deliberately separate because they change independently:

	  * OWNED    -- the set of weapon ids this player has picked up. Grows on a prompt; never shrinks.
	  * SELECTED -- which owned weapon the draw key will pull out. Survives sheathing, so drawing again
	                gives you back the sword you just put away rather than resetting to the first one.
	  * DRAWN    -- whether SELECTED is actually in hand right now.

	FISTS ARE ALWAYS IN HAND WHEN NOTHING ELSE IS (2026-10-06, owner: "you don't have to equip your fists, they're
	always auto equipped"). What combat reads is IN HAND (inHandOf): the selected weapon while it is drawn, and
	Fists otherwise -- on spawn, after a sheathe, before anything is picked up. So there is no unarmed state left
	to fight out of: sheathing a sword puts your fists up, and the draw key only ever matters for a real weapon.
	Selecting Fists counts as drawn (there is nothing to sheathe them into), and the draw key does nothing then.

	DRAWN IS EXPRESSED AS "DOES SwingSequencer HAVE A WEAPON", NOT AS A FOURTH CanAttack GATE. Sheathing
	calls SwingSequencer.ClearWeapon, and SwingSequencer.Resolve ALREADY returns nil for a combatant
	holding nothing -- which every caller already treats as "do not swing". So a sheathed player cannot
	attack for the same structural reason a player with an empty roster cannot, with no new gate, no new
	seam into AttackRequestSystem, and no second source of truth about what is in someone's hand. That
	is why this System is a sibling of the attack layer that pushes INTO SwingSequencer rather than
	another gate it reads out of -- see GrabSystem's own header for the shape this deliberately is not.

	THE INPUT IS A NATIVE ProximityPrompt, for exactly the reasons Server/Systems/BlimpSystem.lua's own
	header sets out at length: a hand-rolled "am I near it" needs a distance poll, an occlusion test,
	an on-screen affordance, a gamepad path and a touch path, all five of which ProximityPrompt already
	is. The keybind system still gets its say the same way -- the client sets KeyboardKeyCode from the
	player's own Interact bind.

	PROMPTS GO ON THE WORLD MODELS, WHICH ARE ALSO THE TEMPLATES. Workspace.Weapons is read by three
	things now: WeaponRoster (for the numbers), WeaponModelRegistry (for the equippable Tool) and this
	System (for the pickup). A weapon left standing in the world is therefore a permanent source rather
	than a one-time drop -- picking it up clones it and leaves the original, so a rack keeps working for
	the next player. That is a deliberate choice, not an oversight; a consumed pickup would need its own
	respawn story and there is nothing yet asking for one.

	SESSION-SCOPED, NOT PERSISTED. An inventory lives as long as the player's session and is empty again
	on rejoin. Persisting it means a schema bump on the PlayerDataSystem profile and a decision about
	what happens to a saved weapon whose model has since been renamed or deleted -- both real, neither
	asked for yet, and neither cheap to undo once saved data exists in the wild.

	Does not own: what a weapon looks like (WeaponModelRegistry/WeaponVisualSystem, reached only
	indirectly -- this System changes the SwingSequencer record and the existing OnWeaponChanged signal
	does the rest), what it hits for (WeaponRoster), or the string a swing resolves to (SwingSequencer).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CharacterUtil = require(ReplicatedStorage.Shared.CharacterUtil)
local Logger = require(ReplicatedStorage.Shared.Logger)
local NetworkBridge = require(ReplicatedStorage.Shared.NetworkBridge)
local PlayerLifecycle = require(ReplicatedStorage.Shared.PlayerLifecycle)
local RateLimiter = require(ReplicatedStorage.Shared.RateLimiter)
local Types = require(ReplicatedStorage.Shared.Types)
local WeaponConstants = require(ReplicatedStorage.Shared.Combat.WeaponConstants)
local WeaponRoster = require(ReplicatedStorage.Shared.Combat.WeaponRoster)

local AttackRequestSystem = require(script.Parent.Parent.Attack.AttackRequestSystem)
local WeaponAssets = require(ReplicatedStorage.Shared.Combat.WeaponAssets)

type WeaponId = Types.WeaponId

local logger = Logger.scope("WeaponInventorySystem")

local WeaponInventorySystem = {}

local started = false

-- Keyed by Player rather than by character Model, unlike every combat record next door -- an inventory
-- outlives a life. Dying and respawning must not lose the swords you picked up; only leaving does.
-- Cleared on PlayerRemoving, which is the only edge that ends a session.
type Record = {
	Owned: { [WeaponId]: true },
	-- Insertion order, so cycling is stable and predictable rather than following a hash order that
	-- changes between sessions.
	Order: { WeaponId },
	Selected: WeaponId?,
	Drawn: boolean,
}

local records: { [Player]: Record } = {}

local toggleLimiter = RateLimiter.New(WeaponConstants.Network.MaxTogglesPerSecondPerPlayer)
-- Bounds the ProximityPrompt.Triggered signal itself -- see WeaponConstants.Network.
-- MaxPickupsPerSecondPerPlayer's own header for why a prompt trigger needs this the same way a
-- remote does.
local pickupLimiter = RateLimiter.New(WeaponConstants.Network.MaxPickupsPerSecondPerPlayer)
local inventoryChangedRemote: RemoteEvent? = nil

-- Fists is owned and selected from the moment a record exists -- not picked up, never dropped, and
-- always the fallback a player who has picked up nothing at all can still draw and fight with. See
-- WeaponRoster.FISTS_ID's own header for why the roster carries it with no Workspace.Weapons model.
local function recordFor(player: Player): Record
	local existing = records[player]
	if existing then
		return existing
	end
	local created: Record = {
		Owned = { [WeaponRoster.FISTS_ID] = true },
		Order = { WeaponRoster.FISTS_ID },
		Selected = WeaponRoster.FISTS_ID,
		Drawn = false,
	}
	records[player] = created
	return created
end

-- What is actually in this player's hand: the selected weapon while drawn, Fists otherwise (this file's
-- header, FISTS ARE ALWAYS IN HAND). Never nil -- there is no empty hand any more.
local function inHandOf(record: Record): WeaponId
	if record.Drawn and record.Selected ~= nil then
		return record.Selected
	end
	return WeaponRoster.FISTS_ID
end

-- Server -> owner only. The whole inventory every time rather than a delta: it is at most a handful of
-- short strings, and a client that missed one delta (joined late, hit a dropped packet) would otherwise
-- be wrong until the next pickup with nothing to correct it.
local function pushInventory(player: Player): ()
	local remote = inventoryChangedRemote
	if not remote then
		return
	end
	local record = recordFor(player)
	local inHand = inHandOf(record)
	remote:FireClient(
		player,
		{
			Owned = table.clone(record.Order),
			Selected = record.Selected,
			-- "Is the selected weapon the one in hand" -- true for Fists whenever they are selected.
			Drawn = record.Selected ~= nil and inHand == record.Selected,
			InHand = inHand,
		} :: WeaponConstants.InventoryPayload
	)
end

-- Pushes the record's current drawn/selected state into the attack layer, which is what actually puts
-- a weapon in (or takes it out of) the character's hand.
--
-- THROUGH AttackRequestSystem.SetWeapon, NEVER SwingSequencer DIRECTLY, and that distinction is the
-- whole reason that function exists -- see its own header. SwingSequencer.SetWeapon only mutates the
-- record; it fires no signal, so WeaponVisualSystem never hears about it and no Tool appears. Calling
-- it directly here is exactly the bug that shipped: drawing reported success, the HUD said DRAWN, and
-- there was no sword.
local function applyToCharacter(player: Player): ()
	local character = player.Character
	if not character then
		return
	end
	AttackRequestSystem.SetWeapon(character, inHandOf(recordFor(player)), os.clock())
end

-- Adds `weaponId` to this player's inventory. Returns whether anything changed -- picking up a weapon
-- you already own is a no-op, not an error: the world model is a permanent source (see this file's
-- header), so walking past a rack you already looted is an ordinary thing to do.
function WeaponInventorySystem.Pickup(player: Player, weaponId: WeaponId): boolean
	if not WeaponRoster.Has(weaponId) then
		logger:warn("Refusing a pickup for a weapon the roster does not know", { weaponId = weaponId })
		return false
	end

	local record = recordFor(player)
	if record.Owned[weaponId] then
		return false
	end

	record.Owned[weaponId] = true
	table.insert(record.Order, weaponId)
	-- First REAL weapon picked up becomes the selected one, so the very next draw press works without
	-- the player having to also discover a separate "choose weapon" control. Fists (always seeded,
	-- never nil -- see recordFor) counts the same as "nothing chosen yet" here on purpose: a fresh
	-- pickup should not lose to a fallback the player never asked for.
	if record.Selected == nil or record.Selected == WeaponRoster.FISTS_ID then
		record.Selected = weaponId
	end

	logger:info("Weapon picked up", { player = player.Name, weaponId = weaponId })
	pushInventory(player)
	return true
end

-- Draws the selected weapon if sheathed, sheathes it if drawn. The whole of what the draw key does.
-- Returns the new drawn state, or false for a player with an empty inventory (nothing to draw, which
-- is not an error -- it is what every player starts as).
function WeaponInventorySystem.ToggleDraw(player: Player): boolean
	local record = recordFor(player)
	if record.Selected == nil then
		return false
	end
	-- Fists are never sheathed (this file's header): with them selected the key has nothing to do.
	if record.Selected == WeaponRoster.FISTS_ID then
		return true
	end

	record.Drawn = not record.Drawn
	applyToCharacter(player)
	pushInventory(player)
	return record.Drawn
end

-- Moves selection to the next owned weapon, in pickup order. Applies immediately if drawn, so
-- switching mid-fight swaps what is in hand rather than waiting for a re-draw.
function WeaponInventorySystem.SelectNext(player: Player): WeaponId?
	local record = recordFor(player)
	if #record.Order == 0 then
		return nil
	end

	local index = if record.Selected then table.find(record.Order, record.Selected) else nil
	record.Selected = record.Order[((index or 0) % #record.Order) + 1]
	applyToCharacter(player)
	pushInventory(player)
	return record.Selected
end

-- Whether this player's SELECTED weapon is the one in hand -- the payload's Drawn, so always true for
-- Fists. Read by nothing in combat (see this file's header on why drawn-ness is expressed through
-- SwingSequencer rather than as a gate) -- this exists for a HUD or a spec.
function WeaponInventorySystem.IsDrawn(player: Player): boolean
	local record = recordFor(player)
	return record.Selected ~= nil and inHandOf(record) == record.Selected
end

-- What is in this player's hand right now -- Fists whenever nothing else is drawn. For a HUD or a spec.
function WeaponInventorySystem.InHand(player: Player): WeaponId
	return inHandOf(recordFor(player))
end

function WeaponInventorySystem.GetOwned(player: Player): { WeaponId }
	return table.clone(recordFor(player).Order)
end

local function handleToggle(player: Player): ()
	if toggleLimiter:IsLimited(player) then
		return
	end
	WeaponInventorySystem.ToggleDraw(player)
end

local function handleSelectNext(player: Player): ()
	if toggleLimiter:IsLimited(player) then
		return
	end
	WeaponInventorySystem.SelectNext(player)
end

-- Prompts ------------------------------------------------------------------------------------------

-- A prompt needs a BasePart or Attachment to hang off. The Handle is the natural choice -- it is the
-- part a player reaches for -- with the model's own PrimaryPart and then any BasePart as fallbacks, so
-- a weapon still becomes pickup-able even if its parts are named differently than expected.
local function promptAnchor(model: Instance): BasePart?
	local handle = model:FindFirstChild("Handle", true)
	if handle and handle:IsA("BasePart") then
		return handle :: BasePart
	end
	if model:IsA("Model") and model.PrimaryPart then
		return model.PrimaryPart
	end
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			return descendant :: BasePart
		end
	end
	return nil
end

local function addPrompt(model: Instance): ()
	local anchor = promptAnchor(model)
	if not anchor then
		logger:warn("Weapon has no BasePart to hang a pickup prompt on; skipping", { weapon = model.Name })
		return
	end
	if anchor:FindFirstChild(WeaponConstants.Prompt.Name) then
		return
	end

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = WeaponConstants.Prompt.Name
	prompt.ActionText = WeaponConstants.Prompt.ActionText
	prompt.ObjectText = model.Name
	prompt.MaxActivationDistance = WeaponConstants.Prompt.MaxActivationDistance
	prompt.HoldDuration = WeaponConstants.Prompt.HoldDuration
	prompt.RequiresLineOfSight = WeaponConstants.Prompt.RequiresLineOfSight
	prompt.Parent = anchor

	prompt.Triggered:Connect(function(player: Player)
		if pickupLimiter:IsLimited(player) then
			return
		end

		-- Independent server-side range re-check. ProximityPrompt.MaxActivationDistance/
		-- RequiresLineOfSight are client-enforced only -- a Triggered signal from an exploited client
		-- can fire from anywhere, at any distance, regardless of what the prompt itself claims. Re-
		-- deriving distance from the anchor Roblox actually hung this prompt on means faking the
		-- trigger buys nothing without also faking proximity.
		local _, _, root = CharacterUtil.LiveRig(player)
		if not root or (root.Position - anchor.Position).Magnitude > WeaponConstants.Prompt.MaxActivationDistance then
			logger:warn(
				"Rejecting a pickup trigger from outside prompt range",
				{ player = player.Name, weapon = model.Name }
			)
			return
		end

		-- The model's Name is the weapon id -- the same join key WeaponRoster and WeaponModelRegistry
		-- both use. Read off the model rather than captured in this closure so a renamed weapon is
		-- picked up under its current name rather than the one it had at boot.
		WeaponInventorySystem.Pickup(player, model.Name)
	end)
end

function WeaponInventorySystem.Init(): ()
	if started then
		return
	end
	started = true

	inventoryChangedRemote = NetworkBridge.CreateRemoteEvent(WeaponConstants.Network.RemoteNames.InventoryChanged)

	local toggleRemote = NetworkBridge.CreateRemoteEvent(WeaponConstants.Network.RemoteNames.ToggleDraw)
	toggleRemote.OnServerEvent:Connect(handleToggle)

	local selectRemote = NetworkBridge.CreateRemoteEvent(WeaponConstants.Network.RemoteNames.SelectNext)
	selectRemote.OnServerEvent:Connect(handleSelectNext)

	-- Through Shared/Combat/WeaponAssets.Container rather than a seventh hand-written
	-- Workspace:FindFirstChild("Weapons") -- this was the one copy that wrote the folder name as a
	-- bare literal, so a rename would have missed it while the six named constants were updated.
	local container = WeaponAssets.Container(logger)
	if container then
		for _, child in container:GetChildren() do
			addPrompt(child)
		end
		container.ChildAdded:Connect(addPrompt)
	else
		logger:warn("Workspace.Weapons folder not found; no weapons will be pickup-able")
	end

	PlayerLifecycle.BindAllPlayers({
		Scope = "WeaponInventorySystem",
		-- Catch-up: a client that joins (or respawns) needs its inventory state, since InventoryChanged
		-- is an edge and it has no other way to learn what it is carrying.
		OnPlayer = function(player: Player)
			pushInventory(player)
		end,
		-- A NEW LIFE STARTS SHEATHED -- WHICH NOW MEANS FISTS UP. Re-applying the old life's drawn state
		-- would mean a corpse's weapon following someone into their next body, so the drawn flag resets;
		-- applying it puts the new body's fists in hand at once, so a fresh spawn can fight (and predict
		-- its swings) without pressing anything. The inventory itself survives.
		OnCharacter = function(player: Player)
			local record = recordFor(player)
			record.Drawn = false
			applyToCharacter(player)
			pushInventory(player)
		end,
		OnPlayerRemoving = function(player: Player)
			records[player] = nil
			toggleLimiter:Clear(player)
			pickupLimiter:Clear(player)
		end,
	})

	logger:info("WeaponInventorySystem.Init() complete")
end

-- Spec-only, so one case cannot serve another its inventories.
function WeaponInventorySystem.Reset(): ()
	table.clear(records)
	started = false
end

return WeaponInventorySystem :: Types.SystemModule & typeof(WeaponInventorySystem)
