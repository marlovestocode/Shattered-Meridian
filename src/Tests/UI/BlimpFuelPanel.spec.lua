--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")
local StarterPlayer = game:GetService("StarterPlayer")

local Fusion = require(ReplicatedStorage.Packages.Fusion)

local UI = StarterPlayer.StarterPlayerScripts.Client.UI
local BlimpFuel = require(UI.Screens.BlimpFuel)
local ModuleWell = require(UI.Components.ModuleWell)
local Tokens = require(UI.Tokens)

-- THE FURNACE INSTRUMENT, reworked 2026-08-25 onto the hotbar dock's material and moved to the
-- bottom-right region. What is asserted here is the half a screenshot cannot settle: that the panel
-- says the right WORD in each of the four states its Heartbeat can produce, and that the two
-- structural decisions behind the rework are actually in the tree.
--
-- The states are driven through SetSnapshot and a real Heartbeat, not by poking the Values -- the
-- bucketing, the extrapolation and the grounded/idle branches all live in that handler, so a test
-- that set the Values directly would be asserting its own arithmetic.

type Scope = Fusion.Scope<typeof(Fusion)>

-- Matches Shared/Blimp/BlimpConstants.Fuel's shape closely enough to drive the screen. Deliberately
-- literal rather than imported: this spec is about what the PANEL does with a snapshot, and pinning
-- the numbers here means a balance retune cannot silently change which branch each case exercises.
local CAPACITY = 500
local MINIMUM = 50

local function snapshot(coal: number, water: number, thrusting: boolean, burn: number)
	return {
		Coal = coal,
		Water = water,
		CoalCapacity = CAPACITY,
		WaterCapacity = CAPACITY,
		CoalMinimum = MINIMUM,
		WaterMinimum = MINIMUM,
		CoalBurnPerSecond = burn,
		WaterBurnPerSecond = burn,
		Thrusting = thrusting,
	} :: any
end

-- BackgroundTransparency is a float32 PROPERTY, so a Tokens value of 0.7 reads back as
-- 0.699999988079071. Same trap Tests/UI/Reveal.spec.lua hit on UIScale.Scale; the tolerance is here
-- rather than at each call site so the three comparisons cannot drift apart.
local function expectNear(actual: number, expected: number): boolean
	return math.abs(actual - expected) < 1e-5
end

local function findLabel(root: Instance, predicate: (TextLabel) -> boolean): TextLabel?
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("TextLabel") and predicate(descendant) then
			return descendant
		end
	end
	return nil
end

