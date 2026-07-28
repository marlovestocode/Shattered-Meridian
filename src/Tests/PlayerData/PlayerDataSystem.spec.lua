--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local PlayerDataSystem = require(ServerScriptService.Server.Systems.PlayerDataSystem)
local Types = require(ReplicatedStorage.Shared.Types)

type PlayerProfile = Types.PlayerProfile

-- Pure-logic surface (CreateDefaultProfile/CopyProfile/EncodeProfile/DecodeProfile/MigrateRecord/
-- ApplyMutation) never touches the DataStore or a live Player -- Init() is never called in this
-- spec file, so `dataStore` stays nil and `loadedProfiles` stays empty throughout, same
-- "requiring the module never calls Init()" contract BugReportSystem.spec/ModerationSystem.spec
-- already rely on. Player-KEYED wrappers (IsLoaded/GetProfile/Transform/WaitForProfile) are
-- exercised below using a plain table standing in for Player (same trick RateLimiter.spec.lua
-- already uses) -- valid because every one of those functions only ever uses a Player as an
-- opaque table key or reads `.Name` for a log line (which safely returns nil on a plain table),
-- never anything Player-specific like :Kick() or .UserId. Anything that genuinely needs a live
-- Player/real DataStore (loadProfile/saveProfile/the PlayerAdded-PlayerRemoving wiring/Transform's
-- actual dirty-then-saved round trip) is Studio/live-server verification only, the same
-- already-accepted gap AdminActionSystem.spec.lua/ModerationSystem.spec.lua document for their own
-- Player-keyed state.

