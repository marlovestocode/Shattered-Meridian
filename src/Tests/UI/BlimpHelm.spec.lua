--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")
local StarterPlayer = game:GetService("StarterPlayer")

local Fusion = require(ReplicatedStorage.Packages.Fusion)
local BlimpTypes = require(ReplicatedStorage.Shared.Blimp.BlimpTypes)

local UI = StarterPlayer.StarterPlayerScripts.Client.UI
local Tokens = require(UI.Tokens)
local BlimpHelm = require(UI.Screens.BlimpHelm)

-- THE HELM CONSOLE'S MODE CHIP, WHICH IS THE ONE THING ON THIS PANEL THAT CAN BE WRONG WITHOUT
-- LOOKING WRONG. Written 2026-08-25 against a reported bug: pressing G at the wheel lit the autopilot
-- legend row but left the chip reading MANUAL, so the panel's primary indicator said nothing had
-- happened.
--
-- WHY THE BUG WAS INVISIBLE TO EVERY EXISTING TEST. It is not in the flight model, and
-- Tests/Blimp/BlimpFlightMode.spec.lua is right to pass: that machine resolves `HasPilot` before
-- `AutopilotArmed` on purpose, so a hull whose pilot still holds the wheel is Piloted whatever the
-- latch says, and the rudder keeps working until they walk away. The defect was that the PANEL had
-- two facts -- Mode and a separate Autopilot boolean, both on the same payload -- and rendered only
-- one of them in the chip. Nothing that tests the server can see that, and nothing that mounts the
-- panel without driving it through a real payload can either.
--
-- STATE, NOT GEOMETRY. Every assertion here reads a string or a Color3 off a built Instance. The
-- panel's layout is measured elsewhere (and mostly by eye); what is provable in a headless place is
-- that a given HelmUpdatedPayload produces the reading it should, which is exactly the axis the bug
-- was on.
local function payload(fields: {
	Mode: BlimpTypes.HullMode,
	Autopilot: boolean,
	Depleted: boolean?,
}): BlimpTypes.HelmUpdatedPayload
	return {
		Mode = fields.Mode,
		SpeedIndex = 3,
		SpeedLabel = "ALL STOP",
		SpeedThrottle = 0,
		SpeedCount = 8,
		Autopilot = fields.Autopilot,
		ForwardYawRadians = 0,
		Depleted = fields.Depleted == true,
	}
end

