--!strict
-- Covers Shared/Defense/ParryWindows.lua -- where a parry's timing comes from.
--
-- Needs no published asset. KeyframeSequences are built in place with Instance.new and fed in through
-- the injectable extractor, which is exactly the shape the real KeyframeSequenceProvider returns -- so
-- these cases exercise the real ExtractMarkers walk rather than a stand-in for it.
--
-- The precedence rules get as much attention as the parsing, because precedence is what makes the
-- registration path safe: markers must always win, and an id with neither source must stay unarmed.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DefenseConstants = require(ReplicatedStorage.Shared.Defense.DefenseConstants)
local ParryWindows = require(ReplicatedStorage.Shared.Defense.ParryWindows)

-- Builds a sequence carrying `markers` as {name -> time}. One Keyframe per marker, which is how an
-- animator's export looks when the markers sit on distinct poses.
local function makeSequence(markers: { [string]: number }): KeyframeSequence
	local sequence = Instance.new("KeyframeSequence")
	for name, time in markers do
		local keyframe = Instance.new("Keyframe")
		keyframe.Time = time
		local marker = Instance.new("KeyframeMarker")
		marker.Name = name
		marker.Parent = keyframe
		keyframe.Parent = sequence
	end
	return sequence
end

-- Points the extractor at a fixed set of markers. Cases that care how MANY times it was called set
-- their own counting extractor instead.
local function serve(markers: { [string]: number }?): ()
	ParryWindows.SetExtractor(function(): KeyframeSequence?
		return if markers then makeSequence(markers) else nil
	end)
end

