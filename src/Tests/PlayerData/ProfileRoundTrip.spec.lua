--!strict
-- The profile round trip, byte for byte. Tests/Fixtures/ProfileCorpus.lua is a frozen set of stored records (every schema
-- version v1..v11, the v11 record with each field corrupted in turn, and junk), and Tests/Fixtures/ProfileCorpusExpected.lua
-- holds the digest of what PlayerDataSystem made of each one BEFORE the profile fields were moved out of it into their
-- domains' ProfileSlices (coworking plan W5, 2026-10-25). Every case must still migrate to the same record and re-encode to
-- the same bytes; a field moved, renamed, re-defaulted or dropped changes a digest and names the case.
--
-- This pins what is persisted, not how it is organised: moving a slice into its domain must not change a stored byte.
local ServerScriptService = game:GetService("ServerScriptService")

local ProfileCorpus = require(ServerScriptService.Tests.Fixtures.ProfileCorpus)
local Expected = require(ServerScriptService.Tests.Fixtures.ProfileCorpusExpected)

return function()
	describe("the profile round trip against the frozen corpus", function()
		local cases = ProfileCorpus.Cases()

		it("covers every case the corpus defines, and defines every case it expects", function()
			local seen: { [string]: boolean } = {}
			for _, case in cases do
				expect(Expected[case.Name]).to.be.ok()
				seen[case.Name] = true
			end
			for name in Expected do
				if name ~= "default" then
					expect(seen[name]).to.equal(true)
				end
			end
			expect(#cases > 1000).to.equal(true)
		end)

		it("migrates every record to the same bytes", function()
			local drifted: { string } = {}
			for _, case in cases do
				local migrated = ProfileCorpus.Fingerprint(case.Record)
				if migrated ~= Expected[case.Name][1] then
					table.insert(drifted, case.Name)
				end
			end
			if #drifted > 0 then
				error(
					`{#drifted} migrated records drifted, first: {table.concat(drifted, ", ", 1, math.min(#drifted, 5))}`
				)
			end
		end)

		it("decodes and re-encodes every record to the same bytes", function()
			local drifted: { string } = {}
			for _, case in cases do
				local _, encoded = ProfileCorpus.Fingerprint(case.Record)
				if encoded ~= Expected[case.Name][2] then
					table.insert(drifted, case.Name)
				end
			end
			if #drifted > 0 then
				error(
					`{#drifted} re-encoded profiles drifted, first: {table.concat(
						drifted,
						", ",
						1,
						math.min(#drifted, 5)
					)}`
				)
			end
		end)

		it("gives a brand-new player the same defaults", function()
			expect(ProfileCorpus.DefaultDigest()).to.equal(Expected.default[2])
		end)
	end)
end
