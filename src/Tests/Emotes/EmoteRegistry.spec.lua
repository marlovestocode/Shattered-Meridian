--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local EmoteRegistry = require(ReplicatedStorage.Shared.Emotes.EmoteRegistry)

local function makeDefinition(overrides: { [string]: any }?): { [string]: any }
	local definition = {
		Id = "test-emote",
		DisplayName = "Test Emote",
		Description = "A test emote.",
		AnimationId = "",
		Icon = "",
		Category = "Reaction",
		Loop = false,
		Duration = 2,
		MovementLocked = false,
		CombatAllowed = true,
		CancelOnDamage = true,
		Unlock = { Type = "Default" },
	}
	if overrides then
		for key, value in overrides do
			definition[key] = value
		end
	end
	return definition
end

return function()
	describe("EmoteRegistry.Exists / Get", function()
		it("Exists is true for every real starter emote", function()
			expect(EmoteRegistry.Exists("Wave")).to.equal(true)
			expect(EmoteRegistry.Exists("Bow")).to.equal(true)
			expect(EmoteRegistry.Exists("Laugh")).to.equal(true)
			expect(EmoteRegistry.Exists("Taunt")).to.equal(true)
			expect(EmoteRegistry.Exists("Sit")).to.equal(true)
			expect(EmoteRegistry.Exists("Cheer")).to.equal(true)
			expect(EmoteRegistry.Exists("Point")).to.equal(true)
			expect(EmoteRegistry.Exists("Dance")).to.equal(true)
		end)

		it("Exists is false for an unknown id", function()
			expect(EmoteRegistry.Exists("DoesNotExist")).to.equal(false)
		end)

		it("Get returns the full definition for a known id", function()
			local wave = EmoteRegistry.Get("Wave")
			expect(wave).to.be.ok()
			expect((wave :: any).DisplayName).to.equal("Wave")
			expect((wave :: any).Unlock.Type).to.equal("Default")
		end)

		it("Get returns nil for an unknown id", function()
			expect(EmoteRegistry.Get("DoesNotExist")).to.equal(nil)
		end)
	end)

	describe("EmoteRegistry.GetAll", function()
		it("includes every starter emote and both locked examples", function()
			local all = EmoteRegistry.GetAll()
			expect(all.Wave).to.be.ok()
			expect(all.VictoryPose).to.be.ok()
			expect(all.CelestialBow).to.be.ok()
		end)
	end)

	describe("EmoteRegistry.GetByCategory", function()
		it("returns only definitions matching the requested category", function()
			local sittingEmotes = EmoteRegistry.GetByCategory("Sitting")
			expect(#sittingEmotes).to.equal(1)
			expect(sittingEmotes[1].Id).to.equal("Sit")
		end)

		it("returns an empty list for a category with no matches", function()
			-- Every real Category is populated today, so this exercises the branch with a value that
			-- is a real Types.EmoteCategory member but not one currently authored against -- Social
			-- has zero starter entries (Bow is the only Social-flavored emote and is NOT tagged
			-- Social).
			local result = EmoteRegistry.GetByCategory("Social")
			expect(#result).to.equal(1)
			expect(result[1].Id).to.equal("Bow")
		end)
	end)

	describe("EmoteRegistry.GetDefaultUnlockedIds", function()
		it("includes every Default-unlock starter emote and excludes both locked examples", function()
			local defaults = EmoteRegistry.GetDefaultUnlockedIds()
			expect(defaults.Wave).to.equal(true)
			expect(defaults.Dance).to.equal(true)
			expect(defaults.VictoryPose).to.equal(nil)
			expect(defaults.CelestialBow).to.equal(nil)
		end)
	end)

	describe("EmoteRegistry.Validate (valid)", function()
		it("accepts a well-formed Default definition", function()
			local ok, reason = EmoteRegistry.Validate(makeDefinition())
			expect(ok).to.equal(true)
			expect(reason).to.equal(nil)
		end)

		it("accepts a well-formed Roll definition with a Pool", function()
			local ok = EmoteRegistry.Validate(makeDefinition({ Unlock = { Type = "Roll", Pool = "RareEmotes" } }))
			expect(ok).to.equal(true)
		end)

		it("accepts Duration = nil for a looping emote", function()
			-- Built by removing the key, NOT via makeDefinition({ Duration = nil }) -- `Duration = nil`
			-- inside a table constructor simply means the key was never written, so the override loop
			-- has nothing to copy and the helper's own default Duration = 2 survives. This test used to
			-- do exactly that and was therefore asserting the opposite of its own name.
			local candidate = makeDefinition({ Loop = true })
			candidate.Duration = nil
			local ok, reason = EmoteRegistry.Validate(candidate)
			expect(ok).to.equal(true)
			expect(reason).to.equal(nil)
		end)

		-- Regression guard for the whole authored roster. The bug this file's Duration rules exist to
		-- catch (a one-shot whose Duration is missing/zero, a looping entry carrying one) is invisible
		-- by inspection and only shows up in play as an emote that ends at the wrong moment -- so the
		-- real content gets run through the same gate an untrusted candidate would be.
		it("accepts every hand-authored definition in the live roster", function()
			for id, definition in EmoteRegistry.GetAll() do
				local ok, reason = EmoteRegistry.Validate(definition)
				if not ok then
					error(`{id} failed EmoteRegistry.Validate: {reason}`)
				end
			end
		end)

		-- Guards the "" vs "rbxassetid://" distinction EmoteDefinitions.lua's own header calls out: a
		-- prefix-only placeholder reads as unauthored to a human but is a non-empty string to every
		-- `AnimationId ~= ""` guard in the codebase (EmoteAnimator's skip-the-template check,
		-- EmoteSystem's hasClip), so it silently takes the clip-bearing path with no clip behind it.
		it("never authors a prefix-only AnimationId placeholder", function()
			for id, definition in EmoteRegistry.GetAll() do
				if definition.AnimationId == "rbxassetid://" then
					error(`{id} has a prefix-only AnimationId placeholder -- use "" for unauthored`)
				end
			end
		end)
	end)

	describe("EmoteRegistry.Validate (invalid)", function()
		it("rejects a non-table candidate", function()
			local ok, reason = EmoteRegistry.Validate("not-a-table")
			expect(ok).to.equal(false)
			expect(reason).to.equal("InvalidShape")
		end)

		it("rejects an empty Id", function()
			local ok, reason = EmoteRegistry.Validate(makeDefinition({ Id = "" }))
			expect(ok).to.equal(false)
			expect(reason).to.equal("InvalidId")
		end)

		it("rejects an unknown Category", function()
			local ok, reason = EmoteRegistry.Validate(makeDefinition({ Category = "NotARealCategory" }))
			expect(ok).to.equal(false)
			expect(reason).to.equal("InvalidCategory")
		end)

		it("rejects a non-boolean Loop", function()
			local ok, reason = EmoteRegistry.Validate(makeDefinition({ Loop = "yes" }))
			expect(ok).to.equal(false)
			expect(reason).to.equal("InvalidLoop")
		end)

		-- The literal "ends way early" trap: EmoteSystem's `definition.Duration or 0` fallback turns a
		-- missing Duration on a one-shot into an expiry that has already passed, stopping the emote on
		-- the very next heartbeat tick.
		it("rejects a one-shot emote with no Duration", function()
			local candidate = makeDefinition()
			candidate.Duration = nil
			local ok, reason = EmoteRegistry.Validate(candidate)
			expect(ok).to.equal(false)
			expect(reason).to.equal("MissingDuration")
		end)

		it("rejects a one-shot emote with a zero or negative Duration", function()
			local zeroOk, zeroReason = EmoteRegistry.Validate(makeDefinition({ Duration = 0 }))
			expect(zeroOk).to.equal(false)
			expect(zeroReason).to.equal("MissingDuration")

			local negativeOk, negativeReason = EmoteRegistry.Validate(makeDefinition({ Duration = -1 }))
			expect(negativeOk).to.equal(false)
			expect(negativeReason).to.equal("MissingDuration")
		end)

		it("rejects a looping emote that carries a Duration", function()
			local ok, reason = EmoteRegistry.Validate(makeDefinition({ Loop = true, Duration = 3 }))
			expect(ok).to.equal(false)
			expect(reason).to.equal("UnexpectedDuration")
		end)

		it("rejects an unknown Unlock.Type", function()
			local ok, reason = EmoteRegistry.Validate(makeDefinition({ Unlock = { Type = "Bribery" } }))
			expect(ok).to.equal(false)
			expect(reason).to.equal("InvalidUnlockType")
		end)

		it("rejects a Roll unlock with no Pool", function()
			local ok, reason = EmoteRegistry.Validate(makeDefinition({ Unlock = { Type = "Roll" } }))
			expect(ok).to.equal(false)
			expect(reason).to.equal("MissingUnlockPool")
		end)

		it("rejects a missing Unlock table entirely", function()
			local candidate = makeDefinition()
			candidate.Unlock = nil
			local ok, reason = EmoteRegistry.Validate(candidate)
			expect(ok).to.equal(false)
			expect(reason).to.equal("InvalidUnlock")
		end)
	end)
end
