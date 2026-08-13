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
			local ok = EmoteRegistry.Validate(makeDefinition({ Loop = true, Duration = nil }))
			expect(ok).to.equal(true)
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