return function()
	afterEach(function()
		ParryWindows.Reset()
		-- Restored to something inert so a later spec file cannot inherit this one's extractor.
		ParryWindows.SetExtractor(function()
			return nil
		end)
	end)

	describe("ParryWindows.ExtractMarkers", function()
		it("reads each marker's time from its own keyframe", function()
			local times = ParryWindows.ExtractMarkers(makeSequence({
				ParryStart = 0.05,
				ParryClose = 0.25,
				ParryRecoveryEnd = 0.6,
			}))
			expect(times.ParryStart).to.be.near(0.05, 1e-6)
			expect(times.ParryClose).to.be.near(0.25, 1e-6)
			expect(times.ParryRecoveryEnd).to.be.near(0.6, 1e-6)
		end)

		it("takes the EARLIEST keyframe when a marker name appears twice", function()
			local sequence = Instance.new("KeyframeSequence")
			for _, time in { 0.4, 0.1, 0.7 } do
				local keyframe = Instance.new("Keyframe")
				keyframe.Time = time
				local marker = Instance.new("KeyframeMarker")
				marker.Name = "ParryStart"
				marker.Parent = keyframe
				keyframe.Parent = sequence
			end
			-- An animator who left two Open markers meant the first; picking the later one would
			-- silently shorten the window.
			expect(ParryWindows.ExtractMarkers(sequence).ParryStart).to.be.near(0.1, 1e-6)
		end)

		it("ignores non-marker children", function()
			local sequence = makeSequence({ ParryStart = 0.1 })
			local pose = Instance.new("Pose")
			pose.Name = "ParryClose"
			pose.Parent = sequence
			local times = ParryWindows.ExtractMarkers(sequence)
			expect(times.ParryClose).to.equal(nil)
		end)
	end)

	describe("ParryWindows.WindowFromMarkers", function()
		it("builds a window from a complete pair", function()
			local window = ParryWindows.WindowFromMarkers({ ParryStart = 0.05, ParryClose = 0.25 })
			expect(window).to.be.ok()
			expect((window :: any).Open).to.be.near(0.05, 1e-6)
			expect((window :: any).Close).to.be.near(0.25, 1e-6)
			expect((window :: any).Source).to.equal("Markers")
		end)

		it("falls back to the constant recovery when ParryRecoveryEnd is absent", function()
			local window = ParryWindows.WindowFromMarkers({ ParryStart = 0, ParryClose = 0.2 })
			expect((window :: any).RecoveryEnd).to.equal(0.2 + DefenseConstants.Parry.RecoverySeconds)
		end)

		it("refuses a half-authored pair rather than honouring it", function()
			local openOnly, openReason = ParryWindows.WindowFromMarkers({ ParryStart = 0.1 })
			expect(openOnly).to.equal(nil)
			expect(openReason).to.equal("MissingClose")

			local closeOnly, closeReason = ParryWindows.WindowFromMarkers({ ParryClose = 0.1 })
			expect(closeOnly).to.equal(nil)
			expect(closeReason).to.equal("MissingOpen")

			local neither, neitherReason = ParryWindows.WindowFromMarkers({})
			expect(neither).to.equal(nil)
			expect(neitherReason).to.equal("NoMarkers")
		end)

		it("refuses a window that does not move forward", function()
			-- Not a short window -- a broken one. Honouring it produces a parry that is either
			-- instantaneous or inverted.
			local equal, equalReason = ParryWindows.WindowFromMarkers({ ParryStart = 0.2, ParryClose = 0.2 })
			expect(equal).to.equal(nil)
			expect(equalReason).to.equal("CloseNotAfterOpen")

			local inverted = ParryWindows.WindowFromMarkers({ ParryStart = 0.3, ParryClose = 0.1 })
			expect(inverted).to.equal(nil)
		end)

		it("refuses a negative open time", function()
			local window, reason = ParryWindows.WindowFromMarkers({ ParryStart = -0.1, ParryClose = 0.2 })
			expect(window).to.equal(nil)
			expect(reason).to.equal("NegativeOpen")
		end)
	end)

	describe("ParryWindows -- fail-closed", function()
		it("leaves an unknown id unarmed", function()
			expect(ParryWindows.Get("rbxassetid://nothing")).to.equal(nil)
			expect(ParryWindows.IsArmed("rbxassetid://nothing")).to.equal(false)
		end)

		it("leaves an id whose asset carries no usable markers unarmed", function()
			serve({ ParryStart = 0.1 })
			ParryWindows.Prefetch("rbxassetid://half")
			-- A default window here is the hardcoded value this whole module exists to remove.
			expect(ParryWindows.IsArmed("rbxassetid://half")).to.equal(false)
		end)
	end)

	describe("ParryWindows -- caching", function()
		it("serves a second Get without re-extracting", function()
			local calls = 0
			ParryWindows.SetExtractor(function(): KeyframeSequence?
				calls += 1
				return makeSequence({ ParryStart = 0, ParryClose = 0.2 })
			end)
			ParryWindows.Prefetch("rbxassetid://cached")
			ParryWindows.Prefetch("rbxassetid://cached")
			ParryWindows.Get("rbxassetid://cached")
			expect(calls).to.equal(1)
		end)

		it("negatively caches a permanent failure instead of retrying forever", function()
			local calls = 0
			ParryWindows.SetExtractor(function(): KeyframeSequence?
				calls += 1
				return nil
			end)
			ParryWindows.Prefetch("rbxassetid://missing")
			local afterFirst = calls
			ParryWindows.Prefetch("rbxassetid://missing")
			-- The retries inside the first Prefetch are expected; a SECOND Prefetch must add none.
			expect(calls).to.equal(afterFirst)
			expect(afterFirst > 1).to.equal(true)
		end)
	end)

	describe("ParryWindows -- precedence", function()
		it("serves a registration for an id with no markers", function()
			expect(ParryWindows.Register("rbxassetid://registered", 0.02, 0.22)).to.equal(true)
			local window = ParryWindows.Get("rbxassetid://registered")
			expect(window).to.be.ok()
			expect((window :: any).Source).to.equal("Registered")
			expect(ParryWindows.IsArmed("rbxassetid://registered")).to.equal(true)
		end)

		it("lets authored markers beat a registration", function()
			ParryWindows.Register("rbxassetid://both", 0.5, 0.9)
			serve({ ParryStart = 0.05, ParryClose = 0.25 })
			ParryWindows.Prefetch("rbxassetid://both")

			local window = ParryWindows.Get("rbxassetid://both")
			expect((window :: any).Source).to.equal("Markers")
			expect((window :: any).Open).to.be.near(0.05, 1e-6)
		end)

		it("refuses a registration that does not describe a real window", function()
			expect(ParryWindows.Register("rbxassetid://bad", 0.3, 0.1)).to.equal(false)
			expect(ParryWindows.IsArmed("rbxassetid://bad")).to.equal(false)
		end)
	end)

	describe("ParryWindows.ValidateAll", function()
		it("reports an unarmed id", function()
			ParryWindows.SetExtractor(function()
				return nil
			end)
			local records = ParryWindows.ValidateAll({ "rbxassetid://absent" })
			expect(#records).to.equal(1)
			expect(records[1].Armed).to.equal(false)
			expect(records[1].HasMarkers).to.equal(false)
			expect(records[1].RegistrationShadowed).to.equal(false)
		end)

		it("reports a registration that markers have shadowed", function()
			ParryWindows.Register("rbxassetid://shadowed", 0.5, 0.9)
			serve({ ParryStart = 0.05, ParryClose = 0.25 })
			local records = ParryWindows.ValidateAll({ "rbxassetid://shadowed" })
			expect(records[1].Armed).to.equal(true)
			expect(records[1].RegistrationShadowed).to.equal(true)
		end)
	end)

	describe("ParryWindows.ParryEndFor", function()
		it("refunds ping up to the cap", function()
			local window = { Open = 0, Close = 0.2, RecoveryEnd = 0.6, Source = "Registered" :: any }
			expect(ParryWindows.ParryEndFor(window, 0.05)).to.be.near(0.25, 1e-9)
		end)

		it("caps the refund so a spoofed ping cannot buy a permanent parry", function()
			local window = { Open = 0, Close = 0.2, RecoveryEnd = 0.6, Source = "Registered" :: any }
			local cap = DefenseConstants.Parry.PingCompensationMaxSeconds
			expect(ParryWindows.ParryEndFor(window, 10)).to.equal(0.2 + cap)
		end)

		it("refunds nothing to a combatant with no latency", function()
			local window = { Open = 0, Close = 0.2, RecoveryEnd = 0.6, Source = "Registered" :: any }
			-- Bots and dummies. Also the degenerate negative/NaN cases.
			expect(ParryWindows.ParryEndFor(window, 0)).to.equal(0.2)
			expect(ParryWindows.ParryEndFor(window, -1)).to.equal(0.2)
			expect(ParryWindows.ParryEndFor(window, 0 / 0)).to.equal(0.2)
		end)
	end)
end
