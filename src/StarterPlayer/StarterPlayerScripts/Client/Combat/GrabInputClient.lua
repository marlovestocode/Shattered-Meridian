--!strict
--[[
	GrabInputClient.lua

	Owns: the LOCAL player's grab-throw input -- the GrabThrow key edge, sent only while this client
	can already see a hold is in progress -- and a small on-screen cue for both roles a hold can put a
	player in ("HOLDING -- [G] to throw" for the attacker, "GRABBED" for the victim).

	Same shape as Client/Combat/AttackInputClient.lua: DECIDES NOTHING about whether a throw is legal.
	Server/Combat/Grab/GrabSystem.lua is the sole authority on holds, throws and impacts; this module
	sends the press and presents whatever GrabSystem.Grab_HoldChanged says happened.

	THE ONE CLIENT-SIDE FILTER THIS MODULE APPLIES IS HONEST, not a guess. It declines to send
	Grab_Throw unless the local player's own Constants.Attributes.Grabbing Attribute is true -- the
	same "the client declines to send what it can already see is illegal" convention Shared/Parkour/
	ParkourOwnership.OwnsBody's own consumers already use. That Attribute is server-written and
	replicated, so this is not a prediction of server state, it is a read of it: a press sent while
	Grabbing is false would always be refused ("NotHolding") server-side regardless, so filtering it
	here costs nothing and saves a wasted round trip.

	THE CUE IS DELIBERATELY A PLAIN Instance-built ScreenGui, not a Screens/ Fusion component. Every
	other panel in this codebase's UI lives behind Client/UI/init.lua's session-long Fusion mount and
	its own uiHandles plumbing -- machinery sized for a real panel (a settings screen, a move editor, a
	whole HUD). A hold's cue is one line of text that toggles on and off with a boolean; wiring it
	through that system would be adding a Screen to grow a caption. If this cue ever needs to become
	richer (a countdown ring for the hold's own timer, an icon), THAT is the point to promote it into
	Screens/ -- not before.

	Does not own: whether a hold/throw is legal (GrabSystem), the hold/flight state machine itself, or
	the ordinary attack input this module sits next to (AttackInputClient.lua).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Constants = require(ReplicatedStorage.Shared.Constants)
local GrabConstants = require(ReplicatedStorage.Shared.Grab.GrabConstants)
local GrabTypes = require(ReplicatedStorage.Shared.Grab.GrabTypes)
local Logger = require(ReplicatedStorage.Shared.Logger)
local PlayerLifecycle = require(ReplicatedStorage.Shared.PlayerLifecycle)
local NetworkBridge = require(ReplicatedStorage.Shared.NetworkBridge)

local KeybindManager = require(script.Parent.Parent.Input.KeybindManager)

local logger = Logger.scope("GrabInputClient")

local GrabInputClient = {}

local started = false
local throwRemote: RemoteEvent? = nil
local boundHumanoid: Humanoid? = nil

-- Cue --------------------------------------------------------------------------------------------

local cueLabel: TextLabel? = nil

-- Built once, lazily, the first time a cue actually needs to show -- most players never grab or get
-- grabbed in a given life, and paying for a ScreenGui/TextLabel pair nobody ever sees would be waste
-- on every single client.
local function ensureCue(): TextLabel
	local label = cueLabel
	if label then
		return label
	end

	local gui = Instance.new("ScreenGui")
	gui.Name = "GrabCue"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 5

	local newLabel = Instance.new("TextLabel")
	newLabel.Name = "Cue"
	newLabel.AnchorPoint = Vector2.new(0.5, 0)
	newLabel.Position = UDim2.fromScale(0.5, 0.28)
	newLabel.Size = UDim2.fromOffset(320, 32)
	newLabel.BackgroundTransparency = 1
	newLabel.Font = Enum.Font.GothamBold
	newLabel.TextSize = 20
	newLabel.TextColor3 = Color3.fromRGB(255, 235, 200)
	newLabel.TextStrokeTransparency = 0.4
	newLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	newLabel.Text = ""
	newLabel.Visible = false
	newLabel.Parent = gui

	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")

	cueLabel = newLabel
	return newLabel
end

local function setCue(text: string?): ()
	local label = ensureCue()
	if text then
		label.Text = text
		label.Visible = true
	else
		label.Visible = false
	end
end

-- Sending -------------------------------------------------------------------------------------------

local function requestThrow(): ()
	local humanoid = boundHumanoid
	if not humanoid or humanoid:GetAttribute(Constants.Attributes.Grabbing) ~= true then
		-- Not currently holding anyone, as far as this client can already see -- see file header on
		-- why this is a read of replicated server state rather than a guess.
		return
	end
	local remote = throwRemote
	if not remote then
		logger:warn("Grab throw pressed before the throw remote was ready")
		return
	end
	remote:FireServer()
end

local function onInputBegan(input: InputObject, gameProcessed: boolean): ()
	if gameProcessed then
		return
	end
	if KeybindManager.Matches("GrabThrow", input) then
		requestThrow()
	end
end

-- Presentation ---------------------------------------------------------------------------------------

local function onHoldChanged(raw: unknown): ()
	if typeof(raw) ~= "table" then
		return
	end
	local payload = raw :: GrabTypes.GrabHoldChangedPayload
	if payload.Role ~= "Attacker" and payload.Role ~= "Victim" then
		return
	end

	if not payload.Active then
		setCue(nil)
		return
	end

	if payload.Role == "Attacker" then
		setCue("HOLDING -- [G] TO THROW")
	else
		setCue("GRABBED")
	end
end

-- Lifecycle ------------------------------------------------------------------------------------------

function GrabInputClient.Start(): ()
	if started then
		return
	end
	started = true

	throwRemote = NetworkBridge.GetRemoteEvent(GrabConstants.Network.RemoteNames.Throw)

	local holdChangedRemote = NetworkBridge.GetRemoteEvent(GrabConstants.Network.RemoteNames.HoldChanged)
	holdChangedRemote.OnClientEvent:Connect(onHoldChanged)

	UserInputService.InputBegan:Connect(onInputBegan)

	-- The Humanoid wait, the boot-thread task.spawn and the no-Humanoid warning all live in
	-- Shared/PlayerLifecycle.lua now -- this module's own comment about all three used to be one of
	-- the fifteen byte-identical copies of it. See that module's header.
	PlayerLifecycle.BindLocalCharacter({
		Scope = "GrabInputClient",
		OnCharacter = function(_character: Model, humanoid: Humanoid)
			boundHumanoid = humanoid
			-- A new life is never mid-hold -- GrabSystem's own Players.PlayerRemoving/Step sweeps
			-- already cleared any hold this player was part of when the previous character ended.
			setCue(nil)
		end,
		OnCharacterRemoving = function()
			boundHumanoid = nil
			setCue(nil)
		end,
	})

	logger:info("GrabInputClient started")
end

return GrabInputClient
