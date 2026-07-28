--!strict
local ServerScriptService = game:GetService("ServerScriptService")

local ModerationSystem = require(ServerScriptService.Server.Systems.ModerationSystem)

type BanRecord = ModerationSystem.BanRecord

-- Pure-logic surface only -- IsRecordActive never touches the DataStore (IsBanned/BanPlayer do, and
-- are Studio/live-server verification only per this codebase's own headless-harness caveat -- see
-- reference_headless_test_workflow). Requiring this module never calls ModerationSystem.Init(), so
-- banStore stays nil throughout this file. MutePlayer/IsMuted are plain in-memory table operations
-- with no DataStore or live Player involved, so those get real coverage too.

return function()
	describe("ModerationSystem.IsRecordActive", function()
		it("treats a permanent ban (no ExpiresAt) as always active", function()
			local record: BanRecord = { BannedAt = 0, BannedByUserId = 1, Reason = "test", ExpiresAt = nil }
			expect(ModerationSystem.IsRecordActive(record, 0)).to.equal(true)
			expect(ModerationSystem.IsRecordActive(record, math.huge)).to.equal(true)
		end)

		it("treats a timed ban as active before its expiry", function()
			local record: BanRecord = { BannedAt = 0, BannedByUserId = 1, Reason = "test", ExpiresAt = 100 }
			expect(ModerationSystem.IsRecordActive(record, 50)).to.equal(true)
		end)

		it("treats a timed ban as expired at/after its expiry", function()
			local record: BanRecord = { BannedAt = 0, BannedByUserId = 1, Reason = "test", ExpiresAt = 100 }
			expect(ModerationSystem.IsRecordActive(record, 100)).to.equal(false)
			expect(ModerationSystem.IsRecordActive(record, 150)).to.equal(false)
		end)
	end)

	describe("ModerationSystem.MutePlayer / IsMuted", function()
		it("is unmuted by default", function()
			expect(ModerationSystem.IsMuted(999111)).to.equal(false)
		end)

		it("marks a UserId muted when enabled", function()
			ModerationSystem.MutePlayer(999111, true)
			expect(ModerationSystem.IsMuted(999111)).to.equal(true)
			ModerationSystem.MutePlayer(999111, false)
		end)

		it("clears a UserId's muted state when disabled", function()
			ModerationSystem.MutePlayer(999222, true)
			expect(ModerationSystem.IsMuted(999222)).to.equal(true)

			ModerationSystem.MutePlayer(999222, false)
			expect(ModerationSystem.IsMuted(999222)).to.equal(false)
		end)

		it("MutePlayer always reports success", function()
			expect(ModerationSystem.MutePlayer(999333, true)).to.equal(true)
			ModerationSystem.MutePlayer(999333, false)
		end)
	end)

	describe("ModerationSystem.IsBanned / BanPlayer (no DataStore acquired)", function()
		-- Init() is never called in this spec file, so banStore stays nil throughout -- this exercises
		-- the "storage isn't available" fail-open contract (see IsBanned's own header: a storage error
		-- must never be conflated with "confirmed not banned", and must never lock every player out).
		it("IsBanned reports a StorageError rather than silently allowing or denying", function()
			local isBanned, record, reason = ModerationSystem.IsBanned(123456)
			expect(isBanned).to.equal(false)
			expect(record).to.equal(nil)
			expect(reason).to.equal("StorageError")
		end)

		it("BanPlayer returns false rather than throwing", function()
			expect(ModerationSystem.BanPlayer(123456, 1, "test", nil)).to.equal(false)
		end)

		-- With banStore nil, BanPlayer's early `if not banStore then return false end` guard fires
		-- before pendingBanUserIds is ever touched -- so this only proves the accessor's default, not
		-- the set/clear-around-SetAsync-yield behavior itself. That behavior (BanPlayer marking a
		-- UserId pending synchronously, then clearing it once SetAsync resolves either way) needs a
		-- real, yielding DataStore call to observe mid-flight, which isn't reachable from this headless
		-- harness -- see ModerationSystem.lua's own pendingBanUserIds header for the reasoning, and
		-- treat it the same as IsBanned/BanPlayer's own DataStore-backed behavior: Studio/live-server
		-- verification only.
		it("IsPendingBan is false for a UserId that was never passed to BanPlayer", function()
			expect(ModerationSystem.IsPendingBan(654321)).to.equal(false)
		end)
	end)

	-- ModerationSystem.KickPlayer requires a real Player (can't be constructed headlessly) -- same
	-- already-accepted gap AdminActionSystem.spec.lua documents for its own Player-keyed wrappers.
	-- Requires Studio/live-server verification, as does IsBanned/BanPlayer's actual DataStore-backed
	-- behavior once a store is acquired.

	describe("ModerationSystem.ComputeSuspicionCountDelta", function()
		it("returns 0 when the flagged state does not change", function()
			expect(ModerationSystem.ComputeSuspicionCountDelta(false, false)).to.equal(0)
			expect(ModerationSystem.ComputeSuspicionCountDelta(true, true)).to.equal(0)
		end)

		it("returns +1 when newly flagged", function()
			expect(ModerationSystem.ComputeSuspicionCountDelta(false, true)).to.equal(1)
		end)

		it("returns -1 when unflagged from a previously-flagged state", function()
			expect(ModerationSystem.ComputeSuspicionCountDelta(true, false)).to.equal(-1)
		end)
	end)

	describe("ModerationSystem.IsSuspectedCheater / GetSuspectedCheaterCount", function()
		it("is unflagged by default", function()
			expect(ModerationSystem.IsSuspectedCheater(999444)).to.equal(false)
		end)

		it("defaults to a count of 0 before Init() ever seeds it", function()
			expect(ModerationSystem.GetSuspectedCheaterCount()).to.equal(0)
		end)
	end)

	describe("ModerationSystem.FlagSuspectedCheater / UnflagSuspectedCheater (no DataStore acquired)", function()
		-- Same "storage isn't available" contract as BanPlayer's own spec above -- Init() is never
		-- called in this file, so suspicionStore stays nil throughout, and neither function ever
		-- reaches its in-memory mirror/count update.
		it("FlagSuspectedCheater returns false rather than throwing", function()
			expect(ModerationSystem.FlagSuspectedCheater(123456, 1, "test", "Manual")).to.equal(false)
		end)

		it("UnflagSuspectedCheater returns false rather than throwing", function()
			expect(ModerationSystem.UnflagSuspectedCheater(123456)).to.equal(false)
		end)
	end)
end
