--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local Fusion = require(ReplicatedStorage.Packages.Fusion)

local DevMenu = require(StarterPlayer.StarterPlayerScripts.Client.UI.Screens.DevTools.DevMenu)

-- The admin panel fed real-shaped data, so every dynamic path -- roster rows, the inspector, report
-- rows, flight fields, vehicle rows -- actually constructs. Roblox property names are unchecked until
-- the code runs (ScreenFrameScreens.spec.lua only mounts the empty panel), and most of this screen is
-- built only once data arrives.

local function rosterEntry(userId: number, name: string, isRequester: boolean): any
	return {
		UserId = userId,
		Name = name,
		DisplayName = name,
		CharacterName = nil,
		IsRequester = isRequester,
		Tier = 3,
		PingMs = 42,
		Alive = true,
		HealthFraction = 0.6,
		InCombat = not isRequester,
		Godmode = isRequester,
		Flying = false,
		Frozen = false,
		Invisible = false,
		SpeedMultiplier = 1,
		Muted = false,
		Flagged = not isRequester,
		Marked = false,
	}
end

local function inspection(userId: number, isRequester: boolean): any
	return {
		UserId = userId,
		Name = "tester",
		DisplayName = "Tester",
		AccountAgeDays = 400,
		IsRequester = isRequester,
		PingMs = 42,
		ProfileLoaded = true,
		CharacterName = "Lin Wei",
		RaceId = "Human",
		Faction = "Unbound",
		Tier = 3,
		TierName = "Third",
		MeridianXP = 1500,
		TierFloorXP = 1000,
		TierNextXP = 2000,
		Bloodlines = { { Id = "Test", Name = "Test Line", Stage = 2 } },
		BloodlineRerolls = 1,
		Corruption = 0,
		QiDeviationRisk = 0.2,
		EquippedArtCount = 2,
		Alive = true,
		Health = 60,
		MaxHealth = 100,
		Qi = 30,
		MaxQi = 50,
		Guard = 70,
		MaxGuard = 100,
		DefenseState = "Idle",
		Engagement = {
			InCombat = true,
			SecondsRemaining = 3,
			OpponentName = "DebugDummy",
			DamageDealt = 40,
			DamageTaken = 10,
			LastOutcomeKind = "Clean",
		},
		KillStreak = 2,
		Marked = false,
		Position = Vector3.new(1, 2, 3),
		Godmode = true,
		Flying = false,
		FlyCollide = false,
		Frozen = false,
		Invisible = false,
		SpeedMultiplier = 2,
		Muted = false,
		Flagged = false,
	}
end

local SERVER = {
	UptimeSeconds = 3600,
	PlayerCount = 2,
	MaxPlayers = 20,
	ServerFps = 60,
	WorstFrameMs = 18,
	MemoryMb = 1200,
	PlaceVersion = 10,
	LatestPlaceVersion = 11,
	JobId = "",
	IsStudio = true,
	OpenReports = 1,
	FlaggedCount = 1,
	EngagedCount = 1,
	HitboxVolumes = false,
	DummyGuard = true,
	DummyCount = 1,
	BotCount = 0,
}

local REPORT = {
	Id = "report-1",
	ReporterUserId = 202,
	ReporterName = "Other",
	Category = "Bug",
	Description = "Fell through the floor near the ferry.",
	CreatedAt = 1700000000,
	PlaceId = 1,
	JobId = "job",
	Position = Vector3.new(4, 5, 6),
	Status = "Open",
	Priority = "High",
	Notes = { { Id = "n1", AuthorUserId = 101, AuthorName = "Admin", Text = "Looking.", CreatedAt = 1700000100 } },
}

local function hasText(root: Instance, text: string): boolean
	for _, descendant in root:GetDescendants() do
		if (descendant:IsA("TextLabel") or descendant:IsA("TextButton")) and (descendant :: any).Text == text then
			return true
		end
	end
	return false
end

