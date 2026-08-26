--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")
local StarterPlayer = game:GetService("StarterPlayer")

local Fusion = require(ReplicatedStorage.Packages.Fusion)

local UI = StarterPlayer.StarterPlayerScripts.Client.UI
local BlimpFuel = require(UI.Screens.BlimpFuel)
local BlimpHelm = require(UI.Screens.BlimpHelm)
local ModuleWell = require(UI.Components.ModuleWell)
local ChamferedSurface = require(UI.ChamferedSurface)
local Tokens = require(UI.Tokens)

-- THE FURNACE PLATE AND THE JOINT IT RIDES ON. Reworked 2026-08-25 onto the helm console's material
-- and bolted to its top edge, the way Screens/HUD/ArmamentIsland is bolted to the dock's left edge.
--
-- Two things are asserted here and they are different in kind. The first is what the readout SAYS in
-- each of the four states its Heartbeat can produce -- driven through SetSnapshot and real frames,
-- because the bucketing, the extrapolation and the grounded/idle branches all live in that handler
-- and poking the state values directly would only assert this file's own arithmetic. The second is
-- the JOINT: the four seam rules that can be measured without a font, which are the ones a future
-- edit is most likely to break silently.

type Scope = Fusion.Scope<typeof(Fusion)>

-- Matches Shared/Blimp/BlimpConstants.Fuel's shape closely enough to drive the screen. Deliberately
-- literal rather than imported: this spec is about what the PLATE does with a snapshot, and pinning
-- the numbers here means a balance retune cannot silently change which branch each case exercises.
local CAPACITY = 500
local MINIMUM = 50

-- BackgroundTransparency is a float32 PROPERTY, so a Tokens value of 0.7 reads back as
-- 0.699999988079071. Same trap Tests/UI/Reveal.spec.lua hit on UIScale.Scale.
local function near(actual: number, expected: number): boolean
	return math.abs(actual - expected) < 1e-5
end

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

local function findLabel(root: Instance, predicate: (TextLabel) -> boolean): TextLabel?
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("TextLabel") and predicate(descendant) then
			return descendant
		end
	end
	return nil
end