return function()
	describe("PlayerDataSystem.CreateDefaultProfile", function()
		it("returns every field at its inert starting default", function()
			local profile = PlayerDataSystem.CreateDefaultProfile(123456)

			expect(profile.userId).to.equal(123456)
			expect(profile.faction).to.equal(nil)
			expect(profile.raceId).to.equal(nil)
			expect(profile.displayName).to.equal(nil)
			expect(profile.attributes).to.equal(nil)
			expect(profile.tier).to.equal(1)
			expect(#profile.bloodlineIds).to.equal(0)
			expect(next(profile.artMastery)).to.equal(nil)
			expect(profile.corruption).to.equal(0)
			expect(profile.qiDeviationRisk).to.equal(0)
			expect(profile.factionStanding).to.equal(0)
			expect(profile.hasAscended).to.equal(false)
		end)
	end)

	describe("PlayerDataSystem.CopyProfile", function()
		local function makeProfile(): PlayerProfile
			local profile = PlayerDataSystem.CreateDefaultProfile(999)
			profile.bloodlineIds = { "bloodline-a" }
			profile.artMastery = { ["art-a"] = 3 }
			return profile
		end

		it("copies every scalar field", function()
			local original = makeProfile()
			original.faction = "Celestial"
			original.tier = 5
			original.corruption = 12

			local copy = PlayerDataSystem.CopyProfile(original)

			expect(copy.userId).to.equal(original.userId)
			expect(copy.faction).to.equal(original.faction)
			expect(copy.tier).to.equal(original.tier)
			expect(copy.corruption).to.equal(original.corruption)
		end)

		it("mutating the copy's bloodlineIds never affects the original", function()
			local original = makeProfile()
			local copy = PlayerDataSystem.CopyProfile(original)

			table.insert(copy.bloodlineIds, "bloodline-b")

			expect(#copy.bloodlineIds).to.equal(2)
			expect(#original.bloodlineIds).to.equal(1)
		end)

		it("mutating the copy's artMastery never affects the original", function()
			local original = makeProfile()
			local copy = PlayerDataSystem.CopyProfile(original)

			copy.artMastery["art-a"] = 99
			copy.artMastery["art-b"] = 1

			expect(original.artMastery["art-a"]).to.equal(3)
			expect(original.artMastery["art-b"]).to.equal(nil)
		end)
	end)

	describe("PlayerDataSystem.EncodeProfile / DecodeProfile round trip", function()
		it("decodes exactly what was encoded", function()
			local original = PlayerDataSystem.CreateDefaultProfile(42)
			original.faction = "Demonic"
			original.raceId = "Rivenkin"
			original.displayName = "Wren Ashfall"
			original.attributes = {
				Vitality = 13,
				Fortitude = 13,
				MeridianFlow = 13,
				Might = 13,
				Pressure = 13,
				Fleetness = 13,
			}
			original.tier = 4
			original.bloodlineIds = { "bl-1", "bl-2" }
			original.artMastery = { ["art-1"] = 7 }
			original.corruption = 15
			original.qiDeviationRisk = 0.5
			original.factionStanding = -10
			original.hasAscended = true

			local encoded = PlayerDataSystem.EncodeProfile(original)
			local decoded = PlayerDataSystem.DecodeProfile(42, encoded)

			expect(decoded).never.to.equal(nil)
			local decodedProfile = decoded :: PlayerProfile
			expect(decodedProfile.faction).to.equal("Demonic")
			expect(decodedProfile.raceId).to.equal("Rivenkin")
			expect(decodedProfile.displayName).to.equal("Wren Ashfall")
			expect(decodedProfile.attributes).never.to.equal(nil)
			expect((decodedProfile.attributes :: any).Might).to.equal(13)
			expect(decodedProfile.tier).to.equal(4)
			expect(#decodedProfile.bloodlineIds).to.equal(2)
			expect(decodedProfile.artMastery["art-1"]).to.equal(7)
			expect(decodedProfile.corruption).to.equal(15)
			expect(decodedProfile.qiDeviationRisk).to.equal(0.5)
			expect(decodedProfile.factionStanding).to.equal(-10)
			expect(decodedProfile.hasAscended).to.equal(true)
		end)
	end)

	describe("PlayerDataSystem.DecodeProfile (displayName/attributes -- new onboarding fields)", function()
		it("decodes a missing displayName/attributes as nil (legacy pre-onboarding record)", function()
			local decoded = PlayerDataSystem.DecodeProfile(1, {})
			local profile = decoded :: PlayerProfile
			expect(profile.displayName).to.equal(nil)
			expect(profile.attributes).to.equal(nil)
		end)

		it("rejects a non-string displayName back to nil rather than throwing", function()
			local decoded = PlayerDataSystem.DecodeProfile(1, { displayName = 42 })
			local profile = decoded :: PlayerProfile
			expect(profile.displayName).to.equal(nil)
		end)

		it("decodes a fully-populated attributes block", function()
			local decoded = PlayerDataSystem.DecodeProfile(1, {
				attributes = {
					Vitality = 10,
					Fortitude = 10,
					MeridianFlow = 10,
					Might = 10,
					Pressure = 10,
					Fleetness = 10,
				},
			})
			local profile = decoded :: PlayerProfile
			expect(profile.attributes).never.to.equal(nil)
			expect((profile.attributes :: any).Vitality).to.equal(10)
			expect((profile.attributes :: any).Fleetness).to.equal(10)
		end)

		it("discards the WHOLE attributes block to nil when a single field is missing", function()
			local decoded = PlayerDataSystem.DecodeProfile(1, {
				attributes = {
					Vitality = 10,
					Fortitude = 10,
					MeridianFlow = 10,
					Might = 10,
					Pressure = 10,
					-- Fleetness deliberately omitted.
				},
			})
			local profile = decoded :: PlayerProfile
			expect(profile.attributes).to.equal(nil)
		end)

		it("discards the WHOLE attributes block to nil when a single field is wrong-typed", function()
			local decoded = PlayerDataSystem.DecodeProfile(1, {
				attributes = {
					Vitality = 10,
					Fortitude = 10,
					MeridianFlow = 10,
					Might = "not-a-number",
					Pressure = 10,
					Fleetness = 10,
				},
			})
			local profile = decoded :: PlayerProfile
			expect(profile.attributes).to.equal(nil)
		end)

		it("treats a non-table attributes value as absent rather than throwing", function()
			local decoded = PlayerDataSystem.DecodeProfile(1, { attributes = "not-a-table" })
			local profile = decoded :: PlayerProfile
			expect(profile.attributes).to.equal(nil)
		end)
	end)

	describe("PlayerDataSystem.DecodeProfile (defensive decoding)", function()
		it("returns nil for a non-table value", function()
			expect(PlayerDataSystem.DecodeProfile(1, "not a table")).to.equal(nil)
			expect(PlayerDataSystem.DecodeProfile(1, nil)).to.equal(nil)
		end)

		it("falls back to fallbackUserId when the stored userId is missing/wrong-typed", function()
			local decoded = PlayerDataSystem.DecodeProfile(555, { userId = "not-a-number" })
			expect(decoded).never.to.equal(nil)
			expect((decoded :: PlayerProfile).userId).to.equal(555)
		end)

		it("defaults every missing field instead of throwing", function()
			local decoded = PlayerDataSystem.DecodeProfile(1, {})
			expect(decoded).never.to.equal(nil)
			local profile = decoded :: PlayerProfile
			expect(profile.tier).to.equal(1)
			expect(profile.corruption).to.equal(0)
			expect(profile.hasAscended).to.equal(false)
			expect(#profile.bloodlineIds).to.equal(0)
		end)

		it("filters out non-string entries from a corrupt bloodlineIds array", function()
			local decoded = PlayerDataSystem.DecodeProfile(1, { bloodlineIds = { "valid", 42, true } })
			local profile = decoded :: PlayerProfile
			expect(#profile.bloodlineIds).to.equal(1)
			expect(profile.bloodlineIds[1]).to.equal("valid")
		end)

		it("filters out malformed entries from a corrupt artMastery table", function()
			local decoded =
				PlayerDataSystem.DecodeProfile(1, { artMastery = { ["good"] = 5, ["bad"] = "not-a-number" } })
			local profile = decoded :: PlayerProfile
			expect(profile.artMastery["good"]).to.equal(5)
			expect(profile.artMastery["bad"]).to.equal(nil)
		end)
	end)

	describe("PlayerDataSystem.MigrateRecord", function()
		it("returns an already-current-version record unchanged", function()
			local raw = { SchemaVersion = 1, Profile = { tier = 3 } }
			local migrated = PlayerDataSystem.MigrateRecord(raw)
			expect(migrated.SchemaVersion).to.equal(1)
			expect((migrated.Profile :: any).tier).to.equal(3)
		end)

		it("treats a missing SchemaVersion as version 1", function()
			local raw = { Profile = { tier = 2 } }
			local migrated = PlayerDataSystem.MigrateRecord(raw)
			expect(migrated.SchemaVersion).never.to.equal(nil)
		end)
	end)

	describe("PlayerDataSystem.ApplyMutation", function()
		it("applies the mutator and returns true", function()
			local stored: Types.StoredPlayerProfile =
				{ SchemaVersion = 1, Profile = PlayerDataSystem.CreateDefaultProfile(1) }
			local applied = PlayerDataSystem.ApplyMutation(stored, function(profile)
				profile.tier = 3
				profile.corruption = 10
			end)

			expect(applied).to.equal(true)
			expect(stored.Profile.tier).to.equal(3)
			expect(stored.Profile.corruption).to.equal(10)
		end)

		it("returns false and never propagates an error when the mutator throws", function()
			local stored: Types.StoredPlayerProfile =
				{ SchemaVersion = 1, Profile = PlayerDataSystem.CreateDefaultProfile(1) }

			local ok, applied = pcall(function()
				return PlayerDataSystem.ApplyMutation(stored, function(_profile)
					error("mutator bug")
				end)
			end)

			expect(ok).to.equal(true)
			expect(applied).to.equal(false)
		end)
	end)

	describe("PlayerDataSystem.IsLoaded / GetProfile (no profile ever loaded)", function()
		it("IsLoaded is false for a player with no loaded profile", function()
			local fakePlayer = {} :: any
			expect(PlayerDataSystem.IsLoaded(fakePlayer)).to.equal(false)
		end)

		it("GetProfile returns nil for a player with no loaded profile", function()
			local fakePlayer = {} :: any
			expect(PlayerDataSystem.GetProfile(fakePlayer)).to.equal(nil)
		end)
	end)

	describe("PlayerDataSystem.Transform (no profile ever loaded)", function()
		it("returns false and never calls the mutator when the profile isn't loaded", function()
			local fakePlayer = {} :: any
			local mutatorCalled = false

			local applied = PlayerDataSystem.Transform(fakePlayer, function(_profile)
				mutatorCalled = true
			end)

			expect(applied).to.equal(false)
			expect(mutatorCalled).to.equal(false)
		end)
	end)

	describe("PlayerDataSystem.WaitForProfile (never loads, bounded timeout)", function()
		it("times out and returns nil rather than blocking forever", function()
			local fakePlayer = {} :: any
			local result = PlayerDataSystem.WaitForProfile(fakePlayer, 0.05)
			expect(result).to.equal(nil)
		end)
	end)
end