return function()
	local scope: any
	local parent: Instance
	local handle: any

	beforeEach(function()
		scope = Fusion.scoped(Fusion)
		parent = Instance.new("Folder")
		handle = DevMenu.Mount(scope, parent :: any)
	end)

	afterEach(function()
		scope:doCleanup()
		parent:Destroy()
	end)

	it("builds a roster row per player, and none twice across a poll", function()
		handle.Roster:set({ rosterEntry(101, "Admin", true), rosterEntry(202, "Other", false) })
		handle.Server:set(SERVER)
		expect(parent:FindFirstChild("Player_101", true)).to.be.ok()
		expect(parent:FindFirstChild("Player_202", true)).to.be.ok()

		local row = parent:FindFirstChild("Player_202", true)
		-- A second poll with fresh tables for the same players reuses the rows.
		handle.Roster:set({ rosterEntry(101, "Admin", true), rosterEntry(202, "Other", false) })
		expect(parent:FindFirstChild("Player_202", true)).to.equal(row)

		handle.Roster:set({ rosterEntry(101, "Admin", true) })
		expect(parent:FindFirstChild("Player_202", true)).never.to.be.ok()
	end)

	it("names the selected player on the plate, and ignores an inspection of anyone else", function()
		handle.SelectedUserId:set(101)
		handle.Inspection:set(inspection(101, true))
		expect(hasText(parent, "Tester  (you)")).to.equal(true)

		-- The selection moves on while an older answer is still arriving: it must not be shown.
		handle.SelectedUserId:set(202)
		expect(hasText(parent, "Tester  (you)")).to.equal(false)
		expect(hasText(parent, "Nobody selected")).to.equal(true)

		handle.Inspection:set(inspection(202, false))
		expect(hasText(parent, "Tester")).to.equal(true)
	end)

	it("lists the overrides the server reports on the inspected player", function()
		handle.SelectedUserId:set(101)
		handle.Inspection:set(inspection(101, true))
		expect(hasText(parent, "Godmode · Speed x2")).to.equal(true)
	end)

	it("builds report rows, flight fields and vehicle rows from data", function()
		handle.LocalUserId:set(101)
		handle.Reports:set({ REPORT })
		expect(parent:FindFirstChild("Report_report-1", true)).to.be.ok()

		handle.Flight:set({
			{ Field = "CruiseSpeed", DisplayName = "Cruise Speed", Value = 60, Min = 5, Max = 300, Default = 60 },
			{ Field = "BoostSpeedMultiplier", DisplayName = "Boost", Value = 2, Min = 1, Max = 5, Default = 2 },
		})
		expect(parent:FindFirstChild("CruiseSpeed", true)).to.be.ok()
		local field = parent:FindFirstChild("CruiseSpeed", true)
		-- A value change from the server does not rebuild the field under the slider.
		handle.Flight:set({
			{ Field = "CruiseSpeed", DisplayName = "Cruise Speed", Value = 80, Min = 5, Max = 300, Default = 60 },
			{ Field = "BoostSpeedMultiplier", DisplayName = "Boost", Value = 2, Min = 1, Max = 5, Default = 2 },
		})
		expect(parent:FindFirstChild("CruiseSpeed", true)).to.equal(field)

		handle.VehicleCatalog:set({
			{ Id = "Blimp", DisplayName = "Blimp", Kind = "Blimp", MaxLive = 2, FootprintStuds = 40, LiveCount = 2 },
		})
		handle.VehicleLive:set({
			{
				InstanceId = "v1",
				VehicleId = "Blimp",
				DisplayName = "Blimp",
				OwnerUserId = 101,
				OwnerName = "Admin",
				Position = Vector3.new(0, 10, 0),
				AgeSeconds = 90,
				Occupied = true,
				BerthName = nil,
			},
		})
		handle.VehicleBerths:set({ { Name = "Dock A", Accepts = { "Blimp" }, Occupied = false } })
		expect(parent:FindFirstChild("Catalog", true)).to.be.ok()
	end)

	it("switches tabs through the shared tab state", function()
		for _, name in { "World", "Server", "Reports", "Tuning", "Player" } do
			handle.CurrentTab:set(name)
			expect(handle.CurrentTab).to.be.ok()
		end
	end)
end