return function()
	-- Declared inside the returned function so it can see TestEZ's injected `expect` -- the same note
	-- Hotbar.spec.lua and WeaponInventory.spec.lua both carry for their own mount helpers.
	local function mount(): (Fusion.Scope<typeof(Fusion)>, BlimpHelm.BlimpHelmHandle, Frame, ScreenGui)
		local scope = Fusion.scoped(Fusion)
		local handle, tile = BlimpHelm.Mount(scope)

		-- Parented into StarterGui and stepped, because Fusion applies a Value's effect on the
		-- Instance rather than synchronously inside :set(). Without a frame every assertion below
		-- would read whatever the panel happened to be built with.
		local gui = Instance.new("ScreenGui")
		gui.Name = "BlimpHelmSpec"
		gui.Parent = StarterGui
		tile.Parent = gui

		handle.SetVisible(true)
		handle.SetKind("Helm")
		handle.SetReleaseKey("E")
		return scope, handle, tile, gui
	end

	local function settle(): ()
		for _ = 1, 3 do
			RunService.Heartbeat:Wait()
		end
	end

	-- The chip is a Components/StatusTag, which builds one TextLabel for its (reactive) label. Found
	-- by walking to the tag rather than by an index, so re-ordering the header cannot silently make
	-- this spec read some other label on the panel.
	local function chip(tile: Frame): TextLabel
		local tag = tile:FindFirstChild("StatusTag", true)
		assert(tag, "helm header has no StatusTag")
		local label = tag:FindFirstChildWhichIsA("TextLabel")
		assert(label, "StatusTag has no TextLabel")
		return label
	end

	local function descriptions(tile: Frame): { string }
		local found = {}
		local controls = tile:FindFirstChild("Controls", true)
		assert(controls, "helm has no Controls well")
		for _, row in controls:GetChildren() do
			if row:IsA("Frame") and row.Name == "LegendRow" then
				for _, cell in row:GetChildren() do
					if cell:IsA("Frame") then
						local hint = cell:FindFirstChild("KeyHint")
						local label = hint and hint:FindFirstChildWhichIsA("TextLabel")
						if label then
							table.insert(found, label.Text)
						end
					end
				end
			end
		end
		return found
	end

	describe("the mode chip", function()
		it("reads MANUAL at the wheel with autopilot off", function()
			local scope, handle, tile, gui = mount()
			handle.SetHelmState(payload({ Mode = "Piloted", Autopilot = false }))
			settle()

			expect(chip(tile).Text).to.equal("MANUAL")

			Fusion.doCleanup(scope)
			gui:Destroy()
		end)

		-- THE REGRESSION. Before the fix this read "MANUAL" -- the server reports Mode = "Piloted"
		-- for a hull whose pilot is still holding the wheel, and the panel read Mode alone.
		it("switches the chip when autopilot is armed at the wheel", function()
			local scope, handle, tile, gui = mount()
			handle.SetHelmState(payload({ Mode = "Piloted", Autopilot = true }))
			settle()

			local label = chip(tile)
			expect(label.Text).never.to.equal("MANUAL")
			expect(label.Text).to.equal("AUTO ARMED")
			-- The colour moves too, so the press is confirmed by hue as well as by word.
			expect(label.TextColor3).to.equal(Tokens.Color.AccentPrimary)

			Fusion.doCleanup(scope)
			gui:Destroy()
		end)

		it("distinguishes armed-at-the-wheel from actually flying itself", function()
			local scope, handle, tile, gui = mount()

			handle.SetHelmState(payload({ Mode = "Piloted", Autopilot = true }))
			settle()
			local armed = chip(tile).Text

			-- What the server reports once the pilot steps away from the helm but stays aboard.
			handle.SetHelmState(payload({ Mode = "Autopilot", Autopilot = true }))
			settle()
			local unattended = chip(tile).Text

			expect(unattended).to.equal("AUTOPILOT")
			-- Both halves asserted by VALUE, not just as "these two differ". Checked by reverting the
			-- fix: on the old code `armed` was "MANUAL" and `unattended` "AUTOPILOT", so a
			-- difference-only assertion passed while the bug was live and this case earned nothing.
			expect(armed).to.equal("AUTO ARMED")
			expect(armed).never.to.equal(unattended)

			Fusion.doCleanup(scope)
			gui:Destroy()
		end)

		it("lets a dry tank outrank an armed autopilot", function()
			local scope, handle, tile, gui = mount()
			handle.SetHelmState(payload({ Mode = "Piloted", Autopilot = true, Depleted = true }))
			settle()

			expect(chip(tile).Text).to.equal("NO FUEL")
			expect(chip(tile).TextColor3).to.equal(Tokens.Color.Danger)

			Fusion.doCleanup(scope)
			gui:Destroy()
		end)

		it("goes back to MANUAL when autopilot is switched off again", function()
			local scope, handle, tile, gui = mount()
			handle.SetHelmState(payload({ Mode = "Piloted", Autopilot = true }))
			settle()
			handle.SetHelmState(payload({ Mode = "Piloted", Autopilot = false }))
			settle()

			expect(chip(tile).Text).to.equal("MANUAL")

			Fusion.doCleanup(scope)
			gui:Destroy()
		end)
	end)

	describe("the control legend", function()
		it("names the W/S pair for what it does, not for the instrument", function()
			local scope, _handle, tile, gui = mount()
			settle()

			local texts = descriptions(tile)
			local joined = table.concat(texts, "|")
			expect(string.find(joined, "Throttle", 1, true)).to.be.ok()
			expect(string.find(joined, "Telegraph", 1, true)).never.to.be.ok()

			Fusion.doCleanup(scope)
			gui:Destroy()
		end)

		-- One key per action, which is also what lets every row share one cap column -- see the
		-- panel's own header on why the old "SPACE / SHIFT -> Climb / dive" row had to go.
		it("gives climb and dive a row each rather than pairing them", function()
			local scope, _handle, tile, gui = mount()
			settle()

			local joined = table.concat(descriptions(tile), "|")
			expect(string.find(joined, "Climb", 1, true)).to.be.ok()
			expect(string.find(joined, "Dive", 1, true)).to.be.ok()
			expect(string.find(joined, "Climb / dive", 1, true)).never.to.be.ok()

			Fusion.doCleanup(scope)
			gui:Destroy()
		end)

		-- The one row a passenger keeps. Hidden rows are the panel's own mechanism for a passenger
		-- (Visible = false on the row, not a greyed cell), so this is what proves the release row is
		-- outside it.
		it("keeps the release row for a passenger and drops the helm-only ones", function()
			local scope, handle, tile, gui = mount()
			handle.SetKind("Handhold")
			settle()

			local controls = tile:FindFirstChild("Controls", true)
			assert(controls, "helm has no Controls well")
			local visibleRows = 0
			for _, row in controls:GetChildren() do
				if row:IsA("Frame") and row.Name == "LegendRow" and row.Visible then
					visibleRows += 1
				end
			end
			expect(visibleRows).to.equal(1)

			Fusion.doCleanup(scope)
			gui:Destroy()
		end)
	end)
end
