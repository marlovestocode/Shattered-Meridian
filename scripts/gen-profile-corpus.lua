-- Loose script run by `run-in-roblox --script` against a place built from test.project.json (same as run-tests.lua).
-- Prints one `EXPECT<TAB>name<TAB>migratedDigest<TAB>encodedDigest` line per case in Tests/Fixtures/ProfileCorpus.lua,
-- plus `EXPECT<TAB>default<TAB>-<TAB>digest`. scripts/gen-profile-corpus.py turns that output into
-- Tests/Fixtures/ProfileCorpusExpected.lua. Only run it to ADD cases or to regenerate on purpose from a commit you trust:
-- the whole point of the file it writes is that it was made before the code under test changed.
local ServerScriptService = game:GetService("ServerScriptService")

local ProfileCorpus = require(ServerScriptService.Tests.Fixtures.ProfileCorpus)

for _, case in ProfileCorpus.Cases() do
	local migrated, encoded = ProfileCorpus.Fingerprint(case.Record)
	print(`EXPECT\t{case.Name}\t{migrated}\t{encoded}`)
end
print(`EXPECT\tdefault\t-\t{ProfileCorpus.DefaultDigest()}`)
print("EXPECT-DONE")
