--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")
local StarterPlayer = game:GetService("StarterPlayer")

local Fusion = require(ReplicatedStorage.Packages.Fusion)

local UI = StarterPlayer.StarterPlayerScripts.Client.UI
local Shell = UI.Shell

local Layers = require(Shell.Layers)
local Regions = require(Shell.Regions)
local Surface = require(Shell.Surface)

-- THE ONE ScreenGui FACTORY, AND THE TWO THINGS IT MAKES UNIFORM.
--
-- Phase 2 of docs/architecture/2026-08-25-hud-shell-plan.md. Both defects it closes are of the same
-- shape -- a question every surface answered independently, and answered differently:
--
--   §2.3  IgnoreGuiInset was true on exactly three surfaces (HUD, CombatFeedback, StartMenu) and
--         absent on the other six always-on panels, so a 16px top margin meant 16px for the dock and
--         52px for the kill feed. The margins were authored to match and did not.
--   §2.4  ViewportScale.Compute had exactly two callers, so at 2560x1440 the dock grew to 1.5 and
--         every ambient panel beside it did not.
--
-- WHAT IS ASSERTED HERE AND WHAT IS NOT. Both defects are about RENDERED GEOMETRY, and the plan
-- assumed neither was checkable in this place ("a headless place never resolves AbsoluteSize", §3.2).
-- That turns out to be false, and Tests/UI/Hotbar.spec.lua already relied on it being false -- its
-- "sizes itself to its content" case mounts into StarterGui, steps Heartbeat and measures
-- AbsoluteSize, which is how the dock's full-screen-height bug was caught. So the scale half of this
-- is measured here for real, in the same style: parent into StarterGui, step frames, read the
-- numbers back, and fail loudly on a pair of zeroes rather than passing on them.
--
-- The INSET half genuinely is not checkable: GuiService reports a zero gui inset in this place (no
-- topbar is drawn), so IgnoreGuiInset has no observable effect on any measurement. What is asserted
-- instead is that the property is set at all, on every surface, from one place -- which is the part
-- that was actually wrong. Whether the margins then LOOK aligned against a real 36px topbar is a
-- screenshot's job.

local function fakePlayerGui(): PlayerGui
	return Instance.new("Folder") :: any
end

-- Long enough for AutomaticSize and a UIListLayout to settle, matching Hotbar.spec.lua's own wait.
local function settle(): ()
	for _ = 1, 8 do
		RunService.Heartbeat:Wait()
	end
end