return function()
	-- The whole assembly, exactly as UI/init.lua builds it: fuel state first, console second, one
	-- tile out. Parented into StarterGui and stepped because the readout is produced by a Heartbeat
	-- handler that early-outs unless the screen is visible, and because the plate's drawer is a
	-- spring. Same harness as Tests/UI/Hotbar.spec.lua.
	local function mount(): (Scope, BlimpFuel.BlimpFuelHandle, Frame, Frame, ScreenGui)
		local scope = Fusion.scoped(Fusion)
		local holder = Instance.new("ScreenGui")
		holder.Parent = StarterGui

		local fuel, furnace = BlimpFuel.Mount(scope)
		local helm, stack = BlimpHelm.Mount(scope, furnace)
		stack.Parent = holder

		helm.SetKind("Helm")
		helm.SetVisible(true)
		fuel.SetVisible(true)

		local plate = stack:FindFirstChild("FurnacePlate", true) :: Frame
		expect(plate).to.be.ok()

		return scope, fuel, stack, plate, holder
	end

	local function step(frames: number?): ()
		for _ = 1, frames or 2 do
			RunService.Heartbeat:Wait()
		end
	end

	-- The endurance chip is the only StatusTag on the plate, so it is findable without reaching for
	-- an instance name that is StatusTag's to choose.
	local function chipText(plate: Frame): string?
		local label = findLabel(plate, function(candidate)
			return candidate.Parent ~= nil and candidate.Parent.Name == "StatusTag"
		end)
		return if label then label.Text else nil
	end

	local function hasText(plate: Frame, text: string): boolean
		return findLabel(plate, function(candidate)
			return candidate.Text == text
		end) ~= nil
	end

	describe("the endurance chip", function()
		it("reads IDLE while the hull is not burning anything", function()
			-- The state this panel did not used to have. It printed "--:--" here, which is a
			-- placeholder standing where a number goes and reads as a fault rather than as "nothing
			-- is being consumed".
			local _scope, fuel, _stack, plate, holder = mount()

			fuel.SetSnapshot(snapshot(CAPACITY, CAPACITY, false, 5))
			step()

			expect(chipText(plate)).to.equal("IDLE")

			holder:Destroy()
		end)

		it("counts down while thrusting", function()
			local _scope, fuel, _stack, plate, holder = mount()

			-- Asserted as a shape rather than an exact string: the value extrapolates against real
			-- elapsed time between the snapshot and the frame that renders it, so the seconds digit
			-- is not this test's to pin.
			fuel.SetSnapshot(snapshot(CAPACITY, CAPACITY, true, 1))
			step()

			local text = chipText(plate)
			expect(text).to.be.ok()
			expect(string.match(text :: string, "^%d+:%d%d$")).to.be.ok()

			holder:Destroy()
		end)

		it("says GROUNDED once either pool is under its own minimum", function()
			-- The hull is gated the instant EITHER crosses -- BlimpConstants.Fuel's own rule -- so a
			-- full water tank does not save a spent furnace. That asymmetry is the reason the two
			-- gauges share one well rather than getting one each.
			local _scope, fuel, _stack, plate, holder = mount()

			fuel.SetSnapshot(snapshot(MINIMUM - 1, CAPACITY, true, 1))
			step()

			expect(chipText(plate)).to.equal("GROUNDED")

			holder:Destroy()
		end)
	end)

	describe("a gauge says nothing when there is nothing wrong", function()
		it("shows no status word at full tanks", function()
			-- It used to read NOMINAL on both gauges permanently, which meant a real warning arrived
			-- as a word CHANGING rather than as a word appearing. Presence is the primary cue.
			local _scope, fuel, _stack, plate, holder = mount()

			fuel.SetSnapshot(snapshot(CAPACITY, CAPACITY, true, 0.1))
			step()

			expect(hasText(plate, "NOMINAL")).to.equal(false)
			expect(hasText(plate, "LOW")).to.equal(false)
			expect(hasText(plate, "CRITICAL")).to.equal(false)
			expect(hasText(plate, "OFFLINE")).to.equal(false)

			holder:Destroy()
		end)

		it("names the state as soon as there is one", function()
			local _scope, fuel, _stack, plate, holder = mount()

			-- 50 above the minimum at 5/s is ten seconds, which is inside the critical bucket.
			fuel.SetSnapshot(snapshot(MINIMUM + 50, CAPACITY, true, 5))
			step()
			expect(hasText(plate, "CRITICAL")).to.equal(true)

			-- Under its own minimum is a stronger fact than "running low" and gets its own word.
			fuel.SetSnapshot(snapshot(MINIMUM - 1, CAPACITY, true, 5))
			step()
			expect(hasText(plate, "OFFLINE")).to.equal(true)

			holder:Destroy()
		end)

		it("renders each store's level and capacity as one string", function()
			-- They used to be two labels pinned to opposite edges of a 196px row, with the numerator
			-- and its own denominator as far apart as the panel physically allowed.
			local _scope, fuel, _stack, plate, holder = mount()

			fuel.SetSnapshot(snapshot(340, CAPACITY, false, 0))
			step()

			expect(hasText(plate, `340 / {CAPACITY}`)).to.equal(true)

			holder:Destroy()
		end)
	end)

	describe("the seam", function()
		-- Screens/BlimpHelm/FurnacePlate.lua's five rules, minus the one no test here can see. Rule 5
		-- (bronze at the assembly's outer corners only) is a consequence of rule 2 -- the bottom
		-- brackets are built inside the bleed and clipped -- so asserting the clip asserts both.
		it("shares one width with the console, so the outer edges are continuous", function()
			-- RULE 3, and the reason the plate restates the console's width as a literal instead of
			-- importing it: the arrow between those two files runs one way. This is the assertion that
			-- makes the literal safe.
			local _scope, _fuel, stack, plate, holder = mount()
			-- 120, not 20: the plate rides Tokens.Motion.IslandSpring, which is deliberately
			-- under-damped, so a shorter wait catches the drawer still travelling and every geometry
			-- reading below it a pixel or two out.
			step(120)

			local console = stack:FindFirstChild("BlimpHelmPanel", true) :: Frame
			expect(console).to.be.ok()
			expect(plate.AbsoluteSize.X).to.equal(console.AbsoluteSize.X)

			holder:Destroy()
		end)

		it("sinks the plate into the console by exactly the chamfer depth", function()
			-- RULE 1, and it is a NEGATIVE gap rather than zero. Both surfaces are chamfered, so a
			-- plate clipped flat at the seam ends its full width against a console top edge that is
			-- two chamfer depths narrower -- which left a square 8px ear at each end of the joint on
			-- an assembly whose whole silhouette is cut corners. Sinking by the chamfer depth puts the
			-- clipped bottom below the line where the console's cuts finish, so the outer edges run
			-- straight through.
			--
			-- Measured off the SLOT rather than the plate, because the plate deliberately hangs past
			-- the slot into the bleed.
			local _scope, _fuel, stack, _plate, holder = mount()
			step(120)

			local console = stack:FindFirstChild("BlimpHelmPanel", true) :: Frame
			local slot = stack:FindFirstChild("FurnaceSlot", true) :: Frame
			expect(slot).to.be.ok()

			local slotBottom = slot.AbsolutePosition.Y + slot.AbsoluteSize.Y
			local sink = slotBottom - console.AbsolutePosition.Y
			-- Positive (into the console) and no deeper than the chamfer: one pixel more and the
			-- plate starts covering console content rather than console chrome.
			expect(sink > 0).to.equal(true)
			expect(sink <= ChamferedSurface.CHAMFER_PX + 1).to.equal(true)

			holder:Destroy()
		end)

		it("clips the plate's bottom chrome away at the seam", function()
			-- RULE 2, and the whole reason the plate is built taller than its slot. If the slot ever
			-- stopped clipping, or the plate stopped carrying a bleed, the join would grow a second
			-- border and a pair of bronze elbows pointing into the middle of the assembly.
			local _scope, _fuel, stack, plate, holder = mount()
			step(120)

			local slot = stack:FindFirstChild("FurnaceSlot", true) :: Frame
			expect(slot.ClipsDescendants).to.equal(true)
			expect(plate.AbsoluteSize.Y > slot.AbsoluteSize.Y).to.equal(true)

			holder:Destroy()
		end)

		it("fastens the joint with one bronze bead sitting on the shared rule", function()
			-- The rule has to be DRAWN here, unlike at the dock's seam where the island stops at the
			-- dock's edge and that edge's own stroke is the line. This plate sinks past the console's
			-- top edge and its fill covers that stroke, so without a rule the two faces merge into one
			-- unbroken surface and the bead is left floating in the middle of it.
			--
			-- Both are asserted at the SAME Y, which is the whole point: a bead eight pixels off the
			-- line it is fastening is the defect this replaced.
			local _scope, _fuel, stack, _plate, holder = mount()
			step(120)

			local slot = stack:FindFirstChild("FurnaceSlot", true) :: Frame
			local rule = stack:FindFirstChild("SeamRule", true) :: Frame
			local bolt = stack:FindFirstChild("SeamBolt", true) :: Frame
			expect(rule).to.be.ok()
			expect(bolt).to.be.ok()
			expect(bolt.BackgroundColor3).to.equal(Tokens.Color.AccentSecondary)
			-- THE DIVISION OUT-READS THE OUTER EDGE, and that inversion is the assertion. A joined
			-- assembly whose internal line is quieter than its own border merges back into one object,
			-- which is what this looked like at the panels' own AccentPrimary/0.3 before the owner
			-- asked for "a much more prominent divider". Pinned against the token rather than a
			-- literal, and against the panel border it has to beat rather than against a number.
			expect(rule.BackgroundColor3).to.equal(Tokens.Border.Seam.Color)
			expect(Tokens.Border.Seam.Transparency < 0.3).to.equal(true)
			expect(rule.BackgroundTransparency < 0.05).to.equal(true)

			-- The junction is the plate's clipped bottom, which is where the two faces actually meet.
			local junction = slot.AbsolutePosition.Y + slot.AbsoluteSize.Y
			local ruleCentre = rule.AbsolutePosition.Y + rule.AbsoluteSize.Y / 2
			local boltCentre = bolt.AbsolutePosition.Y + bolt.AbsoluteSize.Y / 2
			expect(math.abs(ruleCentre - junction) <= 1).to.equal(true)
			expect(math.abs(boltCentre - junction) <= 1).to.equal(true)
			-- Full width, because the console is already past its chamfer at this Y -- which is the
			-- reason the sink is the chamfer depth and not some other number.
			expect(rule.AbsoluteSize.X).to.equal(slot.AbsoluteSize.X)
			expect(rule.AbsoluteSize.Y).to.equal(Tokens.Control.SeamRuleThickness)

			holder:Destroy()
		end)

		it("leaves the console alone when there is no fuel state at all", function()
			-- The optional half of the joint. A console with no furnace must be byte-identical to what
			-- it was before the plate existed -- which is also what every other spec that mounts a
			-- bare helm depends on.
			local scope = Fusion.scoped(Fusion)
			local _helm, tile = BlimpHelm.Mount(scope)

			expect(tile.Name).to.equal("BlimpHelmPanel")
			expect(tile:FindFirstChild("FurnaceSlot", true)).to.equal(nil)
			expect(tile:FindFirstChild("SeamBolt", true)).to.equal(nil)
		end)
	end)

	describe("the plate wears the console's material", function()
		it("is chamfered with un-rivetted bronze brackets, not the menu register", function()
			-- docs/ui-ux-philosophy.md's Shape Language puts the cut-corner silhouette on combat
			-- surfaces and the sharp rect on menu ones, and says using one on the other "is the wrong
			-- register -- not a stylistic choice either way". This panel was wearing the menu register
			-- while never being a thing you open.
			--
			-- Asserted through the brackets rather than through the chamfer: the chamfered fill needs
			-- ChamferedSurface.IsAvailable(), which is false in this place (it requires Mesh/Image
			-- APIs), so Panel falls back to a sharp rect and there is nothing to measure. The brackets
			-- render either way, and their rivets and colour are the half of the decision a fallback
			-- does not change.
			--
			-- CornerBracket.BuildAll returns flat pieces rather than one node per corner, so the elbows
			-- are counted by their horizontal arms: four corners, four arms, zero rivets.
			local _scope, _fuel, _stack, plate, holder = mount()

			local arms = 0
			local rivets = 0
			for _, descendant in plate:GetDescendants() do
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
			-- coal and water are one furnace's inputs rather than two independent gauges.
			local _scope, _fuel, _stack, plate, holder = mount()

			local wells = 0
			for _, descendant in plate:GetDescendants() do
				if descendant:IsA("Frame") and descendant.Name == "Stores" then
					wells += 1
					expect(near(descendant.BackgroundTransparency, Tokens.Wash.RailScrim.Transparency)).to.equal(true)
					expect(descendant:FindFirstChildOfClass("UIStroke")).to.be.ok()
					expect(descendant:FindFirstChildOfClass("UICorner")).to.be.ok()
				end
			end

			expect(wells).to.equal(1)

			holder:Destroy()
		end)
	end)

	describe("ModuleWell", function()
		-- Promoted to a shared component at the furnace, its third call site, which is CLAUDE.md's own
		-- bar -- Screens/BlimpHelm's inline copy had already named the trigger. What is asserted is
		-- the thing three copies would drift on: that the chrome is identical whichever direction it
		-- is built in, and that the direction still reaches the layout.
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
				expect(near(frame.BackgroundTransparency, Tokens.Wash.RailScrim.Transparency)).to.equal(true)

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
			-- The property that lets a well shrink when its cluster does -- the console's legend well
			-- collapses to one row for a passenger and must get shorter rather than part-empty.
			local _scope, frame = build()

			expect(frame.Size).to.equal(UDim2.fromScale(1, 0))
			expect(frame.AutomaticSize).to.equal(Enum.AutomaticSize.Y)
		end)
	end)
end
