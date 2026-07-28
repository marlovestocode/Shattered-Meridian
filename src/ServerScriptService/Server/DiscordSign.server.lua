--!strict
--[[
	DiscordSign.server.lua

	Cosmetic-only: spawns a floating sign near the map's SpawnLocation crediting the developer's
	Discord handle. Not gameplay state, so it runs as its own Script rather than a System with an
	Init() wired into Main.server.lua's boot order.
]]

local Workspace = game:GetService("Workspace")

local DISCORD_HANDLE = "7th.warddragon"

local function findSpawnLocation(): BasePart?
	for _, instance in Workspace:GetDescendants() do
		if instance:IsA("SpawnLocation") then
			return instance
		end
	end
	return nil
end

local spawnLocation = findSpawnLocation()
local position = if spawnLocation then spawnLocation.Position + Vector3.new(0, 6, -8) else Vector3.new(0, 10, 0)

local sign = Instance.new("Part")
sign.Name = "DiscordSign"
sign.Size = Vector3.new(6, 3, 1)
sign.Anchored = true
sign.CanCollide = false
sign.Position = position
sign.Material = Enum.Material.SmoothPlastic
sign.Color = Color3.fromRGB(88, 101, 242)

local gui = Instance.new("SurfaceGui")
gui.Name = "DiscordSignGui"
gui.Face = Enum.NormalId.Front
gui.LightInfluence = 0
gui.Parent = sign

local label = Instance.new("TextLabel")
label.Size = UDim2.fromScale(1, 1)
label.BackgroundTransparency = 1
label.Font = Enum.Font.GothamBold
label.TextScaled = true
label.TextColor3 = Color3.new(1, 1, 1)
label.Text = "Discord: " .. DISCORD_HANDLE
label.Parent = gui

sign.Parent = Workspace