return function()
	describe("Surface.New", function()
		it("puts every surface in one coordinate space", function()
			local scope = Fusion.scoped(Fusion)
			local parent = fakePlayerGui()
			local gui = Surface.New(scope, {
				Name = "Probe",
				Layer = Layers.Overlay,
				Parent = parent,
				Scaled = false,
			})

			-- The §2.3 fix, and the only part of it this place can see. Three of seventeen surfaces
			-- set this and the rest did not; now nothing decides it per-surface at all.
			expect(gui.IgnoreGuiInset).to.equal(true)
			expect(gui.ResetOnSpawn).to.equal(false)
			expect(gui.ZIndexBehavior).to.equal(Enum.ZIndexBehavior.Sibling)
			expect(gui.Parent).to.equal(parent)
		end)

		it("refuses a DisplayOrder that is not on the ladder", function()
			local scope = Fusion.scoped(Fusion)
			local parent = fakePlayerGui()

			-- 0 is where thirteen surfaces sat before this phase, and 10/20/30 are the literals the
			-- four self-ordering screens carried. A surface that reaches for one of those now fails at
			-- mount rather than rendering somewhere nobody predicted.
			for _, literal in { 0, 10, 20, 30 } do
				expect(function()
					Surface.New(scope, {
						Name = "Probe",
						Layer = literal,
						Parent = parent,
						Scaled = false,
					})
				end).to.throw()
			end
		end)

		it("refuses a scaled surface with no scale to use", function()
			-- Not a convenience fallback, deliberately: computing one here would open a second
			-- Camera.ViewportSize connection, and one per surface is the exact idle cost this whole
			-- layer exists to avoid (plan §11 rule 2). The value has to come from the root scope.
			local scope = Fusion.scoped(Fusion)
			expect(function()
				Surface.New(scope, {
					Name = "Probe",
					Layer = Layers.Overlay,
					Parent = fakePlayerGui(),
					Scaled = true,
				})
			end).to.throw()
		end)

		it("carries exactly one UIScale when scaled, and none when not", function()
			local scope = Fusion.scoped(Fusion)
			local parent = fakePlayerGui()

			local scaled = Surface.New(scope, {
				Name = "Scaled",
				Layer = Layers.Overlay,
				Parent = parent,
				Scaled = true,
				Scale = 1,
			})
			local unscaled = Surface.New(scope, {
				Name = "Unscaled",
				Layer = Layers.World,
				Parent = parent,
				Scaled = false,
			})

			local function countScales(gui: ScreenGui): number
				local found = 0
				for _, child in gui:GetChildren() do
					if child:IsA("UIScale") then
						found += 1
					end
				end
				return found
			end

			-- ON THE ScreenGui ITSELF, not wrapped around the caller's content, and that placement is
			-- load-bearing rather than incidental. Measured against a real render pass: a UIScale here
			-- multiplies its descendants' offsets -- size AND position -- while leaving a
			-- Size = UDim2.fromScale(1, 1) child at exactly the viewport. One level lower, inside a
			-- full-bleed Frame, the same UIScale inflates that Frame past the screen instead. This is
			-- the only placement where "scale the chrome" and "full-bleed stays full-bleed" are both
			-- true, which is what lets one flag serve a corner panel and a cinematic backdrop.
			expect(countScales(scaled)).to.equal(1)
			expect(countScales(unscaled)).to.equal(0)
		end)

		it("reports a top bar inset that is a real number", function()
			-- Zero in this place -- nothing draws a topbar over a headless Studio session -- so this
			-- asserts the shape, not the value. What it is really guarding is that the call does not
			-- throw on the server: Shell/Regions.lua and Client/Parkour/ParkourDebug.lua both make it
			-- at mount, and scripts/run-tests.lua's client load-check requires both.
			local inset = Surface.TopBarInset()
			expect(type(inset)).to.equal("number")
			expect(inset >= 0).to.equal(true)
		end)
	end)

	describe("the DisplayOrder ladder covers the whole client", function()
		-- THE ASSERTION PHASE 1 COULD NOT WRITE. It is deliberately a SOURCE scan rather than a walk
		-- over mounted Instances, because the surfaces that matter most here are the ones this place
		-- cannot mount: Screens/Onboarding wants a character creator's worth of state, ParkourDebug is
		-- built from inside a controller, and the grab cue is created lazily by an input module the
		-- first time somebody is held. A scan sees all of them.
		--
		-- Reading .Source works because TestEZ runs specs on the thread that required them, and
		-- scripts/run-tests.lua runs at plugin security. If that ever stops being true this fails
		-- loudly on the pcall below rather than quietly scanning nothing.
		local function clientSources(): { { Name: string, Source: string } }
			local found = {}
			for _, descendant in StarterPlayer.StarterPlayerScripts.Client:GetDescendants() do
				if not descendant:IsA("LuaSourceContainer") then
					continue
				end
				-- Layers.lua is where the numbers live. Its own literals are the ladder.
				if descendant.Name == "Layers" then
					continue
				end
				local ok, source = pcall(function()
					return (descendant :: any).Source
				end)
				expect(ok).to.equal(true)
				table.insert(found, { Name = descendant:GetFullName(), Source = source })
			end
			return found
		end

		-- Comments in this codebase are long, and several of them QUOTE the literals this scan is
		-- looking for -- Shell/Layers.lua's rationale is repeated in three headers. Stripping them is
		-- what keeps the scan from failing on the prose that explains why it exists.
		local function codeLines(source: string): { string }
			local lines = {}
			local inBlockComment = false
			for line in string.gmatch(source .. "\n", "([^\n]*)\n") do
				if inBlockComment then
					if string.find(line, "]]", 1, true) then
						inBlockComment = false
					end
					continue
				end
				local trimmed = string.match(line, "^%s*(.-)%s*$") or ""
				if string.sub(trimmed, 1, 4) == "--[[" then
					if not string.find(line, "]]", 1, true) then
						inBlockComment = true
					end
					continue
				end
				if string.sub(trimmed, 1, 2) == "--" then
					continue
				end
				table.insert(lines, line)
			end
			return lines
		end

		it("has no raw DisplayOrder literal left anywhere outside Layers.lua", function()
			local offenders = {}
			local scanned = 0
			for _, file in clientSources() do
				for _, line in codeLines(file.Source) do
					scanned += 1
					if string.match(line, "DisplayOrder%s*=%s*%-?%d") then
						table.insert(offenders, string.format("%s: %s", file.Name, line))
					end
					-- The same mistake in its new spelling: Surface.New takes the band as `Layer`, so
					-- a literal there is a literal DisplayOrder one call later.
					if string.match(line, "[^%w_]Layer%s*=%s*%-?%d") then
						table.insert(offenders, string.format("%s: %s", file.Name, line))
					end
				end
			end

			-- Guards the guard: a scan that silently matched nothing would pass forever.
			expect(scanned > 1000).to.equal(true)
			if #offenders > 0 then
				error("DisplayOrder literals outside Shell/Layers.lua:\n\t" .. table.concat(offenders, "\n\t"), 0)
			end
		end)

		it("puts every surface it can mount inside a named band", function()
			-- The runtime half. A source scan cannot see `local n = 10` followed by `Layer = n`;
			-- BandOf on a really-built ScreenGui can. Every surface that goes through Surface.New is
			-- checked at mount by the factory itself, so this is belt-and-braces for the ones a spec
			-- can reach.
			local scope = Fusion.scoped(Fusion)
			local parent = fakePlayerGui()
			Regions.Mount(scope, parent, 1)

			local seen = 0
			for _, child in parent:GetChildren() do
				if not child:IsA("ScreenGui") then
					continue
				end
				seen += 1
				local band = Layers.BandOf(child.DisplayOrder)
				if band == nil then
					error(
						string.format(
							"ScreenGui %q is at DisplayOrder %d, which is outside every band in " .. "Shell/Layers.lua.",
							child.Name,
							child.DisplayOrder
						)
					)
				end
			end
			expect(seen).to.equal(1)
		end)
	end)

	describe("the ambient layer scales with the dock", function()
		-- §2.4, MEASURED. This is the assertion the plan expected to need a human and a 2560x1440
		-- Studio session for. It does not: the dock and the six ambient tiles now live in ONE host
		-- wearing ONE UIScale, so "do they agree about how big the screen is" stops being a question
		-- about two surfaces and becomes a question about one number -- and the number is observable.
		--
		-- What a human still has to check is that 1.5 LOOKS right on a real 4K panel. That is taste,
		-- and this is arithmetic.
		it("grows a tile and its edge margin by the same multiplier", function()
			local scope = Fusion.scoped(Fusion)
			local holder = Instance.new("Folder")
			holder.Parent = StarterGui

			local scale: Fusion.Value<number> = scope:Value(1)
			local host = Regions.Mount(scope, holder :: any, scale)

			local tile = Instance.new("Frame")
			tile.Name = "ProbeTile"
			tile.Size = UDim2.fromOffset(100, 40)
			host:Add("BottomCentre", 10, tile)

			settle()

			-- Asserted rather than tolerated, exactly as Hotbar.spec.lua does: if layout ever stops
			-- resolving in this harness this test must fail loudly instead of quietly passing on a
			-- pair of zeroes.
			expect(host.Gui.AbsoluteSize.Y > 0).to.equal(true)
			expect(tile.AbsoluteSize.Y > 0).to.equal(true)

			local function bottomGap(): number
				return host.Gui.AbsoluteSize.Y - (tile.AbsolutePosition.Y + tile.AbsoluteSize.Y)
			end

			local heightAtOne = tile.AbsoluteSize.Y
			local gapAtOne = bottomGap()

			scale:set(2)
			settle()

			-- The tile itself. Authored in raw pixels, like every ambient panel in this UI.
			expect(tile.AbsoluteSize.Y).to.equal(heightAtOne * 2)
			-- AND ITS MARGIN, which is the half that used to be hand-written. Screens/HUD carried a
			-- Computed multiplying Tokens.Space.L by the viewport scale, with a comment explaining
			-- that a UIScale does not affect Position -- true of the UIScale it had, which sat on the
			-- band stack itself, and not of the one on the host above it. This assertion is what says
			-- the hand-scaling was really replaced rather than merely deleted.
			expect(math.abs(bottomGap() - gapAtOne * 2) <= 1).to.equal(true)

			holder:Destroy()
		end)
	end)
end