return function()
	-- Parented into StarterGui and stepped, because the whole readout is produced by a Heartbeat
	-- handler that early-outs unless the screen is visible. Same harness as Tests/UI/Hotbar.spec.lua.
	local function mount(): (Scope, BlimpFuel.BlimpFuelHandle, Frame, ScreenGui)
		local scope = Fusion.scoped(Fusion)
		local holder = Instance.new("ScreenGui")
		holder.Parent = StarterGui

		local handle, tile = BlimpFuel.Mount(scope)
		tile.Parent = holder
		handle.SetVisible(true)

		return scope, handle, tile, holder
	end

	local function step(): ()
		-- Two frames: one for the Heartbeat handler to write the Values, one for Fusion to flush them
		-- into the TextLabels.
		RunService.Heartbeat:Wait()
		RunService.Heartbeat:Wait()
	end

	-- The endurance chip is the only StatusTag on this panel, so it is findable without reaching for
	-- an instance name that is StatusTag's to choose.
	local function chipText(tile: Frame): string?
		local label = findLabel(tile, function(candidate)
			return candidate.Parent ~= nil and candidate.Parent.Name == "StatusTag"
		end)
		return if label then label.Text else nil
	end

	local function hasText(tile: Frame, text: string): boolean
		return findLabel(tile, function(candidate)
			return candidate.Text == text
		end) ~= nil
	end

	describe("the endurance chip", function()
		it("reads IDLE while the hull is not burning anything", function()
			-- The state this panel did not used to have. It printed "--:--" here, which is a
			-- placeholder standing where a number goes and reads as a fault rather than as "nothing
			-- is being consumed".
			local _scope, handle, tile, holder = mount()

			handle.SetSnapshot(snapshot(CAPACITY, CAPACITY, false, 5))
			step()

			expect(chipText(tile)).to.equal("IDLE")

			holder:Destroy()
		end)

		it("counts down while thrusting", function()
			local _scope, handle, tile, holder = mount()

			-- 450 above the minimum at 1/s is 7:30. Asserted as a shape rather than an exact string:
			-- the value extrapolates against real elapsed time between the snapshot and the frame
			-- that renders it, so the seconds digit is not this test's to pin.
			handle.SetSnapshot(snapshot(CAPACITY, CAPACITY, true, 1))
			step()

			local text = chipText(tile)
			expect(text).to.be.ok()
			expect(string.match(text :: string, "^%d+:%d%d$")).to.be.ok()

			holder:Destroy()
		end)

		it("says GROUNDED once either pool is under its own minimum", function()
			-- The hull is gated the instant EITHER crosses -- BlimpConstants.Fuel's own rule -- so a
			-- full water tank does not save a spent furnace. That asymmetry is the reason the two
			-- gauges share one well rather than getting one each.
			local _scope, handle, tile, holder = mount()

			handle.SetSnapshot(snapshot(MINIMUM - 1, CAPACITY, true, 1))
			step()

			expect(chipText(tile)).to.equal("GROUNDED")

			holder:Destroy()
		end)
	end)

	describe("a gauge says nothing when there is nothing wrong", function()
		it("shows no status word at full tanks", function()
			-- It used to read NOMINAL on both gauges permanently, which meant a real warning arrived
			-- as a word CHANGING rather than as a word appearing. Presence is the primary cue.
			local _scope, handle, tile, holder = mount()

			handle.SetSnapshot(snapshot(CAPACITY, CAPACITY, true, 0.1))
			step()

			expect(hasText(tile, "NOMINAL")).to.equal(false)
			expect(hasText(tile, "LOW")).to.equal(false)
			expect(hasText(tile, "CRITICAL")).to.equal(false)
			expect(hasText(tile, "OFFLINE")).to.equal(false)

			holder:Destroy()
		end)

		it("names the state as soon as there is one", function()
			local _scope, handle, tile, holder = mount()

			-- 50 above the minimum at 5/s is ten seconds, which is inside the critical bucket.
			handle.SetSnapshot(snapshot(MINIMUM + 50, CAPACITY, true, 5))
			step()
			expect(hasText(tile, "CRITICAL")).to.equal(true)

			-- Under its own minimum is a stronger fact than "running low" and gets its own word.
			handle.SetSnapshot(snapshot(MINIMUM - 1, CAPACITY, true, 5))
			step()
			expect(hasText(tile, "OFFLINE")).to.equal(true)

			holder:Destroy()
		end)

		it("renders each store's level and capacity as one string", function()
			-- They used to be two labels pinned to opposite edges of a 196px row, with the numerator
			-- and its own denominator as far apart as the panel physically allowed.
			local _scope, handle, tile, holder = mount()

			handle.SetSnapshot(snapshot(340, CAPACITY, false, 0))
			step()

			expect(hasText(tile, `340 / {CAPACITY}`)).to.equal(true)

			holder:Destroy()
		end)
	end)

	describe("it wears the dock's material", function()
		it("is chamfered with un-rivetted bronze brackets, not the menu register", function()
			-- docs/ui-ux-philosophy.md's Shape Language puts the cut-corner silhouette on combat
			-- surfaces and the sharp rect on menu ones, and says using one on the other "is the wrong
			-- register -- not a stylistic choice either way". This panel was wearing the menu register
			-- while never being a thing you open.
			--
			-- Asserted through the CornerBracket instances rather than through the chamfer: the
			-- chamfered fill needs ChamferedSurface.IsAvailable(), which is false in this place (it
			-- requires Mesh/Image APIs), so Panel falls back to a sharp rect and there is nothing to
			-- measure. The brackets render either way, and their rivets and colour are the half of the
			-- decision that a fallback does not change.
			local _scope, _handle, tile, holder = mount()

			-- CornerBracket.BuildAll returns flat pieces rather than one node per corner, so the
			-- elbows are counted by their horizontal arms: four corners, four arms, zero rivets.
			local arms = 0
			local rivets = 0
			for _, descendant in tile:GetDescendants() do
				if descendant.Name == "BracketArmHorizontal" then
					arms += 1
					expect((descendant :: Frame).BackgroundColor3).to.equal(Tokens.Color.AccentSecondary)
				elseif descendant.Name == "BracketRivet" then
					rivets += 1
				end
			end

			expect(arms).to.equal(4)
			expect(rivets).to.equal(0)

			holder:Destroy()
		end)

		it("groups both stores in one recessed well rather than in loose bands", function()
			-- ONE well, not two: the hull is grounded the instant either pool crosses its minimum, so
			-- coal and water are one furnace's inputs rather than two independent gauges. Two wells
			-- would draw a box between them.
			local _scope, _handle, tile, holder = mount()

			local wells = 0
			for _, descendant in tile:GetDescendants() do
				if descendant:IsA("Frame") and descendant.Name == "Stores" then
					wells += 1
					expect(expectNear(descendant.BackgroundTransparency, Tokens.Wash.RailScrim.Transparency)).to.equal(
						true
					)
					expect(descendant:FindFirstChildOfClass("UIStroke")).to.be.ok()
					expect(descendant:FindFirstChildOfClass("UICorner")).to.be.ok()
				end
			end

			expect(wells).to.equal(1)

			holder:Destroy()
		end)
	end)

	describe("ModuleWell", function()
		-- Promoted to a shared component at this screen, its third call site, which is CLAUDE.md's
		-- own bar -- Screens/BlimpHelm's inline copy had already named the trigger. What is asserted
		-- is the thing three copies would drift on: that the chrome is identical whichever direction
		-- it is built in, and that the direction still reaches the layout.
		local function build(direction: ("Vertical" | "Horizontal")?): (Scope, Frame)
			local scope = Fusion.scoped(Fusion)
			return scope,
				ModuleWell(scope, {
					Name = "Probe",
					Direction = direction,
					Gap = Tokens.Space.S,
					Children = {},
				})
		end

		for _, direction in { "Vertical", "Horizontal" } do
			it(string.format("wears the same recessed chrome %s", string.lower(direction)), function()
				local _scope, frame = build(direction :: any)

				expect(frame.BackgroundColor3).to.equal(Tokens.Wash.RailScrim.Color)
				expect(expectNear(frame.BackgroundTransparency, Tokens.Wash.RailScrim.Transparency)).to.equal(true)

				local corner = frame:FindFirstChildOfClass("UICorner")
				expect(corner).to.be.ok()
				expect((corner :: UICorner).CornerRadius).to.equal(Tokens.Radius.Hairline)

				local stroke = frame:FindFirstChildOfClass("UIStroke")
				expect(stroke).to.be.ok()
				expect((stroke :: UIStroke).Thickness).to.equal(1)

				expect(frame:FindFirstChildOfClass("UIPadding")).to.be.ok()
			end)
		end

		it("lays a vertical well out as a column and a horizontal one as a row", function()
			local _verticalScope, vertical = build("Vertical")
			local _horizontalScope, horizontal = build("Horizontal")

			local verticalLayout = vertical:FindFirstChildOfClass("UIListLayout")
			local horizontalLayout = horizontal:FindFirstChildOfClass("UIListLayout")
			expect(verticalLayout).to.be.ok()
			expect(horizontalLayout).to.be.ok()
			expect((verticalLayout :: UIListLayout).FillDirection).to.equal(Enum.FillDirection.Vertical)
			expect((horizontalLayout :: UIListLayout).FillDirection).to.equal(Enum.FillDirection.Horizontal)
		end)

		it("defaults a column to full width and content height", function()
			-- The property that lets a well shrink when its cluster does -- the helm's legend well
			-- collapses to one row for a passenger and must get shorter rather than part-empty.
			local _scope, frame = build()

			expect(frame.Size).to.equal(UDim2.fromScale(1, 0))
			expect(frame.AutomaticSize).to.equal(Enum.AutomaticSize.Y)
		end)
	end)
end
